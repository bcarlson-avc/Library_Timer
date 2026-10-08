namespace AVCPublicAccess.Server.Models;

public class AccessCode
{
    public int Id { get; set; }

    public string Code { get; set; } = string.Empty;

    public int DurationMinutes { get; set; }

    public DateTime CreatedUtc { get; set; }

    public DateTime ActivationExpiresUtc { get; set; }

    public bool Used { get; set; }

    public DateTime? ActivatedUtc { get; set; }

    public string? UsedByComputer { get; set; }
}
