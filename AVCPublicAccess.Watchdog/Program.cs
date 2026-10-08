using System.Diagnostics;

const string ClientProcessName =
    "AVCPublicAccess.Client";

var clientPath =
    Path.Combine(
        AppContext.BaseDirectory,
        "Client",
        "AVCPublicAccess.Client.exe");

var logDirectory =
    Path.Combine(
        Environment.GetFolderPath(
            Environment.SpecialFolder.CommonApplicationData),
        "AVC",
        "PublicAccess");

var logPath =
    Path.Combine(
        logDirectory,
        "watchdog.log");

Directory.CreateDirectory(
    logDirectory);

Log("Watchdog started.");
Log($"Client path: {clientPath}");

while (true)
{
    try
    {
        var running =
            Process.GetProcessesByName(
                ClientProcessName);

        try
        {
            if (running.Length == 0)
            {
                if (File.Exists(clientPath))
                {
                    Log("Client is not running. Starting client.");

                    Process.Start(
                        new ProcessStartInfo
                        {
                            FileName = clientPath,
                            WorkingDirectory =
                                Path.GetDirectoryName(
                                    clientPath)!,
                            UseShellExecute = true
                        });
                }
                else
                {
                    Log(
                        "Client executable not found: " +
                        clientPath);
                }
            }
        }
        finally
        {
            foreach (var process in running)
            {
                process.Dispose();
            }
        }
    }
    catch (Exception ex)
    {
        Log(
            "Watchdog error: " +
            ex);
    }

    await Task.Delay(
        TimeSpan.FromSeconds(3));
}

void Log(string message)
{
    try
    {
        File.AppendAllText(
            logPath,
            $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} " +
            $"{message}{Environment.NewLine}");
    }
    catch
    {
        // The watchdog must continue even if logging fails.
    }
}
