import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import '../motion.dart';

/// Renders assistant Markdown with Procul's streaming reveal.
///
/// Network streaming and *visual* streaming are decoupled: tokens arrive in
/// bursts, but [StreamingText] buffers the full target text and reveals it at a
/// steady cadence (a "pacer"), so a bursty SSE stream still reads as a smooth
/// flow. While [isStreaming], the newest text is tinted with the brand accent
/// (a frontier bloom via a [ShaderMask]) and a pulsing caret trails it; when the
/// reply completes the bloom and caret disappear and the full text renders
/// normally.
///
/// The pacer owns a [Ticker] and stops the moment it catches up, so it never
/// schedules frames while idle (and `pumpAndSettle` always settles). Rebuilds
/// are throttled to ~25 fps so a long reply is not reparsed on every vsync. Under
/// reduced motion the reveal is inert — the full text renders immediately with
/// no bloom and no caret.
///
/// The Markdown still renders through [GptMarkdown], so styling is unchanged and
/// `find.byType(GptMarkdown)` keeps working.
class StreamingText extends StatefulWidget {
  const StreamingText({
    super.key,
    required this.text,
    required this.isStreaming,
    this.style,
  });

  final String text;
  final bool isStreaming;
  final TextStyle? style;

  @override
  State<StreamingText> createState() => _StreamingTextState();
}

class _StreamingTextState extends State<StreamingText>
    with SingleTickerProviderStateMixin {
  /// The reveal rate. ~220 chars/s reads comfortably (see the plan's research).
  static const double _charsPerSecond = 220;

  /// The most often the tail is rebuilt; keeps long replies cheap.
  static const Duration _minRebuildInterval = Duration(milliseconds: 40);

  late final Ticker _ticker = createTicker(_onTick);
  Duration _lastTick = Duration.zero;
  Duration _lastBuild = Duration.zero;
  double _revealed = 0;

  @override
  void initState() {
    super.initState();
    _revealed = widget.isStreaming ? 0 : widget.text.length.toDouble();
    if (widget.isStreaming) _start();
  }

  @override
  void didUpdateWidget(covariant StreamingText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.isStreaming) {
      if (_ticker.isActive) _ticker.stop();
      return;
    }
    // The target may have shrunk (a destructive edit rewrites in place); never
    // show more than exists.
    if (_revealed > widget.text.length) {
      _revealed = widget.text.length.toDouble();
    }
    if (_revealed < widget.text.length && !_ticker.isActive) _start();
  }

  void _start() {
    _lastTick = Duration.zero;
    _lastBuild = Duration.zero;
    _ticker.start();
  }

  void _onTick(Duration elapsed) {
    final dt = _lastTick == Duration.zero ? elapsed : elapsed - _lastTick;
    _lastTick = elapsed;
    final target = widget.text.length.toDouble();
    final advanced =
        _revealed +
        dt.inMicroseconds /
            Duration.microsecondsPerSecond *
            _charsPerSecond;
    final next = math.min(target, advanced);
    final caughtUp = next >= target;
    final due = elapsed - _lastBuild >= _minRebuildInterval;
    if (next != _revealed && (caughtUp || due)) {
      _lastBuild = elapsed;
      setState(() => _revealed = next);
    } else {
      _revealed = next;
    }
    if (caughtUp) _ticker.stop();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  /// A substring cut that never splits a UTF-16 surrogate pair.
  int _safeCut(String text, int cut) {
    if (cut <= 0) return 0;
    if (cut >= text.length) return text.length;
    final unit = text.codeUnitAt(cut - 1);
    if (unit >= 0xD800 && unit <= 0xDBFF) return cut - 1;
    return cut;
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.isStreaming && !reduceMotion(context);
    final shown = active
        ? widget.text.substring(0, _safeCut(widget.text, _revealed.floor()))
        : widget.text;

    Widget markdown = GptMarkdown(
      shown,
      isStreaming: widget.isStreaming,
      style: widget.style,
    );
    if (active) markdown = _FrontierBloom(child: markdown);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        markdown,
        if (active) const Gap(6),
        if (active) const _StreamingCaret(),
      ],
    );
  }
}

/// Tints the newest text with a soft accent gradient, so the frontier of a
/// streaming reply glows rather than sitting flat. Implemented as a paint-only
/// [ShaderMask] (no per-frame Markdown rebuild), which is why it is cheap.
class _FrontierBloom extends StatelessWidget {
  const _FrontierBloom({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);
    final foreground = colors.foreground;
    final frontier = Color.lerp(foreground, colors.primary, 0.6)!;

    return ShaderMask(
      key: const Key('streaming-bloom'),
      blendMode: BlendMode.srcIn,
      shaderCallback: (bounds) => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [foreground, foreground, frontier],
        stops: const [0.0, 0.72, 1.0],
      ).createShader(bounds),
      child: child,
    );
  }
}

/// A small pulsing dot that trails a streaming reply (an "ink bloom" caret).
class _StreamingCaret extends StatefulWidget {
  const _StreamingCaret();

  @override
  State<_StreamingCaret> createState() => _StreamingCaretState();
}

class _StreamingCaretState extends State<_StreamingCaret>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => Opacity(
        opacity: 0.35 + 0.55 * _controller.value,
        child: Container(
          key: const Key('streaming-caret'),
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: colors.primary,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}
