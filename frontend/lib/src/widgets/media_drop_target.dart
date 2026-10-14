import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

import '../media_input.dart';

import 'package:super_clipboard/super_clipboard.dart' show DataReader;

/// Native incoming drop surface. Data requests are started before returning to
/// the platform; file reads and network uploads continue outside its callback.
class MediaDropTarget extends StatefulWidget {
  const MediaDropTarget({
    super.key,
    required this.enabled,
    required this.maxBytes,
    required this.maxItems,
    required this.onReceive,
    required this.child,
  });
  final bool enabled;
  final int maxBytes;
  final int maxItems;
  final ValueChanged<Future<MediaInputPayload>> onReceive;
  final Widget child;
  @override
  State<MediaDropTarget> createState() => _MediaDropTargetState();
}

class _MediaDropTargetState extends State<MediaDropTarget> {
  bool _over = false;
  @override
  Widget build(BuildContext context) {
    // Keep the composer subtree mounted when uploads/reads toggle availability.
    // Replacing this wrapper detaches focused text fields during a paste.
    return DropRegion(
      formats: Formats.standardFormats,
      hitTestBehavior: HitTestBehavior.opaque,
      onDropOver: (event) =>
          widget.enabled &&
              event.session.allowedOperations.contains(DropOperation.copy) &&
              event.session.items.any(
                (i) =>
                    i.canProvide(Formats.fileUri) ||
                    Formats.standardFormats.whereType<FileFormat>().any(
                      i.canProvide,
                    ),
              )
          ? DropOperation.copy
          : DropOperation.none,
      onDropEnter: (_) => setState(() => _over = widget.enabled),
      onDropLeave: (_) => setState(() => _over = false),
      onDropEnded: (_) {
        if (mounted) setState(() => _over = false);
      },
      onPerformDrop: (event) async {
        if (!widget.enabled) return;
        final readers = event.session.items
            .map((i) => i.dataReader)
            .whereType<DataReader>();
        widget.onReceive(
          readMediaItems(
            readers,
            maxBytes: widget.maxBytes,
            maxItems: widget.maxItems,
          ),
        );
      },
      child: Stack(
        children: [
          widget.child,
          if (_over && widget.enabled)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  alignment: Alignment.center,
                  color: ColorScheme.of(context).background
                      .withValues(alpha: 0.9),
                  child: const Text('Drop files to attach').large.semiBold,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
