using Microsoft.EntityFrameworkCore;
using Procul.Api.Chat;

namespace Procul.Api.Infrastructure;

public class ProculDbContext(DbContextOptions<ProculDbContext> options) : DbContext(options)
{
    public DbSet<Conversation> Conversations { get; set; }
    public DbSet<ConversationMessage> ConversationMessages { get; set; }

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.Entity<Conversation>(e =>
        {
            e.HasKey(c => c.Id);
            e.Property(c => c.Id).ValueGeneratedNever();
            e.HasMany<ConversationMessage>()
                .WithOne()
                .HasForeignKey(m => m.ConversationId)
                .IsRequired();
        });

        modelBuilder.Entity<ConversationMessage>(e =>
        {
            e.HasKey(m => m.Id);
            e.Property(m => m.Id).ValueGeneratedNever();
            e.Property(m => m.MessageRole).HasConversion<string>().HasMaxLength(16);
        });
    }
}