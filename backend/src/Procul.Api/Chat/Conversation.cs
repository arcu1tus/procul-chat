namespace Procul.Api.Chat;

public class Conversation
{
    public Guid Id { get; set; } = Guid.CreateVersion7();
    public string Title { get; set; } = "New Conversation";
    public DateTimeOffset CreatedAt { get; private set; } = DateTimeOffset.UtcNow;

    /// <summary>Last time a message was added to this conversation. Drives list ordering.</summary>
    public DateTimeOffset UpdatedAt { get; set; } = DateTimeOffset.UtcNow;

    /// <summary>The model slug this conversation uses, or null for the configured default.</summary>
    public string? Model { get; set; }

    /// <summary>
    /// Optimistic-concurrency revision. Incremented on every mutating save (send, edit, rename,
    /// set-model). Clients echo the revision they last saw as <c>expectedRevision</c>; a mismatch
    /// is a <c>409 Conflict</c> so two devices cannot silently clobber each other.
    /// </summary>
    public int Revision { get; set; }
}
