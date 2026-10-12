import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'auth_controller.dart';
import 'chat_api.dart';
import 'mcp_status.dart';
import 'mcp_status_controller.dart';
import 'server_form.dart';
import 'settings_controller.dart';
import 'widgets/content_width.dart';
import 'widgets/icon_action.dart';
import 'widgets/skeleton.dart';

/// The Settings destination: appearance, server management, and tool servers.
///
/// A full pane with the same `Scaffold` + `AppBar` treatment as Usage and Models
/// (a menu button on narrow screens), selected from the sidebar's tab row — not
/// a popup. Add-server and the remove confirmation stay modal; they are the only
/// settings flows that are genuinely modal.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.settings,
    required this.auth,
    required this.api,
    this.showMenuButton = false,
    this.onMenu,
  });

  final SettingsController settings;
  final AuthController auth;
  final ChatApi api;

  /// Whether to show a leading button that opens the conversation drawer.
  final bool showMenuButton;
  final VoidCallback? onMenu;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([settings, auth]),
      builder: (context, _) {
        return Scaffold(
          headers: [
            AppBar(
              title: const Text(
                'Settings',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: const Text(
                'Appearance, server, and tools',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ).muted.small,
              leading: showMenuButton
                  ? [
                      IconAction(
                        icon: LucideIcons.panelLeft,
                        label: 'Open chats',
                        onPressed: onMenu,
                      ),
                    ]
                  : const [],
            ),
            const Divider(),
          ],
          child: LayoutBuilder(
            builder: (context, constraints) {
              final side = centeredSidePadding(constraints.maxWidth);
              return ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.fromLTRB(20 + side, 20, 20 + side, 28),
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
                  const Gap(24),
                  const Divider(),
                  const Gap(16),
                  _McpSection(api: api),
                ],
              );
            },
          ),
        );
      },
    );
  }
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
                  onPressed: () => auth.switchTo(profile.id),
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
            onPressed: auth.logout,
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

/// Read-only view of the MCP tool servers the backend is configured with.
///
/// The backend never returns headers or tokens, and this section never renders any.
class _McpSection extends StatefulWidget {
  const _McpSection({required this.api});

  final ChatApi api;

  @override
  State<_McpSection> createState() => _McpSectionState();
}

class _McpSectionState extends State<_McpSection> {
  late final McpStatusController _mcp;

  @override
  void initState() {
    super.initState();
    _mcp = McpStatusController(api: widget.api);
    _mcp.load();
  }

  @override
  void dispose() {
    _mcp.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);
    return ListenableBuilder(
      listenable: _mcp,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(child: const Text('Tools (MCP)').semiBold()),
              IconAction(
                icon: LucideIcons.refreshCw,
                label: 'Refresh tool servers',
                size: 16,
                onPressed: _mcp.isLoading ? null : _mcp.refresh,
              ),
            ],
          ),
          const Gap(2),
          const Text(
            'Remote tool servers the assistant can call. Read-only; tokens are never shown.',
          ).muted.small(),
          const Gap(14),
          _body(colors),
        ],
      ),
    );
  }

  Widget _body(ColorScheme colors) {
    if (_mcp.isLoading && _mcp.servers.isEmpty) {
      return const _McpSkeleton();
    }

    if (_mcp.error != null) {
      return Text(
        _mcp.error!,
        style: TextStyle(fontSize: 12, color: colors.destructive),
      );
    }

    if (_mcp.servers.isEmpty) {
      return const Text('No tool servers configured.').muted.small;
    }

    final online = _mcp.servers.where((server) => server.connected).length;
    final tools = _mcp.servers.fold<int>(
      0,
      (sum, server) => sum + server.toolCount,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$online of ${_mcp.servers.length} servers online · $tools tools')
            .muted
            .small,
        const Gap(8),
        RefreshTrigger(
          onRefresh: _mcp.refresh,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260),
            child: ListView(
              shrinkWrap: true,
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                for (final server in _mcp.servers)
                  _McpServerTile(server: server),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _McpServerTile extends StatelessWidget {
  const _McpServerTile({required this.server});

  final McpServerStatus server;

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);
    final statusColor = server.connected
        ? const Color(0xFF22C55E)
        : colors.destructive;

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
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
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: statusColor,
                  shape: BoxShape.circle,
                ),
              ),
              const Gap(8),
              Expanded(
                child: Text(
                  server.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ).medium,
              ),
              const Gap(8),
              _TransportBadge(type: server.type),
            ],
          ),
          const Gap(4),
          Text(
            server.connected
                ? '${server.toolCount} ${server.toolCount == 1 ? 'tool' : 'tools'}'
                : (server.lastError ?? 'Offline'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              color: server.connected
                  ? colors.mutedForeground
                  : colors.destructive,
            ),
          ),
        ],
      ),
    );
  }
}

/// A small pill showing the transport (`http` / `sse`).
class _TransportBadge extends StatelessWidget {
  const _TransportBadge({required this.type});

  final String type;

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: colors.secondary,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: colors.border),
      ),
      child: Text(
        type,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: colors.mutedForeground,
        ),
      ),
    );
  }
}

/// Shimmer rows shaped like server tiles, shown while the status loads.
class _McpSkeleton extends StatelessWidget {
  const _McpSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Shimmer(
      child: Column(children: [_McpSkeletonRow(), _McpSkeletonRow()]),
    );
  }
}

class _McpSkeletonRow extends StatelessWidget {
  const _McpSkeletonRow();

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.border),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          FractionallySizedBox(
            widthFactor: 0.5,
            alignment: Alignment.centerLeft,
            child: Skeleton(height: 12),
          ),
          Gap(8),
          FractionallySizedBox(
            widthFactor: 0.25,
            alignment: Alignment.centerLeft,
            child: Skeleton(height: 10),
          ),
        ],
      ),
    );
  }
}
