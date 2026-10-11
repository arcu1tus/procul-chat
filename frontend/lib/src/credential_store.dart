import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Stores each server profile's session token in the platform's secure storage
/// (Keychain / Keystore / libsecret / DPAPI / WebCrypto). An interface so tests
/// can inject a fake and so the token never has to touch `shared_preferences`.
abstract interface class CredentialStore {
  Future<String?> readToken(String profileId);
  Future<void> writeToken(String profileId, String token);
  Future<void> deleteToken(String profileId);
}

/// The real [CredentialStore], backed by `flutter_secure_storage`.
///
/// macOS is configured with `usesDataProtectionKeychain: false` so the app does
/// not need a provisioning profile / the data-protection-keychain entitlement to
/// read and write tokens.
class SecureCredentialStore implements CredentialStore {
  SecureCredentialStore([FlutterSecureStorage? storage])
    : _storage =
          storage ??
          const FlutterSecureStorage(
            mOptions: MacOsOptions(usesDataProtectionKeychain: false),
          );

  final FlutterSecureStorage _storage;

  static String _key(String profileId) => 'procul.session.$profileId';

  @override
  Future<String?> readToken(String profileId) =>
      _storage.read(key: _key(profileId));

  @override
  Future<void> writeToken(String profileId, String token) =>
      _storage.write(key: _key(profileId), value: token);

  @override
  Future<void> deleteToken(String profileId) =>
      _storage.delete(key: _key(profileId));
}
