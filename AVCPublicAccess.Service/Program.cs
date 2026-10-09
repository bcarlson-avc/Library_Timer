using AVCPublicAccess.Service;

var builder = Host.CreateApplicationBuilder(args);

builder.Services.AddWindowsService(options =>
{
    options.ServiceName = "AVC Public Access Service";
});

builder.Services.AddHttpClient();

builder.Services.Configure<HostOptions>(options =>
    options.BackgroundServiceExceptionBehavior = BackgroundServiceExceptionBehavior.StopHost);
builder.Services.AddSingleton<IEnforcementPlatform>(_ =>
{
    if (!OperatingSystem.IsWindows())
        throw new PlatformNotSupportedException("AVC Public Access enforcement requires Windows.");
    return new WindowsEnforcementPlatform();
});
builder.Services.AddSingleton(new SessionStateStore(Path.Combine(
    Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
    "AVC", "PublicAccess", "session-state.json")));
builder.Services.AddSingleton<SessionEnforcement>();
builder.Services.AddHostedService<Worker>();

using var host = builder.Build();
try
{
    await host.RunAsync();
}
catch (Exception ex)
{
    host.Services.GetRequiredService<ILoggerFactory>().CreateLogger("ServiceStartup")
        .LogCritical(ex, "Service failed to start or run.");
    Environment.ExitCode = 1;
}
