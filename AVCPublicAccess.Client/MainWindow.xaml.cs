using System.Net.Http;
using System.Net.Http.Json;
using System.Text.Json.Serialization;
using System.Windows;
using System.Windows.Input;
using System.Windows.Threading;

namespace AVCPublicAccess.Client;

public partial class MainWindow : Window
{
    private const string LocalServiceAddress =
        "http://127.0.0.1:5051";

    private readonly HttpClient _httpClient;
    private readonly DispatcherTimer _displayTimer;
    private readonly DispatcherTimer _serviceTimer;
    private readonly DispatcherTimer _warningTimer;

    private SessionTimerWindow? _sessionTimerWindow;

    private DateTime? _sessionExpiresUtc;
    private bool _expiredViewShown;

    private bool _tenMinuteWarningShown;
    private bool _fiveMinuteWarningShown;
    private bool _oneMinuteWarningShown;

    private double? _previousRemainingSeconds;

    public MainWindow()
    {
        InitializeComponent();

        _httpClient = new HttpClient
        {
            Timeout = TimeSpan.FromSeconds(5)
        };

        _displayTimer = new DispatcherTimer
        {
            Interval = TimeSpan.FromSeconds(1)
        };

        _displayTimer.Tick += DisplayTimer_Tick;

        _serviceTimer = new DispatcherTimer
        {
            Interval = TimeSpan.FromSeconds(5)
        };

        _serviceTimer.Tick += ServiceTimer_Tick;

        _warningTimer = new DispatcherTimer
        {
            Interval = TimeSpan.FromSeconds(8)
        };

        _warningTimer.Tick += WarningTimer_Tick;

        Loaded += MainWindow_Loaded;
        Closed += MainWindow_Closed;
        Closing += MainWindow_Closing;
    }

    private async void MainWindow_Loaded(
        object sender,
        RoutedEventArgs e)
    {
        ComputerNameText.Text =
            $"Computer: {Environment.MachineName.ToUpperInvariant()}";

        _displayTimer.Start();
        _serviceTimer.Start();

        await RefreshServiceStatusAsync();

        if (AccessCodeView.Visibility == Visibility.Visible)
        {
            CodeTextBox.Focus();
        }
    }

    private void MainWindow_Closing(
        object? sender,
        System.ComponentModel.CancelEventArgs e)
    {
        // Public computers must not allow the patron to close the
        // access window and reach the Windows desktop.
        e.Cancel = true;

        WindowState = WindowState.Maximized;
        Topmost = true;
        Activate();
        Focus();
    }
    private void MainWindow_Closed(
        object? sender,
        EventArgs e)
    {
        CloseFloatingTimer();

        _displayTimer.Stop();
        _serviceTimer.Stop();
        _warningTimer.Stop();

        _httpClient.Dispose();
    }

    private async void ServiceTimer_Tick(
        object? sender,
        EventArgs e)
    {
        await RefreshServiceStatusAsync();
    }

    private void DisplayTimer_Tick(
        object? sender,
        EventArgs e)
    {
        UpdateCountdown();
    }

    private void WarningTimer_Tick(
        object? sender,
        EventArgs e)
    {
        _warningTimer.Stop();

        WarningBanner.Visibility =
            Visibility.Collapsed;
    }

    private async Task RefreshServiceStatusAsync()
    {
        try
        {
            var status =
                await _httpClient.GetFromJsonAsync<ServiceStatusResponse>(
                    $"{LocalServiceAddress}/status");

            if (status == null)
            {
                ShowServiceUnavailable(
                    "The session service returned an invalid response.");

                return;
            }

            ServiceStatusText.Text =
                "Session service connected";

            if (!string.IsNullOrWhiteSpace(status.HostName))
            {
                ComputerNameText.Text =
                    $"Computer: {status.HostName}";
            }

            if (status.Status.Equals(
                    "In Use",
                    StringComparison.OrdinalIgnoreCase) &&
                status.RemainingSeconds.HasValue)
            {
                var remainingSeconds =
                    Math.Max(
                        0,
                        status.RemainingSeconds.Value);

                var newExpiration =
                    DateTime.UtcNow.AddSeconds(
                        remainingSeconds);

                if (!_sessionExpiresUtc.HasValue)
                {
                    ResetWarnings();
                }

                _sessionExpiresUtc = newExpiration;
                _expiredViewShown = false;

                ShowSessionView();
                EnsureFloatingTimer();
                UpdateCountdown();

                return;
            }

            if (status.Status.Equals(
                    "Expired",
                    StringComparison.OrdinalIgnoreCase))
            {
                if (status.SessionExpiresUtc.HasValue)
                {
                    _sessionExpiresUtc =
                        DateTime.SpecifyKind(
                            status.SessionExpiresUtc.Value,
                            DateTimeKind.Utc);
                }

                ShowExpiredView();

                return;
            }

            if (status.Status.Equals(
                    "Available",
                    StringComparison.OrdinalIgnoreCase))
            {
                _sessionExpiresUtc = null;
                _expiredViewShown = false;

                ResetWarnings();
                CloseFloatingTimer();
                ShowAccessCodeView();

                return;
            }

            ServiceStatusText.Text =
                $"Service status: {status.Status}";
        }
        catch
        {
            ShowServiceUnavailable(
                "Unable to contact the local session service.");
        }
    }

