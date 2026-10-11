import 'package:flutter/foundation.dart';

import 'chat_api.dart';
import 'conversation_store.dart';
import 'models.dart';

/// Holds the chat state in memory and drives the SSE turn lifecycle.
///
/// History is fetched **once** on [init] into an in-memory buffer; subsequent
/// assistant replies are appended from the stream rather than re-fetched.
class ChatController extends ChangeNotifier {
  ChatController({required this.api, ConversationStore? store})
    : _store = store ?? ConversationStore();

  final ChatApi api;
  final ConversationStore _store;

  final List<ChatMessage> messages = [];

  String? _conversationId;

  /// True while the initial history fetch is running.
  bool isLoading = false;

  /// True while an assistant reply is being streamed.
  bool isStreaming = false;

  /// The most recent user-facing error, if any.
  String? error;

  /// Whether a conversation is already established on the backend.
  bool get hasConversation => _conversationId != null;

  /// Loads the persisted conversation id (if any) and fills the buffer with its
  /// message history. A missing/removed conversation is treated as "start fresh".
  Future<void> init() async {
    isLoading = true;
    notifyListeners();

    try {
      final storedId = await _store.read();
      if (storedId != null) {
        final history = await api.fetchMessages(storedId);
        _conversationId = storedId;
        messages
          ..clear()
          ..addAll(history);
      }
    } catch (e) {
      // Most likely the stored conversation no longer exists on the backend.
      _conversationId = null;
      messages.clear();
      await _store.clear();
      error = 'Could not load the previous conversation: $e';
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  /// Sends [text]. Creates a conversation on the first message, otherwise
  /// appends to the existing one. The reply is streamed into the buffer.
  Future<void> send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || isStreaming) return;

    error = null;
    messages.add(ChatMessage(text: trimmed, role: MessageRole.user));
    final assistant = ChatMessage(text: '', role: MessageRole.assistant);
    messages.add(assistant);
    isStreaming = true;
    notifyListeners();

    final reply = StringBuffer();
    try {
      final stream = _conversationId == null
          ? api.createConversation(trimmed)
          : api.sendMessage(_conversationId!, trimmed);

      await for (final event in stream) {
        switch (event) {
          case CreatedEvent(:final conversation):
            _conversationId = conversation.id;
            await _store.write(conversation.id);
          case TokenEvent(:final content):
            reply.write(content);
            assistant.text = reply.toString();
            notifyListeners();
          case ToolCallEvent(:final callId, :final name, :final arguments):
            assistant.toolCalls.add(
              ToolCall(id: callId, name: name, arguments: arguments),
            );
            notifyListeners();
          case ToolResultEvent(:final callId, :final result, :final error):
            for (final call in assistant.toolCalls) {
              if (call.id == callId) {
                call.result = result;
                call.error = error;
                break;
              }
            }
            notifyListeners();
          case ErrorEvent(:final error):
            this.error = error;
          case AcknowledgeEvent():
          case DoneEvent():
        }
      }
    } catch (e) {
      error = '$e';
    } finally {
      if (assistant.text.isEmpty) {
        assistant.text = error == null ? '(no reply)' : '(failed)';
      }
      isStreaming = false;
      notifyListeners();
    }
  }

  /// Clears the buffer and forgets the conversation so the next send starts a
  /// brand-new conversation.
  Future<void> newChat() async {
    _conversationId = null;
    messages.clear();
    error = null;
    await _store.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    api.close();
    super.dispose();
  }
}
