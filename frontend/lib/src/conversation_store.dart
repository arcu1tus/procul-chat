import 'package:shared_preferences/shared_preferences.dart';

/// Remembers the id of the active conversation so the app can reload its
/// message history on the next launch instead of starting blank.
class ConversationStore {
  static const _key = 'active_conversation_id';

  Future<String?> read() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key);
  }

  Future<void> write(String conversationId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, conversationId);
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
