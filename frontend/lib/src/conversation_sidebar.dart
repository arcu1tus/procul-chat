import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'chat_controller.dart';
import 'conversation_actions.dart';
import 'models.dart';
import 'motion.dart';
import 'time_format.dart';
import 'widgets/app_dialog.dart';
import 'widgets/icon_action.dart';
import 'widgets/procul_logo.dart';
import 'widgets/skeleton.dart';

/// Which of the sidebar's destinations is currently shown in the main pane, so
/// its tab reads as selected.
enum SidebarSection { chat, usage, models, settings }

/// Brand, new chat, search, chats, and utility navigation.
///
/// Shown persistently on wide screens and inside a drawer on narrow ones
/// (where [onClose] dismisses it).
class ConversationSidebar extends StatefulWidget {
  const ConversationSidebar({
    super.key,
    required this.chat,
    this.section = SidebarSection.chat,
    this.onClose,
    this.onOpenUsage,
    this.onOpenModels,
    this.onOpenSettings,
    this.onOpenChat,
  });

  final ChatController chat;

  /// The destination currently shown in the main pane, if any.
  final SidebarSection section;

  /// Called after an action that should dismiss a drawer-hosted sidebar.
  final VoidCallback? onClose;

  /// Opens the usage dashboard in the main pane.
  final VoidCallback? onOpenUsage;

  /// Opens the model catalog in the main pane.
  final VoidCallback? onOpenModels;

  /// Opens the settings pane in the main pane.
  final VoidCallback? onOpenSettings;

  /// Returns the main pane to the active conversation.
  final VoidCallback? onOpenChat;

  @override
  State<ConversationSidebar> createState() => _ConversationSidebarState();
}

class _ConversationSidebarState extends State<ConversationSidebar> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);
    // Use the raw view padding, not `MediaQuery.padding`: the narrow sidebar is
    // a `Positioned` panel in a `Stack` (not inside a `Scaffold`), and an
    // ancestor may have consumed the bottom inset — this guarantees the list
    // clears the system navigation bar on gesture-nav devices.
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;

    return Container(
      color: Color.alphaBlend(
        colors.muted.withValues(alpha: 0.5),
        colors.background,
      ),
      child: SafeArea(
        right: false,
        // The bottom inset is added explicitly below (via `viewPadding`), so
        // don't let `SafeArea` add `padding.bottom` too.
        bottom: false,
        child: ListenableBuilder(
          listenable: widget.chat,
          builder: (context, _) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Header(
                  onClose: widget.onClose,
                  onRefresh: widget.chat.refreshConversations,
                  isRefreshing: widget.chat.isRefreshing,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  child: OutlineButton(
                    onPressed: widget.chat.isStreaming
                        ? null
                        : () => _newChat(context),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(LucideIcons.plus, size: 16),
                        Gap(8),
                        Text('New chat'),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 18),
                  child: TextField(
                    key: const Key('chat-search'),
                    controller: _search,
                    placeholder: const Text('Search chats'),
                    onChanged: (_) => setState(() {}),
                    features: [
                      const InputFeature.leading(
                        Icon(LucideIcons.search, size: 15),
                      ),
                      if (_search.text.isNotEmpty)
                        InputFeature.trailing(
                          IconAction(
                            icon: LucideIcons.x,
                            size: 14,
                            label: 'Clear search',
                            onPressed: () => setState(_search.clear),
                          ),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 0, 22, 8),
                  child: const Text('Your chats').muted.xSmall,
                ),
                Expanded(
                  child: _ConversationList(
                    query: _search.text,
                    showSelection: widget.section == SidebarSection.chat,
                    chat: widget.chat,
                    onClose: widget.onClose,
                    onOpenChat: widget.onOpenChat,
                  ),
                ),
                const Divider(),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: _SectionList(
                    section: widget.section,
                    onOpenUsage: widget.onOpenUsage,
                    onOpenModels: widget.onOpenModels,
                    onOpenSettings: widget.onOpenSettings,
                  ),
                ),
                SizedBox(height: bottomInset),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _newChat(BuildContext context) async {
    setState(_search.clear);
    await widget.chat.newChat();
    if (!mounted) return;
    widget.onOpenChat?.call();
    widget.onClose?.call();
  }
}

/// Utility destinations sit below the conversations, with a shared selected state.
class _SectionList extends StatelessWidget {
  const _SectionList({
    required this.section,
    required this.onOpenUsage,
    required this.onOpenModels,
    required this.onOpenSettings,
  });

  final SidebarSection section;
  final VoidCallback? onOpenUsage;
  final VoidCallback? onOpenModels;
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 2, 8, 2),
      child: Column(
        children: [
          _SidebarTile(
            selected: section == SidebarSection.usage,
            onPressed: onOpenUsage,
            leading: const Icon(LucideIcons.chartColumn),
            title: 'Usage',
          ),
          _SidebarTile(
            selected: section == SidebarSection.models,
            onPressed: onOpenModels,
            leading: const Icon(LucideIcons.blocks),
            title: 'Models',
          ),
          _SidebarTile(
            selected: section == SidebarSection.settings,
            onPressed: onOpenSettings,
            leading: const Icon(LucideIcons.settings),
            title: 'Settings',
          ),
        ],
      ),
    );
  }
}

