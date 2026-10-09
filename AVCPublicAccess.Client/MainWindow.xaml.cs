using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
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

    // Presentation metadata only; never used to calculate the session deadline.
    private DateTime? _presentationExpirationUtc;
    private DateTime? _sessionStartedUtc;
    private int? _originalDurationMinutes;
    private bool _startAnnounced;
    private readonly HashSet<int> _announcedMilestones = new();
    private double? _announcementPreviousSeconds;

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

            SetAccessibleMessage(ServiceStatusText, "Session service connected");

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

                PrepareSessionInformation(status.SessionExpiresUtc);
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
                PrepareSessionInformation(status.SessionExpiresUtc);
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

            SetAccessibleMessage(ServiceStatusText, $"Service status: {status.Status}");
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
            SetAccessibleMessage(ServiceStatusText, "Session service unavailable");

            SetAccessibleMessage(ErrorText, message);

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
        // An Available poll is not a new screen transition.
        if (IsVisible && AccessCodeView.Visibility == Visibility.Visible)
        {
            if (CodeTextBox.IsEnabled)
            {
                StartSessionButton.IsEnabled = CodeTextBox.Text.Length == 6;
            }

            return;
        }

        CloseFloatingTimer();

        AccessCodeView.Visibility =
            Visibility.Visible;

        SessionView.Visibility =
            Visibility.Collapsed;

        ExpiredView.Visibility =
            Visibility.Collapsed;

        SetAccessibleMessage(ErrorText, "");

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
        if (_announcedMilestones.Add(0))
        {
            AnnounceSessionMessage("Session ended. The computer will now reboot.");
        }
    }

    private void EnsureFloatingTimer()
    {
        _sessionTimerWindow?.SetSessionInformation(_sessionStartedUtc, _originalDurationMinutes);
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

        _sessionTimerWindow.SetSessionInformation(_sessionStartedUtc, _originalDurationMinutes);
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
        AnnounceSessionMilestones(remaining);
    }

    private void PrepareSessionInformation(DateTime? expirationUtc, int? durationMinutes = null)
    {
        if (!expirationUtc.HasValue) return;
        var expiration = DateTime.SpecifyKind(expirationUtc.Value, DateTimeKind.Utc);
        if (_presentationExpirationUtc != expiration)
        {
            _presentationExpirationUtc = expiration;
            _sessionStartedUtc = null;
            _originalDurationMinutes = null;
            _startAnnounced = false;
            _announcedMilestones.Clear();
            _announcementPreviousSeconds = null;
        }

        if (durationMinutes > 0)
        {
            _originalDurationMinutes = durationMinutes;
            _sessionStartedUtc = expiration.AddMinutes(-durationMinutes.Value);
        }
    }

    private void AnnounceSessionMessage(string message)
    {
        // Dispatch after rendering; never wait for speech or alter countdown timing.
        Dispatcher.BeginInvoke(DispatcherPriority.Background, new Action(() =>
        {
            UIElement target = ExpiredView.Visibility == Visibility.Visible
                ? this : _sessionTimerWindow ?? (UIElement)this;
            var peer = UIElementAutomationPeer.FromElement(target) ??
                UIElementAutomationPeer.CreatePeerForElement(target);
            peer?.RaiseNotificationEvent(AutomationNotificationKind.Other,
                AutomationNotificationProcessing.ImportantAll, message, "Session status");
        }));
    }

    private void AnnounceSessionMilestones(TimeSpan remaining)
    {
        if (!_startAnnounced && _sessionStartedUtc.HasValue && _originalDurationMinutes.HasValue)
        {
            _startAnnounced = true;
            var duration = SessionTimerWindow.DescribeRemainingTime(
                TimeSpan.FromMinutes(_originalDurationMinutes.Value));
            AnnounceSessionMessage($"Session started. You have {duration}. " +
                $"Your session started at {_sessionStartedUtc.Value.ToLocalTime():t}. " +
                "The countdown timer is now active.");
        }

        var seconds = remaining.TotalSeconds;
        var milestones = new (int Seconds, string Message)[]
        {
            (300, "5 minutes remaining. Please save your work."),
            (60, "1 minute remaining. Session ending. Please save your work."),
            (30, "30 seconds remaining. Please save your work."),
            (10, "10 seconds remaining.")
        };

        // On restoration below a threshold, announce only the most relevant
        // warning; do not replay older milestones or announce every poll.
        var crossed = milestones.Where(m => seconds <= m.Seconds &&
            !_announcedMilestones.Contains(m.Seconds) &&
            (!_announcementPreviousSeconds.HasValue ||
             _announcementPreviousSeconds.Value > m.Seconds)).ToArray();
        foreach (var milestone in crossed)
        {
            _announcedMilestones.Add(milestone.Seconds);
            if (_announcementPreviousSeconds.HasValue)
                AnnounceSessionMessage(milestone.Message);
        }
        if (!_announcementPreviousSeconds.HasValue && crossed.Length > 0)
            AnnounceSessionMessage(crossed[^1].Message);
        _announcementPreviousSeconds = seconds;
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

    private void SetAccessibleMessage(TextBlock control, string message)
    {
        if (control.Text == message)
        {
            return;
        }

        control.Text = message;

        // Announce meaningful changes only on the visible access-code screen.
        if (string.IsNullOrWhiteSpace(message) || !control.IsVisible ||
            AccessCodeView.Visibility != Visibility.Visible)
        {
            return;
        }

        var peer = UIElementAutomationPeer.FromElement(control) ??
            UIElementAutomationPeer.CreatePeerForElement(control);
        peer?.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
    }

    private void CodeTextBox_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter && StartSessionButton.IsEnabled &&
            CodeTextBox.Text.Length == 6 && CodeTextBox.Text.All(char.IsDigit))
        {
            e.Handled = true;
            StartSessionButton_Click(StartSessionButton, new RoutedEventArgs());
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

        SetAccessibleMessage(ErrorText, "");
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
            SetAccessibleMessage(ErrorText, "Enter the six-digit access code provided by staff.");

            return;
        }

        StartSessionButton.IsEnabled = false;
        CodeTextBox.IsEnabled = false;

        SetAccessibleMessage(ErrorText, "");

        SetAccessibleMessage(ServiceStatusText, "Validating access code...");

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

                SetAccessibleMessage(ErrorText, !string.IsNullOrWhiteSpace(error?.Error)
                        ? error.Error
                        : "The access code could not be validated.");

                SetAccessibleMessage(ServiceStatusText, "Session service connected");

                return;
            }

            var session =
                await response.Content
                    .ReadFromJsonAsync<RedeemResponse>();

            if (session == null ||
                !session.Success)
            {
                SetAccessibleMessage(ErrorText, "The session service returned an invalid response.");

                return;
            }

            PrepareSessionInformation(session.SessionExpiresUtc, session.DurationMinutes);

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
                SetAccessibleMessage(ErrorText, "Unable to obtain the active session timer.");

                SetAccessibleMessage(ServiceStatusText, "Session timer unavailable");

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
            SetAccessibleMessage(ErrorText, "Unable to contact the local session service.");

            SetAccessibleMessage(ServiceStatusText, "Session service unavailable");
        }
        finally
        {
            CodeTextBox.IsEnabled = true;

            if (AccessCodeView.Visibility ==
                Visibility.Visible)
            {
                StartSessionButton.IsEnabled =
                    CodeTextBox.Text.Length == 6;

                // Restore lost focus after a failed submission, but leave a
                // usable focus target or another application undisturbed.
                var focusedElement = Keyboard.FocusedElement as UIElement;
                if (!string.IsNullOrWhiteSpace(ErrorText.Text) && IsActive &&
                    (focusedElement == null || focusedElement == this ||
                     !focusedElement.IsVisible || !focusedElement.IsEnabled))
                {
                    CodeTextBox.Focus();
                }
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








