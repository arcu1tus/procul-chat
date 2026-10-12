import 'dart:typed_data';

import 'package:procul_chat_flutter/src/attachments.dart';

/// An [AttachmentPicker] test double that never touches the `file_picker` /
/// `image_picker` platform channels.
///
/// Set the canned result for a source before triggering it; each `*Calls`
/// counter records how many times that source was opened, and [saved] records
/// every `save` call so tap-to-save behaviour is assertable.
class FakeAttachmentPicker implements AttachmentPicker {
  FakeAttachmentPicker({this.cameraResult});

  /// The file the next [pickFromCamera] returns, or null to simulate a cancel.
  PickedAttachment? cameraResult;

  /// The files the next [pickFromGallery] returns.
  List<PickedAttachment> galleryResult = const [];

  /// The files the next [pickFiles] returns.
  List<PickedAttachment> filesResult = const [];

  int cameraCalls = 0;
  int galleryCalls = 0;
  int filesCalls = 0;

  /// Every pick across all sources.
  int get pickCalls => cameraCalls + galleryCalls + filesCalls;

  /// The allow-list the file picker was asked for on the last [pickFiles], or
  /// null when unrestricted.
  List<String>? lastAllowedExtensions;

  /// Every `(fileName, bytes)` handed to [save], in order.
  final List<(String, Uint8List)> saved = [];

  @override
  Future<PickedAttachment?> pickFromCamera() async {
    cameraCalls++;
    final result = cameraResult;
    cameraResult = null;
    return result;
  }

  @override
  Future<List<PickedAttachment>> pickFromGallery({
    bool allowMultiple = true,
  }) async {
    galleryCalls++;
    final result = galleryResult;
    galleryResult = const [];
    return result;
  }

  @override
  Future<List<PickedAttachment>> pickFiles({
    List<String>? allowedExtensions,
  }) async {
    filesCalls++;
    lastAllowedExtensions = allowedExtensions;
    final result = filesResult;
    filesResult = const [];
    return result;
  }

  @override
  Future<void> save(String fileName, Uint8List bytes) async {
    saved.add((fileName, bytes));
  }
}
