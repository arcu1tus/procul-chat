import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:procul_chat_flutter/src/chat_api.dart';

/// Existing shell fixtures implement chat routes; supply the new policy route
/// centrally while leaving their streaming transport and assertions intact.
class PolicyChatApi extends ChatApi {
  PolicyChatApi({
    required super.baseUrl,
    required super.token,
    http.Client? client,
    super.onUnauthorized,
  }) : super(client: _PolicyClient(client ?? http.Client()));
}

class _PolicyClient extends http.BaseClient {
  _PolicyClient(this.client);
  final http.Client client;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.path == '/v1/attachments/policy') {
      return http.StreamedResponse(
        Stream.value(
          utf8.encode(
            '{"maxAttachmentsPerMessage":20,"maxFileSizeBytes":20971520,"allowedContentTypes":["image/*","text/*","application/pdf","audio/mpeg","audio/wav"]}',
          ),
        ),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    return client.send(request);
  }

  @override
  void close() => client.close();
}
