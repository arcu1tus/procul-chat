import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart' show LogicalKeyboardKey, TextInputAction;
import 'package:shadcn_flutter/shadcn_flutter.dart';

import '../chat_controller.dart';
import '../motion.dart';
import 'attachment_views.dart';
import 'icon_action.dart';
import 'pressable.dart';
import 'content_width.dart';

/// The chat composer: one rounded capsule holding the attach button, the text
/// field and the circular send button, with the edit banner and attachment chips
/// living above it.
///
/// The capsule carries a subtle border and shadow; an accent focus ring animates
/// in while the field is focused. Enter sends and Shift+Enter inserts a newline
/// (desktop only — the hint is hidden on touch), and the accessible labels
/// (`Send message` / `Attach file`) are preserved.
class Composer extends StatelessWidget {
  const Composer({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.chat,
    required this.onSubmit,
    required this.onAttach,
    required this.onCancelEdit,
    this.onPaste,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ChatController chat;
  final VoidCallback onSubmit;
  final ValueChanged<BuildContext> onAttach;
  final VoidCallback onCancelEdit;
  final VoidCallback? onPaste;

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);
    final enabled = !chat.isStreaming && !chat.isLoadingMessages;
    final canAttach =
        enabled &&
        !chat.isUploadingAttachment &&
        !chat.isReadingMedia &&
        chat.mediaReady;
    final pending = chat.pendingAttachments;
    final isEditing = chat.isEditing;
    // The Enter / Shift+Enter hint is meaningless without a hardware keyboard.
    final isTouch =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;

    return SafeArea(
      top: false,
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: kContentMaxWidth + 32),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _AnimatedSlot(
                  visible: isEditing,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        Icon(
                          LucideIcons.squarePen,
                          size: 14,
                          color: colors.mutedForeground,
                        ),
                        const Gap(6),
                        const Text('Editing message').muted.small,
                        const Spacer(),
                        IconAction(
                          key: const Key('cancel-edit'),
                          icon: LucideIcons.x,
                          label: 'Cancel edit',
                          size: 16,
                          onPressed: onCancelEdit,
                        ),
                      ],
                    ),
                  ),
                ),
                _AnimatedSlot(
                  visible: pending.isNotEmpty || chat.isUploadingAttachment,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        for (final attachment in pending)
                          AttachmentChip(
                            attachment: attachment,
                            chat: chat,
                            thumbnail: true,
                            problem: chat.pendingAttachmentProblem(attachment),
                            onRemove: () =>
                                chat.removePendingAttachment(attachment.id),
                          ),
                        if (chat.isUploadingAttachment) const UploadingChip(),
                      ],
                    ),
                  ),
                ),
                _Capsule(
                  controller: controller,
                  focusNode: focusNode,
                  enabled:
                      enabled &&
                      !chat.isUploadingAttachment &&
                      !chat.isReadingMedia,
                  canSubmit:
                      pending.isEmpty ||
                      chat.submissionProblem('message') == null,
                  hasAttachments: pending.isNotEmpty,
                  onPaste: onPaste,
                  canAttach: canAttach,
                  isEditing: isEditing,
                  onAttach: onAttach,
                  onSubmit: onSubmit,
                ),
                const Gap(8),
                Center(
                  child: Text(
                    chat.isStreaming
                        ? 'Procul is replying…'
                        : isEditing
                        ? 'Saving replaces the replies after this message.'
                        : isTouch
                        ? 'Add photos or files with the paperclip.'
                        : 'Enter to send · Shift + Enter for a new line',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 11,
                      color: colors.mutedForeground,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Animates a child in and out of the layout (fade + slide + size), so the edit
/// banner and the attachment strip appear and disappear smoothly.
class _AnimatedSlot extends StatelessWidget {
  const _AnimatedSlot({required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: motionDuration(context, Motion.medium),
      curve: Motion.curve,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: motionDuration(context, Motion.medium),
        switchInCurve: Motion.curve,
        switchOutCurve: Motion.curve,
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: SizeTransition(
            sizeFactor: animation,
            alignment: Alignment.topCenter,
            child: child,
          ),
        ),
        child: visible
            ? KeyedSubtree(key: const ValueKey('shown'), child: child)
            : const SizedBox.shrink(key: ValueKey('hidden')),
      ),
    );
  }
}

/// The writing surface, with a field above the attach/send toolbar.
class _Capsule extends StatelessWidget {
  const _Capsule({
    required this.controller,
    required this.focusNode,
    required this.enabled,
    required this.canAttach,
    required this.isEditing,
    required this.onAttach,
    required this.onSubmit,
    required this.canSubmit,
    required this.hasAttachments,
    this.onPaste,
  });

  final bool canSubmit;
  final bool hasAttachments;
  final VoidCallback? onPaste;
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool enabled;
  final bool canAttach;
  final bool isEditing;
  final ValueChanged<BuildContext> onAttach;
  final VoidCallback onSubmit;

