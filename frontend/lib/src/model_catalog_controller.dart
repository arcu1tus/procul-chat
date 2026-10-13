import 'package:flutter/foundation.dart';

import 'chat_api.dart';
import 'models.dart';

/// Loads and exposes the configured models for the active backend.
///
/// Owned by the shell so the app-bar model picker and the Models screen share a
/// single source: `load()`ed once when the shell mounts and refreshed on demand
/// (pull-to-refresh, the refresh button, or a health check). Mirrors
/// [McpStatusController].
class ModelCatalogController extends ChangeNotifier {
  ModelCatalogController({required this.api});

  final ChatApi api;
  int _generation = 0;
  bool _disposed = false;

  /// Every configured model, in backend order.
  List<ChatModel> models = const [];

  /// The slug of the default model, or null before the first load.
  String? defaultModel;

  /// True while a catalog fetch is in flight.
  bool isLoading = false;

  /// The slug currently being re-probed by [check], or null when none is.
  String? checkingSlug;

  /// True while [checkAll] is running.
  bool isCheckingAll = false;

  /// The most recent user-facing error, if any.
  String? error;

  /// Whether more than one model is configured (i.e. there is something to pick).
  bool get hasChoice => models.length > 1;

  /// Fetches the catalog, showing the loading state. Safe to call repeatedly.
  Future<void> refresh() async {
    if (_disposed) return;
    final generation = ++_generation;
    isLoading = true;
    error = null;
    notifyListeners();

    try {
      final fetched = await api.fetchModels();
      if (generation != _generation) return;
      models = fetched;
      defaultModel = _deriveDefault(fetched);
    } catch (e) {
      if (generation == _generation) error = 'Could not load models: $e';
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

  /// Re-probes one model, then refreshes its health snapshot.
  Future<void> check(String slug) => _check(slug);

  /// Re-probes every health-checked model, then refreshes the catalog.
  Future<void> checkAll() => _check(null);

  Future<void> _check(String? slug) async {
    if (_disposed || checkingSlug != null || isCheckingAll) return;
    checkingSlug = slug;
    isCheckingAll = slug == null;
    error = null;
    notifyListeners();
    try {
      if (slug == null) {
        await api.checkModels();
      } else {
        await api.checkModel(slug);
      }
      if (_disposed) return;
      // Refresh only after this probe succeeds; another refresh can change
      // `error` independently while the probe is in flight.
      await refresh();
    } catch (e) {
      if (!_disposed) {
        error = slug == null
            ? 'Could not check models: $e'
            : 'Could not check $slug: $e';
      }
    } finally {
      if (!_disposed) {
        checkingSlug = null;
        isCheckingAll = false;
        notifyListeners();
      }
    }
  }

  /// The `isDefault` entry's slug, falling back to the first model.
  static String? _deriveDefault(List<ChatModel> models) {
    for (final model in models) {
      if (model.isDefault) return model.slug;
    }
    return models.isEmpty ? null : models.first.slug;
  }
}
