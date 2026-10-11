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

  /// The configured servers, in backend order.
  List<McpServerStatus> servers = const [];

  /// True while a fetch is in flight.
  bool isLoading = false;

  /// The most recent user-facing error, if any.
  String? error;

  /// Fetches the status, showing the loading state. Safe to call repeatedly.
  Future<void> refresh() async {
    isLoading = true;
    error = null;
    notifyListeners();

    try {
      servers = await api.fetchMcpServers();
    } catch (e) {
      error = 'Could not load tool servers: $e';
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  /// Initial load; identical to [refresh] but reads better at the call site.
  Future<void> load() => refresh();
}
