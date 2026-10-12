import 'package:flutter/widgets.dart';

import '../motion.dart';

/// Fades a child in and lifts it a few pixels, once, staggered by [index].
///
/// A single shared implementation of the app's list/card entrance, so the
/// sidebar, the Models catalog, the Usage dashboard and the Connect screen all
/// cascade the same way. Inert under reduced motion.
class Stagger extends StatelessWidget {
  const Stagger({
    super.key,
    required this.index,
    required this.child,
    this.offset = 8,
  });

  /// Position in the list; later items start slightly later.
  final int index;
  final Widget child;

  /// How far the child rises, in logical pixels.
  final double offset;

  @override
  Widget build(BuildContext context) {
    if (reduceMotion(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Motion.medium + Motion.stagger(index),
      curve: Motion.curve,
      child: child,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, offset * (1 - value)),
          child: child,
        ),
      ),
    );
  }
}
