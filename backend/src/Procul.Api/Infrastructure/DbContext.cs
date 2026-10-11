using Microsoft.EntityFrameworkCore;
using Procul.Api.Chat;

namespace Procul.Api.Infrastructure;

public class ProculDbContext(DbContextOptions<ProculDbContext> options) : DbContext(options)
{
    public DbSet<Conversation> Conversations { get; set; }
    public DbSet<ConversationMessage> ConversationMessages { get; set; }
    public DbSet<TurnUsage> TurnUsages { get; set; }

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.Entity<Conversation>(e =>
        {
            e.HasKey(c => c.Id);
            e.Property(c => c.Id).ValueGeneratedNever();
            e.Property(c => c.Model).HasMaxLength(256);
            e.HasMany<ConversationMessage>()
                .WithOne()
                .HasForeignKey(m => m.ConversationId)
                .IsRequired();
            e.HasMany<TurnUsage>()
                .WithOne()
                .HasForeignKey(u => u.ConversationId)
                .IsRequired();
        });

        modelBuilder.Entity<ConversationMessage>(e =>
        {
            e.HasKey(m => m.Id);
            e.Property(m => m.Id).ValueGeneratedNever();
            e.Property(m => m.MessageRole).HasConversion<string>().HasMaxLength(16);
        });

        modelBuilder.Entity<TurnUsage>(e =>
        {
            e.HasKey(u => u.Id);
            e.Property(u => u.Id).ValueGeneratedNever();
            e.Property(u => u.Model).HasMaxLength(256);
            e.Property(u => u.Kind).HasConversion<string>().HasMaxLength(16);
            e.HasIndex(u => u.ConversationId);
            e.HasIndex(u => u.CreatedAt);
        });
    }
}