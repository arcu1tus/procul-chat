import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'attachments.dart';
import 'chat_controller.dart';
import 'conversation_actions.dart';
import 'model_catalog_controller.dart';
import 'models.dart';
import 'motion.dart';
import 'responsive.dart';
import 'time_format.dart';
import 'widgets/app_dialog.dart';
import 'widgets/attachment_views.dart';
import 'widgets/composer.dart';
import 'widgets/chat_welcome.dart';
import 'widgets/procul_logo.dart';
import 'widgets/chat_refresh_trigger.dart';
import 'widgets/content_width.dart';
import 'widgets/icon_action.dart';
import 'widgets/model_badges.dart';
import 'widgets/skeleton.dart';
import 'widgets/streaming_text.dart';

/// The chat pane: header, message list, and composer.
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.chat,
    this.catalog,
    this.picker = const FilePickerAttachmentPicker(),
    this.showMenuButton = false,
    this.compactModelPicker = false,
    this.compactActions = false,
    this.onMenu,
  });

  final ChatController chat;

  /// The shared model catalog backing the app-bar model picker. When null (or
  /// when only one model is configured) the picker is hidden.
  final ModelCatalogController? catalog;

  /// Picks and saves attachment files. Injected in tests so the platform
  /// channel is never touched.
  final AttachmentPicker picker;

  /// Whether to show a leading button that opens the conversation drawer.
  final bool showMenuButton;
  final VoidCallback? onMenu;

  /// Collapse the model picker to an icon, for narrow app bars.
  final bool compactModelPicker;

  /// Collapse rename/delete into an overflow menu, for narrow app bars.
  final bool compactActions;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  final _inputFocus = FocusNode();

  bool _pinnedToBottom = true;
  String? _lastError;

  /// Messages whose entrance animation has already played, so rebuilds (token
  /// updates, scrolling) never replay it.
  final Set<ChatMessage> _seenMessages = {};

  /// Set when a history load finishes, so the whole batch appears at once
  /// instead of cascading in.
  bool _suppressEntrance = false;
  bool _wasLoadingMessages = false;

  @override
  void initState() {
    super.initState();
    widget.chat.addListener(_onChanged);
    _scrollController.addListener(_trackPin);
  }

  @override
  void dispose() {
    widget.chat.removeListener(_onChanged);
    _inputController.dispose();
    _scrollController.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  void _trackPin() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    // The list is reversed, so offset 0 is the newest message (the bottom of the
    // screen). "Pinned" means the user is near it; "near the top" (older
    // messages) is near `maxScrollExtent`.
    final pinned = position.pixels < 140;
    if (pinned != _pinnedToBottom) {
      setState(() => _pinnedToBottom = pinned);
    }
    if (position.pixels > position.maxScrollExtent - 300) {
      widget.chat.loadOlderMessages();
    }
  }

  void _onChanged() {
    final loading = widget.chat.isLoadingMessages;
    if (_wasLoadingMessages && !loading) {
      // A history load just landed: show it as a static list.
      _suppressEntrance = true;
    }
    _wasLoadingMessages = loading;
    if (widget.chat.messages.isEmpty) {
      _seenMessages.clear();
    }

    final error = widget.chat.error;
    if (error != null && error != _lastError && mounted) {
      _lastError = error;
      _showError(error);
    }
    if (error == null) {
      _lastError = null;
    }
    if (_pinnedToBottom) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) return;
        // Reversed list: the newest message lives at offset 0.
        _scrollController.jumpTo(0);
      });
    }
  }

  /// Scrolls back to the newest message (the jump-to-latest pill).
  void _jumpToLatest() {
    if (!_scrollController.hasClients) return;
    if (reduceMotion(context)) {
      _scrollController.jumpTo(0);
      return;
    }
    _scrollController.animateTo(
      0,
      duration: motionDuration(context, Motion.medium),
      curve: Motion.curve,
    );
  }

  void _showError(String error) {
    showToast(
      context: context,
      location: ToastLocation.topRight,
      builder: (context, overlay) => SurfaceCard(
        child: Basic(
          leading: const Icon(LucideIcons.info, size: 18),
          title: const Text('Something went wrong').semiBold,
          subtitle: Text(error),
        ),
      ),
    );
  }

  void _submit() {
    final text = _inputController.text;
    if (text.trim().isEmpty ||
        widget.chat.isStreaming ||
        widget.chat.isLoadingMessages ||
        widget.chat.isUploadingAttachment) {
      return;
    }
    final editing = widget.chat.isEditing;
    _inputController.clear();
    _pinnedToBottom = true;
    if (editing) {
      widget.chat.editMessage(text);
    } else {
      widget.chat.send(text);
    }
  }

  /// Enters edit mode for a user message: the controller remembers it and seeds
  /// the pending attachments; here the input is prefilled, focused and pinned.
  void _beginEdit(ChatMessage message) {
    if (widget.chat.isStreaming) return;
    widget.chat.beginEdit(message);
    _inputController.text = message.text;
    _inputController.selection = TextSelection.collapsed(
      offset: message.text.length,
    );
    _pinnedToBottom = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _inputFocus.requestFocus();
    });
  }

  /// Leaves edit mode, clearing the composer.
  void _cancelEdit() {
    widget.chat.cancelEdit();
    _inputController.clear();
  }

  /// The app-bar trailing actions. On a narrow bar every action collapses into
  /// a single overflow `…` so the title keeps room and nothing paints over
  /// anything (the shadcn `AppBar` lays the trailing out at its intrinsic width
  /// and does not wrap).
  List<Widget> _trailing(ChatController chat, Conversation? active) {
    final compact =
        widget.compactActions ||
        MediaQuery.sizeOf(context).width < appBarCompactWidth;
    if (compact) {
      return [
        Builder(
          builder: (context) => IconAction(
            key: const Key('chat-options'),
            icon: LucideIcons.ellipsis,
            label: 'Chat options',
            onPressed: () => _showChatMenu(context, chat, active),
          ),
        ),
      ];
    }
    return [
      if (widget.catalog != null)
        _ModelPicker(
          key: const Key('model-picker'),
          chat: chat,
          catalog: widget.catalog!,
          compact: widget.compactModelPicker,
        ),
      if (active != null && chat.activeUsage.hasTokens)
        _UsageChip(usage: chat.activeUsage),
      IconAction(
        icon: LucideIcons.refreshCw,
        label: 'Refresh',
        busy: chat.isRefreshing,
        onPressed: chat.refreshAll,
      ),
      if (active != null)
        Builder(
          builder: (context) => IconAction(
            key: const Key('chat-options'),
            icon: LucideIcons.ellipsis,
            label: 'Chat options',
            onPressed: () => _showChatMenu(context, chat, active),
          ),
        ),
    ];
  }

  /// The overflow menu shown on narrow app bars: every chat action lives here.
  /// The model list is a submenu so a phone-width menu stays short.
  ///
  /// [context] must be a descendant of a `DrawerOverlay` (shadcn presents a
  /// `showDropdown` as a bottom sheet on mobile, which needs one); callers wrap
  /// the trigger in a `Builder` so this is the trigger's own context.
  void _showChatMenu(
    BuildContext context,
    ChatController chat,
    Conversation? active,
  ) {
    final catalog = widget.catalog;
    final models = catalog?.models ?? const <ChatModel>[];
    final showModels = catalog != null && catalog.hasChoice;
    final usage = chat.activeUsage;

    showAppMenu(
      context: context,
      builder: (context) => DropdownMenu(
        children: [
          MenuButton(
            leading: const Icon(LucideIcons.refreshCw, size: 16),
            onPressed: (context) => chat.refreshAll(),
            child: const Text('Refresh'),
          ),
          if (showModels)
            MenuButton(
              leading: const Icon(LucideIcons.cpu, size: 16),
              subMenu: [
                for (final model in models)
                  MenuButton(
                    enabled: !chat.isStreaming,
                    leading: ModelHealthDot(status: model.health.status),
                    trailing: model.slug == chat.activeModel
                        ? const Icon(LucideIcons.check, size: 16)
                        : null,
                    onPressed: (context) => chat.setModel(model.slug),
                    child: Text(
                      model.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              child: const Text('Model'),
            ),
          if (active != null && usage.hasTokens)
            MenuButton(
              leading: const Icon(LucideIcons.coins, size: 16),
              subMenu: [
                _UsageChip.usageLabel('Input', usage.inputTokens),
                _UsageChip.usageLabel('Output', usage.outputTokens),
                _UsageChip.usageLabel('Cached', usage.cachedInputTokens),
                const MenuDivider(),
                _UsageChip.usageLabel(
                  'Total',
                  usage.totalTokens,
                  emphasized: true,
                ),
              ],
              child: const Text('Token usage'),
            ),
          if (active != null) ...[
            const MenuDivider(),
            MenuButton(
              leading: const Icon(LucideIcons.squarePen, size: 16),
              onPressed: (context) =>
                  renameConversationDialog(context, chat, active),
              child: const Text('Rename'),
            ),
            MenuButton(
              leading: const Icon(LucideIcons.trash2, size: 16),
              onPressed: (context) =>
                  confirmDeleteConversation(context, chat, active),
              child: const Text('Delete'),
            ),
          ],
        ],
      ),
    );
  }

  void _useSuggestion(String suggestion) {
    _inputController.text = suggestion;
    _inputController.selection = TextSelection.collapsed(
      offset: suggestion.length,
    );
    _inputFocus.requestFocus();
  }

  /// The active model's input modalities, or null when unknown (catalog not
  /// loaded), in which case the client does not gate — the backend still does.
  Set<ModelInputModality>? _activeCapabilities() {
    final catalog = widget.catalog;
    final slug = widget.chat.activeModel;
    if (catalog == null || slug == null) return null;
    for (final model in catalog.models) {
      if (model.slug == slug) return model.capabilities.input;
    }
    return null;
  }

  /// Opens the attachment source menu (Camera / Gallery / Files), filtered by
  /// the platform and the active model's readable types, then uploads whatever
  /// was picked. With a single available source (e.g. desktop Files only) the
  /// picker opens directly.
  Future<void> _attach(BuildContext context) async {
    final chat = widget.chat;
    if (chat.isStreaming || chat.isUploadingAttachment) return;

    final capabilities = _activeCapabilities();
    final sources = _availableSources(capabilities);
    if (sources.isEmpty) return;
    if (sources.length == 1) {
      await _pickFrom(sources.single, capabilities);
      return;
    }

    showAppMenu(
      context: context,
      builder: (context) => DropdownMenu(
        children: [
          for (final source in sources)
            MenuButton(
              leading: Icon(_sourceIcon(source), size: 16),
              onPressed: (context) => _pickFrom(source, capabilities),
              child: Text(_sourceLabel(source)),
            ),
        ],
      ),
    );
  }

  /// The attachment sources to offer: the platform's sources minus any the
  /// active model cannot read. Camera/Gallery produce images, so they are
  /// hidden for a model without the image modality; Files always remains.
  List<AttachmentSource> _availableSources(
    Set<ModelInputModality>? capabilities,
  ) {
    final canReadImages =
        capabilities == null || capabilities.contains(ModelInputModality.image);
    return [
      for (final source in AttachmentSources.available())
        if (source == AttachmentSource.files || canReadImages) source,
    ];
  }

  static IconData _sourceIcon(AttachmentSource source) => switch (source) {
    AttachmentSource.camera => LucideIcons.camera,
    AttachmentSource.gallery => LucideIcons.image,
    AttachmentSource.files => LucideIcons.paperclip,
  };

  static String _sourceLabel(AttachmentSource source) => switch (source) {
    AttachmentSource.camera => 'Camera',
    AttachmentSource.gallery => 'Gallery',
    AttachmentSource.files => 'Files',
  };

  Future<void> _pickFrom(
    AttachmentSource source,
    Set<ModelInputModality>? capabilities,
  ) async {
    final chat = widget.chat;
    final List<PickedAttachment> picked;
    try {
      picked = switch (source) {
        AttachmentSource.camera => [?await widget.picker.pickFromCamera()],
        AttachmentSource.gallery => await widget.picker.pickFromGallery(),
        AttachmentSource.files => await widget.picker.pickFiles(
          allowedExtensions: capabilities == null
              ? null
              : allowedExtensionsForCapabilities(capabilities),
        ),
      };
    } catch (e) {
      chat.reportError('Could not open the picker: $e');
      return;
    }
    if (picked.isEmpty || !mounted) return;

    await chat.uploadAttachments(picked, capabilities: capabilities);
  }

  /// Fetches an attachment's bytes (authenticated) and hands them to the
  /// platform save dialog.
  Future<void> _saveAttachment(Attachment attachment) async {
    try {
      final bytes = await widget.chat.loadAttachmentBytes(attachment.id);
      await widget.picker.save(attachment.fileName, bytes);
    } catch (e) {
      widget.chat.reportError('Could not save ${attachment.fileName}: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.chat,
      builder: (context, _) {
        final chat = widget.chat;
        final active = chat.activeConversation;

        return Scaffold(
          loadingProgressIndeterminate: chat.isStreaming,
          headers: [
            AppBar(
              // A long title must never wrap: shadcn's AppBar uses
              // `IntrinsicHeight`, so an N-line title stretches the whole bar to
              // N lines tall (and, at ~0 remaining width, wraps one character
              // per line). One ellipsized line keeps the bar a single row.
              title: Text(
                active?.title ?? 'New chat',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: active == null
                  ? const Text('A fresh start').muted.small
                  : null,
              leading: widget.showMenuButton
                  ? [
                      IconAction(
                        icon: LucideIcons.panelLeft,
                        label: 'Open chats',
                        onPressed: widget.onMenu,
                      ),
                    ]
                  : const [],
              trailing: _trailing(chat, active),
            ),
            const Divider(),
          ],
          child: Column(
            children: [
              Expanded(
                child: ChatRefreshTrigger(
                  // A pull must not clobber a live stream, so disable it mid-turn.
                  onRefresh: chat.isStreaming
                      ? null
                      : chat.reloadActiveConversation,
                  child: _body(chat),
                ),
              ),
              Composer(
                controller: _inputController,
                focusNode: _inputFocus,
                chat: chat,
                onSubmit: _submit,
                onAttach: _attach,
                onCancelEdit: _cancelEdit,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _body(ChatController chat) {
    if (chat.isLoadingMessages) {
      return const _MessageHistorySkeleton();
    }

    if (chat.messages.isEmpty) {
      return ChatWelcome(onSuggestion: _useSuggestion);
    }

    if (_suppressEntrance) {
      _seenMessages.addAll(chat.messages);
      _suppressEntrance = false;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final side = centeredSidePadding(constraints.maxWidth);
        final count = chat.messages.length;
        // In a reversed list the "older" end is the visual top, so the
        // loading-older row is the *last* item.
        final showOlder = chat.isLoadingOlder;
        return Stack(
          children: [
            ListView.builder(
              controller: _scrollController,
              reverse: true,
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.fromLTRB(16 + side, 20, 16 + side, 12),
              itemCount: count + (showOlder ? 1 : 0),
              itemBuilder: (context, index) {
                if (showOlder && index == count) {
                  return const _LoadingOlderRow();
                }
                final message = chat.messages[count - 1 - index];
                final animate = !_seenMessages.contains(message);
                if (animate) _seenMessages.add(message);
                return _MessageEntrance(
                  animate: animate,
                  child: _MessageBubble(
                    message: message,
                    chat: chat,
                    // Reversed: index 0 is the newest message.
                    isStreaming: chat.isStreaming && index == 0,
                    onSaveAttachment: _saveAttachment,
                    onEdit: _beginEdit,
                  ),
                );
              },
            ),
            if (!_pinnedToBottom)
              Positioned(
                right: 16,
                bottom: 12,
                child: _JumpToLatest(onPressed: _jumpToLatest),
              ),
          ],
        );
      },
    );
  }
}

/// A small pill shown while the user has scrolled away from the newest message;
/// tapping it animates back down to the latest.
class _JumpToLatest extends StatelessWidget {
  const _JumpToLatest({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);
    return Semantics(
      button: true,
      label: 'Jump to latest',
      child: Tooltip(
        tooltip: (context) =>
            const TooltipContainer(child: Text('Jump to latest')),
        child: Clickable(
          onPressed: onPressed,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: colors.secondary,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: colors.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  LucideIcons.arrowDown,
                  size: 15,
                  color: colors.secondaryForeground,
                ),
                const Gap(6),
                Text('Latest').small,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A small row shown at the top of the (reversed) list while an older page of
/// history loads.
class _LoadingOlderRow extends StatelessWidget {
  const _LoadingOlderRow();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const Gap(8),
          const Text('Loading older messages…').muted.small,
        ],
      ),
    );
  }
}

/// Fades a message in and lifts it a few pixels, once.
class _MessageEntrance extends StatefulWidget {
  const _MessageEntrance({required this.animate, required this.child});

  final bool animate;
  final Widget child;

  @override
  State<_MessageEntrance> createState() => _MessageEntranceState();
}

class _MessageEntranceState extends State<_MessageEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: Motion.medium,
    value: widget.animate ? 0 : 1,
  );
  late final Animation<double> _curve = CurvedAnimation(
    parent: _controller,
    curve: Motion.curve,
  );

  @override
  void initState() {
    super.initState();
    if (widget.animate) _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (reduceMotion(context)) return widget.child;
    return AnimatedBuilder(
      animation: _curve,
      builder: (context, child) => Opacity(
        opacity: _curve.value,
        child: Transform.translate(
          offset: Offset(0, 6 * (1 - _curve.value)),
          child: child,
        ),
      ),
      child: widget.child,
    );
  }
}

class _MessageBubble extends StatefulWidget {
  const _MessageBubble({
    required this.message,
    required this.chat,
    required this.isStreaming,
    required this.onSaveAttachment,
    required this.onEdit,
  });

  final ChatMessage message;
  final ChatController chat;
  final bool isStreaming;
  final ValueChanged<Attachment> onSaveAttachment;
  final ValueChanged<ChatMessage> onEdit;

  @override
  State<_MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<_MessageBubble> {
  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);
    final message = widget.message;
    final chat = widget.chat;
    final isUser = message.isUser;
    final hasTools = message.toolCalls.isNotEmpty;
    final hasAttachments = message.attachments.isNotEmpty;
    // While tools run there is no reply text yet, so don't also show the
    // thinking dots — the tool rows already signal activity.
    final showText = message.text.isNotEmpty || !hasTools;
    // Actions are disabled mid-turn and while already editing.
    final canAct = !widget.isStreaming && !chat.isEditing;

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final call in message.toolCalls) _ToolCallRow(call: call),
        if (hasTools && showText) const Gap(8),
        if (hasAttachments) ...[
          AttachmentList(
            chat: chat,
            attachments: message.attachments,
            onTap: widget.onSaveAttachment,
          ),
          if (showText) const Gap(8),
        ],
        if (showText)
          isUser
              ? Text(message.text, style: TextStyle(color: colors.foreground))
              : _AssistantText(
                  text: message.text,
                  isStreaming: widget.isStreaming,
                ),
      ],
    );

    final actions = _MessageActions(
      isUser: isUser,
      canAct: canAct,
      onEdit: isUser ? () => widget.onEdit(widget.message) : null,
      onCopy: () => Clipboard.setData(ClipboardData(text: widget.message.text)),
      onMenu: isUser ? () => _showMessageMenu(context) : null,
    );

    if (isUser) {
      // Right-aligned filled bubble on a subtle surface; no avatar on this side.
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Flexible(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: _userBubbleMaxWidth(context),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: colors.secondary,
                        // A slightly tighter corner at the alignment edge.
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(18),
                          topRight: Radius.circular(18),
                          bottomLeft: Radius.circular(18),
                          bottomRight: Radius.circular(6),
                        ),
                      ),
                      child: content,
                    ),
                    actions,
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    // The assistant reply renders directly on the background (no fill, no
    // stroke), with a small tappable brand mark at the top.
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _AssistantAvatar(chat: chat, message: message),
          const Gap(12),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [content, actions],
            ),
          ),
        ],
      ),
    );
  }

  /// The user bubble's max width: a reading cap on desktop, most of the
  /// viewport on phones.
  double _userBubbleMaxWidth(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (breakpointForWidth(width) == Breakpoint.expanded) {
      return math.min(680, width * 0.75);
    }
    return width * 0.9;
  }

  /// The user-message `…` menu: Edit (enters the composer edit mode) and Copy.
  void _showMessageMenu(BuildContext context) {
    showAppMenu(
      context: context,
      builder: (context) => DropdownMenu(
        children: [
          MenuButton(
            leading: const Icon(LucideIcons.squarePen, size: 16),
            onPressed: (context) => widget.onEdit(widget.message),
            child: const Text('Edit'),
          ),
          MenuButton(
            leading: const Icon(LucideIcons.copy, size: 16),
            onPressed: (context) =>
                Clipboard.setData(ClipboardData(text: widget.message.text)),
            child: const Text('Copy'),
          ),
        ],
      ),
    );
  }
}

