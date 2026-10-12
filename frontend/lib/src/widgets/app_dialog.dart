import 'package:shadcn_flutter/shadcn_flutter.dart';

import '../motion.dart';

/// Presents a modal dialog with the app's standard motion.
///
/// A thin, opinionated wrapper over shadcn's `showOverlay` +
/// `DialogConfiguration`: one place to keep dialog presentation consistent
/// (barrier, safe area, root navigator) so a call site does not have to
/// remember it. Returns the dialog's result via `.future`.
///
/// Use it for the modals that genuinely should be modals — add-server, rename,
/// delete/remove confirmations. Full destinations are panes, not dialogs (see
/// `SettingsScreen`).
Future<T?> showAppDialog<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  return showOverlay<T>(
    context,
    DialogConfiguration(barrierDismissible: barrierDismissible),
    builder: builder,
  ).future;
}

/// Presents a dropdown/popover menu with the app's standard open/close motion.
///
/// Mirrors `showDropdown` but fixes [showDuration]/[dismissDuration] to the
/// shared motion tokens so every menu in the app opens and dismisses at the same
/// cadence. Returns the [OverlayCompleter] so callers can await a selection.
OverlayCompleter<T?> showAppMenu<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  AlignmentGeometry? alignment,
  Offset? offset,
  bool modal = true,
}) {
  return showDropdown<T>(
    context: context,
    alignment: alignment,
    offset: offset,
    modal: modal,
    showDuration: Motion.medium,
    dismissDuration: Motion.fast,
    builder: builder,
  );
}
