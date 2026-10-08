using AVCPublicAccess.Server.Data;
using AVCPublicAccess.Server.Models;
using Microsoft.AspNetCore.Authentication.Negotiate;
using Microsoft.EntityFrameworkCore;

var builder = WebApplication.CreateBuilder(args);

builder.Host.UseWindowsService();

var serverPort = builder.Configuration.GetValue<int?>("Server:Port") ?? 5000;


builder.WebHost.ConfigureKestrel(options =>
{
    options.ListenAnyIP(serverPort);
});

builder.Services.AddAuthentication(options =>
{
    options.DefaultAuthenticateScheme = "OperatorCookie";
    options.DefaultChallengeScheme = "OperatorCookie";
})
.AddCookie("OperatorCookie", options =>
{
    options.LoginPath = "/Login";
    options.AccessDeniedPath = "/Login";
    options.Cookie.Name = "AVCPublicAccess.Operator";
    options.Cookie.HttpOnly = true;
    options.Cookie.SameSite = SameSiteMode.Lax;
    options.Cookie.SecurePolicy = CookieSecurePolicy.SameAsRequest;

    var sessionHours =
        builder.Configuration.GetValue<int?>(
            "Security:OperatorSessionHours") ?? 8;

    options.ExpireTimeSpan =
        TimeSpan.FromHours(sessionHours);

    options.SlidingExpiration = true;
})
.AddNegotiate();

builder.Services.AddAuthorization(options =>
{
    options.AddPolicy("Operator", policy =>
    {
        policy.AddAuthenticationSchemes("OperatorCookie");
        policy.RequireAuthenticatedUser();
    });
});

builder.Services.AddRazorPages(options =>
{
    //
    // The operator web interface requires Windows authentication
    options.Conventions.AuthorizeFolder("/", "Operator");
});

builder.Services.AddDbContext<PublicAccessDbContext>(options =>
    options.UseSqlite("Data Source=AVCPublicAccess.db"));

var app = builder.Build();

if (!app.Environment.IsDevelopment())
{
    app.UseExceptionHandler("/Error");
    app.UseHsts();
}

app.UseStaticFiles();
app.UseRouting();

//
// Windows Integrated Authentication
//
app.UseAuthentication();
app.UseAuthorization();

app.MapRazorPages();

//
// Public computer heartbeat
//
app.MapPost("/api/computers/heartbeat",
    async (HeartbeatRequest request, PublicAccessDbContext db) =>
{
    if (string.IsNullOrWhiteSpace(request.HostName))
    {
        return Results.BadRequest(new
        {
            error = "HostName is required."
        });
    }

    var hostName =
        request.HostName.Trim().ToUpperInvariant();

    var now = DateTime.UtcNow;

    var computer = await db.Computers
        .SingleOrDefaultAsync(c => c.HostName == hostName);

    if (computer == null)
    {
        computer = new PublicComputer
        {
            HostName = hostName,
            LastHeartbeatUtc = now,
            Status = "Available"
        };

        db.Computers.Add(computer);
    }
    else
    {
        computer.LastHeartbeatUtc = now;

        //
        // A retired computer that comes back online
        // automatically re-registers itself.
        //
        if (computer.Status == "Retired")
        {
            computer.Status = "Available";
            computer.SessionExpiresUtc = null;

            db.AuditEvents.Add(new AuditEvent
            {
                TimestampUtc = now,
                EventType = "ComputerReactivated",
                Computer = hostName,
                Description =
                    "Retired computer automatically reactivated by heartbeat."
            });
        }

        //
        // If the previous session has expired,
        // return the computer to Available.
        //
        if (computer.Status == "In Use" &&
            computer.SessionExpiresUtc.HasValue &&
            computer.SessionExpiresUtc.Value <= now)
        {
            computer.Status = "Available";
            computer.SessionExpiresUtc = null;

            db.AuditEvents.Add(new AuditEvent
            {
                TimestampUtc = now,
                EventType = "SessionExpired",
                Computer = hostName,
                Description = "Session expired."
            });
        }
    }

    await db.SaveChangesAsync();

    return Results.Ok(new
    {
        computer.HostName,
        computer.Status,
        computer.SessionExpiresUtc,
        ServerTimeUtc = DateTime.UtcNow
    });
});

//
// Redeem a one-time access code and begin a session
//
//
//
app.MapPost("/api/sessions/redeem",
    async (RedeemCodeRequest request, PublicAccessDbContext db) =>
{
    if (string.IsNullOrWhiteSpace(request.HostName) ||
        string.IsNullOrWhiteSpace(request.Code))
    {
        return Results.BadRequest(new
        {
            error = "HostName and Code are required."
        });
    }

    var hostName =
        request.HostName.Trim().ToUpperInvariant();

    var code =
        request.Code.Trim();

    var now = DateTime.UtcNow;

    var computer = await db.Computers
        .SingleOrDefaultAsync(c => c.HostName == hostName);

    if (computer == null)
    {
        return Results.BadRequest(new
        {
            error = "Computer is not registered."
        });
    }

    //
    // Clear an expired session before checking whether
    // the computer is already in use.
    //
    if (computer.Status == "In Use" &&
        computer.SessionExpiresUtc.HasValue &&
        computer.SessionExpiresUtc.Value <= now)
    {
        computer.Status = "Available";
        computer.SessionExpiresUtc = null;
    }

    if (computer.Status == "In Use" &&
        computer.SessionExpiresUtc.HasValue &&
        computer.SessionExpiresUtc.Value > now)
    {
        return Results.Conflict(new
        {
            error = "Computer already has an active session."
        });
    }

    var accessCode = await db.AccessCodes
        .SingleOrDefaultAsync(c => c.Code == code);

    //
    // Invalid, expired and previously used codes all
    // receive the same patron-facing response.
    //
    if (accessCode == null ||
        accessCode.Used ||
        accessCode.ActivationExpiresUtc <= now)
    {
        return Results.BadRequest(new
        {
            error = "Invalid or expired access code."
        });
    }

    var sessionExpires =
        now.AddMinutes(accessCode.DurationMinutes);

    accessCode.Used = true;
    accessCode.ActivatedUtc = now;
    accessCode.UsedByComputer = hostName;

    computer.Status = "In Use";
    computer.SessionExpiresUtc = sessionExpires;

    db.AuditEvents.Add(new AuditEvent
    {
        TimestampUtc = now,
        EventType = "SessionStarted",
        Computer = hostName,
        Description =
            $"{accessCode.DurationMinutes} minute session started."
    });

    await db.SaveChangesAsync();

    return Results.Ok(new
    {
        Success = true,
        computer.HostName,
        DurationMinutes = accessCode.DurationMinutes,
        SessionStartedUtc = now,
        SessionExpiresUtc = sessionExpires,
        ServerTimeUtc = DateTime.UtcNow
    });
});

//
// Create the pilot database automatically.
//
using (var scope = app.Services.CreateScope())
{
    var db = scope.ServiceProvider
        .GetRequiredService<PublicAccessDbContext>();

    db.Database.EnsureCreated();
}

app.Run();

public record HeartbeatRequest(
    string HostName
);

public record RedeemCodeRequest(
    string HostName,
    string Code
);











