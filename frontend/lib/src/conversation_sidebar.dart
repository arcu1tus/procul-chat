import 'package:google_fonts/google_fonts.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'chat_controller.dart';
import 'conversation_actions.dart';
import 'models.dart';
import 'motion.dart';
import 'time_format.dart';
import 'widgets/app_dialog.dart';
import 'widgets/icon_action.dart';
import 'widgets/skeleton.dart';

/// Which of the sidebar's destinations is currently shown in the main pane, so
/// its tab reads as selected.
enum SidebarSection { chat, usage, models, settings }

/// The conversation list: brand header, a tab row (Usage / Models / Settings),
/// "new chat", and the chats themselves. Shown persistently on wide screens and
/// inside a drawer on narrow ones (where [onClose] dismisses it).
class ConversationSidebar extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);
    // Use the raw view padding, not `MediaQuery.padding`: the narrow sidebar is
    // a `Positioned` panel in a `Stack` (not inside a `Scaffold`), and an
    // ancestor may have consumed the bottom inset — this guarantees the list
    // clears the system navigation bar on gesture-nav devices.
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;

    return Container(
      color: colors.background,
      child: SafeArea(
        right: false,
        // The bottom inset is added explicitly below (via `viewPadding`), so
        // don't let `SafeArea` add `padding.bottom` too.
        bottom: false,
        child: ListenableBuilder(
          listenable: chat,
          builder: (context, _) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Header(
                  onClose: onClose,
                  onRefresh: chat.refreshConversations,
                  isRefreshing: chat.isRefreshing,
                ),
                _SectionTabs(
                  section: section,
                  onOpenUsage: onOpenUsage,
                  onOpenModels: onOpenModels,
                  onOpenSettings: onOpenSettings,
                ),
                const Divider(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  child: PrimaryButton(
                    onPressed: chat.isStreaming
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
                Expanded(
                  child: _ConversationList(
                    chat: chat,
                    onClose: onClose,
                    onOpenChat: onOpenChat,
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
    await chat.newChat();
    onOpenChat?.call();
    onClose?.call();
  }
}

/// The tab row above the chat list: Usage / Models / Settings. The one whose
/// overlay is currently shown reads as selected.
class _SectionTabs extends StatelessWidget {
  const _SectionTabs({
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: _Tab(
              icon: LucideIcons.chartColumn,
              label: 'Usage',
              selected: section == SidebarSection.usage,
              onPressed: onOpenUsage,
            ),
          ),
          const Gap(4),
          Expanded(
            child: _Tab(
              icon: LucideIcons.blocks,
              label: 'Models',
              selected: section == SidebarSection.models,
              onPressed: onOpenModels,
            ),
          ),
          const Gap(4),
          Expanded(
            child: _Tab(
              icon: LucideIcons.settings,
              label: 'Settings',
              selected: section == SidebarSection.settings,
              onPressed: onOpenSettings,
            ),
          ),
        ],
      ),
    );
  }
}

/// One tab in the sidebar's section row. Kept compact so three fit across the
/// 300 px sidebar; the label ellipsizes rather than overflowing.
class _Tab extends StatelessWidget {
  const _Tab({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    const ghost = ButtonStyle.ghost(
      size: ButtonSize.small,
      density: ButtonDensity.compact,
    );
    const selectedStyle = ButtonStyle.secondary(
      size: ButtonSize.small,
      density: ButtonDensity.compact,
    );
    return SelectedButton(
      value: selected,
      onChanged: onPressed == null ? null : (_) => onPressed!(),
      style: ghost,
      selectedStyle: selectedStyle,
      alignment: Alignment.center,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15),
          const Gap(6),
          Flexible(
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
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
      padding: const EdgeInsets.fromLTRB(16, 16, 12, 8),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: colors.primary,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(
              LucideIcons.messagesSquare,
              size: 17,
              color: colors.primaryForeground,
            ),
          ),
          const Gap(10),
          Expanded(
            child: Text(
              'Procul',
              style: GoogleFonts.coiny(
                fontSize: 24,
                height: 1,
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
  const _ConversationList({required this.chat, this.onClose, this.onOpenChat});

  final ChatController chat;
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
                'No chats yet.\nSend a message to start one.',
                textAlign: TextAlign.center,
              ).muted.small,
            ),
          ],
        ),
      );
    }

    return RefreshTrigger(
      onRefresh: chat.refreshConversations,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        itemCount: chat.conversations.length,
        itemBuilder: (context, index) {
          final conversation = chat.conversations[index];
          return _ConversationTile(
            conversation: conversation,
            selected: conversation.id == chat.activeConversationId,
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

class _ConversationTile extends StatefulWidget {
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
  State<_ConversationTile> createState() => _ConversationTileState();
}

class _ConversationTileState extends State<_ConversationTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);
    final conversation = widget.conversation;
    final selected = widget.selected;
    final showOptions = _hovered || selected;

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Clickable(
        onPressed: widget.onSelect,
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
                Icon(
                  LucideIcons.messageSquare,
                  size: 16,
                  color: selected
                      ? colors.accentForeground
                      : colors.mutedForeground,
                ),
                const Gap(10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        conversation.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w500,
                        ),
                      ),
                      if (conversation.updatedAt != null) ...[
                        const Gap(1),
                        Text(
                          relativeTime(conversation.updatedAt!),
                          style: TextStyle(
                            fontSize: 11,
                            color: colors.mutedForeground,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (showOptions)
                  IconAction(
                    icon: LucideIcons.ellipsis,
                    label: 'Chat options',
                    size: 16,
                    onPressed: () => _showMenu(context),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showMenu(BuildContext context) {
    showAppMenu(
      context: context,
      builder: (context) => DropdownMenu(
        children: [
          MenuButton(
            onPressed: (context) => widget.onRename(),
            child: const Text('Rename'),
          ),
          MenuButton(
            onPressed: (context) => widget.onDelete(),
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
