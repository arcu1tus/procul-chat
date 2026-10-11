import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'server_profile.dart';

/// Persists the saved server profiles and which one is active, in
/// `shared_preferences`. Session tokens are **not** stored here — they live in
/// the [CredentialStore].
class ServerStore {
  static const _profilesKey = 'server_profiles';
  static const _activeKey = 'active_server_id';

  Future<List<ServerProfile>> readProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_profilesKey);
    if (raw == null || raw.isEmpty) return const [];

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((entry) => ServerProfile.fromJson(entry.cast<String, dynamic>()))
          .toList(growable: false);
    } on FormatException {
      return const [];
    }
  }

  Future<void> writeProfiles(List<ServerProfile> profiles) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _profilesKey,
      jsonEncode([for (final profile in profiles) profile.toJson()]),
    );
  }

  Future<String?> readActiveId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_activeKey);
  }

  Future<void> writeActiveId(String? id) async {
    final prefs = await SharedPreferences.getInstance();
    if (id == null) {
      await prefs.remove(_activeKey);
    } else {
      await prefs.setString(_activeKey, id);
    }
  }
}
