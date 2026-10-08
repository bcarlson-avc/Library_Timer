using System.ComponentModel;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;

namespace AVCPublicAccess.Client;

public partial class SessionTimerWindow : Window
{
    private bool _allowClose;

    private readonly DispatcherTimer _pulseTimer;
    private bool _pulseState;
    private bool _finalMinuteActive;

    public SessionTimerWindow()
    {
        InitializeComponent();

        // Pulse twice per second during the final minute.
        _pulseTimer = new DispatcherTimer
        {
            Interval = TimeSpan.FromMilliseconds(500)
        };

        _pulseTimer.Tick += PulseTimer_Tick;

        Loaded += SessionTimerWindow_Loaded;
        Closing += SessionTimerWindow_Closing;
        LocationChanged += SessionTimerWindow_LocationChanged;

        // Normal countdown appearance.
        // The timer becomes fully opaque during the final minute.
        Opacity = 0.65;
    }

    private void SessionTimerWindow_Loaded(
        object sender,
        RoutedEventArgs e)
    {
        PositionWindow();
    }

    private void PositionWindow()
    {
        var workArea = SystemParameters.WorkArea;

        Left = workArea.Right - ActualWidth - 18;
        Top = workArea.Top + 18;

        KeepOnScreen();
    }

    private void Timer_MouseLeftButtonDown(
        object sender,
        MouseButtonEventArgs e)
    {
        if (e.ButtonState != MouseButtonState.Pressed)
        {
            return;
        }

        try
        {
            DragMove();
        }
        catch
        {
            // Ignore a drag that ends before WPF completes DragMove.
        }

        KeepOnScreen();
    }

    private void SessionTimerWindow_LocationChanged(
        object? sender,
        EventArgs e)
    {
        KeepOnScreen();
    }

    private void KeepOnScreen()
    {
        if (!IsLoaded)
        {
            return;
        }

        var workArea = SystemParameters.WorkArea;

        var width =
            ActualWidth > 0
                ? ActualWidth
                : Width;

        var height =
            ActualHeight > 0
                ? ActualHeight
                : 60;

        var newLeft = Left;
        var newTop = Top;

        if (newLeft < workArea.Left)
        {
            newLeft = workArea.Left;
        }

        if (newTop < workArea.Top)
        {
            newTop = workArea.Top;
        }

        if (newLeft + width > workArea.Right)
        {
            newLeft = workArea.Right - width;
        }

        if (newTop + height > workArea.Bottom)
        {
            newTop = workArea.Bottom - height;
        }

        if (Math.Abs(Left - newLeft) > 0.5)
        {
            Left = newLeft;
        }

        if (Math.Abs(Top - newTop) > 0.5)
        {
            Top = newTop;
        }
    }

    public void UpdateTime(
        TimeSpan remaining)
    {
        if (remaining <= TimeSpan.Zero)
        {
            StopFinalMinutePulse();

            TimerValueText.Text = "00:00";
            Opacity = 1.0;

            return;
        }

        if (remaining.TotalHours >= 1)
        {
            TimerValueText.Text =
                $"{(int)remaining.TotalHours}:" +
                $"{remaining.Minutes:00}:" +
                $"{remaining.Seconds:00}";
        }
        else
        {
            TimerValueText.Text =
                $"{remaining.Minutes:00}:" +
                $"{remaining.Seconds:00}";
        }

        UpdateAppearance(remaining);
    }