/// The actions under a message: a `…` menu (Edit / Copy) on the user side, a
/// Copy button on the assistant side.
///
/// The row fades and slides in on hover on pointer platforms, and stays visible
/// on touch. It is always in the tree and always hit-testable, so the actions
/// remain reachable however they are revealed.
class _MessageActions extends StatefulWidget {
  const _MessageActions({
    required this.isUser,
    required this.canAct,
    required this.onCopy,
    this.onEdit,
    this.onMenu,
  });

  final bool isUser;
  final bool canAct;
  final VoidCallback onCopy;
  final VoidCallback? onEdit;
  final VoidCallback? onMenu;

  @override
  State<_MessageActions> createState() => _MessageActionsState();
}

class _MessageActionsState extends State<_MessageActions> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final isTouch =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    final shown = isTouch || _hovered;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedOpacity(
        opacity: shown ? 1 : 0,
        duration: motionDuration(context, Motion.fast),
        curve: Motion.curve,
        child: AnimatedSlide(
          offset: shown ? Offset.zero : const Offset(0, -0.15),
          duration: motionDuration(context, Motion.fast),
          curve: Motion.curve,
          child: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: widget.isUser
                ? IconAction(
                    key: const Key('message-options'),
                    icon: LucideIcons.ellipsis,
                    label: 'Message options',
                    size: 16,
                    onPressed: widget.canAct ? widget.onMenu : null,
                  )
                : IconAction(
                    key: const Key('message-copy'),
                    icon: LucideIcons.copy,
                    label: 'Copy reply',
                    size: 15,
                    onPressed: widget.onCopy,
                  ),
          ),
        ),
      ),
    );
  }
}

