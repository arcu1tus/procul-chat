import 'package:google_fonts/google_fonts.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'auth_controller.dart';
import 'config.dart';
import 'motion.dart';
import 'widgets/stagger.dart';
import 'server_form.dart';
import 'server_profile.dart';

/// Shown when no server is authenticated: pick a saved server or add one.
class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key, required this.auth});

  final AuthController auth;

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  ServerProfile? _selected;

  Future<void> _select(ServerProfile profile) async {
    setState(() => _selected = profile);
    // A stored token authenticates immediately; otherwise the form below asks
    // for the password (the profile is now active, so the URL is preserved).
    await widget.auth.switchTo(profile.id);
  }

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);

    return Scaffold(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: ListenableBuilder(
              listenable: widget.auth,
              builder: (context, _) {
                final profiles = widget.auth.profiles;

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Stagger(index: 0, child: _Brand(colors: colors)),
                    const Gap(28),
                    if (profiles.isNotEmpty) ...[
                      const Text('Saved servers').semiBold,
                      const Gap(8),
                      for (final (index, profile) in profiles.indexed)
                        Stagger(
                          index: index + 1,
                          child: _ServerTile(
                            profile: profile,
                            selected: profile.id == _selected?.id,
                            onTap: () => _select(profile),
                          ),
                        ),
                      const Gap(22),
                      const Text('Or add another server').semiBold,
                    ] else
                      const Text('Connect to your server').semiBold,
                    const Gap(10),
                    ServerForm(
                      key: ValueKey(_selected?.id ?? 'new'),
                      auth: widget.auth,
                      initialBaseUrl: _selected?.baseUrl ?? apiBaseUrl,
                      initialName: _selected?.name,
                      autofocusPassword: _selected != null,
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand({required this.colors});

  final ColorScheme colors;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: colors.primary,
            borderRadius: BorderRadius.circular(13),
          ),
          child: Icon(
            LucideIcons.messagesSquare,
            size: 25,
            color: colors.primaryForeground,
          ),
        ),
        const Gap(14),
        Text(
          'Procul',
          style: GoogleFonts.coiny(
            fontSize: 40,
            height: 1,
            color: colors.foreground,
          ),
        ),
        const Gap(8),
        const Text('Sign in to start chatting.').muted.small,
      ],
    );
  }
}

class _ServerTile extends StatefulWidget {
  const _ServerTile({
    required this.profile,
    required this.selected,
    required this.onTap,
  });

  final ServerProfile profile;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_ServerTile> createState() => _ServerTileState();
}

class _ServerTileState extends State<_ServerTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Clickable(
        onPressed: widget.onTap,
        onHover: (value) => setState(() => _hovered = value),
        disableHoverEffect: true,
        child: AnimatedContainer(
          duration: motionDuration(context, Motion.fast),
          curve: Motion.curve,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: widget.selected
                ? colors.accent
                : _hovered
                ? colors.accent.withValues(alpha: 0.5)
                : const Color(0x00000000),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: colors.border),
          ),
          child: Row(
            children: [
              Icon(LucideIcons.server, size: 16, color: colors.mutedForeground),
              const Gap(10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(widget.profile.name).medium,
                    const Gap(1),
                    Text(
                      widget.profile.baseUrl,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ).muted.xSmall,
                  ],
                ),
              ),
              if (widget.selected) ...[
                const Gap(8),
                Icon(LucideIcons.check, size: 16, color: colors.primary),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
