using Procul.Api.Attachments;

namespace Procul.Api.Chat.Tools;

/// <summary>
/// Bridges media produced inside a tool call to the SSE stream and to the assistant message that is
/// persisted after the stream. A tool cannot <c>yield</c> into the reply enumerable, so it enqueues
/// an <c>image</c> event here; <c>StreamTokens</c> drains the queue after each update. The created
/// <see cref="Attachment"/> rows are held so the reply core can link them to the assistant message
/// before the turn is saved.
/// </summary>
internal sealed class GeneratedMediaCollector
{
    private readonly object _gate = new();
    private readonly Queue<Chat.V1.ChatStreamEventV1> _events = new();
    private readonly List<Attachment> _attachments = [];

    /// <summary>Records an image: enqueues its SSE event and holds the attachment for linking.</summary>
    public void AddImage(Attachment attachment, Chat.V1.ChatStreamEventV1 imageEvent)
    {
        lock (_gate)
        {
            _attachments.Add(attachment);
            _events.Enqueue(imageEvent);
        }
    }

    /// <summary>Dequeues one pending event, or returns false when the queue is empty.</summary>
    public bool TryDequeueEvent(out Chat.V1.ChatStreamEventV1? imageEvent)
    {
        lock (_gate)
        {
            if (_events.Count == 0)
            {
                imageEvent = null;
                return false;
            }

            imageEvent = _events.Dequeue();
            return true;
        }
    }

    /// <summary>A snapshot of the attachments created during this turn.</summary>
    public IReadOnlyList<Attachment> Attachments
    {
        get
        {
            lock (_gate)
            {
                return [.. _attachments];
            }
        }
    }
}
