import 'dart:typed_data';

import 'package:shadcn_flutter/shadcn_flutter.dart';

import '../attachments.dart';
import '../chat_api.dart';
import '../chat_controller.dart';
import 'model_badges.dart';

/// The icon for a file's content type: a modality icon where one exists, else a
/// generic file (video falls back to its own icon rather than the placeholder).
IconData attachmentIconFor(String contentType) {
  final type = contentType.toLowerCase();
  if (type.startsWith('video/')) return LucideIcons.video;
  if (type.startsWith('text/')) return LucideIcons.fileText;
  final modality = attachmentRequiredModality(contentType);
  return modality == null ? LucideIcons.file : modelInputModalityIcon(modality);
}

/// A compact pill for a non-image attachment (icon, name, size). [onTap] saves
/// it; [onRemove] turns it into a pending-composer chip.
class AttachmentChip extends StatelessWidget {
  const AttachmentChip({
    super.key,
    required this.attachment,
    this.chat,
    this.onTap,
    this.onRemove,
    this.thumbnail = false,
    this.problem,
  });

  final Attachment attachment;
  final String? problem;
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
          border: Border.all(
            color: problem == null ? colors.border : colors.destructive,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showThumb)
              SizedBox(
                width: 30,
                height: 30,
                child: AttachmentImage(
                  chat: chat!,
                  attachment: attachment,
                  maxWidth: 30,
                  maxHeight: 30,
                ),
              )
            else
              Icon(
                attachmentIconFor(attachment.contentType),
                size: 14,
                color: colors.mutedForeground,
              ),
            if (problem != null) ...[
              const Gap(4),
              Tooltip(
                tooltip: (_) => TooltipContainer(child: Text(problem!)),
                child: Icon(
                  LucideIcons.info,
                  size: 14,
                  color: colors.destructive,
                ),
              ),
            ],
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
class AttachmentImage extends StatelessWidget {
  const AttachmentImage({
    super.key,
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
          // A 404 means the backend's retention window purged the bytes (the
          // metadata is kept). Say so instead of showing a broken image.
          final error = snapshot.error;
          if (error is ChatApiException && error.statusCode == 404) {
            return ExpiredAttachmentChip(attachment: attachment);
          }
          return AttachmentChip(attachment: attachment, onTap: onTap);
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

/// A chip for an attachment whose bytes the backend has purged (its retention
/// window elapsed). The metadata is kept, so history still shows what was there
/// — just not the file itself.
class ExpiredAttachmentChip extends StatelessWidget {
  const ExpiredAttachmentChip({super.key, required this.attachment});

  final Attachment attachment;

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);
    return Semantics(
      label: 'File expired: ${attachment.fileName}',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: colors.muted,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: colors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.fileX, size: 14, color: colors.mutedForeground),
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
            const Text('no longer stored').muted.xSmall,
          ],
        ),
      ),
    );
  }
}

/// A small pill shown in the composer while an attachment uploads.
class UploadingChip extends StatelessWidget {
  const UploadingChip({super.key});

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

/// The attachments of one message: image thumbnails and file chips. Tapping a
/// file saves it; images are fetched through the authenticated [ChatController].
class AttachmentList extends StatelessWidget {
  const AttachmentList({
    super.key,
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
            AttachmentImage(
              chat: chat,
              attachment: attachment,
              onTap: () => onTap(attachment),
            )
          else
            AttachmentChip(
              attachment: attachment,
              onTap: () => onTap(attachment),
            ),
      ],
    );
  }
}
