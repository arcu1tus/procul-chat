import 'package:flutter/foundation.dart';

import 'chat_api.dart';
import 'usage.dart';

/// Loads and exposes the token-usage dashboard for the active backend.
///
/// Owned by [UsageScreen]: created when the screen opens, `load()`ed once, and
/// refreshed by pull-to-refresh, the app-bar button, or a range change.
class UsageController extends ChangeNotifier {
  UsageController({required this.api});

  final ChatApi api;

  /// The ranges offered, in tokens-days. `365` is the "all" view (the backend
  /// caps a window at 366 days).
  static const rangeOptions = <int>[7, 30, 90, 365];

  /// The most recently fetched summary, or null before the first load.
  UsageSummary? summary;

  /// The selected window, in days.
  int selectedRange = 30;

  /// True while a fetch is in flight.
  bool isLoading = false;

  /// The most recent user-facing error, if any.
  String? error;

  /// Lifetime totals (zero before the first load).
  UsageBreakdown get lifetime => summary?.lifetime ?? const UsageBreakdown();

  /// The per-day breakdown of the selected window (empty before the first load).
  List<UsageDay> get days => summary?.days ?? const [];

  /// The per-model breakdown of the selected window (empty before the first load).
  List<UsageModel> get models => summary?.models ?? const [];

  /// Whether nothing has ever been recorded.
  bool get isEmpty => lifetime.isEmpty;

  /// Fetches the summary for [selectedRange], showing the loading state.
  Future<void> refresh() async {
    isLoading = true;
    error = null;
    notifyListeners();

    try {
      summary = await api.fetchUsage(days: selectedRange);
    } catch (e) {
      error = 'Could not load usage: $e';
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  /// Initial load; identical to [refresh] but reads better at the call site.
  Future<void> load() => refresh();

  /// Switches the window and refetches. No-op when the range is unchanged.
  Future<void> setRange(int days) async {
    if (days == selectedRange) return;
    selectedRange = days;
    await refresh();
  }
}
