import 'package:flutter/foundation.dart';

import 'chat_api.dart';
import 'mcp_status.dart';

/// Loads and exposes the read-only MCP server status for the active backend.
///
/// Owned by the Settings dialog's Tools (MCP) section: created when the dialog opens,
/// `load()`ed once, and refreshed by pull-to-refresh or the section's refresh button.
class McpStatusController extends ChangeNotifier {
  McpStatusController({required this.api});

  final ChatApi api;
  int _generation = 0;
  bool _disposed = false;

  /// The configured servers, in backend order.
  List<McpServerStatus> servers = const [];

  /// True while a fetch is in flight.
  bool isLoading = false;

  /// The most recent user-facing error, if any.
  String? error;

  /// Fetches the status, showing the loading state. Safe to call repeatedly.
  Future<void> refresh() async {
    if (_disposed) return;
    final generation = ++_generation;
    isLoading = true;
    error = null;
    notifyListeners();

    try {
      final fetched = await api.fetchMcpServers();
      if (generation != _generation) return;
      servers = fetched;
    } catch (e) {
      if (generation == _generation) error = 'Could not load tool servers: $e';
    } finally {
      if (generation == _generation) {
        isLoading = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }

  /// Initial load; identical to [refresh] but reads better at the call site.
  Future<void> load() => refresh();
}
