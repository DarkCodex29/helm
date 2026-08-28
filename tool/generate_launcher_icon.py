#!/usr/bin/env python3
"""Draws helm's launcher icon source art.

Run from the repository root:

    python3 tool/generate_launcher_icon.py

Writes three 1024x1024 PNGs into `assets/icon/`, which
`flutter_launcher_icons` then resizes into every density bucket. Those
outputs are committed, so this script does not run in CI or at build time —
it exists so the geometry below is a recorded decision rather than a binary
nobody can re-derive.

## The shape

The same terminal prompt as the notification icon
(`android/app/src/main/res/drawable/ic_stat_helm.xml`), drawn from the same
coordinates so the two cannot drift apart. A user who sees the tray icon
and then looks for the app should be looking for the same mark.

## Sizing is by DIAMETER, not by width

Android's adaptive icon is two layers, each 108dp, of which a mask keeps
roughly the middle 72dp; the guidance puts the logo inside a centred 66dp
CIRCLE. That circle is the whole subtlety, and getting it wrong is easy to
miss: sizing this glyph to 62dp WIDE put its corners 80.5dp apart, so a
round mask sliced the chevron's points off and cut the end from the cursor.
Measured by rendering the layer and masking it, before this comment existed.

The number that matters is therefore the greatest distance from the centre
to any inked pixel, which for a stroked path is an endpoint's distance plus
half the stroke — the round cap's outer edge. `_ink_diameter_units`
computes it from the same coordinates the drawing uses, so the two cannot
disagree.

  foreground  the glyph, transparent, sized for the 108dp canvas
  monochrome  the same alpha, flat white, for Android 13+ themed icons,
              where the system discards colour and re-tints the shape
  full        glyph on the app's background, for the pre-26 launchers that
              have no adaptive icon and would otherwise get a bare glyph

The full icon draws the logo larger (`_LEGACY_LOGO_DP`), because a legacy
icon is not masked down to a safe zone and the adaptive geometry would
leave it looking lost in its own padding.
"""

from __future__ import annotations

import math
import os

from PIL import Image, ImageDraw

# ── The palette, as decided in lib/features/terminal/presentation/widgets/
# agent_state_chip.dart. Not a second brand: the amber is the colour this
# app reserves for "a human is needed here", and the near-black is the
# background every surface already sits on.
_AMBER = (0xD2, 0x99, 0x22, 0xFF)
_BACKGROUND = (0x0D, 0x11, 0x17, 0xFF)
_WHITE = (0xFF, 0xFF, 0xFF, 0xFF)

_CANVAS = 1024

# Supersampled, then reduced. PIL has no antialiased primitives, and a
# 3px-wide stroke drawn straight to 1024 has visibly stepped diagonals on
# the chevron.
_SUPERSAMPLE = 4

# The glyph in the notification drawable's 24-unit coordinate space, so the
# two icons are provably the same drawing.
_STROKE_UNITS = 3.0
_CHEVRON = [(4.6, 5.2), (11.3, 12.0), (4.6, 18.8)]
_CURSOR = [(13.4, 18.8), (19.4, 18.8)]

# The inked extent, endpoints plus the half-stroke the round caps add.
_INK_LEFT = 4.6 - _STROKE_UNITS / 2
_INK_RIGHT = 19.4 + _STROKE_UNITS / 2
_INK_TOP = 5.2 - _STROKE_UNITS / 2
_INK_BOTTOM = 18.8 + _STROKE_UNITS / 2
_INK_WIDTH = _INK_RIGHT - _INK_LEFT
_INK_HEIGHT = _INK_BOTTOM - _INK_TOP

_ADAPTIVE_CANVAS_DP = 108

# What the launcher must END UP showing. Just inside the 66dp safe circle;
# the margin is small on purpose, because this glyph is strokes rather
# than a solid body and reads lighter than a filled mark of the same
# diameter would.
_TARGET_LOGO_DIAMETER_DP = 64.0

# `flutter_launcher_icons` does not use the foreground PNG as the layer.
# It wraps it in `<inset android:inset="16%">` in the generated
# `mipmap-anydpi-v26/ic_launcher.xml`, which shrinks the art into the
# middle 68% of the 108dp canvas — it assumes callers hand it a full-bleed
# logo that needs padding added.
#
# So there are TWO shrinks between this file and the screen, and drawing
# to the safe zone here silently gets it halved: art sized to a correct
# 64dp came out at 43.8dp, under Android's own 48dp floor. Measured off
# the generated `drawable-xxxhdpi/ic_launcher_foreground.png`, not
# reasoned about.
#
# Compensating HERE rather than by editing the generated XML is what keeps
# the two in agreement: `dart run flutter_launcher_icons` overwrites that
# file every time, so a hand-edit is a change that silently reverts the
# next time anyone regenerates.
_GENERATOR_INSET = 0.16