    private void UpdateAppearance(
        TimeSpan remaining)
    {
        // Final minute: solid and flashing.
        if (remaining.TotalSeconds <= 60)
        {
            Opacity = 1.0;
            TimerTitleText.Text =
                "SESSION ENDING";

            TimerWarningText.Text =
                "Save your work now";

            WarningBorder.Visibility =
                Visibility.Visible;

            if (!_finalMinuteActive)
            {
                StartFinalMinutePulse();
            }

            KeepOnScreen();
            return;
        }

        // Five minutes or less: strong warning appearance.
        if (remaining.TotalMinutes <= 5)
        {
            Opacity = 0.65;
            StopFinalMinutePulse();

            OuterBorder.BorderBrush =
                new SolidColorBrush(
                    Color.FromRgb(180, 35, 35));

            OuterBorder.BorderThickness =
                new Thickness(2);

            TimerBorder.Background =
                new SolidColorBrush(
                    Color.FromRgb(255, 242, 242));

            TimerTitleText.Text =
                "TIME REMAINING";

            TimerValueText.Foreground =
                new SolidColorBrush(
                    Color.FromRgb(120, 20, 20));

            WarningBorder.Background =
                new SolidColorBrush(
                    Color.FromRgb(255, 225, 225));

            WarningBorder.BorderBrush =
                new SolidColorBrush(
                    Color.FromRgb(180, 35, 35));

            TimerWarningText.Foreground =
                new SolidColorBrush(
                    Color.FromRgb(145, 20, 20));

            TimerWarningText.Text =
                "Please save your work";

            WarningBorder.Visibility =
                Visibility.Visible;

            KeepOnScreen();
            return;
        }

        // More than five minutes: semi-transparent compact timer.
        StopFinalMinutePulse();
        Opacity = 0.65;

        OuterBorder.BorderBrush =
            new SolidColorBrush(
                Color.FromRgb(80, 80, 80));

        OuterBorder.BorderThickness =
            new Thickness(1);


        OuterBorder.Background =
            Brushes.Transparent;
        TimerBorder.Background =
            Brushes.Transparent;

        TimerTitleText.Text =
            "TIME REMAINING";

        TimerValueText.Foreground =
            new SolidColorBrush(
                Color.FromRgb(32, 32, 32));

        TimerWarningText.Text = "";

        WarningBorder.Visibility =
            Visibility.Collapsed;

        KeepOnScreen();
    }

    private void StartFinalMinutePulse()
    {
        _finalMinuteActive = true;
        _pulseState = false;

        ApplyFinalMinuteAppearance();

        if (!_pulseTimer.IsEnabled)
        {
            _pulseTimer.Start();
        }
    }

    private void StopFinalMinutePulse()
    {
        if (_pulseTimer.IsEnabled)
        {
            _pulseTimer.Stop();
        }

        _finalMinuteActive = false;
        _pulseState = false;
    }

    private void PulseTimer_Tick(
        object? sender,
        EventArgs e)
    {
        if (!_finalMinuteActive)
        {
            return;
        }

        _pulseState = !_pulseState;

        ApplyFinalMinuteAppearance();
    }

    private void ApplyFinalMinuteAppearance()
    {
        // Flash between two solid warning states.
        if (_pulseState)
        {
            OuterBorder.BorderBrush =
                new SolidColorBrush(
                    Color.FromRgb(190, 25, 25));

            OuterBorder.BorderThickness =
                new Thickness(2);

            TimerBorder.Background =
                new SolidColorBrush(
                    Color.FromRgb(255, 205, 205));

            TimerValueText.Foreground =
                new SolidColorBrush(
                    Color.FromRgb(150, 15, 15));

            WarningBorder.Background =
                new SolidColorBrush(
                    Color.FromRgb(255, 195, 195));
        }
        else
        {
            OuterBorder.BorderBrush =
                new SolidColorBrush(
                    Color.FromRgb(180, 35, 35));

            OuterBorder.BorderThickness =
                new Thickness(2);

            TimerBorder.Background =
                new SolidColorBrush(
                    Color.FromRgb(255, 242, 242));

            TimerValueText.Foreground =
                new SolidColorBrush(
                    Color.FromRgb(120, 20, 20));

            WarningBorder.Background =
                new SolidColorBrush(
                    Color.FromRgb(255, 225, 225));
        }

        WarningBorder.BorderBrush =
            new SolidColorBrush(
                Color.FromRgb(180, 35, 35));

        TimerWarningText.Foreground =
            new SolidColorBrush(
                Color.FromRgb(145, 20, 20));

        TimerTitleText.Foreground =
            new SolidColorBrush(
                Color.FromRgb(145, 20, 20));
    }
    public void Reposition()
    {
        PositionWindow();
    }

    public void CloseForSessionEnd()
    {
        StopFinalMinutePulse();

        _allowClose = true;
        Close();
    }

    private void SessionTimerWindow_Closing(
        object? sender,
        CancelEventArgs e)
    {
        if (!_allowClose)
        {
            e.Cancel = true;
            return;
        }

        StopFinalMinutePulse();
    }
}









