import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, visibleForTesting;
import 'package:image_picker/image_picker.dart'
    show ImagePicker, ImageSource, XFile;
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart'
    show ImagePickerPlatform;

import 'models.dart';

/// An uploaded file's metadata, mirroring the backend's `AttachmentV1`.
///
/// The bytes never travel with the metadata: they are fetched on demand through
/// [ChatApi.fetchAttachmentBytes] (an `<img>` URL cannot carry the bearer token,
/// and this works on every platform).
class Attachment {
  const Attachment({
    required this.id,
    required this.fileName,
    required this.contentType,
    required this.sizeBytes,
    this.createdAt,
  });

  final String id;
  final String fileName;
  final String contentType;
  final int sizeBytes;
  final DateTime? createdAt;

  /// Whether the file should render as an image preview rather than a chip.
  bool get isImage => contentType.toLowerCase().startsWith('image/');

  factory Attachment.fromJson(Map<String, dynamic> json) => Attachment(
    id: '${json['id']}',
    fileName: '${json['fileName'] ?? 'file'}',
    contentType: '${json['contentType'] ?? 'application/octet-stream'}',
    sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
    createdAt: DateTime.tryParse('${json['createdAt']}'),
  );
}

/// Upload policy fetched from the authenticated backend.
class AttachmentPolicy {
  const AttachmentPolicy({
    required this.maxAttachmentsPerMessage,
    required this.maxFileSizeBytes,
    required this.allowedContentTypes,
  });
  final int maxAttachmentsPerMessage;
  final int maxFileSizeBytes;
  final List<String> allowedContentTypes;
  factory AttachmentPolicy.fromJson(
    Map<String, dynamic> json,
  ) => AttachmentPolicy(
    maxAttachmentsPerMessage: (json['maxAttachmentsPerMessage'] as num).toInt(),
    maxFileSizeBytes: (json['maxFileSizeBytes'] as num).toInt(),
    allowedContentTypes: (json['allowedContentTypes'] as List).cast<String>(),
  );
  bool allows(String contentType) {
    final type = contentType.trim().toLowerCase();
    return allowedContentTypes.any((raw) {
      final pattern = raw.trim().toLowerCase();
      return pattern.endsWith('/*')
          ? type.startsWith(pattern.substring(0, pattern.length - 1))
          : type == pattern;
    });
  }
}

/// The client-side pre-check cap (20 MiB). The backend's configured
/// `attachments.maxFileSizeBytes` is the source of truth; this just gives a
/// friendlier error before the bytes leave the device.
const int defaultMaxAttachmentBytes = 20 * 1024 * 1024;

/// The audio types the backend's adapter maps to an input-audio part.
const _audioTypes = {
  'audio/mpeg',
  'audio/mp3',
  'audio/wav',
  'audio/x-wav',
  'audio/wave',
};

/// The input modality a content type needs in order to be sent, or null when it
/// is always sent (text) or never sent (video / unknown).
///
/// Mirrors the backend's `AttachmentContentBuilder.RequiredModality`, which is
/// what the server enforces; the client uses this only to fail fast with a
/// friendly message.
ModelInputModality? attachmentRequiredModality(String contentType) {
  final type = contentType.trim().toLowerCase();
  if (type.startsWith('image/')) return ModelInputModality.image;
  if (type == 'application/pdf') return ModelInputModality.file;
  if (_audioTypes.contains(type)) return ModelInputModality.audio;
  return null;
}

/// A human label for a required modality, used in the rejection message.
String _modalityLabel(ModelInputModality modality) => switch (modality) {
  ModelInputModality.image => 'image',
  ModelInputModality.file => 'file',
  ModelInputModality.audio => 'audio',
  ModelInputModality.video => 'video',
  ModelInputModality.text => 'text',
};

