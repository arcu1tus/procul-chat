import 'package:flutter/services.dart' show TextInputAction;
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'chat_controller.dart';
import 'conversation_actions.dart';
import 'models.dart';

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
                      IconButton.ghost(
                        icon: const Icon(LucideIcons.panelLeft),
                        onPressed: widget.onMenu,
                      ),
                    ]
                  : const [],
              trailing: active == null
                  ? const []
                  : [
                      IconButton.ghost(
                        icon: const Icon(LucideIcons.squarePen),
                        onPressed: () =>
                            renameConversationDialog(context, chat, active),
                      ),
                      IconButton.ghost(
                        icon: const Icon(LucideIcons.trash2),
                        onPressed: () =>
                            confirmDeleteConversation(context, chat, active),
                      ),
                    ],
            ),
            const Divider(),
          ],
          child: Column(
            children: [
              Expanded(child: _body(chat)),
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
      return const Center(child: CircularProgressIndicator());
    }

    if (chat.messages.isEmpty) {
      return _EmptyState(onSuggestion: _useSuggestion);
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
      itemCount: chat.messages.length,
      itemBuilder: (context, index) {
        final message = chat.messages[index];
        return _MessageBubble(
          message: message,
          isStreaming: chat.isStreaming && index == chat.messages.length - 1,
        );
      },
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
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: colors.primary,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  LucideIcons.sparkles,
                  color: colors.primaryForeground,
                  size: 28,
                ),
              ),
              const Gap(18),
              const Text('How can I help?').semiBold.xLarge,
              const Gap(6),
              const Text(
                'Start a new chat by sending a message below.',
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
    // While tools run there is no reply text yet, so don't also show the "…"
    // placeholder — the tool rows already signal activity.
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
      return Text('…', style: TextStyle(color: colors.mutedForeground));
    }
    return GptMarkdown(text, isStreaming: isStreaming);
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
            if (call.isPending)
              SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colors.mutedForeground,
                ),
              )
            else
              Icon(
                call.hasFailed ? LucideIcons.info : LucideIcons.check,
                size: 14,
                color: colors.mutedForeground,
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
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 6,
                textInputAction: TextInputAction.send,
                placeholder: const Text('Message Procul…'),
                onSubmitted: (_) => onSubmit(),
              ),
            ),
            const Gap(8),
            PrimaryButton(
              density: ButtonDensity.icon,
              onPressed: enabled ? onSubmit : null,
              child: const Icon(LucideIcons.sendHorizontal),
            ),
          ],
        ),
      ),
    );
  }
}
