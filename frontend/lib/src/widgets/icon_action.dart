import 'package:shadcn_flutter/shadcn_flutter.dart';

/// A ghost icon button with a hover tooltip and an accessible label.
///
/// Icon-only buttons carry no text, so screen readers would otherwise announce
/// them as just "button". Every icon-only control in the app uses this.
class IconAction extends StatelessWidget {
  const IconAction({
    super.key,
    required this.icon,
    required this.label,
    this.onPressed,
    this.size,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final double? size;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: Tooltip(
        tooltip: (context) => TooltipContainer(child: Text(label)),
        child: IconButton.ghost(
          icon: Icon(icon, size: size),
          onPressed: onPressed,
        ),
      ),
    );
  }
}
