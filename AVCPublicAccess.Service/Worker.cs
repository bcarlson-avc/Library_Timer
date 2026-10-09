using System.Net;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Extensions.Hosting.WindowsServices;

namespace AVCPublicAccess.Service;

public class Worker : BackgroundService
{
    private readonly ILogger<Worker> _logger;
    private readonly IHttpClientFactory _httpClientFactory;
    private readonly IConfiguration _configuration;

    private readonly SessionEnforcement _session;
    private readonly SemaphoreSlim _redeemGate = new(1, 1);
    private readonly TaskCompletionSource _requestFailure =
        new(TaskCreationOptions.RunContinuationsAsynchronously);
    private HttpListener? _listener;
    private string _hostName = "";
    private string _serverAddress = "";
    private string _location = "";
    private bool _unownedSessionLogged;

    private const string LocalApiPrefix =
        "http://127.0.0.1:5051/";

    public Worker(
        ILogger<Worker> logger,
        IHttpClientFactory httpClientFactory,
        IConfiguration configuration,
        SessionEnforcement session)
    {
        _logger = logger;
        _httpClientFactory = httpClientFactory;
        _configuration = configuration;
        _session = session;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(stoppingToken);
        var tasks = new List<Task>();
        try
        {
            _hostName = Environment.MachineName.ToUpperInvariant();
            _serverAddress = (_configuration["PublicAccess:ServerAddress"] ??
                throw new InvalidOperationException("PublicAccess:ServerAddress is not configured."))
                .TrimEnd('/');
            _location = _configuration["PublicAccess:Location"] ?? "";
            var heartbeatSeconds = Math.Max(5,
                _configuration.GetValue<int>("PublicAccess:HeartbeatSeconds", 15));

            _session.Initialize(_hostName);
            tasks.Add(RunLocalApiAsync(lifetime.Token));
            tasks.Add(RunExpirationAsync(lifetime.Token));
            tasks.Add(RunHeartbeatAsync(heartbeatSeconds, lifetime.Token));
            var completed = await Task.WhenAny(tasks.Append(_requestFailure.Task));
            await completed;
            if (!stoppingToken.IsCancellationRequested)
                throw new FatalServiceException("A required Service loop stopped unexpectedly.");
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
        {
            // Normal Windows Service shutdown; persisted enforcement is retained.
        }
        catch (Exception ex)
        {
            _logger.LogCritical(ex, "Service startup/readiness or enforcement failure; exiting unsuccessfully.");
            Environment.ExitCode = 1;
            // A Windows Service must exit unsuccessfully for SCM recovery to see a failure.
            if (WindowsServiceHelpers.IsWindowsService()) Environment.Exit(1);
            throw;
        }
        finally
        {
            lifetime.Cancel();
            try { _listener?.Close(); } catch { /* Listener is already closing. */ }
            try { await Task.WhenAll(tasks).WaitAsync(TimeSpan.FromSeconds(5)); }
            catch (Exception) { /* The original failure above is the authoritative one. */ }
            _logger.LogInformation("AVC Public Access Service stopping.");
        }
    }

    private async Task RunExpirationAsync(CancellationToken stoppingToken)
    {
        // No heartbeat, HTTP request, or Server response participates in this loop.
        while (!stoppingToken.IsCancellationRequested)
        {
            await _session.CheckAsync(stoppingToken);
            await Task.Delay(TimeSpan.FromMilliseconds(250), stoppingToken);
        }
    }

    private async Task RunHeartbeatAsync(int heartbeatSeconds, CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            await SendHeartbeatAsync(stoppingToken);
            await Task.Delay(TimeSpan.FromSeconds(heartbeatSeconds), stoppingToken);
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

    private void ProcessServerState(HeartbeatResponse serverState)
    {
        if (!serverState.Status.Equals("In Use", StringComparison.OrdinalIgnoreCase) ||
            !serverState.SessionExpiresUtc.HasValue) return;

        var local = _session.Snapshot();
        if (!local.ExpiresUtc.HasValue)
        {
            // A Server heartbeat may still describe the previous patron after reboot.
            // Only a successful local redemption establishes a new local session.
            if (!_unownedSessionLogged)
            {
                _logger.LogWarning("Server reports a session without current-boot local state. " +
                    "It will not be resurrected from a heartbeat.");
                _unownedSessionLogged = true;
            }
            return;
        }
        if (local.ExpiresUtc != DateTime.SpecifyKind(serverState.SessionExpiresUtc.Value, DateTimeKind.Utc))
            _logger.LogWarning("Server session differs from authoritative local session; local deadline retained.");
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

            throw new FatalServiceException("Local patron API listener failed to start.", ex);
        }

        _logger.LogInformation("Service ready. Reboot enforcement enabled; local API: {Prefix}.", LocalApiPrefix);
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
            catch (ObjectDisposedException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                _logger.LogCritical(ex, "Local API listener failed.");
                throw new FatalServiceException("Local API listener failed.", ex);
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
        catch (FatalServiceException ex)
        {
            _logger.LogCritical(ex, "Local API encountered an authoritative state failure.");
            _requestFailure.TrySetException(ex);
            try
            {
                await WriteJsonAsync(context, 503,
                    new { error = "The session service is unavailable." }, stoppingToken);
            }
            catch { /* The client may have disconnected. */ }
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
        var session = _session.Snapshot();
        var expiration = session.ExpiresUtc;
        var remainingSeconds = session.RemainingSeconds;
        var status = expiration.HasValue
            ? remainingSeconds <= 0 ? "Expired" : "In Use"
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
                TestMode = false,
                ServerTimeUtc =
                    DateTime.UtcNow
            },
            stoppingToken);
    }
    private async Task HandleRedeemAsync(HttpListenerContext context, CancellationToken stoppingToken)
    {
        await _redeemGate.WaitAsync(stoppingToken);
        try { await HandleRedeemCoreAsync(context, stoppingToken); }
        finally { _redeemGate.Release(); }
    }

    private async Task HandleRedeemCoreAsync(
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

        var existingSession = _session.Snapshot();
        if (existingSession.ExpiresUtc.HasValue)
        {
            var existingExpired = existingSession.RemainingSeconds <= 0;

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

            if (session == null || !session.Success || session.DurationMinutes <= 0 ||
                session.SessionExpiresUtc == default)
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

            if (!_session.TryStart(expiration,
                TimeSpan.FromMinutes(session.DurationMinutes).TotalSeconds))
            {
                throw new LocalSessionException("This computer already has a session.");
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
                    TestMode = false
                },
                stoppingToken);
        }
        catch (OperationCanceledException)
            when (stoppingToken.IsCancellationRequested)
        {
            throw;
        }
        catch (FatalServiceException) { throw; }
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
        HttpListenerContext context, CancellationToken stoppingToken)
    {
        if (!_session.RequestEnd())
        {
            await WriteJsonAsync(context, 409,
                new { error = "There is no active session." }, stoppingToken);
            return;
        }

        // The independent enforcement loop issues the one shared reboot workflow.
        await WriteJsonAsync(context, 200, new
        {
            Success = true,
            Message = "Session ended. The computer will now reboot.",
            TestMode = false
        }, stoppingToken);
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

