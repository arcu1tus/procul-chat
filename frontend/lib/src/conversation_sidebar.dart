import 'package:google_fonts/google_fonts.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'auth_controller.dart';
import 'chat_controller.dart';
import 'conversation_actions.dart';
import 'models.dart';
import 'settings_controller.dart';
import 'settings_dialog.dart';
import 'widgets/icon_action.dart';
import 'widgets/skeleton.dart';

/// The conversation list: brand header, "new chat", the chats themselves, and
/// a settings footer. Shown persistently on wide screens and inside a drawer on
/// narrow ones (where [onClose] dismisses it).
class ConversationSidebar extends StatelessWidget {
  const ConversationSidebar({
    super.key,
    required this.chat,
    required this.settings,
    required this.auth,
    this.onClose,
  });

  final ChatController chat;
  final SettingsController settings;
  final AuthController auth;

  /// Called after an action that should dismiss a drawer-hosted sidebar.
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);

    return Container(
      color: colors.background,
      child: SafeArea(
        right: false,
        child: ListenableBuilder(
          listenable: chat,
          builder: (context, _) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Header(onClose: onClose, onRefresh: chat.refreshConversations),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
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
                  child: _ConversationList(chat: chat, onClose: onClose),
                ),
                const Divider(),
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: GhostButton(
                    alignment: Alignment.centerLeft,
                    onPressed: () =>
                        showSettingsDialog(context, settings, auth, chat.api),
                    child: const Row(
                      children: [
                        Icon(LucideIcons.settings, size: 16),
                        Gap(10),
                        Text('Settings'),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _newChat(BuildContext context) async {
    await chat.newChat();
    onClose?.call();
  }
}

class _Header extends StatelessWidget {
  const _Header({this.onClose, this.onRefresh});

  final VoidCallback? onClose;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 12, 14),
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
  const _ConversationList({required this.chat, this.onClose});

  final ChatController chat;
  final VoidCallback? onClose;

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

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Clickable(
        onPressed: widget.onSelect,
        onHover: (value) => setState(() => _hovered = value),
        disableHoverEffect: true,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
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
                        _relativeTime(conversation.updatedAt!),
                        style: TextStyle(
                          fontSize: 11,
                          color: colors.mutedForeground,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (_hovered || selected)
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
    );
  }

  void _showMenu(BuildContext context) {
    showDropdown(
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

String _relativeTime(DateTime time) {
  final local = time.toLocal();
  final difference = DateTime.now().difference(local);
  if (difference.inSeconds < 60) return 'just now';
  if (difference.inMinutes < 60) return '${difference.inMinutes}m ago';
  if (difference.inHours < 24) return '${difference.inHours}h ago';
  if (difference.inDays < 7) return '${difference.inDays}d ago';
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  return '${local.year}-$month-$day';
}