    private void ResetWarnings()
    {
        _tenMinuteWarningShown = false;
        _fiveMinuteWarningShown = false;
        _oneMinuteWarningShown = false;

        _previousRemainingSeconds = null;

        _warningTimer.Stop();

        WarningBanner.Visibility =
            Visibility.Collapsed;
    }

    private void ShowServiceUnavailable(
        string message)
    {
        if (AccessCodeView.Visibility ==
            Visibility.Visible)
        {
            ServiceStatusText.Text =
                "Session service unavailable";

            ErrorText.Text = message;

            StartSessionButton.IsEnabled = false;
        }
        else
        {
            SessionStatusText.Text =
                "Session service temporarily unavailable. " +
                "Your session timer remains active.";
        }
    }

    private void ShowAccessCodeView()
    {
        CloseFloatingTimer();

        AccessCodeView.Visibility =
            Visibility.Visible;

        SessionView.Visibility =
            Visibility.Collapsed;

        ExpiredView.Visibility =
            Visibility.Collapsed;

        ErrorText.Text = "";

        StartSessionButton.IsEnabled =
            CodeTextBox.Text.Length == 6;

        // Restore the main window when waiting for a patron code.
        if (!IsVisible)
        {
            Show();
        }

        WindowState = WindowState.Maximized;

        // Bring the access-code screen in front of other applications.
        Topmost = true;
        Activate();
        Focus();

        if (IsLoaded)
        {
            CodeTextBox.Focus();
        }
    }

    private void ShowSessionView()
    {
        AccessCodeView.Visibility =
            Visibility.Collapsed;

        SessionView.Visibility =
            Visibility.Collapsed;

        ExpiredView.Visibility =
            Visibility.Collapsed;

        SessionStatusText.Text =
            "Session service connected";

        EnsureFloatingTimer();

        if (IsVisible)
        {
            Hide();
        }
    }

    private void ShowExpiredView()
    {
        if (_expiredViewShown)
        {
            CloseFloatingTimer();
            return;
        }

        _expiredViewShown = true;

        CloseFloatingTimer();

        _warningTimer.Stop();

        WarningBanner.Visibility =
            Visibility.Collapsed;

        AccessCodeView.Visibility =
            Visibility.Collapsed;

        SessionView.Visibility =
            Visibility.Collapsed;

        ExpiredView.Visibility =
            Visibility.Visible;

        if (!IsVisible)
        {
            Show();
        }

        WindowState = WindowState.Maximized;

        Topmost = true;
        Activate();
        Focus();
    }

    private void EnsureFloatingTimer()
    {
        if (_sessionTimerWindow != null)
        {
            if (!_sessionTimerWindow.IsVisible)
            {
                _sessionTimerWindow.Show();
            }

            return;
        }

        _sessionTimerWindow =
            new SessionTimerWindow();

        _sessionTimerWindow.Show();
    }

    private void CloseFloatingTimer()
    {
        if (_sessionTimerWindow == null)
        {
            return;
        }

        try
        {
            _sessionTimerWindow.CloseForSessionEnd();
        }
        catch
        {
            // Ignore cleanup errors during shutdown.
        }

        _sessionTimerWindow = null;
    }

