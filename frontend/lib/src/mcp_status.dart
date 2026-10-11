/// Read-only status of one MCP server, as returned by `GET /v1/mcp/servers`.
///
/// The backend never includes headers or tokens, so nothing here is secret.
class McpServerStatus {
  const McpServerStatus({
    required this.name,
    required this.type,
    required this.url,
    required this.connected,
    required this.toolCount,
    required this.tools,
    this.lastError,
    this.lastConnectedAt,
  });

  final String name;

  /// The transport: `http` (Streamable HTTP) or `sse` (legacy).
  final String type;

  final String url;
  final bool connected;
  final int toolCount;

  /// Names of the tools discovered from this server (un-namespaced).
  final List<String> tools;

  /// Why the last connection attempt failed, or null.
  final String? lastError;

  /// When the server was last successfully connected, or null.
  final DateTime? lastConnectedAt;

  factory McpServerStatus.fromJson(Map<String, dynamic> json) =>
      McpServerStatus(
        name: '${json['name'] ?? ''}',
        type: '${json['type'] ?? ''}',
        url: '${json['url'] ?? ''}',
        connected: json['connected'] == true,
        toolCount: (json['toolCount'] as num?)?.toInt() ?? 0,
        tools: (json['tools'] as List<dynamic>? ?? const [])
            .map((tool) => '$tool')
            .toList(growable: false),
        lastError: json['lastError'] as String?,
        lastConnectedAt: DateTime.tryParse('${json['lastConnectedAt']}'),
      );
}
