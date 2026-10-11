import 'package:procul_chat_flutter/src/credential_store.dart';

/// In-memory [CredentialStore] for tests, so they don't need
/// `flutter_secure_storage` or a platform channel.
class FakeCredentialStore implements CredentialStore {
  final Map<String, String> tokens = {};

  @override
  Future<String?> readToken(String profileId) async => tokens[profileId];

  @override
  Future<void> writeToken(String profileId, String token) async =>
      tokens[profileId] = token;

  @override
  Future<void> deleteToken(String profileId) async => tokens.remove(profileId);
}