    private void UpdateCountdown()
    {
        if (!_sessionExpiresUtc.HasValue)
        {
            return;
        }

        var remaining =
            _sessionExpiresUtc.Value -
            DateTime.UtcNow;

        if (remaining <= TimeSpan.Zero)
        {
            RemainingTimeText.Text = "00:00";

            if (_sessionTimerWindow != null)
            {
                _sessionTimerWindow.UpdateTime(
                    TimeSpan.Zero);
            }

            // Show the full-screen expiration view immediately.
            // The service remains authoritative for the actual
            // session expiration and reboot.
            ShowExpiredView();

            return;
        }

        string displayTime;

        if (remaining.TotalHours >= 1)
        {
            displayTime =
                $"{(int)remaining.TotalHours}:" +
                $"{remaining.Minutes:00}:" +
                $"{remaining.Seconds:00}";
        }
        else
        {
            displayTime =
                $"{remaining.Minutes:00}:" +
                $"{remaining.Seconds:00}";
        }

        RemainingTimeText.Text =
            displayTime;

        EnsureFloatingTimer();

        _sessionTimerWindow?.UpdateTime(
            remaining);

        CheckSessionWarnings(remaining);
    }

    private void CheckSessionWarnings(
        TimeSpan remaining)
    {
        var currentSeconds =
            remaining.TotalSeconds;

        if (!_previousRemainingSeconds.HasValue)
        {
            _previousRemainingSeconds =
                currentSeconds;

            return;
        }

        var previousSeconds =
            _previousRemainingSeconds.Value;

        if (!_tenMinuteWarningShown &&
            previousSeconds > 600 &&
            currentSeconds <= 600)
        {
            _tenMinuteWarningShown = true;

            ShowWarningBanner(
                "10 Minutes Remaining",
                "Please save your work.",
                false);
        }

        if (!_fiveMinuteWarningShown &&
            previousSeconds > 300 &&
            currentSeconds <= 300)
        {
            _fiveMinuteWarningShown = true;

            ShowWarningBanner(
                "5 Minutes Remaining",
                "Please save your work now.",
                false);
        }

        if (!_oneMinuteWarningShown &&
            previousSeconds > 60 &&
            currentSeconds <= 60)
        {
            _oneMinuteWarningShown = true;

            ShowWarningBanner(
                "1 Minute Remaining",
                "Save your work immediately. " +
                "Your session is about to end.",
                true);
        }

        _previousRemainingSeconds =
            currentSeconds;
    }

    private void ShowWarningBanner(
        string title,
        string message,
        bool remainVisible)
    {
        _warningTimer.Stop();

        WarningTitleText.Text = title;
        WarningMessageText.Text = message;

        WarningBanner.Visibility =
            Visibility.Visible;

        if (!remainVisible)
        {
            _warningTimer.Start();
        }
    }

    private void CodeTextBox_PreviewTextInput(
        object sender,
        TextCompositionEventArgs e)
    {
        e.Handled =
            !e.Text.All(char.IsDigit);
    }

    private void CodeTextBox_TextChanged(
        object sender,
        System.Windows.Controls.TextChangedEventArgs e)
    {
        var digits =
            new string(
                CodeTextBox.Text
                    .Where(char.IsDigit)
                    .Take(6)
                    .ToArray());

        if (CodeTextBox.Text != digits)
        {
            var caret =
                CodeTextBox.CaretIndex;

            CodeTextBox.Text = digits;

            CodeTextBox.CaretIndex =
                Math.Min(
                    caret,
                    CodeTextBox.Text.Length);
        }

        StartSessionButton.IsEnabled =
            CodeTextBox.Text.Length == 6;

        ErrorText.Text = "";
    }

