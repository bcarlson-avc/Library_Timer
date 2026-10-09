using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace AVCPublicAccess.Service;

public enum RebootCommandOutcome { Accepted, Rejected, Uncertain }

public sealed record RebootCommandResult(
    RebootCommandOutcome Outcome, int? ExitCode, int? NativeErrorCode = null);

// The production implementation always requests a real reboot. Tests supply a fake.
public interface IEnforcementPlatform
{
    Guid BootIdentifier { get; }
    long TickCount64 { get; }
    Task<RebootCommandResult> RequestRebootAsync(string reason, CancellationToken cancellationToken);
}

[SupportedOSPlatform("windows")]
public sealed class WindowsEnforcementPlatform : IEnforcementPlatform
{
    public Guid BootIdentifier { get; } = ReadBootIdentifier();
    public long TickCount64 => Environment.TickCount64;

    private static Guid ReadBootIdentifier()
    {
        // SystemBootEnvironmentInformation (90) exposes the kernel's per-boot GUID.
        // Unlike wall-clock minus uptime, clock corrections do not change this ID.
        var status = NtQuerySystemInformation(90, out var information,
            (uint)Marshal.SizeOf<BootEnvironmentInformation>(), out _);
        if (status < 0 || information.BootIdentifier == Guid.Empty)
        {
            throw new InvalidOperationException(
                $"Cannot obtain Windows boot identity (NTSTATUS 0x{status:X8}).");
        }

        return information.BootIdentifier;
    }

    public async Task<RebootCommandResult> RequestRebootAsync(
        string reason, CancellationToken cancellationToken)
    {
        if (reason is not ("SessionExpired" or "SessionEnded"))
            throw new ArgumentException("Invalid reboot reason.", nameof(reason));

        var start = new ProcessStartInfo
        {
            FileName = Path.Combine(Environment.SystemDirectory, "shutdown.exe"),
            UseShellExecute = false,
            CreateNoWindow = true
        };
        foreach (var argument in new[] { "/r", "/f", "/t", "5", "/d", "p:4:1",
                     "/c", $"AVC Public Access: {reason}" })
            start.ArgumentList.Add(argument);

        Process? process;
        try
        {
            process = Process.Start(start);
        }
        catch (System.ComponentModel.Win32Exception ex)
        {
            // The process was not started: a bounded retry cannot duplicate it.
            return new(RebootCommandOutcome.Rejected, null, ex.NativeErrorCode);
        }

        if (process == null) return new(RebootCommandOutcome.Rejected, null);
        using (process)
        using (var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken))
        {
            timeout.CancelAfter(TimeSpan.FromSeconds(5));
            try
            {
                await process.WaitForExitAsync(timeout.Token);
                // ERROR_SHUTDOWN_IN_PROGRESS also means Windows is already shutting down.
                return new(process.ExitCode is 0 or 1115
                    ? RebootCommandOutcome.Accepted : RebootCommandOutcome.Rejected,
                    process.ExitCode);
            }
            catch (OperationCanceledException)
            {
                // A launched command may have scheduled the reboot. Never blindly retry.
                return new(RebootCommandOutcome.Uncertain, null);
            }
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BootEnvironmentInformation
    {
        public Guid BootIdentifier;
        public int FirmwareType;
        public ulong BootFlags;
    }

    [DllImport("ntdll.dll")]
    private static extern int NtQuerySystemInformation(int informationClass,
        out BootEnvironmentInformation information, uint length, out uint returnLength);
}