/// The file extensions a model with [capabilities] can actually receive, used to
/// restrict the native picker so an unsupported file cannot even be chosen.
///
/// `text/*` is always included (the backend always inlines it). Video is
/// excluded on purpose: no model can receive it, so offering the extension would
/// only promise something the app cannot deliver.
const _extensionsByModality = <ModelInputModality, List<String>>{
  ModelInputModality.image: [
    'png',
    'jpg',
    'jpeg',
    'gif',
    'webp',
    'heic',
    'bmp',
  ],
  ModelInputModality.file: ['pdf'],
  ModelInputModality.audio: ['mp3', 'wav'],
  ModelInputModality.text: [
    'txt',
    'md',
    'csv',
    'json',
    'xml',
    'log',
    'yaml',
    'yml',
  ],
};

/// The picker's allow-list for a model's input modalities (sorted, for stable
/// tests and dialogs).
List<String> allowedExtensionsForCapabilities(
  Set<ModelInputModality> capabilities,
) {
  final extensions = <String>{
    ..._extensionsByModality[ModelInputModality.text]!,
  };
  for (final modality in const [
    ModelInputModality.image,
    ModelInputModality.file,
    ModelInputModality.audio,
  ]) {
    if (capabilities.contains(modality)) {
      extensions.addAll(_extensionsByModality[modality]!);
    }
  }
  return extensions.toList()..sort();
}

/// Returns a user-facing problem when the active model cannot receive the file,
/// or null when it can. [capabilities] is the active model's input set.
String? attachmentProblem({
  required String fileName,
  required String contentType,
  required int sizeBytes,
  required Set<ModelInputModality> capabilities,
  int maxBytes = defaultMaxAttachmentBytes,
  AttachmentPolicy? policy,
}) {
  if (sizeBytes > maxBytes) {
    return "'$fileName' is ${formatAttachmentSize(sizeBytes)}; "
        "the limit is ${formatAttachmentSize(maxBytes)}.";
  }

  if (sizeBytes <= 0) return "'$fileName' is empty.";
  if (policy != null && !policy.allows(contentType)) {
    return "'$fileName' has a content type this server does not allow.";
  }
  final type = contentType.trim().toLowerCase();
  if (!type.startsWith('text/') && attachmentRequiredModality(type) == null) {
    return "'$fileName' ($contentType) cannot be sent by the chat adapter.";
  }
  final required = attachmentRequiredModality(contentType);
  if (required != null && !capabilities.contains(required)) {
    return "'$fileName' needs the ${_modalityLabel(required)} capability, "
        "which the selected model doesn't have.";
  }

  return null;
}

/// Renders a byte count compactly: `512 B`, `12.3 KB`, `1.4 MB`.
///
/// Named `formatAttachmentSize` (not `formatFileSize`) to avoid colliding with
/// shadcn_flutter's own `formatFileSize`, which is exported app-wide.
String formatAttachmentSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    final kb = bytes / 1024;
    return '${kb < 10 ? kb.toStringAsFixed(1) : kb.round()} KB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

const _mimeByExtension = <String, String>{
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'heic': 'image/heic',
  'bmp': 'image/bmp',
  'pdf': 'application/pdf',
  'mp3': 'audio/mpeg',
  'wav': 'audio/wav',
  'm4a': 'audio/mp4',
  'oga': 'audio/ogg',
  'mp4': 'video/mp4',
  'mov': 'video/quicktime',
  'webm': 'video/webm',
  'txt': 'text/plain',
  'md': 'text/plain',
  'csv': 'text/plain',
  'json': 'text/plain',
  'xml': 'text/plain',
  'log': 'text/plain',
  'yaml': 'text/plain',
  'yml': 'text/plain',
};

/// Best-effort MIME type from a file name. `file_picker` does not report a
/// content type, so the extension is all we have; the backend validates again.
String attachmentMimeType(String fileName) {
  final dot = fileName.lastIndexOf('.');
  if (dot < 0 || dot == fileName.length - 1) return 'application/octet-stream';
  return _mimeByExtension[fileName.substring(dot + 1).toLowerCase()] ??
      'application/octet-stream';
}

/// Where an attachment comes from.
enum AttachmentSource { camera, gallery, files }

