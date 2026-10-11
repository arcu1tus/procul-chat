import 'dart:convert';

import 'package:http/http.dart' as http;

/// A session token and its expiry, as returned by `POST /v1/auth/session`.
class SessionToken {
  const SessionToken({required this.token, this.expiresAt});

  final String token;
  final DateTime? expiresAt;
}

/// A user-facing failure while authenticating (unreachable server, wrong
/// password, bad response).
class AuthException implements Exception {
  AuthException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Unauthenticated client for the auth endpoint: exchanges the shared password
/// for a session token.
class AuthApi {
  AuthApi({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// `POST /v1/auth/session`. Throws [AuthException] on a wrong password, an
  /// unreachable server, or any non-success response.
  Future<SessionToken> createSession(String baseUrl, String password) async {
    final http.Response response;
    try {
      response = await _client.post(
        Uri.parse('$baseUrl/v1/auth/session'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'password': password}),
      );
    } catch (e) {
      throw AuthException('Could not reach the server. Check the URL. ($e)');
    }

    if (response.statusCode == 401) {
      throw AuthException('Incorrect password.');
    }
    if (response.statusCode != 200) {
      throw AuthException(
        'The server rejected the request (HTTP ${response.statusCode}).',
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw AuthException('The server returned an unexpected response.');
    }

    if (decoded is! Map) {
      throw AuthException('The server returned an unexpected response.');
    }

    final token = decoded['token'];
    if (token is! String || token.isEmpty) {
      throw AuthException('The server did not return a session token.');
    }

    return SessionToken(
      token: token,
      expiresAt: DateTime.tryParse('${decoded['expiresAt']}'),
    );
  }

  void close() => _client.close();
}
