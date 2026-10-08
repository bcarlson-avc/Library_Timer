using System.Security.Claims;
using System.Security.Cryptography;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;

namespace AVCPublicAccess.Server.Pages;

[Microsoft.AspNetCore.Authorization.AllowAnonymous]
public class LoginModel : PageModel
{
    private readonly IConfiguration _configuration;

    public LoginModel(IConfiguration configuration)
    {
        _configuration = configuration;
    }

    [BindProperty]
    public string? Passcode { get; set; }

    public void OnGet()
    {
    }

    public async Task<IActionResult> OnPostAsync()
    {
        if (string.IsNullOrWhiteSpace(Passcode))
        {
            ModelState.AddModelError(
                nameof(Passcode),
                "Passcode is required.");

            return Page();
        }

        var storedHash =
            _configuration["Security:OperatorPasscodeHash"];

        var storedSalt =
            _configuration["Security:OperatorPasscodeSalt"];

        if (string.IsNullOrWhiteSpace(storedHash) ||
            string.IsNullOrWhiteSpace(storedSalt))
        {
            ModelState.AddModelError(
                string.Empty,
                "Operator authentication is not configured.");

            return Page();
        }

        byte[] expectedHash;
        byte[] salt;

        try
        {
            expectedHash = Convert.FromBase64String(storedHash);
            salt = Convert.FromBase64String(storedSalt);
        }
        catch
        {
            ModelState.AddModelError(
                string.Empty,
                "Operator authentication configuration is invalid.");

            return Page();
        }

        var suppliedHash =
            Rfc2898DeriveBytes.Pbkdf2(
                Passcode,
                salt,
                120000,
                HashAlgorithmName.SHA256,
                expectedHash.Length);

        var valid =
            CryptographicOperations.FixedTimeEquals(
                suppliedHash,
                expectedHash);

        if (!valid)
        {
            ModelState.AddModelError(
                string.Empty,
                "Invalid operator passcode.");

            Passcode = null;

            return Page();
        }

        var claims = new List<Claim>
        {
            new Claim(
                ClaimTypes.Name,
                "AVC Public Access Operator"),

            new Claim(
                ClaimTypes.Role,
                "Operator")
        };

        var identity =
            new ClaimsIdentity(
                claims,
                "OperatorCookie");

        var principal =
            new ClaimsPrincipal(identity);

        await HttpContext.SignInAsync(
            "OperatorCookie",
            principal);

        return RedirectToPage("/Index");
    }
}

