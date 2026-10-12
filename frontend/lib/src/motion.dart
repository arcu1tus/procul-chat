import 'package:flutter/widgets.dart';

/// The app's one motion language.
///
/// Every animation in Procul draws its duration and curve from here so the whole
/// UI moves at a consistent rhythm, and so the reduced-motion gate is central
/// rather than an ad-hoc `MediaQuery` check in each widget. Keep the set small —
/// a new named token is better than a one-off `Duration`.
///
/// See [reduceMotion]: non-essential animation must be skipped when the platform
/// asks for it, and [Motion.curve] / [Motion.emphasized] / [Motion.pop] cover the
/// three shapes the UI needs (ease-out for entrances, an emphasized curve for
/// larger transitions, and a gentle overshoot for small pops).
abstract final class Motion {
  /// A quick state change: hover, focus, press, a chip appearing.
  static const Duration fast = Duration(milliseconds: 150);

  /// The default transition: a screen switch, a menu, an entrance.
  static const Duration medium = Duration(milliseconds: 240);

  /// A larger, more deliberate move: a full-pane cross-fade, a hero reveal.
  static const Duration slow = Duration(milliseconds: 400);

  /// The standard ease-out curve for entrances and state changes.
  static const Curve curve = Curves.easeOutCubic;

  /// A stronger ease-in-out for a whole-pane transition (shared axis).
  static const Curve emphasized = Curves.easeInOutCubicEmphasized;

  /// A gentle overshoot for small pops (a check, a dot).
  static const Curve pop = Curves.easeOutBack;

  /// A staggered delay between list items, used sparingly for entrances.
  static Duration stagger(int index, {int max = 6}) =>
      Duration(milliseconds: 30 * (index < max ? index : max));
}

/// Whether the platform asks for reduced motion (accessibility).
///
/// Non-essential animation should be skipped when this is true — entrances,
/// shimmers, the streaming reveal, press scales, and the sidebar slide all
/// consult it. Essential layout changes still happen instantly rather than not
/// at all.
bool reduceMotion(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context) ||
    MediaQuery.accessibleNavigationOf(context);

/// The duration to use for an animation of [duration] under the current
/// reduced-motion setting: zero when motion is reduced, else [duration].
Duration motionDuration(BuildContext context, Duration duration) =>
    reduceMotion(context) ? Duration.zero : duration;
