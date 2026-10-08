namespace AVCPublicAccess.Server.Models;

public class PublicComputer
{
    public int Id { get; set; }

    public string HostName { get; set; } = string.Empty;

    public DateTime LastHeartbeatUtc { get; set; }

    public string Status { get; set; } = "Available";

    public DateTime? SessionExpiresUtc { get; set; }
}
