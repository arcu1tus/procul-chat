import 'dart:async';
import 'dart:typed_data';

import 'package:super_clipboard/super_clipboard.dart';

import 'attachments.dart';

/// One user paste operation, preserving text and file order separately.
class MediaInputPayload {
  const MediaInputPayload({
    this.text = '',
    this.files = const [],
    this.errors = const [],
  });
  final String text;
  final List<PickedAttachment> files;
  final List<String> errors;
}

/// Clipboard seam: tests can supply payloads without native channels.
abstract interface class MediaInputSource {
  Future<MediaInputPayload> readClipboard({
    required int maxBytes,
    required int maxItems,
  });
}

class SystemMediaInputSource implements MediaInputSource {
  const SystemMediaInputSource();
  @override
  Future<MediaInputPayload> readClipboard({
    required int maxBytes,
    required int maxItems,
  }) async {
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) return const MediaInputPayload();
    final reader = await clipboard.read();
    return readClipboardItems(
      reader.items,
      maxBytes: maxBytes,
      maxItems: maxItems,
      text: await reader.readValue(Formats.plainText) ?? '',
    );
  }
}

/// Text selections often also advertise text/HTML file representations. Keep
/// ordinary paste as text, while retaining named files and mixed media items.
Future<MediaInputPayload> readClipboardItems(
  Iterable<DataReader> readers, {
  required int maxBytes,
  required int maxItems,
  String text = '',
}) async {
  final files = <DataReader>[];
  for (final reader in readers) {
    final formats = reader
        .getFormats(Formats.standardFormats)
        .whereType<FileFormat>();
    final textRepresentation =
        formats.isNotEmpty &&
        formats.every(
          (f) => f == Formats.plainTextFile || f == Formats.htmlFile,
        );
    if (text.isNotEmpty &&
        textRepresentation &&
        !reader.canProvide(Formats.fileUri) &&
        await reader.getSuggestedName() == null) {
      continue;
    }
    files.add(reader);
  }
  return readMediaItems(
    files,
    maxBytes: maxBytes,
    maxItems: maxItems,
    text: text,
  );
}

/// Starts file requests synchronously so drop readers remain valid after the
/// platform callback returns. Each item contributes only one representation.
Future<MediaInputPayload> readMediaItems(
  Iterable<DataReader> readers, {
  required int maxBytes,
  required int maxItems,
  String text = '',
}) {
  final work = <Future<PickedAttachment?>>[];
  final errors = <String>[];
  for (final reader in readers) {
    final formats = reader
        .getFormats(Formats.standardFormats)
        .whereType<FileFormat>()
        .toList();
    final localFile = reader.canProvide(Formats.fileUri);
    if (formats.isEmpty && !localFile) continue;
    if (work.length >= maxItems) {
      errors.add('The attachment limit has been reached.');
      break;
    }
    // Prefer PNG for synthesized DIB/TIFF clipboard images, otherwise preserve
    // the supplied representation and its suggested filename.
    final format = reader.canProvide(Formats.png)
        ? Formats.png
        : formats.firstOrNull;
    final itemIndex = work.length + 1;
    final completer = Completer<PickedAttachment?>();
    work.add(completer.future);
    final progress = reader.getFile(
      format,
      (file) async {
        try {
          final stream = file.getStream();
          if (file.fileSize != null && file.fileSize! > maxBytes) {
            file.close();
            throw StateError('The file exceeds the configured size limit.');
          }
          final bytes = await readMediaBytes(stream, maxBytes);
          final suggested = file.fileName;
          final name = suggested ?? 'pasted-$itemIndex.${_extension(format)}';
          final type = _extension(format) == 'bin'
              ? attachmentMimeType(name)
              : _mime(format);
          completer.complete(
            PickedAttachment(bytes: bytes, fileName: name, contentType: type),
          );
        } catch (e) {
          errors.add('$e');
          completer.complete(null);
        }
      },
      onError: (e) {
        errors.add('$e');
        if (!completer.isCompleted) completer.complete(null);
      },
    );
    if (progress == null) completer.complete(null);
  }
  return Future.wait(work).then(
    (files) => MediaInputPayload(
      text: text,
      files: files.whereType<PickedAttachment>().toList(),
      errors: errors,
    ),
  );
}

/// Buffers at most the configured maximum; subscription cancellation closes
/// native/virtual file streams when the limit is exceeded.
Future<Uint8List> readMediaBytes(Stream<Uint8List> stream, int maxBytes) async {
  final buffer = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    if (buffer.length + chunk.length > maxBytes) {
      throw StateError('The file exceeds the configured size limit.');
    }
    buffer.add(chunk);
  }
  return buffer.takeBytes();
}

String _extension(FileFormat? format) {
  if (format == Formats.png) return 'png';
  if (format == Formats.jpeg) return 'jpg';
  if (format == Formats.webp) return 'webp';
  if (format == Formats.pdf) return 'pdf';
  if (format == Formats.mp3) return 'mp3';
  if (format == Formats.wav) return 'wav';
  if (format == Formats.plainTextFile) return 'txt';
  return 'bin';
}

String _mime(FileFormat? format) =>
    attachmentMimeType('file.${_extension(format)}');