/// The assistant's avatar, tappable to reveal that response's model, time and
/// token usage (a live turn's values; "—" once unknown, e.g. for history before
/// the backend stores per-message metadata).
class _AssistantAvatar extends StatelessWidget {
  const _AssistantAvatar({required this.chat, required this.message});

  final ChatController chat;
  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: const Key('response-details'),
      button: true,
      label: 'Response details',
      child: Tooltip(
        tooltip: (context) =>
            const TooltipContainer(child: Text('Response details')),
        child: Clickable(
          onPressed: () => _showDetails(context),
          disableHoverEffect: true,
          child: const ProculLogo(size: 30),
        ),
      ),
    );
  }

  void _showDetails(BuildContext context) {
    final usage = message.usage;
    final created = message.createdAt;
    showAppMenu(
      context: context,
      builder: (context) => DropdownMenu(
        children: [
          MenuLabel(
            trailing: Text(message.model ?? '—'),
            child: const Text('Model'),
          ),
          MenuLabel(
            trailing: Text(
              created == null
                  ? '—'
                  : '${_formatDateTime(created)}  ·  '
                        '${relativeTime(created)}',
            ),
            child: const Text('Time'),
          ),
          const MenuDivider(),
          _UsageChip.usageLabel('Input', usage?.inputTokens ?? 0),
          _UsageChip.usageLabel('Output', usage?.outputTokens ?? 0),
          _UsageChip.usageLabel('Cached', usage?.cachedInputTokens ?? 0),
          const MenuDivider(),
          _UsageChip.usageLabel(
            'Total',
            usage?.totalTokens ?? 0,
            emphasized: true,
          ),
        ],
      ),
    );
  }
}

