/// How much of the terminal the host-advisory surface may occupy.
///
/// A rule rather than a layout constant, and it lives here rather than in
/// `terminal_view_widget.dart` for the reason this codebase already
/// applies to `host_advisory.dart` and `session_reference.dart`: a
/// decision belongs somewhere it can be tested on its own, and the widget
/// stays thin enough that it cannot drift from it.
library;

/// Share of the terminal area the advisory surface may take at most.
///
/// Measured on the real app before the surface was bounded: two
/// co-occurring advisories — a multiplexer substitution plus the
/// substituted-in binary being off the login PATH, which the verified host
/// raises together — want 931pt at 320pt wide, against the 509.78pt of
/// terminal an iPhone 17 Pro has with the custom keyboard shown. That is
/// 1.8x the entire area, and the surplus was silently clipped, taking the
/// lower rows' dismiss buttons out of reach with it.
///
/// At this fraction the same content is capped to 204pt and scrolls
/// inside that, leaving three fifths of the terminal visible.
const advisorySurfaceMaxFraction = 0.4;

/// Smallest ceiling worth handing back, in logical pixels.
///
/// A row is 12pt of padding above a 32pt minimum-height dismiss button.
/// Below this the one control that gets the surface OFF the screen is
/// itself cut, which is the failure being fixed rather than a milder form
/// of it. [advisorySurfaceMaxFraction] alone would fall under it on any
/// terminal area shorter than 140pt — landscape with the keyboard up.
const advisorySurfaceMinHeight = 56.0;

/// The advisory surface's height ceiling over a terminal [areaHeight].
///
/// Three regimes, in the order they matter:
///
/// * A terminal shorter than [advisorySurfaceMinHeight] gets its own
///   height. There is no honest answer at that size; painting outside the
///   terminal is still not one of them.
/// * A terminal short enough that the fraction would fall below
///   [advisorySurfaceMinHeight] gets that floor, so the dismiss button
///   survives.
/// * Anything larger gets [advisorySurfaceMaxFraction] of itself.
///
/// The floor and the fraction meet exactly at 140pt, so the surface does
/// not visibly snap as the keyboard animates the area past that point.
double advisorySurfaceMaxHeight(double areaHeight) {
  if (areaHeight <= advisorySurfaceMinHeight) return areaHeight;
  final fraction = areaHeight * advisorySurfaceMaxFraction;
  return fraction < advisorySurfaceMinHeight
      ? advisorySurfaceMinHeight
      : fraction;
}
