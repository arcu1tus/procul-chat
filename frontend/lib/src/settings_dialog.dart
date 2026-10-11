import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'settings_controller.dart';

/// Opens the settings dialog. Dark mode is the only setting for now.
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
            builder: (context, _) => Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(
                  settings.isDark ? LucideIcons.moon : LucideIcons.sun,
                  size: 20,
                ),
                const Gap(12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Dark mode').semiBold(),
                      const Text('Use a dark color theme').muted().small(),
                    ],
                  ),
                ),
                Switch(
                  value: settings.isDark,
                  onChanged: (value) => settings.setDarkMode(value),
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
