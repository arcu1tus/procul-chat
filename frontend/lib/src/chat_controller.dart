import 'package:flutter/foundation.dart';

import 'attachments.dart';
import 'chat_api.dart';
import 'chat_stream_event.dart';
import 'conversation_store.dart';
import 'models.dart';

/// A friendly message for an optimistic-concurrency conflict (`409`): the chat
/// changed on another device, so the client resyncs instead of failing hard.
const _conflictMessage = 'This chat changed on another device — refreshed.';

/// Whether [error] is the backend's optimistic-concurrency conflict (`409`),
/// which the client answers by resyncing rather than reporting a hard failure.
bool _isConflict(Object error) =>
    error is ChatApiException && error.statusCode == 409;

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
  int _historyGeneration = 0;
  int _turnGeneration = 0;
  int _draftGeneration = 0;
  bool _disposed = false;

  /// True while the conversation list is being fetched.
  bool isLoadingConversations = false;

  /// True while an explicit refresh (the list, or the whole app) is in flight.
  ///
  /// Distinct from [isLoadingConversations], which drives the full skeleton:
  /// this is what the refresh buttons use to show a spinner without blanking
  /// the list.
  bool isRefreshing = false;

  /// True while the active conversation's history is being fetched.
  bool isLoadingMessages = false;

  /// True while a page of *older* messages is being fetched (infinite scroll up).
  bool isLoadingOlder = false;

  /// Whether the backend may hold more history before the oldest loaded message.
  /// Set from "the last page was full"; cleared when a short page arrives.
  bool hasMoreHistory = false;

  /// The number of messages fetched per history page.
  static const int _pageSize = 100;

  /// True while an assistant reply is being streamed.
  bool isStreaming = false;

  /// The most recent user-facing error, if any.
  String? error;

  /// Files uploaded but not yet sent, shown as removable preview chips in the
  /// composer. Cleared when a message is sent (or the chat changes).
  final List<Attachment> pendingAttachments = [];

  /// True while an attachment upload is in flight.
  bool isUploadingAttachment = false;

  /// The id of the user message currently being edited, or null when not editing.
  String? editingMessageId;

  /// Whether the composer is in edit mode.
  bool get isEditing => editingMessageId != null;

  /// Byte futures for the attachment surface, so a message rebuild does not
  /// refetch (or restart the `FutureBuilder` for) every image. Caching the
  /// *future* — not just the resolved bytes — is what stops a later rebuild from
  /// resetting a loaded image back to its placeholder.
  final Map<String, Future<Uint8List>> _attachmentBytes = {};

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
      if (_disposed) return;
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
    isRefreshing = true;
    notifyListeners();
    try {
      final list = await api.listConversations();
      if (_disposed) return;
      conversations
        ..clear()
        ..addAll(list);
      notifyListeners();
    } catch (e) {
      error = 'Could not refresh your chats: $e';
      notifyListeners();
    } finally {
      isRefreshing = false;
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

  /// Merges any messages the server has that the buffer lacks, **without**
  /// clearing already-loaded history or moving the viewport. This is what the
  /// shell's background sync uses: a full [reloadActiveConversation] would drop
  /// pages loaded by infinite scroll and yank the user back to the newest
  /// message every time it ran. Best-effort — a failure is never surfaced.
  Future<void> syncActiveConversation() async {
    final id = _conversationId;
    if (id == null || isStreaming || isLoadingMessages || isEditing) return;
    final generation = _historyGeneration;

    try {
      final latest = await api.fetchMessages(id, limit: _pageSize);
      if (_conversationId != id ||
          generation != _historyGeneration ||
          isStreaming ||
          isLoadingMessages ||
          isEditing) {
        return;
      }
      // SSE turns have no server IDs. Match their ordered tail against history
      // before merging, otherwise the server copies appear as new bubbles.
      final localStart = messages.indexWhere((message) => message.id == null);
      var reconciled = false;
      if (localStart != -1) {
        final local = messages.sublist(localStart);
        final anchor = localStart == 0 ? null : messages[localStart - 1].id;
        final anchorIndex = anchor == null
            ? -1
            : latest.indexWhere((message) => message.id == anchor);
        // With an anchor, only its immediate successor can be our local turn.
        // Searching by text alone would confuse repeated prompts and replies.
        if (anchor != null && anchorIndex == -1) return;
        final matchStart = anchorIndex + 1;
        // Keep local bubbles while history is incomplete, and retry next sync.
        if (matchStart + local.length > latest.length) return;
        for (var i = 0; i < local.length; i++) {
          final remote = latest[matchStart + i];
          final pending = local[i];
          if ((pending.id != null && pending.id != remote.id) ||
              pending.role != remote.role ||
              pending.text != remote.text ||
              !setEquals(
                pending.attachments.map((a) => a.id).toSet(),
                remote.attachments.map((a) => a.id).toSet(),
              )) {
            return;
          }
        }
        for (var i = 0; i < local.length; i++) {
          local[i].id = latest[matchStart + i].id;
        }
        reconciled = true;
      }
      final known = {
        for (final message in messages)
          if (message.id != null) message.id,
      };
      final additions = [
        for (final message in latest)
          if (message.id == null || known.add(message.id)) message,
      ];
      if (additions.isEmpty && !reconciled) return;
      messages.addAll(additions);
      notifyListeners();
    } catch (_) {
      // Background sync is best-effort; keep the current buffer.
    }
  }

  /// The "refresh the whole app" action: the conversation list plus the active history.
  Future<void> refreshAll() async {
    await refreshConversations();
    await reloadActiveConversation();
  }

  /// Fetches the page of messages older than the oldest one loaded and prepends
  /// it (infinite scroll up). No-op while a reply streams or a page is already
  /// in flight, and when the backend has no more history.
  Future<void> loadOlderMessages() async {
    final id = _conversationId;
    if (id == null ||
        isLoadingOlder ||
        isLoadingMessages ||
        !hasMoreHistory ||
        isStreaming) {
      return;
    }
    final generation = _historyGeneration;
    final oldestId = messages.isEmpty ? null : messages.first.id;
    if (oldestId == null) {
      hasMoreHistory = false;
      notifyListeners();
      return;
    }

    isLoadingOlder = true;
    notifyListeners();
    try {
      final older = await api.fetchMessages(
        id,
        limit: _pageSize,
        afterMessageId: oldestId,
      );
      if (_conversationId != id || generation != _historyGeneration) return;
      final existing = {for (final message in messages) message.id};
      final fresh = [
        for (final message in older)
          if (existing.add(message.id)) message,
      ];
      messages.insertAll(0, fresh);
      hasMoreHistory = older.length >= _pageSize;
    } catch (e) {
      if (generation == _historyGeneration) {
        error = 'Could not load older messages: $e';
      }
    } finally {
      if (generation == _historyGeneration) {
        isLoadingOlder = false;
        notifyListeners();
      }
    }
  }

  /// Opens [id], loading its history into the buffer.
  Future<void> selectConversation(String id) async {
    if (id == _conversationId && messages.isNotEmpty) return;
    await _openConversation(id);
  }

  /// Starts a fresh, unsaved conversation. The backend record is created on the
  /// first [send].
  Future<void> newChat() async {
    _historyGeneration++;
    _turnGeneration++;
    _draftGeneration++;
    isStreaming = false;
    isLoadingMessages = false;
    _conversationId = null;
    messages.clear();
    pendingAttachments.clear();
    editingMessageId = null;
    activeUsage = const TokenUsage();
    lastTurnUsage = null;
    hasMoreHistory = false;
    isLoadingOlder = false;
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
  }) => _uploadAttachments([picked], capabilities: capabilities);

  /// Removes a pending attachment (its bytes stay on the server, unreferenced).
  void removePendingAttachment(String id) {
    pendingAttachments.removeWhere((attachment) => attachment.id == id);
    notifyListeners();
  }

  /// Uploads several picked files, keeping successful files when another fails.
  Future<void> uploadAttachments(
    List<PickedAttachment> picked, {
    Set<ModelInputModality>? capabilities,
  }) async {
    await _uploadAttachments(picked, capabilities: capabilities);
  }

  Future<bool> _uploadAttachments(
    List<PickedAttachment> picked, {
    Set<ModelInputModality>? capabilities,
  }) async {
    if (isUploadingAttachment || isStreaming || _disposed || picked.isEmpty) {
      return false;
    }
    final generation = _draftGeneration;
    final model = activeModel;
    var succeeded = true;
    isUploadingAttachment = true;
    error = null;
    notifyListeners();
    try {
      for (final file in picked) {
        if (_disposed || generation != _draftGeneration) return false;
        if (capabilities != null) {
          final problem = attachmentProblem(
            fileName: file.fileName,
            contentType: file.contentType,
            sizeBytes: file.bytes.length,
            capabilities: capabilities,
          );
          if (problem != null) {
            error = problem;
            succeeded = false;
            continue;
          }
        }
        try {
          final attachment = await api.uploadAttachment(
            bytes: file.bytes,
            fileName: file.fileName,
            contentType: file.contentType,
            model: model,
          );
          if (_disposed || generation != _draftGeneration) return false;
          pendingAttachments.add(attachment);
          notifyListeners();
        } catch (e) {
          if (_disposed || generation != _draftGeneration) return false;
          error = 'Could not attach ${file.fileName}: $e';
          succeeded = false;
        }
      }
      return succeeded;
    } finally {
      isUploadingAttachment = false;
      notifyListeners();
    }
  }

  /// The bytes for an attachment, fetched through the authenticated [api] and
  /// cached for the lifetime of the controller.
  ///
  /// Returns the same [Future] for the same id so an `Image`'s `FutureBuilder`
  /// does not reset on every rebuild (the flicker fix); a failed fetch is
  /// dropped from the cache so a later attempt can retry.
  Future<Uint8List> loadAttachmentBytes(String id) {
    final cached = _attachmentBytes[id];
    if (cached != null) return cached;

    final future = api.fetchAttachmentBytes(id);
    _attachmentBytes[id] = future;
    future.then(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        // A 404 means retention purged the bytes (metadata is kept). Keep the
        // failed future cached so a rebuild shows the "no longer stored" chip
        // without re-hitting the network; any other failure is dropped so a
        // later attempt can retry.
        if (error is ChatApiException && error.statusCode == 404) return;
        _attachmentBytes.remove(id);
      },
    );
    return future;
  }

  /// Sends [text]. Creates a conversation on the first message, otherwise
  /// appends to the active one. The reply is streamed into the buffer.
  Future<void> send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty ||
        isStreaming ||
        isLoadingMessages ||
        isUploadingAttachment ||
        _disposed) {
      return;
    }
    _historyGeneration++;
    isLoadingOlder = false;

    error = null;
    final attachments = List<Attachment>.of(pendingAttachments);
    final attachmentIds = [for (final attachment in attachments) attachment.id];
    pendingAttachments.clear();
    messages.add(
      ChatMessage(
        text: trimmed,
        role: MessageRole.user,
        createdAt: DateTime.now(),
        attachments: attachments,
      ),
    );
    final assistant = ChatMessage(
      text: '',
      role: MessageRole.assistant,
      createdAt: DateTime.now(),
    );
    messages.add(assistant);
    _promoteActive();
    isStreaming = true;
    notifyListeners();

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
            expectedRevision: activeConversation?.revision,
          );
    await _runReply(stream, assistant: assistant, handleCreated: true);
  }

  /// Enters edit mode for [message] (a user message): remembers its id and seeds
  /// the pending queue with its current attachments so the composer shows them.
  /// The caller fills the input field from the message's text.
  void beginEdit(ChatMessage message) {
    if (isStreaming ||
        isLoadingMessages ||
        message.id == null ||
        message.role != MessageRole.user ||
        !messages.contains(message)) {
      return;
    }
    _draftGeneration++;
    editingMessageId = message.id;
    pendingAttachments
      ..clear()
      ..addAll(message.attachments);
    notifyListeners();
  }

  /// Leaves edit mode and drops the seeded attachments.
  void cancelEdit() {
    _draftGeneration++;
    editingMessageId = null;
    pendingAttachments.clear();
    notifyListeners();
  }

  /// Rewrites the message being edited and re-prompts the model.
  ///
  /// Editing is destructive (v1): the local tail is discarded to mirror the
  /// backend, which deletes every message after the edited one and their
  /// attachments.
  Future<void> editMessage(String text) async {
    final trimmed = text.trim();
    final messageId = editingMessageId;
    if (trimmed.isEmpty ||
        isStreaming ||
        isLoadingMessages ||
        isUploadingAttachment ||
        _disposed ||
        messageId == null ||
        !hasConversation) {
      return;
    }

    final index = messages.indexWhere((message) => message.id == messageId);
    if (index == -1) {
      cancelEdit();
      return;
    }

    _historyGeneration++;
    isLoadingOlder = false;
    error = null;
    // The pending queue is the desired attachment set (seeded by [beginEdit] and
    // edited by the user); send it as a full replacement.
    final attachments = List<Attachment>.of(pendingAttachments);
    final attachmentIds = [for (final attachment in attachments) attachment.id];

    final edited = messages[index];
    edited.text = trimmed;
    edited.attachments
      ..clear()
      ..addAll(attachments);
    messages.removeRange(index + 1, messages.length);
    final assistant = ChatMessage(
      text: '',
      role: MessageRole.assistant,
      createdAt: DateTime.now(),
    );
    messages.add(assistant);
    pendingAttachments.clear();
    editingMessageId = null;
    isStreaming = true;
    notifyListeners();

    await _runReply(
      api.editMessage(
        _conversationId!,
        messageId,
        trimmed,
        attachmentIds: attachmentIds,
        expectedRevision: activeConversation?.revision,
      ),
      assistant: assistant,
      refreshUsage: true,
    );
  }

  // Both send and edit use the same failure recovery and stream ownership.
  // A completed create stream can still be waiting for its title while the
  // next turn starts; its cleanup must not change that newer turn's state.
  Future<void> _runReply(
    Stream<ChatStreamEvent> stream, {
    required ChatMessage assistant,
    bool handleCreated = false,
    bool refreshUsage = false,
  }) async {
    final generation = ++_turnGeneration;
    _draftGeneration++;
    var hardFailure = false;
    var conflict = false;
    try {
      await _consumeReply(
        stream,
        assistant: assistant,
        reply: StringBuffer(),
        generation: generation,
        handleCreated: handleCreated,
      );
    } catch (e) {
      if (generation != _turnGeneration) return;
      conflict = _isConflict(e);
      error = conflict ? _conflictMessage : '$e';
      hardFailure = true;
    } finally {
      if (generation == _turnGeneration) {
        if (assistant.text.isEmpty && assistant.attachments.isEmpty) {
          assistant.text = error == null ? '(no reply)' : '(failed)';
        }
        isStreaming = false;
        notifyListeners();
      }
    }
    if (generation != _turnGeneration || !hasConversation) return;
    if (hardFailure) {
      // Refresh revisions as well as history, or the next request conflicts again.
      final failure = error;
      await refreshConversations();
      if (generation != _turnGeneration) return;
      final recoveryGeneration = _turnGeneration + 1;
      await reloadActiveConversation();
      if (_disposed || _turnGeneration != recoveryGeneration) return;
      error = conflict ? _conflictMessage : failure;
      notifyListeners();
    } else if (refreshUsage || error != null) {
      // An edit replaces old usage; an SSE error may still have persisted the
      // user message and bumped the revision. Keep its partial reply visible.
      await refreshConversations();
      if (generation != _turnGeneration) return;
      await _refreshUsage(_conversationId!, _historyGeneration);
    }
  }

  /// Folds an SSE event stream into [assistant] (and the conversation list).
  /// Shared by [send] and [editMessage]; only [send] handles `created`.
  Future<void> _consumeReply(
    Stream<ChatStreamEvent> stream, {
    required ChatMessage assistant,
    required StringBuffer reply,
    required int generation,
    bool handleCreated = false,
  }) async {
    var terminated = false;
    await for (final event in stream) {
      if (_disposed) return;
      // Titles belong to their own conversation, even after a chat switch.
      if (event case TitleEvent(:final conversationId, :final title)) {
        _applyTitle(conversationId, title);
        continue;
      }
      if (generation != _turnGeneration) continue;
      if (terminated) continue;
      switch (event) {
        case CreatedEvent(:final conversation):
          if (handleCreated) {
            _conversationId = conversation.id;
            _upsertConversation(conversation);
            await _store.write(conversation.id);
          }
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
        case ImageEvent(:final attachment):
          if (!assistant.attachments.any((a) => a.id == attachment.id)) {
            assistant.attachments.add(attachment);
            notifyListeners();
          }
        case ErrorEvent(:final error):
          terminated = true;
          this.error = error;
        case DoneEvent(:final revision):
          terminated = true;
          // The reply is complete. Stop treating the turn as streaming now, so
          // the composer is usable even if the `title` event is still in
          // flight (it is emitted after the reply). Record the new revision so
          // the next send/edit can echo it as `expectedRevision`.
          if (revision != null) _applyRevision(revision);
          isStreaming = false;
          notifyListeners();
        case UsageEvent(:final usage, :final model):
          // The turn's token usage, summed across any tool-loop calls. Add it
          // to the conversation's running total and remember it for the chip.
          // Also stamp it on the response so the per-response popover can show
          // *this* reply's model and tokens.
          activeUsage = activeUsage + usage;
          lastTurnUsage = usage;
          assistant.usage = usage;
          assistant.model = model ?? activeModel;
          notifyListeners();
        case AcknowledgeEvent():
      }
    }
    if (!terminated && generation == _turnGeneration && !_disposed) {
      throw ChatApiException(
        'The reply stream ended before the turn completed.',
      );
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
      final updated = await api.setConversationModel(
        conversation.id,
        slug,
        expectedRevision: conversation.revision,
      );
      _replaceConversation(updated);
    } catch (e) {
      if (previous != null) {
        _replaceConversation(previous);
      }
      if (_isConflict(e)) {
        await _resyncAfterConflict();
        return;
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
      final updated = await api.renameConversation(
        id,
        trimmed,
        expectedRevision: previous?.revision,
      );
      _replaceConversation(updated);
    } catch (e) {
      if (previous != null) {
        _replaceConversation(previous);
      }
      if (_isConflict(e)) {
        await _resyncAfterConflict();
        return;
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
        _historyGeneration++;
        _turnGeneration++;
        _draftGeneration++;
        isStreaming = false;
        isLoadingMessages = false;
        _conversationId = null;
        messages.clear();
        pendingAttachments.clear();
        editingMessageId = null;
        activeUsage = const TokenUsage();
        lastTurnUsage = null;
        hasMoreHistory = false;
        isLoadingOlder = false;
        await _store.clear();
      }
      notifyListeners();
    } catch (e) {
      error = 'Could not delete the chat: $e';
      notifyListeners();
    }
  }

  Future<void> _openConversation(String id) async {
    final generation = ++_historyGeneration;
    _turnGeneration++;
    _draftGeneration++;
    isStreaming = false;
    _conversationId = id;
    isLoadingMessages = true;
    isLoadingOlder = false;
    hasMoreHistory = false;
    messages.clear();
    pendingAttachments.clear();
    editingMessageId = null;
    activeUsage = const TokenUsage();
    lastTurnUsage = null;
    error = null;
    notifyListeners();

    try {
      final history = await api.fetchMessages(id, limit: _pageSize);
      if (generation != _historyGeneration) return;
      messages
        ..clear()
        ..addAll(history);
      // A full page means the backend may hold more before the oldest message.
      hasMoreHistory = history.length >= _pageSize;
      await _store.write(id);
    } catch (e) {
      if (generation == _historyGeneration) {
        error = 'Could not load the chat: $e';
      }
    } finally {
      if (generation == _historyGeneration) {
        isLoadingMessages = false;
        notifyListeners();
      }
    }

    if (generation != _historyGeneration) return;
    await _refreshUsage(id, generation);
  }

  Future<void> _refreshUsage(String id, int generation) async {
    // The running total is fetched separately: a failure here must not mark the
    // chat as broken, so it is best-effort and never touches `error`.
    try {
      final usage = await api.fetchConversationUsage(id);
      if (_conversationId == id && generation == _historyGeneration) {
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

  /// Records the active conversation's post-turn revision (from the `done`
  /// event) so the next mutation can echo it as `expectedRevision`.
  void _applyRevision(int revision) {
    final id = _conversationId;
    if (id == null) return;
    final index = conversations.indexWhere((c) => c.id == id);
    if (index == -1) return;
    conversations[index] = conversations[index].copyWith(revision: revision);
  }

  /// Resyncs after a `409 Conflict`: refresh the conversation list (so the
  /// revision is current) and the active history, then surface a friendly
  /// message. Refreshing the list matters — without it the client would keep
  /// echoing the stale revision and conflict again on the next attempt.
  Future<void> _resyncAfterConflict() async {
    await refreshConversations();
    await reloadActiveConversation();
    error = _conflictMessage;
    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _historyGeneration++;
    _turnGeneration++;
    _draftGeneration++;
    api.close();
    super.dispose();
  }
}
