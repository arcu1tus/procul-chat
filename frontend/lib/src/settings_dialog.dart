import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'settings_controller.dart';

/// Opens the settings dialog. Theme mode is the only setting for now.
Future<void> showSettingsDialog(
  BuildContext context,
  SettingsController settings,
) {
  return showOverlay<void>(
    context,
    DialogConfiguration(),
    builder: (context) {
      return AlertDialog(
        title: const Text('Settings'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: ListenableBuilder(
            listenable: settings,
            builder: (context, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Appearance').semiBold(),
                const Gap(2),
                const Text(
                  'Choose how Procul looks. System follows your device.',
                ).muted.small(),
                const Gap(14),
                _ThemeModeSelector(
                  mode: settings.themeMode,
                  onChanged: settings.setThemeMode,
                ),
              ],
            ),
          ),
        ),
        actions: [
          PrimaryButton(
            child: const Text('Done'),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      );
    },
  ).future;
}

/// A three-way Light / Dark / System segmented control.
class _ThemeModeSelector extends StatelessWidget {
  const _ThemeModeSelector({required this.mode, required this.onChanged});

  final ThemeMode mode;
  final ValueChanged<ThemeMode> onChanged;

  static const _options = [
    (ThemeMode.light, 'Light', LucideIcons.sun),
    (ThemeMode.dark, 'Dark', LucideIcons.moon),
    (ThemeMode.system, 'System', LucideIcons.monitor),
  ];

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: colors.muted,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        children: [
          for (final (value, label, icon) in _options)
            Expanded(
              child: SelectedButton(
                value: mode == value,
                onChanged: (_) => onChanged(value),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [Icon(icon, size: 15), const Gap(6), Text(label)],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
