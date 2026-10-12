using Procul.Api.Attachments;
using Procul.Api.Configuration;
using Procul.Api.Infrastructure;

namespace Procul.Api.Chat.Tools;

/// <summary>
/// The scoped services and per-turn state a tool needs. Built once per turn by
/// <c>ChatStreamServiceV1</c> and passed to <see cref="TurnToolFactory.BuildTurnTools"/>.
/// </summary>
internal sealed record TurnToolContext(
    ProculDbContext Db,
    IAttachmentStore Store,
    AttachmentOptions AttachmentOptions,
    Guid ConversationId,
    string ModelSlug,
    GeneratedMediaCollector Media);
