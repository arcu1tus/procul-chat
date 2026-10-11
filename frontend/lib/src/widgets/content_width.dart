/// The widest a content column grows before it is centered on the screen.
///
/// On very wide displays (an ultra-wide monitor, for example) a full-width list
/// pins its content to the edges; capping it keeps the reading column sensible.
const double kContentMaxWidth = 900;

/// The extra horizontal padding that centers a [kContentMaxWidth]-wide content
/// column inside a viewport of [width]. Zero when the viewport is narrower.
double centeredSidePadding(double width) {
  if (width <= kContentMaxWidth) return 0;
  return (width - kContentMaxWidth) / 2;
}
