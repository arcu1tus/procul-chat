import 'package:shadcn_flutter/shadcn_flutter.dart';

class ChatRefreshTrigger extends StatefulWidget {
  const ChatRefreshTrigger({super.key, required this.child, this.onRefresh});

  final Widget child;
  final Future<void> Function()? onRefresh;

  @override
  State<ChatRefreshTrigger> createState() => _ChatRefreshTriggerState();
}

class _ChatRefreshTriggerState extends State<ChatRefreshTrigger> {
  static const _threshold = 80.0;
  double _extent = 0;
  bool _bottom = true;
  bool _refreshing = false;

  @override
  void didUpdateWidget(covariant ChatRefreshTrigger oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.onRefresh == null) _extent = 0;
  }

  void _finishPull() {
    final callback = widget.onRefresh;
    if (_refreshing) return;
    if (_extent >= _threshold && callback != null) {
      setState(() {
        _extent = 0;
        _refreshing = true;
      });
      _refresh(callback);
    } else if (_extent != 0) {
      setState(() => _extent = 0);
    }
  }

  Future<void> _refresh(Future<void> Function() callback) async {
    try {
      await callback();
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0 ||
        notification.metrics.axis != Axis.vertical ||
        widget.onRefresh == null ||
        _refreshing) {
      return false;
    }
    final metrics = notification.metrics;
    final reversed = metrics.axisDirection == AxisDirection.up;
    if (notification is ScrollEndNotification) {
      _finishPull();
    } else if (notification is OverscrollNotification &&
        notification.dragDetails != null) {
      final atStart = notification.overscroll < 0;
      final bottom = atStart == reversed;
      setState(() {
        if (_bottom != bottom) _extent = 0;
        _bottom = bottom;
        _extent += notification.overscroll.abs();
      });
    } else if (notification is ScrollUpdateNotification) {
      // Bouncing physics emits updates outside the bounds instead of overscroll.
      // Its first ballistic update marks release, before the bounce erases the pull.
      if (notification.dragDetails == null) {
        _finishPull();
      } else {
        final before = metrics.minScrollExtent - metrics.pixels;
        final after = metrics.pixels - metrics.maxScrollExtent;
        setState(() {
          _extent = before > 0 ? before : (after > 0 ? after : 0);
          if (_extent > 0) _bottom = (before > 0) == reversed;
        });
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          widget.child,
          if (widget.onRefresh != null && (_refreshing || _extent > 0))
            Positioned(
              top: _bottom ? null : 8,
              bottom: _bottom ? 8 : null,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: DefaultRefreshIndicator(
                  stage: RefreshTriggerStage(
                    _refreshing
                        ? TriggerStage.refreshing
                        : TriggerStage.pulling,
                    AlwaysStoppedAnimation(
                      (_extent / _threshold).clamp(0, 1.0),
                    ),
                    Axis.vertical,
                    _bottom,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