/// A compact absolute timestamp for the response-details popover.
String _formatDateTime(DateTime value) {
  final local = value.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

class _AssistantText extends StatelessWidget {
  const _AssistantText({required this.text, required this.isStreaming});

  final String text;
  final bool isStreaming;

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);
    if (text.isEmpty) {
      return isStreaming
          ? const _ThinkingDots()
          : Text('…', style: TextStyle(color: colors.mutedForeground));
    }
    return StreamingText(
      text: text,
      isStreaming: isStreaming,
      // A slightly taller line-height keeps long replies readable.
      style: const TextStyle(height: 1.55),
    );
  }
}

/// The app-bar model picker: a compact chip showing the active model, opening a
/// menu of every configured model. Hidden when only one model is configured and
/// disabled while a reply streams.
class _ModelPicker extends StatelessWidget {
  const _ModelPicker({
    super.key,
    required this.chat,
    required this.catalog,
    this.compact = false,
  });

  final ChatController chat;
  final ModelCatalogController catalog;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: catalog,
      builder: (context, _) {
        if (!catalog.hasChoice) return const SizedBox.shrink();
        final enabled = !chat.isStreaming;
        final active = _activeModel();
        final label = active?.name ?? active?.slug ?? 'Model';

        if (compact) {
          return IconAction(
            icon: LucideIcons.cpu,
            label: 'Choose model: $label',
            onPressed: enabled ? () => _open(context) : null,
          );
        }

        return _PickerButton(
          label: label,
          health: active?.health.status ?? ModelHealthStatus.unknown,
          enabled: enabled,
          onPressed: () => _open(context),
        );
      },
    );
  }

  /// The catalog entry matching [ChatController.activeModel], if any.
  ChatModel? _activeModel() {
    final slug = chat.activeModel;
    if (slug == null) return null;
    for (final model in catalog.models) {
      if (model.slug == slug) return model;
    }
    return null;
  }

  void _open(BuildContext context) {
    final activeSlug = chat.activeModel;
    showAppMenu(
      context: context,
      builder: (context) => DropdownMenu(
        children: [
          for (final model in catalog.models)
            MenuButton(
              enabled: !chat.isStreaming,
              leading: ModelHealthDot(status: model.health.status),
              trailing: model.slug == activeSlug
                  ? const Icon(LucideIcons.check, size: 16)
                  : null,
              onPressed: (context) {
                // MenuButton auto-closes the dropdown; popping here would pop
                // the app's home route (the menu is an overlay, not a route).
                chat.setModel(model.slug);
              },
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    model.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (model.capabilities.input.isNotEmpty) ...[
                    const Gap(4),
                    CapabilityBadges(
                      modalities: model.capabilities.input,
                      compact: true,
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The expanded model picker: a bordered chip with a health dot, the model name
/// and a chevron.
class _PickerButton extends StatelessWidget {
  const _PickerButton({
    required this.label,
    required this.health,
    required this.enabled,
    required this.onPressed,
  });

  final String label;
  final ModelHealthStatus health;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);
    return Semantics(
      button: true,
      enabled: enabled,
      label: 'Choose model: $label',
      child: Tooltip(
        tooltip: (context) =>
            const TooltipContainer(child: Text('Choose model')),
        child: Clickable(
          enabled: enabled,
          onPressed: enabled ? onPressed : null,
          disableHoverEffect: true,
          child: Opacity(
            opacity: enabled ? 1 : 0.5,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: colors.muted,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: colors.border),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ModelHealthDot(status: health, size: 7),
                  const Gap(6),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 160),
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ).small,
                  ),
                  const Gap(4),
                  Icon(
                    LucideIcons.chevronDown,
                    size: 13,
                    color: colors.mutedForeground,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A compact app-bar chip showing the active conversation's cumulative token
/// count; tapping reveals the input / output / cached / total breakdown.
class _UsageChip extends StatelessWidget {
  const _UsageChip({required this.usage});

  final TokenUsage usage;

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);

    return Semantics(
      button: true,
      label: 'Token usage',
      child: Tooltip(
        tooltip: (context) =>
            const TooltipContainer(child: Text('Token usage')),
        child: Clickable(
          onPressed: () => _showBreakdown(context),
          disableHoverEffect: true,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: colors.muted,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: colors.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  LucideIcons.coins,
                  size: 14,
                  color: colors.mutedForeground,
                ),
                const Gap(6),
                Text('${formatTokenCount(usage.totalTokens)} tokens').small,
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showBreakdown(BuildContext context) {
    showAppMenu(
      context: context,
      builder: (context) => DropdownMenu(
        children: [
          usageLabel('Input', usage.inputTokens),
          usageLabel('Output', usage.outputTokens),
          usageLabel('Cached', usage.cachedInputTokens),
          const MenuDivider(),
          usageLabel('Total', usage.totalTokens, emphasized: true),
        ],
      ),
    );
  }

  /// A read-only labelled token count for the usage popover.
  static MenuLabel usageLabel(
    String label,
    int value, {
    bool emphasized = false,
  }) => MenuLabel(
    trailing: Text(
      formatTokenCount(value),
      style: TextStyle(
        fontWeight: emphasized ? FontWeight.w600 : FontWeight.w500,
      ),
    ),
    child: Text(label),
  );
}

/// Three softly pulsing dots shown in an assistant bubble until the first token
/// arrives.
class _ThinkingDots extends StatefulWidget {
  const _ThinkingDots();

  @override
  State<_ThinkingDots> createState() => _ThinkingDotsState();
}

class _ThinkingDotsState extends State<_ThinkingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = ColorScheme.of(context).mutedForeground;
    if (reduceMotion(context)) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 3; i++)
            Padding(
              padding: EdgeInsets.only(right: i == 2 ? 0 : 4),
              child: Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
            ),
        ],
      );
    }
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 3; i++)
            Padding(
              padding: EdgeInsets.only(right: i == 2 ? 0 : 4),
              child: Opacity(
                opacity: _pulse(i),
                child: Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// A 0.35–1.0 opacity triangle wave, phase-shifted per dot.
  double _pulse(int index) {
    final t = (_controller.value + index * 0.16) % 1.0;
    final triangle = 1 - (2 * (t - 0.5)).abs();
    return 0.35 + 0.65 * triangle;
  }
}

/// A compact, muted line summarising one tool invocation. Hovering reveals the
/// arguments and the result or error.
class _ToolCallRow extends StatelessWidget {
  const _ToolCallRow({required this.call});

  final ToolCall call;

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);

    final label = switch (call) {
      ToolCall(isPending: true) => 'Running ${call.name}…',
      ToolCall(hasFailed: true) => '${call.name} failed',
      _ => 'Used ${call.name}',
    };

    return Tooltip(
      tooltip: (context) => TooltipContainer(child: Text(_details)),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              transitionBuilder: (child, animation) =>
                  FadeTransition(opacity: animation, child: child),
              child: call.isPending
                  ? SizedBox(
                      key: const ValueKey('running'),
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: colors.mutedForeground,
                      ),
                    )
                  : Icon(
                      call.hasFailed ? LucideIcons.info : LucideIcons.check,
                      key: const ValueKey('done'),
                      size: 14,
                      color: colors.mutedForeground,
                    ),
            ),
            const Gap(6),
            Flexible(
              child: Text(
                label,
                style: TextStyle(fontSize: 12, color: colors.mutedForeground),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String get _details {
    final buffer = StringBuffer(call.name);
    if (call.arguments != null) {
      buffer.write('\n\nArguments: ${call.arguments}');
    }
    if (call.result != null) {
      buffer.write('\n\nResult: ${call.result}');
    }
    if (call.error != null) {
      buffer.write('\n\nError: ${call.error}');
    }
    return buffer.toString();
  }
}

/// Shimmer bubbles shown while a conversation's history loads.
class _MessageHistorySkeleton extends StatelessWidget {
  const _MessageHistorySkeleton();

  @override
  Widget build(BuildContext context) {
    return Shimmer(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
        physics: const NeverScrollableScrollPhysics(),
        children: const [
          _SkeletonBubble(isUser: false, lines: 3, widthFactor: 0.8),
          _SkeletonBubble(isUser: true, lines: 1, widthFactor: 0.55),
          _SkeletonBubble(isUser: false, lines: 4, widthFactor: 0.85),
          _SkeletonBubble(isUser: true, lines: 2, widthFactor: 0.6),
        ],
      ),
    );
  }
}

class _SkeletonBubble extends StatelessWidget {
  const _SkeletonBubble({
    required this.isUser,
    required this.lines,
    required this.widthFactor,
  });

  final bool isUser;
  final int lines;
  final double widthFactor;

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: isUser
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: [
          if (!isUser) ...[
            const Skeleton(width: 26, height: 26, radius: 9),
            const Gap(12),
          ],
          Flexible(
            child: FractionallySizedBox(
              widthFactor: widthFactor,
              alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 11,
                ),
                decoration: BoxDecoration(
                  color: isUser ? colors.secondary : null,
                  borderRadius: BorderRadius.circular(18),
                  border: isUser ? null : Border.all(color: colors.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < lines; i++)
                      Padding(
                        padding: EdgeInsets.only(top: i == 0 ? 0 : 9),
                        child: FractionallySizedBox(
                          widthFactor: i == lines - 1 ? 0.55 : 1,
                          alignment: Alignment.centerLeft,
                          child: const Skeleton(height: 12),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
