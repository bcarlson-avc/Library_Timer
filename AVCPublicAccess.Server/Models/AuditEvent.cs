namespace AVCPublicAccess.Server.Models;

public class AuditEvent
{
    public int Id { get; set; }

    public DateTime TimestampUtc { get; set; }

    public string EventType { get; set; } = string.Empty;

    public string? Computer { get; set; }

    public string Description { get; set; } = string.Empty;
}
