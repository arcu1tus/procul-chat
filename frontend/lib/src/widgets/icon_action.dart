import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'pressable.dart';

/// A ghost icon button with a hover tooltip and an accessible label.
///
/// Icon-only buttons carry no text, so screen readers would otherwise announce
/// them as just "button". Every icon-only control in the app uses this.
///
/// When [busy] is true the icon is swapped for a small spinner, so an action
/// with no immediate visible effect (a refresh) can still show that it is
/// working. The button dips slightly while pressed ([PressableScale]) for
/// consistent press feedback across the app.
class IconAction extends StatelessWidget {
  const IconAction({
    super.key,
    required this.icon,
    required this.label,
    this.onPressed,
    this.size,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final double? size;

  /// Replaces the icon with a spinner while an action is in flight.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: Tooltip(
        tooltip: (context) => TooltipContainer(child: Text(label)),
        child: PressableScale(
          enabled: onPressed != null,
          scale: 0.9,
          child: IconButton.ghost(
            icon: busy
                ? SizedBox(
                    width: size ?? 16,
                    height: size ?? 16,
                    child: const CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(icon, size: size),
            onPressed: onPressed,
          ),
        ),
      ),
    );
  }
}
