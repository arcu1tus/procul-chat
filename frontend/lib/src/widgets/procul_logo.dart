import 'package:flutter_svg/flutter_svg.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

// The repository's original SVG, with currentColor strokes for both themes.
class ProculLogo extends StatelessWidget {
  const ProculLogo({super.key, this.size = 32});

  final double size;

  @override
  Widget build(BuildContext context) => SvgPicture.asset(
    'assets/brand/procul-logo.svg',
    width: size,
    height: size,
    theme: SvgTheme(currentColor: ColorScheme.of(context).foreground),
    excludeFromSemantics: true,
  );
}