    private async void StartSessionButton_Click(
        object sender,
        RoutedEventArgs e)
    {
        var code =
            CodeTextBox.Text.Trim();

        if (code.Length != 6 ||
            !code.All(char.IsDigit))
        {
            ErrorText.Text =
                "Enter the six-digit access code provided by staff.";

            return;
        }

        StartSessionButton.IsEnabled = false;
        CodeTextBox.IsEnabled = false;

        ErrorText.Text = "";

        ServiceStatusText.Text =
            "Validating access code...";

        try
        {
            var response =
                await _httpClient.PostAsJsonAsync(
                    $"{LocalServiceAddress}/redeem",
                    new
                    {
                        Code = code
                    });

            if (!response.IsSuccessStatusCode)
            {
                var error =
                    await response.Content
                        .ReadFromJsonAsync<ErrorResponse>();

                ErrorText.Text =
                    !string.IsNullOrWhiteSpace(error?.Error)
                        ? error.Error
                        : "The access code could not be validated.";

                ServiceStatusText.Text =
                    "Session service connected";

                return;
            }

            var session =
                await response.Content
                    .ReadFromJsonAsync<RedeemResponse>();

            if (session == null ||
                !session.Success)
            {
                ErrorText.Text =
                    "The session service returned an invalid response.";

                return;
            }

            // Immediately obtain the authoritative remaining time from
            // the local Service. Do not calculate the initial countdown
            // from the workstation wall clock and the server expiration.
            var initialStatus =
                await _httpClient.GetFromJsonAsync<ServiceStatusResponse>(
                    $"{LocalServiceAddress}/status");

            if (initialStatus == null ||
                !initialStatus.Status.Equals(
                    "In Use",
                    StringComparison.OrdinalIgnoreCase) ||
                !initialStatus.RemainingSeconds.HasValue)
            {
                ErrorText.Text =
                    "Unable to obtain the active session timer.";

                ServiceStatusText.Text =
                    "Session timer unavailable";

                return;
            }

            var initialRemainingSeconds =
                Math.Max(
                    0,
                    initialStatus.RemainingSeconds.Value);

            _sessionExpiresUtc =
                DateTime.UtcNow.AddSeconds(
                    initialRemainingSeconds);

            _expiredViewShown = false;

            ResetWarnings();

            CodeTextBox.Clear();

            ShowSessionView();
            EnsureFloatingTimer();
            UpdateCountdown();
        }
        catch
        {
            ErrorText.Text =
                "Unable to contact the local session service.";

            ServiceStatusText.Text =
                "Session service unavailable";
        }
        finally
        {
            CodeTextBox.IsEnabled = true;

            if (AccessCodeView.Visibility ==
                Visibility.Visible)
            {
                StartSessionButton.IsEnabled =
                    CodeTextBox.Text.Length == 6;
            }
        }
    }

    private async void EndSessionButton_Click(
        object sender,
        RoutedEventArgs e)
    {
        var result =
            MessageBox.Show(
                "End this computer session?\n\n" +
                "In production, the computer will restart " +
                "immediately and locally saved files will be erased.\n\n" +
                "TEST MODE is currently enabled, so Windows " +
                "will not restart during this test.",
                "End Session",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning);

        if (result != MessageBoxResult.Yes)
        {
            return;
        }

        EndSessionButton.IsEnabled = false;

        SessionStatusText.Text =
            "Sending End Session request...";

        try
        {
            var response =
                await _httpClient.PostAsync(
                    $"{LocalServiceAddress}/end",
                    null);

            if (response.IsSuccessStatusCode)
            {
                SessionStatusText.Text =
                    "End Session received - TEST MODE. " +
                    "Windows was not restarted.";
            }
            else
            {
                var error =
                    await response.Content
                        .ReadFromJsonAsync<ErrorResponse>();

                SessionStatusText.Text =
                    error?.Error ??
                    "Unable to end the session.";
            }
        }
        catch
        {
            SessionStatusText.Text =
                "Unable to contact the local session service.";
        }
        finally
        {
            EndSessionButton.IsEnabled = true;
        }
    }

    private sealed class ServiceStatusResponse
    {
        [JsonPropertyName("hostName")]
        public string HostName { get; set; } = "";

        [JsonPropertyName("status")]
        public string Status { get; set; } = "";

        [JsonPropertyName("sessionExpiresUtc")]
        public DateTime? SessionExpiresUtc { get; set; }

        [JsonPropertyName("remainingSeconds")]
        public double? RemainingSeconds { get; set; }

        [JsonPropertyName("testMode")]
        public bool TestMode { get; set; }

        [JsonPropertyName("serverTimeUtc")]
        public DateTime ServerTimeUtc { get; set; }
    }

    private sealed class RedeemResponse
    {
        [JsonPropertyName("success")]
        public bool Success { get; set; }

        [JsonPropertyName("hostName")]
        public string HostName { get; set; } = "";

        [JsonPropertyName("durationMinutes")]
        public int DurationMinutes { get; set; }

        [JsonPropertyName("sessionExpiresUtc")]
        public DateTime SessionExpiresUtc { get; set; }

        [JsonPropertyName("testMode")]
        public bool TestMode { get; set; }
    }

    private sealed class ErrorResponse
    {
        [JsonPropertyName("error")]
        public string Error { get; set; } = "";
    }
}