/// Which attachment sources this platform offers, and which the active model
/// can actually read.
///
/// Camera is offered only where the OS has a native camera control
/// (`image_picker`'s `supportsImageSource`); Gallery and Files are always
/// available. The UI additionally hides Camera/Gallery when the active model
/// cannot read images.
class AttachmentSources {
  /// The available sources in menu order (camera, gallery, files).
  static List<AttachmentSource> available() {
    return [
      if (_cameraSupported()) AttachmentSource.camera,
      AttachmentSource.gallery,
      AttachmentSource.files,
    ];
  }

  /// Test override for [available]: the `image_picker` platform channel is not
  /// registered under `flutter_test`.
  @visibleForTesting
  static bool? debugCameraSupported;

  static bool _cameraSupported() {
    if (debugCameraSupported != null) return debugCameraSupported!;
    try {
      return ImagePickerPlatform.instance.supportsImageSource(
        ImageSource.camera,
      );
    } catch (_) {
      // Fall back to the platforms that have a native camera UI.
      return defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS;
    }
  }
}

/// A file the user picked, before it has been uploaded.
class PickedAttachment {
  const PickedAttachment({
    required this.bytes,
    required this.fileName,
    required this.contentType,
  });

  final Uint8List bytes;
  final String fileName;
  final String contentType;
}

/// Picking and saving files, abstracted so widget tests never touch the
/// `file_picker` / `image_picker` platform channels.
abstract interface class AttachmentPicker {
  /// Captures a photo through the OS camera UI. Returns null when cancelled.
  Future<PickedAttachment?> pickFromCamera();

  /// Picks one or more images from the photo library / gallery.
  Future<List<PickedAttachment>> pickFromGallery({bool allowMultiple = true});

  /// Opens the file picker, offering only [allowedExtensions] when given (the
  /// active model's readable file types). Always multi-select.
  Future<List<PickedAttachment>> pickFiles({List<String>? allowedExtensions});

  /// Saves [bytes] under [fileName], opening the platform's save dialog (web
  /// downloads directly).
  Future<void> save(String fileName, Uint8List bytes);
}

/// The real [AttachmentPicker]: `image_picker` for camera + gallery, and
/// `package:file_picker` for files.
class FilePickerAttachmentPicker implements AttachmentPicker {
  const FilePickerAttachmentPicker();

  @override
  Future<PickedAttachment?> pickFromCamera() async {
    final file = await ImagePicker().pickImage(source: ImageSource.camera);
    if (file == null) return null;
    return _fromXFile(file);
  }

  @override
  Future<List<PickedAttachment>> pickFromGallery({
    bool allowMultiple = true,
  }) async {
    final picker = ImagePicker();
    final List<XFile> files;
    if (allowMultiple) {
      files = await picker.pickMultiImage();
    } else {
      final single = await picker.pickImage(source: ImageSource.gallery);
      files = [?single];
    }
    return [for (final file in files) await _fromXFile(file)];
  }

  @override
  Future<List<PickedAttachment>> pickFiles({
    List<String>? allowedExtensions,
  }) async {
    final files = await FilePicker.pickFiles(
      type: allowedExtensions == null ? FileType.any : FileType.custom,
      allowedExtensions: allowedExtensions,
    );
    return [
      for (final file in files)
        PickedAttachment(
          bytes: await file.readAsBytes(),
          fileName: file.name,
          contentType: attachmentMimeType(file.name),
        ),
    ];
  }

  @override
  Future<void> save(String fileName, Uint8List bytes) async {
    await FilePicker.saveFile(
      fileName: fileName,
      bytes: bytes,
      mimeType: attachmentMimeType(fileName),
    );
  }

  Future<PickedAttachment> _fromXFile(XFile file) async {
    final bytes = await file.readAsBytes();
    final name = file.name.isEmpty ? 'image' : file.name;
    return PickedAttachment(
      bytes: bytes,
      fileName: name,
      contentType: file.mimeType ?? attachmentMimeType(name),
    );
  }
}
