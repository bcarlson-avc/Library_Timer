namespace AVCPublicAccess.Service;

public sealed record SessionSnapshot(DateTime? ExpiresUtc, double? RemainingSeconds, bool Enforcing);

public sealed class SessionEnforcement(
    IEnforcementPlatform platform, SessionStateStore store, ILogger<SessionEnforcement> logger)
{
    private readonly object _gate = new();
    private SessionState? _state;
    private bool _commandRunning;
    private bool _duplicateLogged;
    private string _hostName = "";

    public void Initialize(string hostName)
    {
        lock (_gate)
        {
            _hostName = hostName;
            _state = store.Load(platform.BootIdentifier, hostName);
            if (_state?.RebootPhase == RebootPhase.Failed)
                throw new FatalServiceException("Previous reboot enforcement failed; administrator intervention required.");
            if (_state != null)
            {
                if (_state.AttemptTickCount64 > platform.TickCount64 ||
                    _state.RetryAfterTickCount64 > platform.TickCount64 + 2_000)
                    throw new FatalServiceException("Persisted enforcement ticks are invalid for this Windows boot.");
                logger.LogInformation("Same-boot session restored. Reboot phase: {Phase}; attempts: {Attempts}.",
                    _state.RebootPhase, _state.RebootAttempts);
            }
            else
            {
                logger.LogInformation("No current-boot patron session. Previous-boot state, if present, was cleared.");
            }
        }
    }

    public SessionSnapshot Snapshot()
    {
        lock (_gate)
        {
            return new(_state?.SessionEndedUtc ?? _state?.SessionExpiresUtc,
                _state == null ? null : _state.EnforcementReason.HasValue ? 0 :
                    Math.Max(0, (_state.DeadlineTickCount64 - platform.TickCount64) / 1000.0),
                _state?.EnforcementReason.HasValue == true);
        }
    }

    public bool TryStart(DateTime expirationUtc, double remainingSeconds)
    {
        if (expirationUtc == default || !double.IsFinite(remainingSeconds) || remainingSeconds < 0)
            throw new ArgumentException("Invalid authoritative session information.");
        lock (_gate)
        {
            if (_state != null) return false;
            var state = new SessionState
            {
                HostName = _hostName,
                BootIdentifier = platform.BootIdentifier,
                SessionExpiresUtc = DateTime.SpecifyKind(expirationUtc, DateTimeKind.Utc),
                DeadlineTickCount64 = checked(platform.TickCount64 +
                    (long)Math.Ceiling(remainingSeconds * 1000))
            };
            store.Save(state);
            _state = state;
            return true;
        }
    }

    public bool RequestEnd()
    {
        lock (_gate)
        {
            logger.LogInformation("/end requested.");
            if (_state == null) return false;
            BeginEnforcement(_state.DeadlineTickCount64 <= platform.TickCount64
                ? EnforcementReason.SessionExpired : EnforcementReason.SessionEnded);
            return true;
        }
    }

    private void BeginEnforcement(EnforcementReason reason)
    {
        if (_state!.EnforcementReason.HasValue)
        {
            LogDuplicateSuppression();
            return;
        }

        if (reason == EnforcementReason.SessionExpired)
            logger.LogCritical("Session expiration detected.");
        _state.EnforcementReason = reason;
        if (reason == EnforcementReason.SessionEnded)
            _state.SessionEndedUtc = DateTime.UtcNow;
        _state.RebootPhase = RebootPhase.RetryPending;
        _state.RetryAfterTickCount64 = platform.TickCount64;
        store.Save(_state);
        logger.LogCritical("Reboot enforcement initiated. Reason: {Reason}.", reason);
    }

    private void LogDuplicateSuppression()
    {
        if (_duplicateLogged) return;
        logger.LogInformation("Duplicate reboot enforcement suppressed. Reason: {Reason}.",
            _state!.EnforcementReason);
        _duplicateLogged = true;
    }

    public async Task CheckAsync(CancellationToken cancellationToken)
    {
        string reason;
        lock (_gate)
        {
            if (_state == null) return;
            var now = platform.TickCount64;
            if (!_state.EnforcementReason.HasValue && now >= _state.DeadlineTickCount64)
            {
                BeginEnforcement(EnforcementReason.SessionExpired);
            }
            if (!_state.EnforcementReason.HasValue || _commandRunning) return;

            if (_state.RebootPhase is RebootPhase.Accepted or RebootPhase.RequestInProgress)
            {
                LogDuplicateSuppression();
                // Includes an interrupted command from a same-boot Service restart.
                // Its outcome is uncertain: do not issue a second command.
                if (now - _state.AttemptTickCount64!.Value >= 30_000)
                    Fail("Windows did not reboot within the confirmation window.");
                return;
            }
            if (_state.RebootPhase == RebootPhase.Failed)
                throw new FatalServiceException("Reboot enforcement is failed.");
            if (_state.RetryAfterTickCount64 > now) return;

            _state.RebootAttempts++;
            _state.RebootPhase = RebootPhase.RequestInProgress;
            _state.AttemptTickCount64 = now;
            _state.RetryAfterTickCount64 = null;
            store.Save(_state); // Write before calling Windows, including across process crashes.
            _commandRunning = true;
            reason = _state.EnforcementReason.Value.ToString();
            logger.LogCritical("Requesting Windows reboot. Reason: {Reason}; attempt: {Attempt}. " +
                "Command: shutdown.exe /r /f /t 5 /d p:4:1.", reason, _state.RebootAttempts);
        }

        RebootCommandResult result;
        try
        {
            result = await platform.RequestRebootAsync(reason, cancellationToken);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Reboot command outcome is uncertain; it will not be blindly repeated.");
            result = new(RebootCommandOutcome.Uncertain, null);
        }

        lock (_gate)
        {
            _commandRunning = false;
            logger.LogCritical("Reboot command result: {Outcome}; exit code: {ExitCode}; " +
                "Windows error: {NativeErrorCode}; reason: {Reason}.",
                result.Outcome, result.ExitCode, result.NativeErrorCode, reason);
            if (result.Outcome == RebootCommandOutcome.Rejected)
            {
                if (_state!.RebootAttempts >= 3)
                    Fail("Windows rejected all three bounded reboot attempts.");
                _state.RebootPhase = RebootPhase.RetryPending;
                _state.RetryAfterTickCount64 = platform.TickCount64 + 2_000;
            }
            else
            {
                // Accepted or ambiguous: wait for actual boot change, never reset the session.
                _state!.RebootPhase = RebootPhase.Accepted;
            }
            store.Save(_state);
        }
    }

    private void Fail(string explanation)
    {
        _state!.RebootPhase = RebootPhase.Failed;
        store.Save(_state);
        logger.LogCritical("Reboot enforcement failed: {Explanation} Administrator intervention required.", explanation);
        throw new FatalServiceException("Reboot enforcement failed; administrator intervention required.");
    }
}
