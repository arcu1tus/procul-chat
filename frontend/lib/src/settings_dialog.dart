import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'auth_controller.dart';
import 'server_form.dart';
import 'settings_controller.dart';

/// Opens the settings dialog: appearance plus server management.
Future<void> showSettingsDialog(
  BuildContext context,
  SettingsController settings,
  AuthController auth,
) {
  return showOverlay<void>(
    context,
    DialogConfiguration(),
    builder: (context) {
      return AlertDialog(
        title: const Text('Settings'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: ListenableBuilder(
            listenable: Listenable.merge([settings, auth]),
            builder: (context, _) => SingleChildScrollView(
              child: Column(
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
                  const Gap(24),
                  const Divider(),
                  const Gap(16),
                  _ServerSection(auth: auth),
                ],
              ),
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

/// Server management: current server, switching, adding, removing and logging
/// out.
class _ServerSection extends StatelessWidget {
  const _ServerSection({required this.auth});

  final AuthController auth;

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);
    final active = auth.activeProfile;
    final authenticated = auth.active != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Server').semiBold(),
        const Gap(2),
        const Text(
          'The backend this app talks to and the session it is signed in with.',
        ).muted.small(),
        const Gap(14),

        // Current server.
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: colors.muted,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: colors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(active?.name ?? 'Not connected').medium,
              const Gap(1),
              Text(active?.baseUrl ?? '—').muted.xSmall,
              const Gap(4),
              Text(
                authenticated ? 'Signed in' : 'Not signed in',
                style: TextStyle(
                  fontSize: 11,
                  color: authenticated
                      ? colors.primary
                      : colors.mutedForeground,
                ),
              ),
            ],
          ),
        ),

        if (auth.profiles.length > 1) ...[
          const Gap(16),
          const Text('Switch server').muted.small,
          const Gap(6),
          for (final profile in auth.profiles)
            if (profile.id != active?.id)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: OutlineButton(
                  alignment: Alignment.centerLeft,
                  onPressed: () async {
                    Navigator.pop(context);
                    await auth.switchTo(profile.id);
                  },
                  child: Row(
                    children: [
                      Icon(
                        LucideIcons.server,
                        size: 14,
                        color: colors.mutedForeground,
                      ),
                      const Gap(8),
                      Expanded(
                        child: Text(
                          profile.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
        ],

        const Gap(16),
        Row(
          children: [
            Expanded(
              child: OutlineButton(
                onPressed: () => showAddServerDialog(context, auth),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(LucideIcons.plus, size: 15),
                    Gap(6),
                    Text('Add server'),
                  ],
                ),
              ),
            ),
            if (active != null) ...[
              const Gap(8),
              Expanded(
                child: DestructiveButton(
                  onPressed: () => confirmRemoveServer(context, auth, active),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(LucideIcons.trash2, size: 15),
                      Gap(6),
                      Text('Remove'),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),

        if (authenticated) ...[
          const Gap(8),
          OutlineButton(
            alignment: Alignment.centerLeft,
            onPressed: () {
              Navigator.pop(context);
              auth.logout();
            },
            child: const Row(
              children: [
                Icon(LucideIcons.logOut, size: 15),
                Gap(8),
                Text('Log out'),
              ],
            ),
          ),
        ],
      ],
    );
  }
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
