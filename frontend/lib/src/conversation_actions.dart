import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'chat_controller.dart';
import 'models.dart';

/// Prompts for a new title and applies it. No-op if cancelled or left blank.
Future<void> renameConversationDialog(
  BuildContext context,
  ChatController chat,
  Conversation conversation,
) async {
  var value = conversation.title;

  final result = await showOverlay<String>(
    context,
    DialogConfiguration(),
    builder: (context) {
      return AlertDialog(
        title: const Text('Rename chat'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: TextField(
            initialValue: conversation.title,
            autofocus: true,
            onChanged: (text) => value = text,
            onSubmitted: (text) => Navigator.pop(context, text),
          ),
        ),
        actions: [
          OutlineButton(
            child: const Text('Cancel'),
            onPressed: () => Navigator.pop(context),
          ),
          PrimaryButton(
            child: const Text('Save'),
            onPressed: () => Navigator.pop(context, value),
          ),
        ],
      );
    },
  ).future;

  if (result != null && result.trim().isNotEmpty) {
    await chat.renameConversation(conversation.id, result);
  }
}

/// Asks for confirmation, then deletes the conversation.
Future<void> confirmDeleteConversation(
  BuildContext context,
  ChatController chat,
  Conversation conversation,
) async {
  final confirmed = await showOverlay<bool>(
    context,
    DialogConfiguration(),
    builder: (context) {
      return AlertDialog(
        title: const Text('Delete chat?'),
        content: const Text(
          'This permanently deletes the conversation and all of its messages.',
        ),
        actions: [
          OutlineButton(
            child: const Text('Cancel'),
            onPressed: () => Navigator.pop(context, false),
          ),
          DestructiveButton(
            child: const Text('Delete'),
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
      );
    },
  ).future;

  if (confirmed == true) {
    await chat.deleteConversation(conversation.id);
  }
}
