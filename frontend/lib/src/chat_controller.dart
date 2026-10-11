import 'package:flutter/foundation.dart';

import 'attachments.dart';
import 'chat_api.dart';
import 'chat_stream_event.dart';
import 'conversation_store.dart';
import 'models.dart';

/// Holds the conversation list and the active conversation's messages, and
/// drives the SSE turn lifecycle.
///
/// The conversation list is fetched from the backend; the active conversation's
/// history is fetched **once** when it is opened. Assistant replies are then
/// appended from the stream rather than re-fetched.
class ChatController extends ChangeNotifier {
  ChatController({required this.api, ConversationStore? store})
    : _store = store ?? ConversationStore();

  final ChatApi api;
  final ConversationStore _store;

  /// All known conversations, most recently active first.
  final List<Conversation> conversations = [];

  /// Messages of the active conversation, oldest first.
  final List<ChatMessage> messages = [];

  String? _conversationId;

  /// True while the conversation list is being fetched.
  bool isLoadingConversations = false;

  /// True while the active conversation's history is being fetched.
  bool isLoadingMessages = false;

  /// True while an assistant reply is being streamed.
  bool isStreaming = false;

  /// The most recent user-facing error, if any.
  String? error;

  /// Files uploaded but not yet sent, shown as removable preview chips in the
  /// composer. Cleared when a message is sent (or the chat changes).
  final List<Attachment> pendingAttachments = [];

  /// True while an attachment upload is in flight.
  bool isUploadingAttachment = false;

  /// Byte cache for the attachment surface, so a message rebuild does not
  /// refetch every image.
  final Map<String, Uint8List> _attachmentBytes = {};

  /// Cumulative token usage for the active conversation. Seeded from
  /// `GET /v1/usage/conversations/{id}` when it is opened, then incremented by
  /// each turn's `usage` event so it survives switching without a refetch.
  TokenUsage activeUsage = const TokenUsage();

  /// Token usage reported for the most recent reply, or null when none was.
  TokenUsage? lastTurnUsage;

  /// The catalog's default model slug, mirrored from the shell's
  /// `ModelCatalogController` so [activeModel] can fall back to it. Set via
  /// [setDefaultModel].
  String? defaultModel;

  /// A model chosen for a conversation that does not exist yet, applied on the
  /// first [send]. Persists across [newChat] so the last explicit choice sticks.
  String? _pendingModel;

  String? get activeConversationId => _conversationId;

  /// Whether a conversation is already established on the backend.
  bool get hasConversation => _conversationId != null;

  /// The active conversation's record from [conversations], if any.
  Conversation? get activeConversation {
    final id = _conversationId;
    if (id == null) return null;
    for (final conversation in conversations) {
      if (conversation.id == id) return conversation;
    }
    return null;
  }

  /// The model the app-bar picker shows and the next turn will use.
  ///
  /// The active conversation's model when there is one, else a pending choice
  /// for a brand-new chat, else the catalog default.
  String? get activeModel {
    final conversation = activeConversation;
    if (conversation != null) return conversation.model ?? defaultModel;
    return _pendingModel ?? defaultModel;
  }

  /// Mirrors the catalog's default model (set by the shell when it loads).
  void setDefaultModel(String? slug) {
    if (slug == defaultModel) return;
    defaultModel = slug;
    notifyListeners();
  }

  /// Loads the conversation list and reopens the previously active conversation.
  Future<void> init() async {
    isLoadingConversations = true;
    notifyListeners();

    try {
      final storedId = await _store.read();
      final list = await api.listConversations();
      conversations
        ..clear()
        ..addAll(list);

      if (storedId != null && conversations.any((c) => c.id == storedId)) {
        await _openConversation(storedId);
      } else {
        _conversationId = null;
        messages.clear();
        await _store.clear();
      }
    } catch (e) {
      error = 'Could not load your chats: $e';
    } finally {
      isLoadingConversations = false;
      notifyListeners();
    }
  }

  /// Re-fetches the conversation list (used after a failed load, for example).
  Future<void> refreshConversations() async {
    try {
      final list = await api.listConversations();
      conversations
        ..clear()
        ..addAll(list);
      notifyListeners();
    } catch (e) {
      error = 'Could not refresh your chats: $e';
      notifyListeners();
    }
  }

  /// Re-fetches the active conversation's history into the buffer, so messages produced
  /// elsewhere show up. No-op when no conversation is active or a reply is streaming (a
  /// reload must not clobber the live stream).
  Future<void> reloadActiveConversation() async {
    final id = _conversationId;
    if (id == null || isStreaming) return;
    await _openConversation(id);
  }

