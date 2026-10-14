import 'package:flutter/foundation.dart';

import 'auth_api.dart';
import 'credential_store.dart';
import 'server_profile.dart';
import 'server_store.dart';

/// The active, authenticated connection to a backend.
class ActiveSession {
  const ActiveSession({required this.profile, required this.token});

  final ServerProfile profile;
  final String token;

  String get baseUrl => profile.baseUrl;
}

/// Owns the saved server profiles and the active session.
///
/// The profile list and the active id live in [ServerStore]; each profile's
/// session token lives in [CredentialStore]. The controller keeps only the
/// active token in memory.
class AuthController extends ChangeNotifier {
  AuthController({
    AuthApi? api,
    CredentialStore? credentials,
    ServerStore? store,
  }) : _api = api ?? AuthApi(),
       _credentials = credentials ?? SecureCredentialStore(),
       _store = store ?? ServerStore();

  final AuthApi _api;
  final CredentialStore _credentials;
  final ServerStore _store;

  final List<ServerProfile> _profiles = [];

  /// The saved server profiles, in insertion order.
  List<ServerProfile> get profiles => List.unmodifiable(_profiles);

  String? _activeId;

  /// The id of the selected profile, even when it is not authenticated.
  String? get activeId => _activeId;

  ServerProfile? get activeProfile {
    final id = _activeId;
    if (id == null) return null;
    for (final profile in _profiles) {
      if (profile.id == id) return profile;
    }
    return null;
  }

  String? _token;
  Future<void> _credentialDeletion = Future.value();

  /// The active session, or null when no profile is authenticated (so the app
  /// shows the Connect screen).
  ActiveSession? get active {
    final profile = activeProfile;
    final token = _token;
    if (profile == null || token == null) return null;
    return ActiveSession(profile: profile, token: token);
  }

  /// True while a connect attempt is in flight.
  bool isLoading = false;

  /// The most recent user-facing error, if any.
  String? error;

  int _idCounter = 0;

  /// Loads the saved profiles and reopens the active one if its token is still
  /// present. Failures leave the controller in a fresh, logged-out state.
  Future<void> init() async {
    try {
      final profiles = await _store.readProfiles();
      _profiles
        ..clear()
        ..addAll(profiles);

      final activeId = await _store.readActiveId();
      _activeId = _profiles.any((p) => p.id == activeId) ? activeId : null;

      if (_activeId != null) {
        _token = await _credentials.readToken(_activeId!);
      }
    } catch (_) {
      // Start fresh; the Connect screen will let the user add a server.
      _profiles.clear();
      _activeId = null;
      _token = null;
    }
    notifyListeners();
  }

  /// Connects to [baseUrl] with [password], saving the server as a profile if it
  /// is new and making it active. Returns whether the connection succeeded; on
  /// failure [error] explains why.
  Future<bool> connect({
    required String baseUrl,
    required String password,
    String? name,
  }) async {
    final uri = parseServerBaseUrl(baseUrl);
    if (uri == null) {
      error = 'Enter a valid http(s) server URL.';
      notifyListeners();
      return false;
    }

    final normalized = normalizeBaseUrl(uri);
    isLoading = true;
    error = null;
    notifyListeners();

    try {
      final session = await _api.createSession(normalized, password);

      final index = _profiles.indexWhere((p) => p.baseUrl == normalized);
      final existing = index == -1 ? null : _profiles[index];
      final profile =
          existing ??
          ServerProfile(
            id: _newId(),
            name: _resolveName(name, normalized),
            baseUrl: normalized,
          );

      // Store the token first: if secure storage fails, don't leave a
      // half-added profile behind.
      await _credentialDeletion;
      await _credentials.writeToken(profile.id, session.token);
      if (existing == null) {
        _profiles.add(profile);
      }
      _token = session.token;
      _activeId = profile.id;
      await _persist();
      return true;
    } on AuthException catch (e) {
      error = e.message;
      return false;
    } catch (e) {
      error = 'Could not connect: $e';
      return false;
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  /// Adds a server and connects to it. A thin alias for [connect], named for the
  /// "add server" flow in Settings.
  Future<bool> addProfile({
    required String baseUrl,
    required String password,
    String? name,
  }) => connect(baseUrl: baseUrl, password: password, name: name);

  /// Makes [id] active. Returns whether it is authenticated (a stored, present
  /// token exists); when false the Connect screen prompts for the password.
  Future<bool> switchTo(String id) async {
    if (!_profiles.any((p) => p.id == id)) return false;

    _activeId = id;
    error = null;
    await _credentialDeletion;
    _token = await _credentials.readToken(id);
    await _store.writeActiveId(id);
    notifyListeners();
    return _token != null;
  }

  /// Clears the **active** profile's token and returns to the Connect screen.
  /// The profile itself (and its URL) is kept.
  Future<void> logout() async {
    final id = _activeId;
    _token = null;
    error = null;
    notifyListeners();
    if (id != null) {
      _credentialDeletion = _credentials.deleteToken(id).catchError((Object e) {
        error = 'Could not clear the stored session: $e';
        notifyListeners();
      });
      await _credentialDeletion;
    }
  }

  /// A rejected request may belong to a session that has since been replaced.
  Future<void> invalidateSession(ActiveSession rejected) async {
    if (_activeId != rejected.profile.id || _token != rejected.token) return;
    await logout();
  }

  /// Removes [id] and its token. Removing the active server also logs out;
  /// removing the last server leaves a fresh, first-run state.
  Future<void> removeProfile(String id) async {
    await _credentials.deleteToken(id);
    _profiles.removeWhere((p) => p.id == id);

    if (_activeId == id) {
      _activeId = null;
      _token = null;
    }

    await _persist();
    notifyListeners();
  }

  /// Renames [id]. No-op for a blank name or an unknown id.
  Future<void> renameProfile(String id, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;

    final index = _profiles.indexWhere((p) => p.id == id);
    if (index == -1) return;

    _profiles[index] = _profiles[index].copyWith(name: trimmed);
    await _store.writeProfiles(_profiles);
    notifyListeners();
  }

  /// Clears the current error.
  void clearError() {
    if (error == null) return;
    error = null;
    notifyListeners();
  }

  Future<void> _persist() async {
    await _store.writeProfiles(_profiles);
    await _store.writeActiveId(_activeId);
  }

  String _newId() =>
      'srv-${DateTime.now().microsecondsSinceEpoch}-${_idCounter++}';

  static String _resolveName(String? name, String baseUrl) {
    final trimmed = name?.trim() ?? '';
    return trimmed.isEmpty ? serverNameFromUrl(baseUrl) : trimmed;
  }

  @override
  void dispose() {
    _api.close();
    super.dispose();
  }
}
