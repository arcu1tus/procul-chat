import 'dart:typed_data';

import 'package:flutter/services.dart' show LogicalKeyboardKey, TextInputAction;
import 'package:google_fonts/google_fonts.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'attachments.dart';
import 'chat_controller.dart';
import 'conversation_actions.dart';
import 'model_catalog_controller.dart';
import 'models.dart';
import 'widgets/icon_action.dart';
import 'widgets/model_badges.dart';
import 'widgets/skeleton.dart';

/// The chat pane: header, message list, and composer.
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.chat,
    this.catalog,
    this.picker = const FilePickerAttachmentPicker(),
    this.showMenuButton = false,
    this.compactModelPicker = false,
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

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();

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
    super.dispose();
  }

  void _trackPin() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    _pinnedToBottom = position.maxScrollExtent - position.pixels < 140;
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
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      });
    }
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
    if (text.trim().isEmpty || widget.chat.isStreaming) return;
    _inputController.clear();
    _pinnedToBottom = true;
    widget.chat.send(text);
  }

  void _useSuggestion(String suggestion) {
    _inputController.text = suggestion;
    _inputController.selection = TextSelection.collapsed(
      offset: suggestion.length,
    );
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

  /// Picks a file, restricted to what the active model can read, validates it,
  /// and uploads it. The backend re-checks both (see [ChatApi.uploadAttachment]).
  Future<void> _attach() async {
    final chat = widget.chat;
    if (chat.isStreaming || chat.isUploadingAttachment) return;

    final capabilities = _activeCapabilities();

    final PickedAttachment? picked;
    try {
      picked = await widget.picker.pick(
        allowedExtensions: capabilities == null
            ? null
            : allowedExtensionsForCapabilities(capabilities),
      );
    } catch (e) {
      chat.reportError('Could not open the file picker: $e');
      return;
    }
    if (picked == null || !mounted) return;

    await chat.uploadAttachment(picked, capabilities: capabilities);
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
              title: Text(active?.title ?? 'New chat'),
              subtitle: active == null
                  ? const Text('Ask Procul anything').muted.small
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
              trailing: [
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
                  onPressed: chat.refreshAll,
                ),
                if (active != null) ...[
                  IconAction(
                    icon: LucideIcons.squarePen,
                    label: 'Rename chat',
                    onPressed: () =>
                        renameConversationDialog(context, chat, active),
                  ),
                  IconAction(
                    icon: LucideIcons.trash2,
                    label: 'Delete chat',
                    onPressed: () =>
                        confirmDeleteConversation(context, chat, active),
                  ),
                ],
              ],
            ),
            const Divider(),
          ],
          child: Column(
            children: [
              Expanded(
                child: RefreshTrigger(
                  // A pull must not clobber a live stream, so disable it mid-turn.
                  onRefresh: chat.isStreaming
                      ? null
                      : chat.reloadActiveConversation,
                  child: _body(chat),
                ),
              ),
              _Composer(
                controller: _inputController,
                chat: chat,
                onSubmit: _submit,
                onAttach: _attach,
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
      return _EmptyState(onSuggestion: _useSuggestion);
    }

    if (_suppressEntrance) {
      _seenMessages.addAll(chat.messages);
      _suppressEntrance = false;
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
      itemCount: chat.messages.length,
      itemBuilder: (context, index) {
        final message = chat.messages[index];
        final animate = !_seenMessages.contains(message);
        if (animate) _seenMessages.add(message);
        return _MessageEntrance(
          animate: animate,
          child: _MessageBubble(
            message: message,
            chat: chat,
            isStreaming: chat.isStreaming && index == chat.messages.length - 1,
            onSaveAttachment: _saveAttachment,
          ),
        );
      },
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
    duration: const Duration(milliseconds: 200),
    value: widget.animate ? 0 : 1,
  );
  late final Animation<double> _curve = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOut,
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

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onSuggestion});

  final ValueChanged<String> onSuggestion;

  static const _suggestions = [
    'Explain a tricky concept in simple terms',
    'Help me debug this code',
    'Brainstorm ideas with me',
    'Plan my week',
  ];

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);

    return Center(
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Ask Procul anything',
                textAlign: TextAlign.center,
                style: GoogleFonts.coiny(
                  fontSize: 34,
                  height: 1.1,
                  color: colors.foreground,
                ),
              ),
              const Gap(10),
              Container(
                width: 30,
                height: 3,
                decoration: BoxDecoration(
                  color: colors.primary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const Gap(12),
              const Text(
                'Send a message to start a new chat.',
                textAlign: TextAlign.center,
              ).muted,
              const Gap(22),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  for (final suggestion in _suggestions)
                    OutlineButton(
                      onPressed: () => onSuggestion(suggestion),
                      child: Text(suggestion).small,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.chat,
    required this.isStreaming,
    required this.onSaveAttachment,
  });

  final ChatMessage message;
  final ChatController chat;
  final bool isStreaming;
  final ValueChanged<Attachment> onSaveAttachment;

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);
    final isUser = message.isUser;
    final hasTools = message.toolCalls.isNotEmpty;
    final hasAttachments = message.attachments.isNotEmpty;
    // While tools run there is no reply text yet, so don't also show the
    // thinking dots — the tool rows already signal activity.
    final showText = message.text.isNotEmpty || !hasTools;

    final bubble = Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: isUser ? colors.primary : colors.card,
        borderRadius: BorderRadius.circular(14),
        border: isUser ? null : Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final call in message.toolCalls) _ToolCallRow(call: call),
          if (hasTools && showText) const Gap(8),
          if (hasAttachments) ...[
            _AttachmentList(
              chat: chat,
              attachments: message.attachments,
              onTap: onSaveAttachment,
            ),
            if (showText) const Gap(8),
          ],
          if (showText)
            isUser
                ? Text(
                    message.text,
                    style: TextStyle(color: colors.primaryForeground),
                  )
                : _AssistantText(text: message.text, isStreaming: isStreaming),
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: isUser
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: [
          if (!isUser) ...[
            _Avatar(
              icon: LucideIcons.sparkles,
              background: colors.primary,
              foreground: colors.primaryForeground,
            ),
            const Gap(10),
          ],
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: bubble,
            ),
          ),
          if (isUser) ...[
            const Gap(10),
            _Avatar(
              icon: LucideIcons.user,
              background: colors.secondary,
              foreground: colors.secondaryForeground,
            ),
          ],
        ],
      ),
    );
  }
}