_FOREGROUND_LOGO_DIAMETER_DP = _TARGET_LOGO_DIAMETER_DP / (1 - 2 * _GENERATOR_INSET)

# A legacy icon is a full square that no mask reduces to a safe circle, so
# it can be drawn larger. Not edge-to-edge: launchers that round the
# corners of a legacy icon would clip a glyph that filled it.
_LEGACY_LOGO_DIAMETER_DP = 92.0

# Where the ink is centred, which is the middle of its bounding box rather
# than the average of the endpoints.
_INK_CENTRE = (
    (_INK_LEFT + _INK_RIGHT) / 2,
    (_INK_TOP + _INK_BOTTOM) / 2,
)


def _ink_diameter_units() -> float:
    """Twice the greatest distance from the centre to any inked pixel.

    The extreme points of a round-capped stroke are the outer edges of the
    cap circles, so each endpoint contributes its own distance plus half
    the stroke width. Derived rather than measured so that changing the
    glyph cannot silently invalidate the safe-zone fit.
    """
    cx, cy = _INK_CENTRE
    return 2 * max(
        math.hypot(x - cx, y - cy) + _STROKE_UNITS / 2
        for x, y in _CHEVRON + _CURSOR
    )


def _draw_glyph(size: int, diameter_px: float, colour) -> Image.Image:
    """The prompt, centred, its inked DIAMETER equal to `diameter_px`."""
    big = size * _SUPERSAMPLE
    image = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)

    units_to_px = (diameter_px * _SUPERSAMPLE) / _ink_diameter_units()
    stroke = _STROKE_UNITS * units_to_px
    radius = stroke / 2

    # Centre the INKED box, not the endpoints: the round caps are part of
    # what the eye reads as the mark.
    left = (big - _INK_WIDTH * units_to_px) / 2
    top = (big - _INK_HEIGHT * units_to_px) / 2

    def to_px(point):
        x, y = point
        return (
            left + (x - _INK_LEFT) * units_to_px,
            top + (y - _INK_TOP) * units_to_px,
        )

    for path in (_CHEVRON, _CURSOR):
        points = [to_px(p) for p in path]
        draw.line(points, fill=colour, width=round(stroke), joint="curve")
        # PIL has no line cap setting. A disc at every vertex is both the
        # round cap and the round join, and overdrawing is harmless on an
        # opaque single-colour glyph.
        for x, y in points:
            draw.ellipse(
                (x - radius, y - radius, x + radius, y + radius), fill=colour
            )

    return image.resize((size, size), Image.LANCZOS)


def _dp_to_px(dp: float) -> float:
    return _CANVAS * dp / _ADAPTIVE_CANVAS_DP


def main() -> None:
    out = os.path.join("assets", "icon")
    os.makedirs(out, exist_ok=True)

    assert 48 <= _TARGET_LOGO_DIAMETER_DP <= 66, (
        "after the generator's inset the logo must land inside Android's "
        "48-66dp safe circle: smaller looks lost, larger gets clipped by a "
        "round mask"
    )
    assert _FOREGROUND_LOGO_DIAMETER_DP < _ADAPTIVE_CANVAS_DP, (
        "the pre-inset art must still fit its own canvas"
    )

    safe = _dp_to_px(_FOREGROUND_LOGO_DIAMETER_DP)

    _draw_glyph(_CANVAS, safe, _AMBER).save(
        os.path.join(out, "helm_icon_foreground.png")
    )
    _draw_glyph(_CANVAS, safe, _WHITE).save(
        os.path.join(out, "helm_icon_monochrome.png")
    )

    full = Image.new("RGBA", (_CANVAS, _CANVAS), _BACKGROUND)
    full.alpha_composite(
        _draw_glyph(_CANVAS, _dp_to_px(_LEGACY_LOGO_DIAMETER_DP), _AMBER)
    )
    full.save(os.path.join(out, "helm_icon.png"))

    print(f"glyph ink diameter: {_ink_diameter_units():.2f} units")
    print(
        f"adaptive foreground drawn at {_FOREGROUND_LOGO_DIAMETER_DP:.1f}dp, "
        f"showing as {_TARGET_LOGO_DIAMETER_DP:.1f}dp after the "
        f"{_GENERATOR_INSET:.0%} inset"
    )
    for name in (
        "helm_icon.png",
        "helm_icon_foreground.png",
        "helm_icon_monochrome.png",
    ):
        path = os.path.join(out, name)
        print(f"{path}  {os.path.getsize(path):>7} bytes")


if __name__ == "__main__":
    main()