  void _insertNewline() {
    final value = controller.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    controller.value = TextEditingValue(
      text: value.text.replaceRange(start, end, '\n'),
      selection: TextSelection.collapsed(offset: start + 1),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);
    final theme = Theme.of(context);

    return ListenableBuilder(
      listenable: Listenable.merge([focusNode, controller]),
      builder: (context, _) {
        final focused = focusNode.hasFocus;
        return AnimatedContainer(
          duration: motionDuration(context, Motion.medium),
          curve: Motion.curve,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: colors.card,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: focused
                  ? colors.ring.withValues(alpha: 0.55)
                  : colors.border,
              width: focused ? 1.5 : 1,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF000000).withValues(alpha: 0.08),
                blurRadius: focused ? 24 : 16,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              CallbackShortcuts(
                bindings: {
                  if (!kIsWeb && onPaste != null) ...{
                    const SingleActivator(
                      LogicalKeyboardKey.keyV,
                      control: true,
                    ): onPaste!,
                    const SingleActivator(LogicalKeyboardKey.keyV, meta: true):
                        onPaste!,
                  },
                  const SingleActivator(LogicalKeyboardKey.enter): onSubmit,
                  const SingleActivator(LogicalKeyboardKey.enter, shift: true):
                      _insertNewline,
                },
                // The capsule already draws the accent focus ring. shadcn's
                // `TextField` *always* wraps itself in its own `FocusOutline`
                // (passing its own `FocusOutlineTheme`, so an ambient
                // `ComponentTheme` is ignored) and that outline's default
                // border is the scheme's `ring`. Blank the ring for the field
                // only, so just the capsule's outer ring shows.
                child: Theme(
                  data: theme.copyWith(
                    colorScheme: () => theme.colorScheme.copyWith(
                      ring: () => const Color(0x00000000),
                    ),
                  ),
                  child: TextField(
                    key: const Key('message-input'),
                    enabled: enabled,
                    contextMenuBuilder: onPaste == null
                        ? null
                        : (context, editable) => TextFieldTapRegion(
                            child: ContextMenuPopup(
                              anchorContext: context,
                              position:
                                  editable.contextMenuAnchors.primaryAnchor,
                              children: [
                                for (final item
                                    in editable.contextMenuButtonItems.where(
                                      (i) =>
                                          i.type != ContextMenuButtonType.paste,
                                    ))
                                  MenuButton(
                                    onPressed: (_) => item.onPressed?.call(),
                                    child: Text(item.label ?? item.type.name),
                                  ),
                                MenuButton(
                                  onPressed: (_) {
                                    editable.hideToolbar();
                                    onPaste!();
                                  },
                                  child: const Text('Paste'),
                                ),
                              ],
                            ),
                          ),
                    controller: controller,
                    focusNode: focusNode,
                    minLines: 2,
                    maxLines: 6,
                    textInputAction: TextInputAction.send,
                    filled: false,
                    decoration: const BoxDecoration(),
                    border: const Border(),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 8,
                    ),
                    placeholder: Text(
                      isEditing
                          ? 'Edit your message…'
                          : 'Ask, write, or think out loud…',
                    ),
                    onSubmitted: (_) => onSubmit(),
                  ),
                ),
              ),
              const Gap(4),
              Row(
                children: [
                  Builder(
                    builder: (context) => IconAction(
                      icon: LucideIcons.paperclip,
                      label: 'Attach file',
                      onPressed: canAttach ? () => onAttach(context) : null,
                    ),
                  ),
                  const Spacer(),
                  _SendButton(
                    enabled:
                        enabled &&
                        canSubmit &&
                        (controller.text.trim().isNotEmpty || hasAttachments),
                    isEditing: isEditing,
                    onSubmit: onSubmit,
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The circular send button. Scales and fades between enabled and disabled.
class _SendButton extends StatelessWidget {
  const _SendButton({
    required this.enabled,
    required this.isEditing,
    required this.onSubmit,
  });

  final bool enabled;
  final bool isEditing;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      tooltip: (context) =>
          TooltipContainer(child: Text(isEditing ? 'Save changes' : 'Send')),
      child: Semantics(
        button: true,
        label: isEditing ? 'Save changes' : 'Send message',
        child: AnimatedScale(
          scale: enabled ? 1 : 0.9,
          duration: motionDuration(context, Motion.fast),
          curve: Motion.pop,
          child: AnimatedOpacity(
            opacity: enabled ? 1 : 0.5,
            duration: motionDuration(context, Motion.fast),
            curve: Motion.curve,
            child: PressableScale(
              enabled: enabled,
              child: PrimaryButton(
                shape: ButtonShape.circle,
                density: ButtonDensity.icon,
                onPressed: enabled ? onSubmit : null,
                child: Icon(
                  isEditing ? LucideIcons.check : LucideIcons.arrowUp,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
