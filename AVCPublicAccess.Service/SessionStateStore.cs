using System.Text.Json;
using System.Text.Json.Serialization;

namespace AVCPublicAccess.Service;

public enum EnforcementReason { SessionExpired, SessionEnded }
public enum RebootPhase { None, RetryPending, RequestInProgress, Accepted, Failed }

public sealed class SessionState
{
    [JsonRequired]
    public int FormatVersion { get; set; } = 1;
    [JsonRequired]
    public string HostName { get; set; } = "";
    [JsonRequired]
    public Guid BootIdentifier { get; set; }
    [JsonRequired]
    public DateTime SessionExpiresUtc { get; set; }
    [JsonRequired]
    public long DeadlineTickCount64 { get; set; }
    public DateTime? SessionEndedUtc { get; set; }
    public EnforcementReason? EnforcementReason { get; set; }
    public RebootPhase RebootPhase { get; set; }
    public int RebootAttempts { get; set; }
    public long? AttemptTickCount64 { get; set; }
    public long? RetryAfterTickCount64 { get; set; }
}

public sealed class FatalServiceException : Exception
{
    public FatalServiceException(string message, Exception? innerException = null)
        : base(message, innerException) { }
}

public sealed class SessionStateStore(string stateFile)
{
    private static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() }
    };

    public SessionState? Load(Guid bootIdentifier, string hostName)
    {
        try
        {
            // Read directly: File.Exists hides access errors as "missing".
            var state = JsonSerializer.Deserialize<SessionState>(File.ReadAllText(stateFile), Options);
            if (state == null || state.FormatVersion != 1 ||
                state.BootIdentifier == Guid.Empty || state.SessionExpiresUtc == default ||
                state.DeadlineTickCount64 < 0 ||
                !string.Equals(state.HostName, hostName, StringComparison.OrdinalIgnoreCase) ||
                !Enum.IsDefined(state.RebootPhase) ||
                (state.EnforcementReason.HasValue && !Enum.IsDefined(state.EnforcementReason.Value)) ||
                state.RebootAttempts is < 0 or > 3 ||
                state.AttemptTickCount64 < 0 || state.RetryAfterTickCount64 < 0 ||
                (state.RebootPhase == RebootPhase.None &&
                    (state.EnforcementReason.HasValue || state.RebootAttempts != 0 ||
                     state.AttemptTickCount64.HasValue || state.RetryAfterTickCount64.HasValue)) ||
                (state.RebootPhase != RebootPhase.None && !state.EnforcementReason.HasValue) ||
                (state.EnforcementReason == EnforcementReason.SessionEnded &&
                    !state.SessionEndedUtc.HasValue) ||
                (state.EnforcementReason != EnforcementReason.SessionEnded && state.SessionEndedUtc.HasValue) ||
                (state.RebootPhase is RebootPhase.Accepted or RebootPhase.RequestInProgress &&
                    (!state.AttemptTickCount64.HasValue || state.RebootAttempts == 0)) ||
                (state.RebootPhase == RebootPhase.RetryPending &&
                    (!state.RetryAfterTickCount64.HasValue || state.RebootAttempts >= 3)))
            {
                throw new FatalServiceException(
                    "Invalid or legacy session state. Administrator review is required; state was preserved.");
            }

            if (state.BootIdentifier != bootIdentifier)
            {
                // Never restore a previous patron's state after a real Windows reboot.
                File.Delete(stateFile + ".tmp");
                File.Delete(stateFile);
                return null;
            }

            return state;
        }
        catch (FileNotFoundException)
        {
            EnsureNoIncompleteState();
            return null;
        }
        catch (DirectoryNotFoundException)
        {
            EnsureNoIncompleteState();
            return null;
        }
        catch (FatalServiceException) { throw; }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException)
        {
            throw new FatalServiceException("Cannot safely restore session state; startup refused.", ex);
        }
    }

    private void EnsureNoIncompleteState()
    {
        try
        {
            using var pending = File.OpenRead(stateFile + ".tmp");
            throw new FatalServiceException("Incomplete session state exists; administrator review is required.");
        }
        catch (FileNotFoundException) { }
        catch (DirectoryNotFoundException) { }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            throw new FatalServiceException("Cannot inspect incomplete session state.", ex);
        }
    }

    public void Save(SessionState state)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(stateFile)!);
            using (var stream = new FileStream(stateFile + ".tmp", FileMode.Create,
                FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
            {
                JsonSerializer.Serialize(stream, state, Options);
                stream.Flush(flushToDisk: true);
            }
            File.Move(stateFile + ".tmp", stateFile, overwrite: true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            throw new FatalServiceException("Cannot persist authoritative session/enforcement state.", ex);
        }
    }
}
