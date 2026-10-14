import 'package:procul_chat_flutter/src/attachments.dart';
import 'package:procul_chat_flutter/src/chat_controller.dart';
import 'package:procul_chat_flutter/src/models.dart';

ChatController withMediaPolicy(ChatController chat) {
  chat.attachmentPolicy = const AttachmentPolicy(
    maxAttachmentsPerMessage: 20,
    maxFileSizeBytes: 20 * 1024 * 1024,
    allowedContentTypes: [
      'image/*',
      'text/*',
      'application/pdf',
      'audio/mpeg',
      'audio/wav',
    ],
  );
  chat.setModels([
    for (final slug in ['solo', 'model/one', 'openai/gpt-4o-mini', 'test'])
      ChatModel(
        slug: slug,
        name: slug,
        capabilities: const ModelCapabilities(
          input: {
            ModelInputModality.text,
            ModelInputModality.image,
            ModelInputModality.file,
            ModelInputModality.audio,
          },
        ),
      ),
  ]);
  chat.setDefaultModel('test');
  return chat;
}
