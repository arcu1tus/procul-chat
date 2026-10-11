import 'package:procul_chat_flutter/src/conversation_store.dart';

/// In-memory [ConversationStore] for tests, so they don't need
/// `shared_preferences` or a platform channel.
class FakeConversationStore implements ConversationStore {
  FakeConversationStore([this.stored]);

  String? stored;

  @override
  Future<void> clear() async => stored = null;

  @override
  Future<String?> read() async => stored;

  @override
  Future<void> write(String conversationId) async => stored = conversationId;
}
