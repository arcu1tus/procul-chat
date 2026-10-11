import 'package:shadcn_flutter/shadcn_flutter.dart';

/// A group of [Skeleton] blocks that shimmer together.
///
/// One [AnimationController] drives a gradient sweep across every placeholder
/// inside [child], so a list of skeletons animates in sync instead of each
/// block running its own ticker.
class Shimmer extends StatefulWidget {
  const Shimmer({super.key, required this.child});

  final Widget child;

  @override
  State<Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<Shimmer> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);
    final base = colors.muted;
    final highlight = Color.alphaBlend(
      colors.mutedForeground.withValues(alpha: 0.12),
      base,
    );

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => ShaderMask(
        blendMode: BlendMode.srcATop,
        shaderCallback: (bounds) => LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [base, highlight, base],
          stops: const [0.35, 0.5, 0.65],
          transform: _SlidingGradientTransform(_controller.value * 2 - 1),
        ).createShader(bounds),
        child: child,
      ),
      child: widget.child,
    );
  }
}

/// A static placeholder block. Wrap a group of these in a [Shimmer] to animate
/// them.
class Skeleton extends StatelessWidget {
  const Skeleton({super.key, this.width, this.height = 14, this.radius = 8});

  final double? width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: ColorScheme.of(context).muted,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

/// Slides a gradient horizontally by a fraction of its bounds.
class _SlidingGradientTransform extends GradientTransform {
  const _SlidingGradientTransform(this.slidePercent);

  final double slidePercent;

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) {
    return Matrix4.translationValues(bounds.width * slidePercent, 0, 0);
  }
}
