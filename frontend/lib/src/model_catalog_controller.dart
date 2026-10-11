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
    isLoading = true;
    error = null;
    notifyListeners();

    try {
      final fetched = await api.fetchModels();
      models = fetched;
      defaultModel = _deriveDefault(fetched);
    } catch (e) {
      error = 'Could not load models: $e';
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  /// Initial load; identical to [refresh] but reads better at the call site.
  Future<void> load() => refresh();

  /// Re-probes one model, then refreshes so its health snapshot updates.
  Future<void> check(String slug) async {
    checkingSlug = slug;
    error = null;
    notifyListeners();

    try {
      await api.checkModel(slug);
    } catch (e) {
      error = 'Could not check $slug: $e';
    } finally {
      checkingSlug = null;
      notifyListeners();
    }

    // Only refresh when the probe succeeded, so a check failure is not hidden
    // by a successful (but unrelated) catalog reload.
    if (error == null) await refresh();
  }

  /// Re-probes every health-checked model, then refreshes.
  Future<void> checkAll() async {
    isCheckingAll = true;
    error = null;
    notifyListeners();

    try {
      await api.checkModels();
    } catch (e) {
      error = 'Could not check models: $e';
    } finally {
      isCheckingAll = false;
      notifyListeners();
    }

    if (error == null) await refresh();
  }

  /// The `isDefault` entry's slug, falling back to the first model.
  static String? _deriveDefault(List<ChatModel> models) {
    for (final model in models) {
      if (model.isDefault) return model.slug;
    }
    return models.isEmpty ? null : models.first.slug;
  }
}
