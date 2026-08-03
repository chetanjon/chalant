#!/usr/bin/env python3
"""Draws the Chalant mark: the island with an echo around it.

Every icon the app and the site ship comes out of this file. Nothing is
hand drawn and no PNG is ever edited: to change the mark, change a number
in GEOMETRY below and run this again.

That rule is here because the last identity did not have it. Its
generator lived in a brand kit zip outside the repo, and the app and the
kit had drifted apart within a week.

Usage:  python3 scripts/make-icon.py [outdir]

Writes AppIcon.icns and favicon.png into the repo, plus a mark-1024.png
with no plate for whatever needs the bare glyph.
"""

import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw

# Everything is measured in a 1024 box and scaled from there.
BOX = 1024
PLATE = dict(x=100, y=100, w=824, h=824, r=184)
PLATE_COLOR = (11, 11, 11, 255)      # #0B0B0B
MARK_COLOR = (250, 250, 248, 255)    # #FAFAF8

# Two tunings of one mark, not one mark at two sizes. The full echo needs
# room: its outer ring is 16 percent opaque and its strokes are 20.6 of
# 1024 wide, so below about 128 pixels it turns to mush. The bold cut
# carries a single thicker ring and survives a menu bar.
GEOMETRY = {
    # ring and pill rects are (x, y, w, h, radius); rings add (stroke, opacity)
    "full": {
        "pill": (380.2, 462.6, 263.7, 98.9, 49.4),
        "rings": [
            (314.2, 413.1, 395.5, 197.8, 98.9, 20.6, 0.45),
            (248.3, 363.7, 527.4, 296.6, 148.3, 20.6, 0.16),
        ],
    },
    "bold": {
        "pill": (347.2, 446.1, 329.6, 131.8, 65.9),
        "rings": [
            (264.8, 380.2, 494.4, 263.7, 131.8, 24.7, 0.5),
        ],
    },
}

# Below this many pixels, the bold cut. The 32pt icon at 2x is 64 real
# pixels and takes the bold one; the 128pt icon at 1x is the first that
# can hold the full echo.
BOLD_BELOW = 128

# PIL does not antialias shapes, so everything is drawn big and brought
# down. Four is enough for edges this soft and keeps 1024 renders quick.
SUPERSAMPLE = 4


def _rounded(draw, rect, scale, **kwargs):
    x, y, w, h = (v * scale for v in rect[:4])
    radius = rect[4] * scale
    draw.rounded_rectangle([x, y, x + w, y + h], radius=radius, **kwargs)


def render(size, cut="auto", plate=True, color=MARK_COLOR):
    """One mark, `size` pixels square, as an RGBA image."""
    if cut == "auto":
        cut = "bold" if size < BOLD_BELOW else "full"
    spec = GEOMETRY[cut]
    big = size * SUPERSAMPLE
    scale = big / BOX

    canvas = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    if plate:
        layer = Image.new("RGBA", (big, big), (0, 0, 0, 0))
        _rounded(
            ImageDraw.Draw(layer),
            (PLATE["x"], PLATE["y"], PLATE["w"], PLATE["h"], PLATE["r"]),
            scale,
            fill=PLATE_COLOR,
        )
        canvas = Image.alpha_composite(canvas, layer)

    # Each element gets its own layer and is composited, because drawing
    # a translucent shape straight onto the canvas REPLACES the pixels
    # underneath instead of blending with them, which would punch the
    # rings clean through the plate.
    for x, y, w, h, radius, stroke, opacity in spec["rings"]:
        layer = Image.new("RGBA", (big, big), (0, 0, 0, 0))
        # PIL grows an outline INWARD from the boundary; SVG straddles
        # it, half in and half out. Left uncorrected the rings come out
        # a half stroke thin on all four edges, which the structural
        # check caught as a 10 pixel disagreement with the artwork.
        half = stroke / 2
        _rounded(
            ImageDraw.Draw(layer),
            (x - half, y - half, w + stroke, h + stroke, radius + half),
            scale,
            outline=color,
            width=max(1, round(stroke * scale)),
        )
        alpha = layer.getchannel("A").point(lambda value: round(value * opacity))
        layer.putalpha(alpha)
        canvas = Image.alpha_composite(canvas, layer)

    layer = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    _rounded(ImageDraw.Draw(layer), spec["pill"], scale, fill=color)
    canvas = Image.alpha_composite(canvas, layer)

    return canvas.resize((size, size), Image.LANCZOS)


def build_icns(destination, work):
    """The whole family, then iconutil folds it into one file."""
    iconset = work / "Chalant.iconset"
    iconset.mkdir(parents=True, exist_ok=True)
    for point in (16, 32, 128, 256, 512):
        for retina in (False, True):
            pixels = point * (2 if retina else 1)
            name = f"icon_{point}x{point}{'@2x' if retina else ''}.png"
            render(pixels).save(iconset / name)
    subprocess.run(
        ["iconutil", "-c", "icns", str(iconset), "-o", str(destination)],
        check=True,
    )


def main():
    root = Path(__file__).resolve().parent.parent
    work = Path(sys.argv[1]) if len(sys.argv) > 1 else root / "build" / "icon"
    work.mkdir(parents=True, exist_ok=True)

    build_icns(root / "Chalant" / "AppIcon.icns", work)
    render(64).save(root / "docs" / "assets" / "favicon.png")
    # Plateless, for the social card and anything else that sits the mark
    # on its own background.
    render(1024, cut="full", plate=False).save(work / "mark-1024.png")
    # The reference render, for diffing against the artwork this came from.
    render(1024, cut="full").save(work / "icon-1024.png")
    render(1024, cut="bold").save(work / "icon-bold-1024.png")
    print(f"wrote AppIcon.icns, favicon.png, and references in {work}")


if __name__ == "__main__":
    main()
