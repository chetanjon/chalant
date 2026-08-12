#!/usr/bin/env python3
"""Draws the background of the disk image people download.

Same rule as scripts/make-icon.py: nothing here is hand drawn and the
TIFF is never edited by hand. To change the window, change a number in
GEOMETRY below and run this again.

The palette is the site's, which is the app's: a black ground, one
arrow in --ghost, and nothing else. Finder puts Chalant and the
Applications alias on top of this, and those two icons plus the arrow
between them say the whole thing. No instruction text, no wordmark, no
border.

Usage:  python3 scripts/make-dmg-background.py [outdir]

Writes background.png, background@2x.png and dmg-background.tiff into
packaging/ (or outdir). scripts/make-dmg reads the TIFF.
"""

import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw

# Everything is measured in the window's own points and scaled from there.
GEOMETRY = {
    "width": 660,       # the Finder window scripts/make-dmg asks for
    "height": 420,
    "axis": 200,        # the centre line both icons sit on
    "reach": 34,        # half the arrow's length
    "head": 9,          # how far each leg of the chevron reaches back
    "stroke": 1.5,      # hairline, in points
}

GROUND = (0x00, 0x00, 0x00)
GHOST = (0x5A, 0x5A, 0x5A)

# PIL does not antialias a stroked line, and the chevron's legs are
# diagonal. Draw large, then come back down.
SUPERSAMPLE = 4


def render(scale: int) -> Image.Image:
    g = GEOMETRY
    s = scale * SUPERSAMPLE
    width, height = g["width"] * s, g["height"] * s

    canvas = Image.new("RGB", (width, height), GROUND)
    pen = ImageDraw.Draw(canvas)

    cx, cy = width // 2, g["axis"] * s
    reach, head = g["reach"] * s, g["head"] * s
    stroke = max(1, round(g["stroke"] * s))
    tip = cx + reach

    pen.line([(cx - reach, cy), (tip, cy)], fill=GHOST, width=stroke)
    pen.line([(tip - head, cy - head), (tip, cy)], fill=GHOST, width=stroke)
    pen.line([(tip - head, cy + head), (tip, cy)], fill=GHOST, width=stroke)

    return canvas.resize(
        (g["width"] * scale, g["height"] * scale), Image.LANCZOS
    )


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    outdir = Path(sys.argv[1]) if len(sys.argv) > 1 else root / "packaging"
    outdir.mkdir(parents=True, exist_ok=True)

    one = outdir / "background.png"
    two = outdir / "background@2x.png"
    render(1).save(one)
    render(2).save(two)

    # Finder reads one file and picks the representation the display
    # deserves. tiffutil is the only supported way to make that file.
    tiff = outdir / "dmg-background.tiff"
    subprocess.run(
        ["tiffutil", "-cathidpicheck", str(one), str(two), "-out", str(tiff)],
        check=True,
        stdout=subprocess.DEVNULL,
    )

    print(f"wrote {tiff.relative_to(root)}")


if __name__ == "__main__":
    main()
