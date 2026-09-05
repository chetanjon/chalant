#!/usr/bin/env python3
"""Draws the Notes app icon: a black tile with three white bars.

Every number below comes from the spec. To change the mark, change a number
here and run this again; the PNG is never edited by hand.

Usage:  python3 Notes/scripts/make-icon.py

Writes Notes/Notes/Assets.xcassets/AppIcon.appiconset/AppIcon.png at 1024 px.
Xcode generates every other size from it.
"""

from pathlib import Path

from PIL import Image, ImageDraw

BOX = 1024
BACKGROUND = (0, 0, 0, 255)
BAR = (255, 255, 255, 255)

# The content box is inset 23% on the left and right. Bars are placed in
# fractions of the box: (y of the bar's top, width, height, corner radius),
# with y and height as fractions of the tile and width and radius as
# fractions of the content width.
INSET = 0.23
BARS = [
    (0.33, 0.62, 0.070, 0.035),   # title bar
    (0.49, 1.00, 0.044, 0.022),
    (0.62, 0.80, 0.044, 0.022),
]

# PIL does not antialias shapes, so draw big and bring it down.
SUPERSAMPLE = 4


def render(size=BOX):
    big = size * SUPERSAMPLE
    image = Image.new("RGBA", (big, big), BACKGROUND)
    draw = ImageDraw.Draw(image)
    left = INSET * big
    content = (1 - 2 * INSET) * big
    for y, width, height, radius in BARS:
        top = y * big
        draw.rounded_rectangle(
            [left, top, left + width * content, top + height * big],
            radius=radius * content,
            fill=BAR,
        )
    return image.resize((size, size), Image.LANCZOS)


def main():
    out = Path(__file__).resolve().parents[1] / "Notes" / "Assets.xcassets" / "AppIcon.appiconset" / "AppIcon.png"
    out.parent.mkdir(parents=True, exist_ok=True)
    # The App Store wants an opaque icon with no alpha channel.
    render().convert("RGB").save(out, "PNG")
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