/// The attachments of one message: image thumbnails and file chips. Tapping a
/// file saves it; images are fetched through the authenticated [ChatController].
class _AttachmentList extends StatelessWidget {
  const _AttachmentList({
    required this.chat,
    required this.attachments,
    required this.onTap,
  });

  final ChatController chat;
  final List<Attachment> attachments;
  final ValueChanged<Attachment> onTap;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final attachment in attachments)
          if (attachment.isImage)
            _AttachmentImage(
              chat: chat,
              attachment: attachment,
              onTap: () => onTap(attachment),
            )
          else
            _AttachmentChip(
              attachment: attachment,
              onTap: () => onTap(attachment),
            ),
      ],
    );
  }
}

/// A compact pill for a non-image attachment (icon, name, size). [onTap] saves
/// it; [onRemove] turns it into a pending-composer chip.
class _AttachmentChip extends StatelessWidget {
  const _AttachmentChip({
    required this.attachment,
    this.chat,
    this.onTap,
    this.onRemove,
    this.thumbnail = false,
  });

  final Attachment attachment;
  final ChatController? chat;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;

  /// Whether to show a small image preview as the leading element.
  final bool thumbnail;

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);
    final showThumb = thumbnail && attachment.isImage && chat != null;

    return Clickable(
      onPressed: onTap,
      child: Container(
        padding: EdgeInsets.fromLTRB(8, 5, onRemove != null ? 3 : 10, 5),
        decoration: BoxDecoration(
          color: colors.secondary,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: colors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showThumb)
              SizedBox(
                width: 30,
                height: 30,
                child: _AttachmentImage(
                  chat: chat!,
                  attachment: attachment,
                  maxWidth: 30,
                  maxHeight: 30,
                ),
              )
            else
              Icon(
                _attachmentIcon(attachment.contentType),
                size: 14,
                color: colors.mutedForeground,
              ),
            const Gap(8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 170),
              child: Text(
                attachment.fileName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ).small,
            ),
            const Gap(6),
            Text(formatAttachmentSize(attachment.sizeBytes)).muted.xSmall,
            if (onRemove != null) ...[
              const Gap(2),
              IconButton.ghost(
                density: ButtonDensity.compact,
                icon: const Icon(LucideIcons.x, size: 14),
                onPressed: onRemove,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// An image attachment rendered from bytes fetched through [ChatController]
/// (never an `<img>` URL, which could not carry the bearer token).
class _AttachmentImage extends StatelessWidget {
  const _AttachmentImage({
    required this.chat,
    required this.attachment,
    this.onTap,
    this.maxWidth = 260,
    this.maxHeight = 260,
  });

  final ChatController chat;
  final Attachment attachment;
  final VoidCallback? onTap;
  final double maxWidth;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);

    return FutureBuilder<Uint8List>(
      future: chat.loadAttachmentBytes(attachment.id),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _AttachmentChip(attachment: attachment, onTap: onTap);
        }

        if (!snapshot.hasData) {
          return Container(
            width: maxWidth,
            height: maxWidth < 60 ? maxWidth : 120,
            decoration: BoxDecoration(
              color: colors.muted,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: colors.border),
            ),
            child: const Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }

        return Semantics(
          image: true,
          label: attachment.fileName,
          child: Clickable(
            onPressed: onTap,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: maxWidth,
                  maxHeight: maxHeight,
                ),
                child: Image.memory(
                  snapshot.data!,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The icon for a file's content type: a modality icon where one exists, else a
/// generic file (video falls back to its own icon rather than the placeholder).
IconData _attachmentIcon(String contentType) {
  final type = contentType.toLowerCase();
  if (type.startsWith('video/')) return LucideIcons.video;
  if (type.startsWith('text/')) return LucideIcons.fileText;
  final modality = attachmentRequiredModality(contentType);
  return modality == null ? LucideIcons.file : modelInputModalityIcon(modality);
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
    return _ShimmerText(
      active: isStreaming,
      child: GptMarkdown(text, isStreaming: isStreaming),
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
    showDropdown(
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
    showDropdown(
      context: context,
      builder: (context) => DropdownMenu(
        children: [
          _usageLabel('Input', usage.inputTokens),
          _usageLabel('Output', usage.outputTokens),
          _usageLabel('Cached', usage.cachedInputTokens),
          const MenuDivider(),
          _usageLabel('Total', usage.totalTokens, emphasized: true),
        ],
      ),
    );
  }

  /// A read-only labelled token count for the usage popover.
  static MenuLabel _usageLabel(
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

/// Sweeps a gradient highlight across [child] while [active], so streaming
/// assistant text shimmers. It owns its own controller, so per-token rebuilds of
/// the text do not restart the sweep; once [active] is false the overlay is
/// removed and the text renders normally.
class _ShimmerText extends StatefulWidget {
  const _ShimmerText({required this.active, required this.child});

  final bool active;
  final Widget child;

  @override
  State<_ShimmerText> createState() => _ShimmerTextState();
}

class _ShimmerTextState extends State<_ShimmerText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void initState() {
    super.initState();
    if (widget.active) _controller.repeat();
  }

  @override
  void didUpdateWidget(_ShimmerText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.active && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) {
      return widget.child;
    }

    final foreground = ColorScheme.of(context).foreground;
    final base = foreground.withValues(alpha: 0.45);

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => ShaderMask(
        blendMode: BlendMode.srcIn,
        shaderCallback: (bounds) => LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [base, foreground, base],
          stops: const [0.35, 0.5, 0.65],
          transform: _SlidingGradientTransform(_controller.value * 2 - 1),
        ).createShader(bounds),
        child: child,
      ),
      child: widget.child,
    );
  }
}

/// Slides a gradient horizontally by a fraction of its bounds.
class _SlidingGradientTransform extends GradientTransform {
  const _SlidingGradientTransform(this.slidePercent);

  final double slidePercent;

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues(bounds.width * slidePercent, 0, 0);
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

class _Avatar extends StatelessWidget {
  const _Avatar({
    required this.icon,
    required this.background,
    required this.foreground,
  });

  final IconData icon;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(color: background, shape: BoxShape.circle),
      child: Icon(icon, size: 16, color: foreground),
    );
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

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.chat,
    required this.onSubmit,
    required this.onAttach,
  });

  final TextEditingController controller;
  final ChatController chat;
  final VoidCallback onSubmit;
  final VoidCallback onAttach;

  @override
  Widget build(BuildContext context) {
    final enabled = !chat.isStreaming;
    final canAttach = enabled && !chat.isUploadingAttachment;
    final pending = chat.pendingAttachments;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (pending.isNotEmpty || chat.isUploadingAttachment)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (final attachment in pending)
                      _AttachmentChip(
                        attachment: attachment,
                        chat: chat,
                        thumbnail: true,
                        onRemove: () =>
                            chat.removePendingAttachment(attachment.id),
                      ),
                    if (chat.isUploadingAttachment) const _UploadingChip(),
                  ],
                ),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconAction(
                  icon: LucideIcons.paperclip,
                  label: 'Attach file',
                  onPressed: canAttach ? onAttach : null,
                ),
                const Gap(4),
                Expanded(
                  child: CallbackShortcuts(
                    // Enter sends; Shift+Enter is left to the field so it
                    // inserts a newline.
                    bindings: {
                      const SingleActivator(LogicalKeyboardKey.enter): onSubmit,
                    },
                    child: TextField(
                      controller: controller,
                      minLines: 1,
                      maxLines: 6,
                      textInputAction: TextInputAction.send,
                      placeholder: const Text('Message Procul…'),
                      onSubmitted: (_) => onSubmit(),
                    ),
                  ),
                ),
                const Gap(8),
                Tooltip(
                  tooltip: (context) =>
                      const TooltipContainer(child: Text('Send')),
                  child: Semantics(
                    button: true,
                    label: 'Send message',
                    child: PrimaryButton(
                      density: ButtonDensity.icon,
                      onPressed: enabled ? onSubmit : null,
                      child: const Icon(LucideIcons.sendHorizontal),
                    ),
                  ),
                ),
              ],
            ),
            const Gap(6),
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Row(
                children: [
                  const KeyboardDisplay(keys: [LogicalKeyboardKey.enter]),
                  const Gap(6),
                  const Text('send').muted.xSmall,
                  const Gap(12),
                  const KeyboardDisplay(
                    keys: [LogicalKeyboardKey.shift, LogicalKeyboardKey.enter],
                  ),
                  const Gap(6),
                  const Text('new line').muted.xSmall,
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A small pill shown in the composer while an attachment uploads.
class _UploadingChip extends StatelessWidget {
  const _UploadingChip();

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: colors.secondary,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 13,
            height: 13,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: colors.mutedForeground,
            ),
          ),
          const Gap(8),
          const Text('Uploading…').muted.small,
        ],
      ),
    );
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
            const Skeleton(width: 30, height: 30, radius: 15),
            const Gap(10),
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
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: colors.border),
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
          if (isUser) ...[
            const Gap(10),
            const Skeleton(width: 30, height: 30, radius: 15),
          ],
        ],
      ),
    );
  }
}
