using System.Net;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace AVCPublicAccess.Service;

public class Worker : BackgroundService
{
    private readonly ILogger<Worker> _logger;
    private readonly IHttpClientFactory _httpClientFactory;
    private readonly IConfiguration _configuration;

    private readonly object _sessionLock = new();

    private DateTime? _localSessionExpiresUtc;
    private long? _sessionEndTickCount64;
    private bool _expirationLogged;

    private HttpListener? _listener;

    private string _hostName = "";
    private string _serverAddress = "";
    private string _location = "";

    private DateTime _currentBootUtc;

    private const string LocalApiPrefix =
        "http://127.0.0.1:5051/";

    private static readonly string StateDirectory =
        Path.Combine(
            Environment.GetFolderPath(
                Environment.SpecialFolder.CommonApplicationData),
            "AVC",
            "PublicAccess");

    private static readonly string StateFile =
        Path.Combine(
            StateDirectory,
            "session-state.json");

    public Worker(
        ILogger<Worker> logger,
        IHttpClientFactory httpClientFactory,
        IConfiguration configuration)
    {
        _logger = logger;
        _httpClientFactory = httpClientFactory;
        _configuration = configuration;
    }

    protected override async Task ExecuteAsync(
        CancellationToken stoppingToken)
    {
        _hostName =
            Environment.MachineName.ToUpperInvariant();

        _serverAddress =
            _configuration["PublicAccess:ServerAddress"]
            ?? throw new InvalidOperationException(
                "PublicAccess:ServerAddress is not configured.");

        _serverAddress =
            _serverAddress.TrimEnd('/');

        _location =
            _configuration["PublicAccess:Location"] ?? "";

        var heartbeatSeconds =
            _configuration.GetValue<int>(
                "PublicAccess:HeartbeatSeconds",
                15);

        if (heartbeatSeconds < 5)
        {
            heartbeatSeconds = 5;
        }

        Directory.CreateDirectory(
            StateDirectory);

        _currentBootUtc =
            GetCurrentBootTimeUtc();

        _logger.LogInformation(
            "Current Windows boot UTC: {BootTime:O}",
            _currentBootUtc);

        LoadPersistentSession();

        _logger.LogInformation(
            "AVC Public Access Service starting.");

        _logger.LogInformation(
            "Computer: {HostName}",
            _hostName);

        _logger.LogInformation(
            "Server: {ServerAddress}",
            _serverAddress);

        _logger.LogInformation(
            "Location: {Location}",
            _location);

        _logger.LogInformation(
            "Local patron API: {LocalApi}",
            LocalApiPrefix);

        _logger.LogWarning(
            "SESSION ENFORCEMENT IS IN TEST MODE. " +
            "Expiration and End Session requests " +
            "will NOT reboot Windows.");

        var localApiTask =
            RunLocalApiAsync(
                stoppingToken);

        try
        {
            while (!stoppingToken.IsCancellationRequested)
            {
                CheckLocalExpiration();

                await SendHeartbeatAsync(
                    stoppingToken);

                CheckLocalExpiration();

                try
                {
                    await Task.Delay(
                        TimeSpan.FromSeconds(
                            heartbeatSeconds),
                        stoppingToken);
                }
                catch (OperationCanceledException)
                {
                    break;
                }
            }
        }
        finally
        {
            if (_listener != null)
            {
                try
                {
                    _listener.Stop();
                    _listener.Close();
                }
                catch
                {
                    // Service is shutting down.
                }
            }

            try
            {
                await localApiTask;
            }
            catch (OperationCanceledException)
            {
                // Normal shutdown.
            }
            catch (Exception ex)
            {
                _logger.LogDebug(
                    ex,
                    "Local API stopped during shutdown.");
            }

            _logger.LogInformation(
                "AVC Public Access Service stopping.");
        }
    }

    private async Task SendHeartbeatAsync(
        CancellationToken stoppingToken)
    {
        try
        {
            var client =
                _httpClientFactory.CreateClient();

            client.Timeout =
                TimeSpan.FromSeconds(10);

            var heartbeat = new
            {
                HostName = _hostName,
                Location = _location
            };

            var response =
                await client.PostAsJsonAsync(
                    $"{_serverAddress}/api/computers/heartbeat",
                    heartbeat,
                    stoppingToken);

            if (!response.IsSuccessStatusCode)
            {
                _logger.LogWarning(
                    "Heartbeat failed. " +
                    "Server returned {StatusCode}",
                    response.StatusCode);

                return;
            }

            var serverState =
                await response.Content
                    .ReadFromJsonAsync<HeartbeatResponse>(
                        cancellationToken:
                            stoppingToken);

            if (serverState != null)
            {
                ProcessServerState(
                    serverState);
            }

            _logger.LogInformation(
                "Heartbeat successful for {HostName}",
                _hostName);
        }
        catch (OperationCanceledException)
            when (stoppingToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception ex)
        {
            _logger.LogWarning(
                "Unable to contact AVC Public Access Server: {Message}",
                ex.Message);
        }
    }

