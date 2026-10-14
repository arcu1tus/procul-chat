using Microsoft.EntityFrameworkCore;
using Procul.Api.Attachments;
using Procul.Api.Chat;

namespace Procul.Api.Infrastructure;

public class ProculDbContext(DbContextOptions<ProculDbContext> options) : DbContext(options)
{
    public DbSet<Conversation> Conversations { get; set; }
    public DbSet<ConversationMessage> ConversationMessages { get; set; }
    public DbSet<TurnUsage> TurnUsages { get; set; }
    public DbSet<Attachment> Attachments { get; set; }
    public DbSet<AttachmentBlob> AttachmentBlobs { get; set; }

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

            // History and keyset queries order by (ConversationId, CreatedAt, Id); this composite
            // index also covers the conversation FK, so no separate single-column index is needed.
            e.HasIndex(m => new { m.ConversationId, m.CreatedAt, m.Id });
        });

        modelBuilder.Entity<ConversationToolCall>(e =>
        {
            e.HasKey(t => new { t.MessageId, t.Sequence });
            e.HasOne<ConversationMessage>().WithMany(m => m.ToolCalls)
                .HasForeignKey(t => t.MessageId).OnDelete(DeleteBehavior.Cascade);
        });

        modelBuilder.Entity<TurnUsage>(e =>
        {
            e.HasKey(u => u.Id);
            e.Property(u => u.Id).ValueGeneratedNever();
            e.Property(u => u.Model).HasMaxLength(256);
            e.Property(u => u.Kind).HasConversion<string>().HasMaxLength(16);
            e.HasIndex(u => u.ConversationId);
            e.HasIndex(u => u.CreatedAt);
            // Per-response metadata: the reply's usage row points at its assistant message.
            e.HasIndex(u => u.MessageId);
        });

        modelBuilder.Entity<Attachment>(e =>
        {
            e.HasKey(a => a.Id);
            e.Property(a => a.Id).ValueGeneratedNever();
            e.Property(a => a.FileName).HasMaxLength(512);
            e.Property(a => a.ContentType).HasMaxLength(256);
            e.Property(a => a.Sha256).HasMaxLength(64);
            e.Property(a => a.StorageKey).HasMaxLength(512);
            e.Property(a => a.Source).HasMaxLength(32).HasDefaultValue(Attachment.SourceUpload);

            // An attachment is removed with the message it is part of (which is itself removed
            // with its conversation). ConversationId is a plain column, not a second FK, so there
            // is a single cascade path.
            e.HasIndex(a => a.MessageId);
            e.HasOne<ConversationMessage>()
                .WithMany(m => m.Attachments)
                .HasForeignKey(a => a.MessageId)
                .OnDelete(DeleteBehavior.Cascade);
        });

        modelBuilder.Entity<AttachmentBlob>(e =>
        {
            e.HasKey(b => b.AttachmentId);
            e.Property(b => b.AttachmentId).ValueGeneratedNever();
            e.HasOne<Attachment>()
                .WithOne()
                .HasForeignKey<AttachmentBlob>(b => b.AttachmentId)
                .OnDelete(DeleteBehavior.Cascade);
        });
    }
}