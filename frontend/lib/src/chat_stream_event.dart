import 'models.dart';

/// Events streamed by the SSE endpoints. The wire shape is
/// `data: {"value":{"type":"...", ...}}` — the discriminator lives inside `value`.
sealed class ChatStreamEvent {
  const ChatStreamEvent();
}

/// `type: "created"` — only emitted by `POST /v1/conversations`.
class CreatedEvent extends ChatStreamEvent {
  const CreatedEvent(this.conversation);
  final Conversation conversation;
}

/// `type: "acknowledge"` — the backend has accepted the turn.
class AcknowledgeEvent extends ChatStreamEvent {
  const AcknowledgeEvent();
}

/// `type: "token"` — a chunk of the assistant's reply.
class TokenEvent extends ChatStreamEvent {
  const TokenEvent(this.content);
  final String content;
}

/// `type: "title"` — the model-generated title for a newly created conversation.
///
/// Only emitted by `POST /v1/conversations`, and only after the reply finished.
/// Arriving after [DoneEvent] is expected: it must not keep the composer busy.
class TitleEvent extends ChatStreamEvent {
  const TitleEvent({required this.conversationId, required this.title});

  final String conversationId;
  final String title;
}

/// `type: "toolCall"` — the model asked to run a tool.
///
/// Emitted before the tool runs; the matching [ToolResultEvent] carries the same
/// [callId] and arrives once it finishes.
class ToolCallEvent extends ChatStreamEvent {
  const ToolCallEvent({
    required this.callId,
    required this.name,
    this.arguments,
  });

  final String callId;
  final String name;

  /// The model's arguments as a JSON object string, or null when there were none.
  final String? arguments;
}

/// `type: "toolResult"` — a previously requested tool finished.
///
/// Exactly one of [result] (output) or [error] (failure message) is typically set.
class ToolResultEvent extends ChatStreamEvent {
  const ToolResultEvent({required this.callId, this.result, this.error});

  final String callId;
  final String? result;
  final String? error;
}

/// `type: "error"` — the turn failed mid-stream.
class ErrorEvent extends ChatStreamEvent {
  const ErrorEvent(this.error);
  final String error;
}

/// `type: "usage"` — token usage for the reply, emitted once just before `done`.
///
/// The counts are summed across every underlying model call on the turn (the
/// tool-invocation loop can make several). [model] is the slug that produced the
/// reply, when the backend sends it (PLAN 2 §B4); older backends omit it.
class UsageEvent extends ChatStreamEvent {
  const UsageEvent(this.usage, {this.model});
  final TokenUsage usage;
  final String? model;
}

/// `type: "done"` — the assistant's reply is complete and persisted.
class DoneEvent extends ChatStreamEvent {
  const DoneEvent();
}
