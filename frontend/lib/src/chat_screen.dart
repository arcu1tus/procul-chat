import 'package:flutter/services.dart' show LogicalKeyboardKey, TextInputAction;
import 'package:google_fonts/google_fonts.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'chat_controller.dart';
import 'conversation_actions.dart';
import 'models.dart';
import 'widgets/icon_action.dart';
import 'widgets/skeleton.dart';

/// The chat pane: header, message list, and composer.
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.chat,
    this.showMenuButton = false,
    this.onMenu,
  });

  final ChatController chat;

  /// Whether to show a leading button that opens the conversation drawer.
  final bool showMenuButton;
  final VoidCallback? onMenu;

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
                enabled: !chat.isStreaming,
                onSubmit: _submit,
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
            isStreaming: chat.isStreaming && index == chat.messages.length - 1,
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
  const _MessageBubble({required this.message, required this.isStreaming});

  final ChatMessage message;
  final bool isStreaming;

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);
    final isUser = message.isUser;
    final hasTools = message.toolCalls.isNotEmpty;
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
    required this.enabled,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
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
