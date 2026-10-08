using AVCPublicAccess.Server.Models;
using Microsoft.EntityFrameworkCore;

namespace AVCPublicAccess.Server.Data;

public class PublicAccessDbContext : DbContext
{
    public PublicAccessDbContext(
        DbContextOptions<PublicAccessDbContext> options)
        : base(options)
    {
    }

    public DbSet<PublicComputer> Computers => Set<PublicComputer>();
    public DbSet<AccessCode> AccessCodes => Set<AccessCode>();
    public DbSet<AuditEvent> AuditEvents => Set<AuditEvent>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.Entity<PublicComputer>()
            .HasIndex(c => c.HostName)
            .IsUnique();

        modelBuilder.Entity<AccessCode>()
            .HasIndex(c => c.Code)
            .IsUnique();
    }
}
