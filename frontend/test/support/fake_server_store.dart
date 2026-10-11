import 'package:procul_chat_flutter/src/server_profile.dart';
import 'package:procul_chat_flutter/src/server_store.dart';

/// In-memory [ServerStore] for tests, so they don't need `shared_preferences`.
class FakeServerStore implements ServerStore {
  FakeServerStore({List<ServerProfile>? profiles, this.activeId})
    : profiles = List.of(profiles ?? const []);

  List<ServerProfile> profiles;
  String? activeId;

  @override
  Future<List<ServerProfile>> readProfiles() async => List.of(profiles);

  @override
  Future<void> writeProfiles(List<ServerProfile> profiles) async =>
      this.profiles = List.of(profiles);

  @override
  Future<String?> readActiveId() async => activeId;

  @override
  Future<void> writeActiveId(String? id) async => activeId = id;
}
