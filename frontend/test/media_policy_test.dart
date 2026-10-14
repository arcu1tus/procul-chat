import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:procul_chat_flutter/src/attachments.dart';
import 'package:procul_chat_flutter/src/chat_api.dart';
import 'package:procul_chat_flutter/src/chat_controller.dart';
import 'package:procul_chat_flutter/src/models.dart';

import 'support/fake_conversation_store.dart';
import 'support/media_fixture.dart';

final photo = PickedAttachment(
  bytes: Uint8List.fromList([1]),
  fileName: 'photo.png',
  contentType: 'image/png',
);
const uploaded = {
  'id': 'a1',
  'fileName': 'photo.png',
  'contentType': 'image/png',
  'sizeBytes': 1,
};
const textModel = ChatModel(
  slug: 'text',
  name: 'Text',
  capabilities: ModelCapabilities(input: {ModelInputModality.text}),
);
ChatController chatWith(http.Client client) => withMediaPolicy(
  ChatController(
    api: ChatApi(baseUrl: 'http://test', token: 'token', client: client),
    store: FakeConversationStore(),
  ),
);
void main() {
  test(
    'media is blocked until the backend policy and catalog are loaded',
    () async {
      var requests = 0;
      final chat = ChatController(
        api: ChatApi(
          baseUrl: 'http://test',
          token: 'token',
          client: MockClient((_) async {
            requests++;
            return http.Response('{}', 200);
          }),
        ),
        store: FakeConversationStore(),
      );
      addTearDown(chat.dispose);
      expect(await chat.uploadAttachment(photo), isFalse);
      expect(requests, 0);
    },
  );
  test('a model switch during upload preserves a marked chip and blocks submission', () async {
    final pending = Completer<http.Response>();
    final chat = chatWith(MockClient((_) => pending.future));
    addTearDown(chat.dispose);
    final uploading = chat.uploadAttachment(photo);
    chat.setModels([textModel]);
    await chat.setModel('text');
    pending.complete(http.Response(jsonEncode(uploaded), 201));
    expect(await uploading, isFalse);
    expect(chat.pendingAttachments, hasLength(1));
    expect(
      chat.pendingAttachmentProblem(chat.pendingAttachments.single),
      contains('capability'),
    );
    await chat.send('caption');
    expect(chat.messages, isEmpty);
    expect(chat.pendingAttachments, hasLength(1));
  });
  test('configured count and MIME limits reject before upload', () async {
    var uploads = 0;
    final chat = chatWith(
      MockClient((_) async {
        uploads++;
        return http.Response(jsonEncode(uploaded), 201);
      }),
    );
    addTearDown(chat.dispose);
    chat.attachmentPolicy = const AttachmentPolicy(
      maxAttachmentsPerMessage: 1,
      maxFileSizeBytes: 10,
      allowedContentTypes: ['image/png'],
    );
    await chat.uploadAttachments([photo, photo]);
    expect(uploads, 1);
    expect(chat.pendingAttachments, hasLength(1));
    expect(chat.error, contains('at most 1'));
  });
  test(
    'media-only messages send and pre-acceptance rejection preserves the draft',
    () async {
      Map<String, dynamic>? sent;
      final chat = chatWith(
        MockClient((request) async {
          if (request.method == 'POST' &&
              request.url.path == '/v1/attachments') {
            return http.Response(jsonEncode(uploaded), 201);
          }
          sent = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response('{"detail":"unsupported"}', 400);
        }),
      );
      addTearDown(chat.dispose);
      await chat.uploadAttachment(photo);
      await chat.send('');
      expect(sent!['initialMessage'], '');
      expect(sent!['attachmentIds'], ['a1']);
      expect(chat.messages, isEmpty);
      expect(chat.pendingAttachments.single.id, 'a1');
      expect(chat.rejectedDraftText, '');
    },
  );
}
