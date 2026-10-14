import 'package:flutter/foundation.dart' show ValueChanged;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:super_clipboard/super_clipboard.dart';
import 'package:procul_chat_flutter/src/media_input.dart';

void main() {
  test('ordinary text representations do not create an attachment', () async {
    final reader = _Reader([Formats.plainTextFile, Formats.htmlFile], [1]);
    final payload = await readClipboardItems(
      [reader],
      maxBytes: 10,
      maxItems: 20,
      text: 'selected text',
    );
    expect(payload.text, 'selected text');
    expect(payload.files, isEmpty);
    expect(reader.reads, 0);
  });
  test('named text files are retained during mixed paste', () async {
    final reader = _Reader([Formats.plainTextFile], [1], name: 'notes.txt');
    final payload = await readClipboardItems(
      [reader],
      maxBytes: 10,
      maxItems: 20,
      text: 'caption',
    );
    expect(payload.files, hasLength(1));
    expect(reader.reads, 1);
  });
  test(
    'one representation per item and deterministic order with mixed text',
    () async {
      final first = _Reader([Formats.png, Formats.jpeg], [1, 2]);
      final second = _Reader([Formats.pdf], [3]);
      final payload = await readMediaItems(
        [first, second],
        maxBytes: 10,
        maxItems: 2,
        text: 'caption',
      );
      expect(first.reads, 1);
      expect(payload.text, 'caption');
      expect(payload.files.map((f) => f.contentType), [
        'image/png',
        'application/pdf',
      ]);
      expect(payload.files.first.bytes, [1, 2]);
    },
  );
  test(
    'bounded reads reject oversize streams and stop consuming them',
    () async {
      var reads = 0;
      Stream<Uint8List> source() async* {
        for (var i = 0; i < 10; i++) {
          reads++;
          yield Uint8List(4);
        }
      }

      await expectLater(readMediaBytes(source(), 5), throwsStateError);
      expect(reads, 2);
    },
  );
  test('count limit does not read excess items', () async {
    final first = _Reader([Formats.png], [1]);
    final second = _Reader([Formats.png], [2]);
    final payload = await readMediaItems(
      [first, second],
      maxBytes: 10,
      maxItems: 1,
    );
    expect(payload.files, hasLength(1));
    expect(second.reads, 0);
    expect(payload.errors, isNotEmpty);
  });
  test('a remote URL is not fetched as a file', () async {
    final reader = _Reader([Formats.uri], []);
    final result = await readMediaItems(
      [reader],
      maxBytes: 10,
      maxItems: 20,
      text: 'https://example.com/image',
    );
    expect(reader.reads, 0);
    expect(result.files, isEmpty);
    expect(result.text, 'https://example.com/image');
  });
}

class _Reader implements DataReader {
  _Reader(this.formats, this.bytes, {this.name});
  final String? name;
  final List<DataFormat> formats;
  final List<int> bytes;
  int reads = 0;
  @override
  Future<String?> getSuggestedName() async => name;
  @override
  bool canProvide(DataFormat format) => formats.contains(format);
  @override
  List<DataFormat> getFormats(List<DataFormat> allFormats) =>
      formats.where(allFormats.contains).toList();
  @override
  ReadProgress? getFile(
    FileFormat? format,
    AsyncValueChanged<DataReaderFile> onFile, {
    ValueChanged<Object>? onError,
    bool allowVirtualFiles = true,
    bool synthesizeFilesFromURIs = true,
  }) {
    reads++;
    unawaited(Future(() async => onFile(_File(bytes))));
    return _Progress();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Progress implements ReadProgress {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _File implements DataReaderFile {
  _File(this.bytes);
  final List<int> bytes;
  @override
  String? get fileName => null;
  @override
  int? get fileSize => bytes.length;
  @override
  Stream<Uint8List> getStream() => Stream.value(Uint8List.fromList(bytes));
  @override
  void close() {}
  @override
  Future<Uint8List> readAll() async => Uint8List.fromList(bytes);
}
