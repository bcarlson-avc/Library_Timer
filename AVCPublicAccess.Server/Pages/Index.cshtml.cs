using System.Security.Cryptography;
using Microsoft.AspNetCore.Authorization;
using AVCPublicAccess.Server.Data;
using AVCPublicAccess.Server.Models;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;
using Microsoft.EntityFrameworkCore;

namespace AVCPublicAccess.Server.Pages;

[Microsoft.AspNetCore.Authorization.Authorize(AuthenticationSchemes = "OperatorCookie")]
public class IndexModel : PageModel
{
    private readonly PublicAccessDbContext _db;

    public IndexModel(PublicAccessDbContext db)
    {
        _db = db;
    }

    public List<PublicComputer> Computers { get; private set; } = new();

    public int AvailableCount { get; private set; }
    public int InUseCount { get; private set; }
    public int OfflineCount { get; private set; }

    [BindProperty]
    public int DurationMinutes { get; set; } = 60;

    [BindProperty]
    public string? HostName { get; set; }

    [TempData]
    public string? GeneratedCode { get; set; }

    [TempData]
    public int GeneratedDuration { get; set; }

    [TempData]
    public string? GeneratedExpiration { get; set; }

    public async Task OnGetAsync()
    {
        await LoadComputersAsync();
    }

    public async Task<IActionResult> OnPostGenerateCodeAsync()
    {
        int[] allowedDurations =
        {
            2, 15, 30, 60, 90, 120
        };

        if (!allowedDurations.Contains(DurationMinutes))
        {
            ModelState.AddModelError(
                string.Empty,
                "Invalid session duration.");

            await LoadComputersAsync();

            return Page();
        }

        string code;

        do
        {
            code = RandomNumberGenerator
                .GetInt32(0, 1_000_000)
                .ToString("D6");
        }
        while (await _db.AccessCodes
            .AnyAsync(c => c.Code == code));

        var now = DateTime.UtcNow;

        var activationExpires =
            now.AddMinutes(15);

        var accessCode = new AccessCode
        {
            Code = code,
            DurationMinutes = DurationMinutes,
            CreatedUtc = now,
            ActivationExpiresUtc = activationExpires,
            Used = false
        };

        _db.AccessCodes.Add(accessCode);

        _db.AuditEvents.Add(new AuditEvent
        {
            TimestampUtc = now,
            EventType = "AccessCodeGenerated",
            Description =
                $"Access code generated for {DurationMinutes} minute session."
        });

        await _db.SaveChangesAsync();

        GeneratedCode = code;
        GeneratedDuration = DurationMinutes;

        GeneratedExpiration =
            activationExpires
                .ToLocalTime()
                .ToString("h:mm tt");

        return RedirectToPage();
    }

    public async Task<IActionResult> OnPostRetireAsync()
    {
        if (string.IsNullOrWhiteSpace(HostName))
        {
            return BadRequest("HostName is required.");
        }

        var hostName =
            HostName.Trim().ToUpperInvariant();

        var computer = await _db.Computers
            .SingleOrDefaultAsync(c => c.HostName == hostName);

        if (computer == null)
        {
            return NotFound();
        }

        //
        // Do not delete the record.
        // Retiring preserves the computer's database history.
        //
        computer.Status = "Retired";
        computer.SessionExpiresUtc = null;

        _db.AuditEvents.Add(new AuditEvent
        {
            TimestampUtc = DateTime.UtcNow,
            EventType = "ComputerRetired",
            Computer = hostName,
            Description = "Computer retired from active dashboard."
        });

        await _db.SaveChangesAsync();

        return RedirectToPage();
    }

    private async Task LoadComputersAsync()
    {
        Computers = await _db.Computers
            .Where(c => c.Status != "Retired")
            .OrderBy(c => c.HostName)
            .ToListAsync();

        var offlineThreshold =
            DateTime.UtcNow.AddSeconds(-60);

        foreach (var computer in Computers)
        {
            if (computer.LastHeartbeatUtc < offlineThreshold)
            {
                computer.Status = "Offline";
            }
        }

        AvailableCount =
            Computers.Count(c => c.Status == "Available");

        InUseCount =
            Computers.Count(c => c.Status == "In Use");

        OfflineCount =
            Computers.Count(c => c.Status == "Offline");
    }
}