/// One row in the sidebar, styled like a conversation: a rounded surface that
/// tints on hover and fills with the accent when selected, a leading icon, a
/// single-line title (plus an optional muted subtitle) and an optional trailing
/// action that stays reachable on touch and keyboard. Shared by the entries and
/// conversations so the whole column looks the same.
class _SidebarTile extends StatefulWidget {
  const _SidebarTile({
    required this.selected,
    required this.onPressed,
    required this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  final bool selected;
  final VoidCallback? onPressed;
  final Widget leading;
  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  State<_SidebarTile> createState() => _SidebarTileState();
}

class _SidebarTileState extends State<_SidebarTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);
    final selected = widget.selected;

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Clickable(
        onPressed: widget.onPressed,
        onHover: (value) => setState(() => _hovered = value),
        disableHoverEffect: true,
        child: AnimatedSlide(
          offset: _hovered ? const Offset(0, -0.02) : Offset.zero,
          duration: motionDuration(context, Motion.fast),
          curve: Motion.curve,
          child: AnimatedContainer(
            duration: motionDuration(context, Motion.fast),
            curve: Motion.curve,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: selected
                  ? colors.accent
                  : _hovered
                  ? colors.accent.withValues(alpha: 0.5)
                  : const Color(0x00000000),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Row(
              children: [
                IconTheme.merge(
                  data: IconThemeData(
                    size: 16,
                    color: selected
                        ? colors.accentForeground
                        : colors.mutedForeground,
                  ),
                  child: widget.leading,
                ),
                const Gap(10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w500,
                        ),
                      ),
                      if (widget.subtitle != null) ...[
                        const Gap(1),
                        Text(
                          widget.subtitle!,
                          style: TextStyle(
                            fontSize: 11,
                            color: colors.mutedForeground,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (widget.trailing != null) widget.trailing!,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({this.onClose, this.onRefresh, this.isRefreshing = false});

  final VoidCallback? onClose;
  final VoidCallback? onRefresh;
  final bool isRefreshing;

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 20, 12, 22),
      child: Row(
        children: [
          const ProculLogo(size: 36),
          const Gap(10),
          Expanded(
            child: Text(
              'Procul',
              style: TextStyle(
                fontSize: 23,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.8,
                color: colors.foreground,
              ),
            ),
          ),
          if (onRefresh != null)
            IconAction(
              icon: LucideIcons.refreshCw,
              label: 'Refresh chats',
              size: 18,
              busy: isRefreshing,
              onPressed: onRefresh,
            ),
          if (onClose != null)
            IconAction(
              icon: LucideIcons.x,
              label: 'Close sidebar',
              size: 18,
              onPressed: onClose,
            ),
        ],
      ),
    );
  }
}

class _ConversationList extends StatelessWidget {
  const _ConversationList({
    required this.chat,
    required this.query,
    required this.showSelection,
    this.onClose,
    this.onOpenChat,
  });

  final ChatController chat;
  final String query;
  final bool showSelection;
  final VoidCallback? onClose;
  final VoidCallback? onOpenChat;

  @override
  Widget build(BuildContext context) {
    if (chat.isLoadingConversations) {
      return const _ConversationListSkeleton();
    }

    if (chat.conversations.isEmpty) {
      // Scrollable so pull-to-refresh works even with no chats.
      return RefreshTrigger(
        onRefresh: chat.refreshConversations,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 64, 24, 24),
              child: const Text(
                'Your chats will live here.\nStart with a message.',
                textAlign: TextAlign.center,
              ).muted.small,
            ),
          ],
        ),
      );
    }

    final search = query.trim().toLowerCase();
    final conversations = chat.conversations
        .where(
          (conversation) => conversation.title.toLowerCase().contains(search),
        )
        .toList();
    if (conversations.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: const Text('No matching chats.\nTry a different word.')
            .muted
            .small,
      );
    }