  /// The "refresh the whole app" action: the conversation list plus the active history.
  Future<void> refreshAll() async {
    await refreshConversations();
    await reloadActiveConversation();
  }

  /// Opens [id], loading its history into the buffer.
  Future<void> selectConversation(String id) async {
    if (id == _conversationId && messages.isNotEmpty) return;
    await _openConversation(id);
  }

  /// Starts a fresh, unsaved conversation. The backend record is created on the
  /// first [send].
  Future<void> newChat() async {
    _conversationId = null;
    messages.clear();
    pendingAttachments.clear();
    activeUsage = const TokenUsage();
    lastTurnUsage = null;
    error = null;
    await _store.clear();
    notifyListeners();
  }

  /// Surfaces [message] as a user-facing error (used by the attach/save flows).
  void reportError(String message) {
    error = message;
    notifyListeners();
  }

  /// Uploads [picked] and queues it as a pending attachment.
  ///
  /// When [capabilities] is given, the file is first checked against the active
  /// model's input modalities and a friendly [error] is surfaced instead of
  /// uploading something the model cannot read. Returns whether the upload
  /// succeeded.
  Future<bool> uploadAttachment(
    PickedAttachment picked, {
    Set<ModelInputModality>? capabilities,
  }) async {
    if (isUploadingAttachment) return false;

    if (capabilities != null) {
      final problem = attachmentProblem(
        fileName: picked.fileName,
        contentType: picked.contentType,
        sizeBytes: picked.bytes.length,
        capabilities: capabilities,
      );
      if (problem != null) {
        reportError(problem);
        return false;
      }
    }

    isUploadingAttachment = true;
    error = null;
    notifyListeners();

    try {
      final attachment = await api.uploadAttachment(
        bytes: picked.bytes,
        fileName: picked.fileName,
        contentType: picked.contentType,
      );
      pendingAttachments.add(attachment);
      return true;
    } catch (e) {
      error = 'Could not attach ${picked.fileName}: $e';
      return false;
    } finally {
      isUploadingAttachment = false;
      notifyListeners();
    }
  }

  /// Removes a pending attachment (its bytes stay on the server, unreferenced).
  void removePendingAttachment(String id) {
    pendingAttachments.removeWhere((attachment) => attachment.id == id);
    notifyListeners();
  }

  /// The bytes for an attachment, fetched through the authenticated [api] and
  /// cached for the lifetime of the controller.
  Future<Uint8List> loadAttachmentBytes(String id) async {
    final cached = _attachmentBytes[id];
    if (cached != null) return cached;
    final bytes = await api.fetchAttachmentBytes(id);
    _attachmentBytes[id] = bytes;
    return bytes;
  }