    private void ProcessServerState(
        HeartbeatResponse serverState)
    {
        if (!serverState.Status.Equals(
                "In Use",
                StringComparison.OrdinalIgnoreCase) ||
            !serverState.SessionExpiresUtc.HasValue)
        {
            return;
        }

        var serverExpiration =
            DateTime.SpecifyKind(
                serverState.SessionExpiresUtc.Value,
                DateTimeKind.Utc);

        var serverNow =
            DateTime.SpecifyKind(
                serverState.ServerTimeUtc,
                DateTimeKind.Utc);

        var remainingSeconds =
            Math.Max(
                0,
                (serverExpiration - serverNow)
                    .TotalSeconds);

        lock (_sessionLock)
        {
            // Once this local session has expired, heartbeat
            // reconciliation must never resurrect it.
            //
            // In production the machine will reboot at expiration.
            // In TEST mode we intentionally preserve the Expired
            // state so it can be verified safely.
            if (_expirationLogged)
            {
                return;
            }

            if (_localSessionExpiresUtc.HasValue &&
                _localSessionExpiresUtc.Value ==
                    serverExpiration &&
                _sessionEndTickCount64.HasValue)
            {
                return;
            }

            _localSessionExpiresUtc =
                serverExpiration;

            _sessionEndTickCount64 =
                Environment.TickCount64 +
                (long)Math.Ceiling(
                    remainingSeconds * 1000.0);

            _expirationLogged = false;

            SavePersistentSessionLocked();

            _logger.LogWarning(
                "ACTIVE SESSION DETECTED. " +
                "Expires UTC: {Expiration:O}. " +
                "Authoritative remaining: {Minutes:F1} minutes.",
                serverExpiration,
                remainingSeconds / 60.0);
        }
    }
    private void CheckLocalExpiration()
    {
        lock (_sessionLock)
        {
            if (!_localSessionExpiresUtc.HasValue ||
                !_sessionEndTickCount64.HasValue)
            {
                return;
            }

            if (_sessionEndTickCount64.Value >
                Environment.TickCount64)
            {
                return;
            }

            if (_expirationLogged)
            {
                return;
            }

            _expirationLogged = true;

            _logger.LogCritical(
                "SESSION EXPIRED. " +
                "Production enforcement would " +
                "force a Windows reboot now.");

            //
            // IMPORTANT:
            // Do NOT clear the persistent session here.
            //
            // In production the reboot/boot-confirmation
            // workflow will clear it. Keeping it now lets
            // us verify that restarting this service does
            // not bypass an expired session.
            //
        }
    }
    private async Task RunLocalApiAsync(
        CancellationToken stoppingToken)
    {
        _listener =
            new HttpListener();

        _listener.Prefixes.Add(
            LocalApiPrefix);

        try
        {
            _listener.Start();

            _logger.LogInformation(
                "Local patron API listening on {Prefix}",
                LocalApiPrefix);
        }
        catch (Exception ex)
        {
            _logger.LogCritical(
                ex,
                "Unable to start local patron API.");

            return;
        }

        while (!stoppingToken.IsCancellationRequested)
        {
            HttpListenerContext context;

            try
            {
                context =
                    await _listener.GetContextAsync()
                        .WaitAsync(
                            stoppingToken);
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (HttpListenerException)
                when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
            catch (ObjectDisposedException)
            {
                break;
            }
            catch (Exception ex)
            {
                _logger.LogWarning(
                    ex,
                    "Local API listener error.");

                continue;
            }

            _ = HandleLocalRequestAsync(
                context,
                stoppingToken);
        }
    }

    private async Task HandleLocalRequestAsync(
        HttpListenerContext context,
        CancellationToken stoppingToken)
    {
        try
        {
            //
            // Defense in depth:
            // only accept loopback callers.
            //
            if (context.Request.RemoteEndPoint == null ||
                !IPAddress.IsLoopback(
                    context.Request.RemoteEndPoint.Address))
            {
                await WriteJsonAsync(
                    context,
                    403,
                    new
                    {
                        error =
                            "Local access only."
                    },
                    stoppingToken);

                return;
            }

            var path =
                context.Request.Url?.AbsolutePath
                    .TrimEnd('/')
                    .ToLowerInvariant()
                ?? "";

            if (context.Request.HttpMethod == "GET" &&
                path == "/status")
            {
                await HandleStatusAsync(
                    context,
                    stoppingToken);

                return;
            }

            if (context.Request.HttpMethod == "POST" &&
                path == "/redeem")
            {
                await HandleRedeemAsync(
                    context,
                    stoppingToken);

                return;
            }

            if (context.Request.HttpMethod == "POST" &&
                path == "/end")
            {
                await HandleEndSessionAsync(
                    context,
                    stoppingToken);

                return;
            }

            await WriteJsonAsync(
                context,
                404,
                new
                {
                    error = "Not found."
                },
                stoppingToken);
        }
        catch (Exception ex)
        {
            _logger.LogError(
                ex,
                "Error processing local API request.");

            try
            {
                await WriteJsonAsync(
                    context,
                    500,
                    new
                    {
                        error =
                            "Internal service error."
                    },
                    stoppingToken);
            }
            catch
            {
                // Client may have disconnected.
            }
        }
        finally
        {
            try
            {
                context.Response.Close();
            }
            catch
            {
                // Ignore close errors.
            }
        }
    }

    private Task HandleStatusAsync(
        HttpListenerContext context,
        CancellationToken stoppingToken)
    {
        DateTime? expiration;
        double? remainingSeconds;
        bool expired;

        lock (_sessionLock)
        {
            expiration =
                _localSessionExpiresUtc;

            if (expiration.HasValue &&
                _sessionEndTickCount64.HasValue)
            {
                remainingSeconds =
                    Math.Max(
                        0,
                        (_sessionEndTickCount64.Value -
                            Environment.TickCount64) /
                        1000.0);

                expired =
                    remainingSeconds <= 0;
            }
            else
            {
                remainingSeconds = null;
                expired = false;
            }
        }

        var status =
            expiration.HasValue
                ? expired
                    ? "Expired"
                    : "In Use"
                : "Available";

        return WriteJsonAsync(
            context,
            200,
            new
            {
                HostName = _hostName,
                Status = status,
                SessionExpiresUtc =
                    expiration,
                RemainingSeconds =
                    remainingSeconds,
                TestMode = true,
                ServerTimeUtc =
                    DateTime.UtcNow
            },
            stoppingToken);
    }
    private async Task HandleRedeemAsync(
        HttpListenerContext context,
        CancellationToken stoppingToken)
    {
        RedeemLocalRequest? request;

        try
        {
            request =
                await JsonSerializer.DeserializeAsync
                    <RedeemLocalRequest>(
                        context.Request.InputStream,
                        JsonOptions,
                        stoppingToken);
        }
        catch (JsonException)
        {
            await WriteJsonAsync(
                context,
                400,
                new
                {
                    error =
                        "Invalid request."
                },
                stoppingToken);

            return;
        }

        var code =
            request?.Code?.Trim() ?? "";

        if (code.Length != 6 ||
            !code.All(char.IsDigit))
        {
            await WriteJsonAsync(
                context,
                400,
                new
                {
                    error =
                        "Enter a valid six-digit access code."
                },
                stoppingToken);

            return;
        }

        DateTime? existingSession;

        lock (_sessionLock)
        {
            existingSession = _localSessionExpiresUtc;
        }

        if (existingSession.HasValue)
        {
            bool existingExpired;

            lock (_sessionLock)
            {
                existingExpired =
                    !_sessionEndTickCount64.HasValue ||
                    _sessionEndTickCount64.Value <=
                        Environment.TickCount64;
            }

            var status =
                existingExpired
                    ? "expired"
                    : "active";

            await WriteJsonAsync(
                context,
                409,
                new
                {
                    error = $"This computer already has an {status} session."
                },
                stoppingToken);

            return;
        }

        try
        {
            var client =
                _httpClientFactory.CreateClient();

            client.Timeout =
                TimeSpan.FromSeconds(10);

            var serverRequest = new
            {
                HostName = _hostName,
                Code = code
            };

            var response =
                await client.PostAsJsonAsync(
                    $"{_serverAddress}/api/sessions/redeem",
                    serverRequest,
                    stoppingToken);

            var responseText =
                await response.Content
                    .ReadAsStringAsync(
                        stoppingToken);

            if (!response.IsSuccessStatusCode)
            {
                string errorMessage =
                    "The access code could not be redeemed.";

                try
                {
                    var error =
                        JsonSerializer.Deserialize
                            <ServerErrorResponse>(
                                responseText,
                                JsonOptions);

                    if (!string.IsNullOrWhiteSpace(
                            error?.Error))
                    {
                        errorMessage =
                            error.Error;
                    }
                }
                catch
                {
                    // Use generic message.
                }

                await WriteJsonAsync(
                    context,
                    (int)response.StatusCode,
                    new
                    {
                        error =
                            errorMessage
                    },
                    stoppingToken);

                return;
            }

            var session =
                JsonSerializer.Deserialize
                    <RedeemServerResponse>(
                        responseText,
                        JsonOptions);

            if (session == null ||
                !session.Success)
            {
                await WriteJsonAsync(
                    context,
                    502,
                    new
                    {
                        error =
                            "Server returned an invalid session response."
                    },
                    stoppingToken);

                return;
            }

            var expiration =
                DateTime.SpecifyKind(
                    session.SessionExpiresUtc,
                    DateTimeKind.Utc);

            lock (_sessionLock)
            {
                _localSessionExpiresUtc =
                    expiration;

                _sessionEndTickCount64 =
                    Environment.TickCount64 +
                    (long)TimeSpan
                        .FromMinutes(
                            session.DurationMinutes)
                        .TotalMilliseconds;

                _expirationLogged = false;

                SavePersistentSessionLocked();
            }

            _logger.LogWarning(
                "SESSION STARTED through local patron API. " +
                "Duration: {Minutes} minutes. " +
                "Expires UTC: {Expiration:O}",
                session.DurationMinutes,
                expiration);

            await WriteJsonAsync(
                context,
                200,
                new
                {
                    Success = true,
                    HostName = _hostName,
                    DurationMinutes =
                        session.DurationMinutes,
                    SessionExpiresUtc =
                        expiration,
                    TestMode = true
                },
                stoppingToken);
        }
        catch (OperationCanceledException)
            when (stoppingToken.IsCancellationRequested)
        {
            throw;
        }
        catch (LocalSessionException ex)
        {
            await WriteJsonAsync(
                context,
                409,
                new
                {
                    error = ex.Message
                },
                stoppingToken);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(
                ex,
                "Unable to redeem access code.");

            await WriteJsonAsync(
                context,
                503,
                new
                {
                    error =
                        "Unable to contact the public access server."
                },
                stoppingToken);
        }
    }

    private async Task HandleEndSessionAsync(
        HttpListenerContext context,
        CancellationToken stoppingToken)
    {
        DateTime? expiration;

        lock (_sessionLock)
        {
            expiration =
                _localSessionExpiresUtc;
        }

        if (!expiration.HasValue)
        {
            await WriteJsonAsync(
                context,
                409,
                new
                {
                    error =
                        "There is no active session."
                },
                stoppingToken);

            return;
        }

        _logger.LogCritical(
            "END SESSION REQUESTED. " +
            "Production enforcement would force " +
            "a Windows reboot now.");

        //
        // TEST MODE:
        // Do not reboot and do not clear the
        // persistent session.
        //

        await WriteJsonAsync(
            context,
            200,
            new
            {
                Success = true,
                Message =
                    "End Session received. " +
                    "TEST MODE - Windows was not rebooted.",
                TestMode = true
            },
            stoppingToken);
    }

    private void LoadPersistentSession()
    {
        if (!File.Exists(StateFile))
        {
            return;
        }

        try
        {
            var json =
                File.ReadAllText(
                    StateFile);

            var state =
                JsonSerializer.Deserialize
                    <PersistentSessionState>(
                        json,
                        JsonOptions);

            if (state?.SessionExpiresUtc == null)
            {
                return;
            }

            _localSessionExpiresUtc =
                DateTime.SpecifyKind(
                    state.SessionExpiresUtc.Value,
                    DateTimeKind.Utc);

            _sessionEndTickCount64 =
                state.SessionEndTickCount64;

            if (!_sessionEndTickCount64.HasValue)
            {
                //
                // Legacy state has no monotonic deadline.
                // Fail closed rather than deriving time
                // from the workstation clock.
                //
                _sessionEndTickCount64 =
                    Environment.TickCount64;
            }

            _expirationLogged = false;

            _logger.LogWarning(
                "Persistent session restored. " +
                "Expiration UTC: {Expiration:O}",
                _localSessionExpiresUtc);

            if (!state.BootTimeUtc.HasValue)
            {
                _logger.LogWarning(
                    "Persistent session has no boot identity. " +
                    "Treating it as legacy state and preserving it.");
            }
            else
            {
                var savedBootUtc =
                    DateTime.SpecifyKind(
                        state.BootTimeUtc.Value,
                        DateTimeKind.Utc);

                var sameBoot =
                    Math.Abs(
                        (savedBootUtc - _currentBootUtc)
                        .TotalSeconds) < 5;

                if (sameBoot)
                {
                    _logger.LogInformation(
                        "Persistent session belongs to the " +
                        "current Windows boot.");
                }
                else
                {
                    _logger.LogWarning(
                        "BOOT CHANGE DETECTED. " +
                        "Saved boot UTC: {SavedBoot:O}. " +
                        "Current boot UTC: {CurrentBoot:O}.",
                        savedBootUtc,
                        _currentBootUtc);

                    _logger.LogWarning(
                        "Windows has restarted since the previous session. " +
                        "Clearing the completed local session state.");

                    _localSessionExpiresUtc = null;
                    _sessionEndTickCount64 = null;
                    _expirationLogged = false;

                    try
                    {
                        File.Delete(StateFile);

                        _logger.LogInformation(
                            "Previous session state cleared after confirmed Windows reboot.");
                    }
                    catch (Exception ex)
                    {
                        _logger.LogError(
                            ex,
                            "Unable to clear previous session state after reboot.");

                        throw;
                    }
                }
            }
        }
        catch (Exception ex)
        {
            _logger.LogError(
                ex,
                "Unable to load persistent session state.");

            //
            // Fail closed:
            // do not silently delete an unreadable
            // session-state file.
            //
        }
    }

    private static DateTime GetCurrentBootTimeUtc()
    {
        var uptime =
            TimeSpan.FromMilliseconds(
                Environment.TickCount64);

        return DateTime.UtcNow - uptime;
    }

    private void SavePersistentSessionLocked()
    {
        Directory.CreateDirectory(
            StateDirectory);

        var state =
            new PersistentSessionState
            {
                HostName = _hostName,
                SessionExpiresUtc =
                    _localSessionExpiresUtc,
                SessionEndTickCount64 =
                    _sessionEndTickCount64,
                BootTimeUtc =
                    _currentBootUtc
            };

        var json =
            JsonSerializer.Serialize(
                state,
                JsonOptions);

        var temporaryFile =
            StateFile + ".tmp";

        File.WriteAllText(
            temporaryFile,
            json);

        File.Move(
            temporaryFile,
            StateFile,
            true);
    }

    private static async Task WriteJsonAsync(
        HttpListenerContext context,
        int statusCode,
        object value,
        CancellationToken stoppingToken)
    {
        var json =
            JsonSerializer.Serialize(
                value,
                JsonOptions);

        var bytes =
            Encoding.UTF8.GetBytes(
                json);

        context.Response.StatusCode =
            statusCode;

        context.Response.ContentType =
            "application/json; charset=utf-8";

        context.Response.ContentEncoding =
            Encoding.UTF8;

        context.Response.ContentLength64 =
            bytes.Length;

        await context.Response.OutputStream
            .WriteAsync(
                bytes,
                stoppingToken);
    }

    private static readonly JsonSerializerOptions
        JsonOptions =
            new(JsonSerializerDefaults.Web)
            {
                WriteIndented = true
            };

    private sealed class RedeemLocalRequest
    {
        public string Code { get; set; } = "";
    }

    private sealed class PersistentSessionState
    {
        public string HostName { get; set; } = "";
        public DateTime? SessionExpiresUtc { get; set; }
        public long? SessionEndTickCount64 { get; set; }
        public DateTime? BootTimeUtc { get; set; }
    }

    private sealed class HeartbeatResponse
    {
        [JsonPropertyName("hostName")]
        public string HostName { get; set; } = "";

        [JsonPropertyName("status")]
        public string Status { get; set; } = "";

        [JsonPropertyName("sessionExpiresUtc")]
        public DateTime? SessionExpiresUtc { get; set; }

        [JsonPropertyName("serverTimeUtc")]
        public DateTime ServerTimeUtc { get; set; }
    }

    private sealed class RedeemServerResponse
    {
        [JsonPropertyName("success")]
        public bool Success { get; set; }

        [JsonPropertyName("hostName")]
        public string HostName { get; set; } = "";

        [JsonPropertyName("durationMinutes")]
        public int DurationMinutes { get; set; }

        [JsonPropertyName("sessionStartedUtc")]
        public DateTime SessionStartedUtc { get; set; }

        [JsonPropertyName("sessionExpiresUtc")]
        public DateTime SessionExpiresUtc { get; set; }

        [JsonPropertyName("serverTimeUtc")]
        public DateTime ServerTimeUtc { get; set; }
    }

    private sealed class ServerErrorResponse
    {
        [JsonPropertyName("error")]
        public string Error { get; set; } = "";
    }

    private sealed class LocalSessionException
        : Exception
    {
        public LocalSessionException(
            string message)
            : base(message)
        {
        }
    }
}