    return RefreshTrigger(
      onRefresh: chat.refreshConversations,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        itemCount: conversations.length,
        itemBuilder: (context, index) {
          final conversation = conversations[index];
          return _ConversationTile(
            conversation: conversation,
            selected:
                showSelection && conversation.id == chat.activeConversationId,
            onSelect: () {
              chat.selectConversation(conversation.id);
              onOpenChat?.call();
              onClose?.call();
            },
            onRename: () =>
                renameConversationDialog(context, chat, conversation),
            onDelete: () =>
                confirmDeleteConversation(context, chat, conversation),
          );
        },
      ),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({
    required this.conversation,
    required this.selected,
    required this.onSelect,
    required this.onRename,
    required this.onDelete,
  });

  final Conversation conversation;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final updatedAt = conversation.updatedAt;
    return _SidebarTile(
      selected: selected,
      onPressed: onSelect,
      leading: const Icon(LucideIcons.messageSquare),
      title: conversation.title,
      subtitle: updatedAt == null ? null : relativeTime(updatedAt),
      trailing: IconAction(
        icon: LucideIcons.ellipsis,
        label: 'Chat options',
        size: 16,
        onPressed: () => _showMenu(context),
      ),
    );
  }

  void _showMenu(BuildContext context) {
    showAppMenu(
      context: context,
      builder: (context) => DropdownMenu(
        children: [
          MenuButton(
            onPressed: (context) => onRename(),
            child: const Text('Rename'),
          ),
          MenuButton(
            onPressed: (context) => onDelete(),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}

/// Shimmer rows shaped like real conversation tiles, shown while the list
/// loads.
class _ConversationListSkeleton extends StatelessWidget {
  const _ConversationListSkeleton();

  @override
  Widget build(BuildContext context) {
    return Shimmer(
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        physics: const NeverScrollableScrollPhysics(),
        itemCount: 7,
        itemBuilder: (context, index) => const _SkeletonTile(),
      ),
    );
  }
}

class _SkeletonTile extends StatelessWidget {
  const _SkeletonTile();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(10, 8, 10, 10),
      child: Row(
        children: [
          Skeleton(width: 16, height: 16, radius: 4),
          Gap(10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                FractionallySizedBox(
                  widthFactor: 0.85,
                  alignment: Alignment.centerLeft,
                  child: Skeleton(height: 13),
                ),
                Gap(6),
                FractionallySizedBox(
                  widthFactor: 0.3,
                  alignment: Alignment.centerLeft,
                  child: Skeleton(height: 10),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
