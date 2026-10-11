/// A saved backend the app can connect to.
///
/// The [id] is stable and independent of the URL (it keys the secure-storage
/// token and the persisted profile list); the [baseUrl] is the canonical origin
/// the API is reached at.
class ServerProfile {
  const ServerProfile({
    required this.id,
    required this.name,
    required this.baseUrl,
  });

  final String id;
  final String name;
  final String baseUrl;

  ServerProfile copyWith({String? name, String? baseUrl}) => ServerProfile(
    id: id,
    name: name ?? this.name,
    baseUrl: baseUrl ?? this.baseUrl,
  );

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'baseUrl': baseUrl};

  factory ServerProfile.fromJson(Map<String, dynamic> json) => ServerProfile(
    id: json['id'] as String,
    name: (json['name'] as String?) ?? '',
    baseUrl: json['baseUrl'] as String,
  );
}

/// Parses a user-entered base URL into an absolute http(s) [Uri], or returns
/// null when it is not usable (empty, relative, wrong scheme, or carrying a
/// query/fragment).
Uri? parseServerBaseUrl(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;

  final uri = Uri.tryParse(trimmed);
  if (uri == null) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  if (!uri.hasAuthority || uri.host.isEmpty) return null;
  if (uri.hasQuery || uri.hasFragment) return null;

  return uri;
}

/// The canonical base URL string for [uri]: no trailing slash, query or
/// fragment. Two spellings of the same origin normalize to the same string so
/// they map to one profile.
String normalizeBaseUrl(Uri uri) {
  var path = uri.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return '${uri.origin}$path';
}

/// Whether [host] is a loopback/emulator address that is safe over plain HTTP.
bool isLocalHost(String host) {
  const local = {'localhost', '127.0.0.1', '::1', '10.0.2.2'};
  return local.contains(host.toLowerCase());
}

/// Derives a default profile name from a base URL: its host, or the whole URL
/// if there is no usable host.
String serverNameFromUrl(String baseUrl) {
  final uri = Uri.tryParse(baseUrl);
  final host = uri?.host ?? '';
  return host.isEmpty ? baseUrl : host;
}