  /// Sends [text]. Creates a conversation on the first message, otherwise
  /// appends to the active one. The reply is streamed into the buffer.
  Future<void> send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || isStreaming) return;

    error = null;
    final attachments = List<Attachment>.of(pendingAttachments);
    final attachmentIds = [for (final attachment in attachments) attachment.id];
    pendingAttachments.clear();
    messages.add(
      ChatMessage(
        text: trimmed,
        role: MessageRole.user,
        attachments: attachments,
      ),
    );
    final assistant = ChatMessage(text: '', role: MessageRole.assistant);
    messages.add(assistant);
    _promoteActive();
    isStreaming = true;
    notifyListeners();

    final reply = StringBuffer();
    try {
      final stream = _conversationId == null
          ? api.createConversation(
              trimmed,
              model: activeModel,
              attachmentIds: attachmentIds,
            )
          : api.sendMessage(
              _conversationId!,
              trimmed,
              attachmentIds: attachmentIds,
            );

      await for (final event in stream) {
        switch (event) {
          case CreatedEvent(:final conversation):
            _conversationId = conversation.id;
            _upsertConversation(conversation);
            await _store.write(conversation.id);
          case TokenEvent(:final content):
            reply.write(content);
            assistant.text = reply.toString();
            notifyListeners();
          case TitleEvent(:final conversationId, :final title):
            _applyTitle(conversationId, title);
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
          case DoneEvent():
            // The reply is complete. Stop treating the turn as streaming now, so
            // the composer is usable even if the `title` event is still in
            // flight (it is emitted after the reply).
            isStreaming = false;
            notifyListeners();
          case UsageEvent(:final usage):
            // The turn's token usage, summed across any tool-loop calls. Add it
            // to the conversation's running total and remember it for the chip.
            activeUsage = activeUsage + usage;
            lastTurnUsage = usage;
            notifyListeners();
          case AcknowledgeEvent():
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

  /// Selects [slug] for the active conversation, persisting it server-side.
  ///
  /// With no conversation yet the choice is pending and applied when the first
  /// message creates one. Applies optimistically and rolls back on failure
  /// (same pattern as [renameConversation]).
  Future<void> setModel(String slug) async {
    _pendingModel = slug;

    final conversation = activeConversation;
    if (conversation == null) {
      notifyListeners();
      return;
    }

    final index = conversations.indexWhere((c) => c.id == conversation.id);
    final previous = index == -1 ? null : conversations[index];
    if (index != -1) {
      conversations[index] = conversations[index].copyWith(model: slug);
      notifyListeners();
    }

    try {
      final updated = await api.setConversationModel(conversation.id, slug);
      _replaceConversation(updated);
    } catch (e) {
      if (previous != null) {
        _replaceConversation(previous);
      }
      error = 'Could not change the model: $e';
      notifyListeners();
    }
  }

  /// Renames [id]. Applies optimistically and rolls back on failure.
  Future<void> renameConversation(String id, String title) async {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return;

    final index = conversations.indexWhere((c) => c.id == id);
    final previous = index == -1 ? null : conversations[index];
    if (index != -1) {
      conversations[index] = conversations[index].copyWith(title: trimmed);
      notifyListeners();
    }

    try {
      final updated = await api.renameConversation(id, trimmed);
      _replaceConversation(updated);
    } catch (e) {
      if (previous != null) {
        _replaceConversation(previous);
      }
      error = 'Could not rename the chat: $e';
      notifyListeners();
    }
  }

  /// Deletes [id] and its messages. If it was active, the view is cleared.
  Future<void> deleteConversation(String id) async {
    try {
      await api.deleteConversation(id);
      conversations.removeWhere((c) => c.id == id);
      if (_conversationId == id) {
        _conversationId = null;
        messages.clear();
        activeUsage = const TokenUsage();
        lastTurnUsage = null;
        await _store.clear();
      }
      notifyListeners();
    } catch (e) {
      error = 'Could not delete the chat: $e';
      notifyListeners();
    }
  }

  Future<void> _openConversation(String id) async {
    _conversationId = id;
    isLoadingMessages = true;
    messages.clear();
    pendingAttachments.clear();
    activeUsage = const TokenUsage();
    lastTurnUsage = null;
    error = null;
    notifyListeners();

    try {
      final history = await api.fetchMessages(id);
      messages
        ..clear()
        ..addAll(history);
      await _store.write(id);
    } catch (e) {
      error = 'Could not load the chat: $e';
    } finally {
      isLoadingMessages = false;
      notifyListeners();
    }

    // The running total is fetched separately: a failure here must not mark the
    // chat as broken, so it is best-effort and never touches `error`.
    try {
      final usage = await api.fetchConversationUsage(id);
      if (_conversationId == id) {
        activeUsage = usage;
        notifyListeners();
      }
    } catch (_) {
      // Keep zeros; the chip just stays hidden until the next load.
    }
  }

  /// Moves the active conversation to the top of the list after new activity.
  void _promoteActive() {
    final id = _conversationId;
    if (id == null) return;
    final index = conversations.indexWhere((c) => c.id == id);
    if (index == -1) return;
    final conversation = conversations
        .removeAt(index)
        .copyWith(updatedAt: DateTime.now());
    conversations.insert(0, conversation);
    notifyListeners();
  }

  void _upsertConversation(Conversation conversation) {
    conversations.removeWhere((c) => c.id == conversation.id);
    conversations.insert(0, conversation);
    notifyListeners();
  }

  void _replaceConversation(Conversation conversation) {
    final index = conversations.indexWhere((c) => c.id == conversation.id);
    if (index == -1) return;
    conversations[index] = conversation;
    notifyListeners();
  }

  void _applyTitle(String conversationId, String title) {
    if (title.trim().isEmpty) return;
    final index = conversations.indexWhere((c) => c.id == conversationId);
    if (index == -1) return;
    conversations[index] = conversations[index].copyWith(title: title.trim());
    notifyListeners();
  }

  @override
  void dispose() {
    api.close();
    super.dispose();
  }
}
