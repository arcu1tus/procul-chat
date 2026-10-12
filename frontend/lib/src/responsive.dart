import 'package:flutter/widgets.dart';

/// The app's responsive breakpoints.
///
/// Procul lays out for three width classes rather than a scatter of magic
/// numbers: a phone ([compact]), a small tablet / large phone in landscape
/// ([medium]), and a desktop or tablet ([expanded]). The shell switches between
/// its persistent sidebar and its slide-in panel at [expanded]; the app bar
/// collapses its actions slightly earlier (see [appBarCompactWidth]).
enum Breakpoint {
  /// Under 600 logical pixels: a phone in portrait.
  compact,

  /// 600–839 logical pixels: a small tablet or a phone in landscape.
  medium,

  /// 840 logical pixels and wider: a desktop or a tablet in landscape.
  expanded;

  /// Whether this class has room for the persistent sidebar.
  bool get hasPersistentSidebar => this == Breakpoint.expanded;
}

/// The width at or above which the shell keeps its sidebar on-screen. Below it
/// the sidebar becomes a slide-in panel behind the app-bar menu button.
const double expandedBreakpoint = 840;

/// The width below which the chat app bar collapses every trailing action into
/// a single overflow `…`. Kept separate from [expandedBreakpoint]: the actions
/// are wider than the sidebar, so they need to fold slightly earlier.
const double appBarCompactWidth = 720;

/// The breakpoint class for a viewport [width].
Breakpoint breakpointForWidth(double width) {
  if (width < 600) return Breakpoint.compact;
  if (width < expandedBreakpoint) return Breakpoint.medium;
  return Breakpoint.expanded;
}

/// The breakpoint class for the current [context]'s width.
Breakpoint breakpointOf(BuildContext context) =>
    breakpointForWidth(MediaQuery.sizeOf(context).width);
