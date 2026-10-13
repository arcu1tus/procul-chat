import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:procul_chat_flutter/src/chat_api.dart';
import 'package:procul_chat_flutter/src/model_catalog_controller.dart';
import 'package:procul_chat_flutter/src/models.dart';

import 'support/model_fixtures.dart';

ChatApi _api(MockClient client) =>
    ChatApi(baseUrl: 'http://test', token: 'tok', client: client);

void main() {
  test('a stale refresh failure cannot clear a newer loading state', () async {
    final first = Completer<http.Response>();
    final second = Completer<http.Response>();
    var requests = 0;
    final controller = ModelCatalogController(
      api: _api(
        MockClient((_) {
          return requests++ == 0 ? first.future : second.future;
        }),
      ),
    );
    addTearDown(controller.dispose);
    final loading = controller.load();
    final refreshing = controller.refresh();
    first.complete(http.Response('old request failed', 500));
    await loading;
    expect(controller.isLoading, isTrue);
    expect(controller.error, isNull);
    second.complete(http.Response(jsonEncode(testModelsJson), 200));
    await refreshing;
    expect(controller.error, isNull);
    expect(controller.isLoading, isFalse);
  });

  test('disposing during load ignores the late response', () async {
    final response = Completer<http.Response>();
    final controller = ModelCatalogController(
      api: _api(MockClient((_) => response.future)),
    );
    final loading = controller.load();
    controller.dispose();
    response.complete(http.Response(jsonEncode(testModelsJson), 200));
    await loading;
    expect(controller.models, isEmpty);
  });

  test(
    'fetchModels parses the payload, sends the token, and maps the model',
    () async {
      late http.BaseRequest seen;
      final api = _api(
        MockClient((request) async {
          seen = request;
          return http.Response(jsonEncode(testModelsJson), 200);
        }),
      );

      final models = await api.fetchModels();

      expect(seen.url.path, '/v1/models');
      expect(seen.headers['Authorization'], 'Bearer tok');
      expect(models, hasLength(2));

      final first = models.first;
      expect(first.slug, 'openai/gpt-4o-mini');
      expect(first.name, 'GPT-4o mini');
      expect(first.description, 'Fast and cheap');
      expect(first.provider, 'openrouter');
      expect(first.isDefault, isTrue);
      expect(first.capabilities.input, {
        ModelInputModality.text,
        ModelInputModality.image,
      });
      expect(first.health.status, ModelHealthStatus.healthy);
      expect(first.health.latencyMs, 123);
      expect(first.health.lastCheckedAt, isNotNull);

      // `pdf` (the backend's alias for `file`) maps to the file modality.
      expect(models[1].capabilities.input, {
        ModelInputModality.text,
        ModelInputModality.audio,
        ModelInputModality.file,
      });
      expect(models[1].health.status, ModelHealthStatus.unhealthy);
      expect(models[1].health.lastError, 'connection refused');
    },
  );

  test('the controller loads models and derives the default', () async {
    final controller = ModelCatalogController(
      api: _api(
        MockClient((_) async => http.Response(jsonEncode(testModelsJson), 200)),
      ),
    );

    expect(controller.isLoading, isFalse);
    expect(controller.models, isEmpty);

    await controller.load();

    expect(controller.isLoading, isFalse);
    expect(controller.error, isNull);
    expect(controller.models, hasLength(2));
    expect(controller.defaultModel, 'openai/gpt-4o-mini');
    expect(controller.hasChoice, isTrue);
  });

  test('refresh surfaces a failure as a user-facing error', () async {
    final controller = ModelCatalogController(
      api: _api(MockClient((_) async => http.Response('boom', 500))),
    );

    await controller.refresh();

    expect(controller.models, isEmpty);
    expect(controller.error, isNotNull);
    expect(controller.error, contains('Could not load models'));
  });

  test('refresh recovers after a failure', () async {
    var fail = true;
    final controller = ModelCatalogController(
      api: _api(
        MockClient(
          (_) async => fail
              ? http.Response('boom', 500)
              : http.Response(jsonEncode(testModelsJson), 200),
        ),
      ),
    );

    await controller.refresh();
    expect(controller.error, isNotNull);

    fail = false;
    await controller.refresh();
    expect(controller.error, isNull);
    expect(controller.models, hasLength(2));
  });

  test('check posts to the model path and then refreshes', () async {
    final gets = <String>[];
    final posts = <String>[];
    final controller = ModelCatalogController(
      api: _api(
        MockClient((request) async {
          if (request.method == 'POST') {
            posts.add(request.url.path);
          } else {
            gets.add(request.url.path);
          }
          return http.Response(jsonEncode(testModelsJson), 200);
        }),
      ),
    );

    await controller.load();
    expect(gets, ['/v1/models']);

    await controller.check('local/llama');

    expect(posts, ['/v1/models/local/llama/check']);
    expect(gets, ['/v1/models', '/v1/models']);
    expect(controller.checkingSlug, isNull);
    expect(controller.error, isNull);
  });

  test('checkAll posts to the check-all path and then refreshes', () async {
    final gets = <String>[];
    final posts = <String>[];
    final controller = ModelCatalogController(
      api: _api(
        MockClient((request) async {
          if (request.method == 'POST') {
            posts.add(request.url.path);
          } else {
            gets.add(request.url.path);
          }
          return http.Response(jsonEncode(testModelsJson), 200);
        }),
      ),
    );

    await controller.load();
    await controller.checkAll();

    expect(posts, ['/v1/models/check']);
    expect(gets, ['/v1/models', '/v1/models']);
    expect(controller.isCheckingAll, isFalse);
    expect(controller.error, isNull);
  });

  test('a failed check surfaces an error and does not refresh', () async {
    var requests = 0;
    final controller = ModelCatalogController(
      api: _api(
        MockClient((request) async {
          requests++;
          if (request.method == 'POST') return http.Response('boom', 500);
          return http.Response(jsonEncode(testModelsJson), 200);
        }),
      ),
    );

    await controller.load();
    await controller.check('local/llama');

    expect(controller.error, contains('Could not check local/llama'));
    // Only the initial load and the failed probe; no follow-up refresh.
    expect(requests, 2);
  });
}
