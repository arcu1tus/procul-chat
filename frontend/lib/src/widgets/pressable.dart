import 'package:flutter/widgets.dart';

import '../motion.dart';

/// Wraps a tappable control so it dips slightly while pressed.
///
/// Uses a raw [Listener] rather than a gesture recognizer, so it observes the
/// pointer without competing in the gesture arena — the wrapped button keeps
/// handling the actual tap exactly as before. The dip is skipped under reduced
/// motion.
///
/// Use it around primary/outline/icon buttons for a consistent press feel:
/// `PressableScale(child: PrimaryButton(...))`.
class PressableScale extends StatefulWidget {
  const PressableScale({
    super.key,
    required this.child,
    this.enabled = true,
    this.scale = 0.96,
  });

  final Widget child;

  /// When false (e.g. a disabled button) the dip is suppressed.
  final bool enabled;

  /// The scale reached while pressed.
  final double scale;

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  bool _pressed = false;

  void _set(bool value) {
    if (!widget.enabled || value == _pressed) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _set(true),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: AnimatedScale(
        scale: _pressed ? widget.scale : 1,
        duration: motionDuration(context, Motion.fast),
        curve: Motion.curve,
        child: widget.child,
      ),
    );
  }
}
