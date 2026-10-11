import 'dart:typed_data';

import 'package:procul_chat_flutter/src/attachments.dart';

/// An [AttachmentPicker] test double that never touches the `file_picker`
/// platform channel.
///
/// Queue a result with [next] before tapping attach; [saved] records every
/// `save` call so tap-to-save behaviour is assertable.
class FakeAttachmentPicker implements AttachmentPicker {
  FakeAttachmentPicker({this.next});

  /// The file the next [pick] returns, or null to simulate a cancel.
  PickedAttachment? next;

  /// Every `(fileName, bytes)` handed to [save], in order.
  final List<(String, Uint8List)> saved = [];

  int pickCalls = 0;

  /// The allow-list the picker was asked for on the last [pick], or null when
  /// unrestricted.
  List<String>? lastAllowedExtensions;

  @override
  Future<PickedAttachment?> pick({List<String>? allowedExtensions}) async {
    pickCalls++;
    lastAllowedExtensions = allowedExtensions;
    final result = next;
    next = null;
    return result;
  }

  @override
  Future<void> save(String fileName, Uint8List bytes) async {
    saved.add((fileName, bytes));
  }
}
