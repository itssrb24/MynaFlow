#!/usr/bin/env python3
"""Generates Packaging/AppIcon.icns.

The mark is the app's own orb: the same Fibonacci dot-sphere the indicator
draws while you speak, so the icon and the thing you actually look at while
dictating are the same object. Brass on warm graphite, matching Theme.Colors.

Run: python3 Packaging/icon/make-icon.py
"""
import math
import subprocess
import shutil
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

S = 1024                      # macOS icon canvas
BODY = 824                    # the squircle body, per Apple's macOS template
N = 5.0                       # superellipse exponent: Apple's continuous corner
# macOS 26 composites app icons into its own rounded container. Artwork that
# draws its own squircle ends up framed twice, so the art is supplied
# edge-to-edge and the system does the shaping.
FULL_BLEED = True
R = BODY / 2
CX = CY = S / 2

BG_TOP = (34, 30, 25)         # warm graphite, lit from above
BG_BOTTOM = (13, 11, 9)
BRASS = (201, 162, 39)        # Theme brass
BRASS_LIT = (243, 216, 138)


def squircle_mask() -> Image.Image:
    """A true superellipse, not a circular-cornered rectangle."""
    y, x = np.mgrid[0:S, 0:S]
    nx = np.abs((x + 0.5 - CX) / R)
    ny = np.abs((y + 0.5 - CY) / R)
    d = nx**N + ny**N
    # 1.0 inside, feathering across roughly one pixel at the boundary
    edge = np.clip((1.0 - d) * (R / 2.2), 0.0, 1.0)
    return Image.fromarray((edge * 255).astype(np.uint8), "L")


def background() -> Image.Image:
    top = np.array(BG_TOP, dtype=float)
    bottom = np.array(BG_BOTTOM, dtype=float)
    t = (np.arange(S) / (S - 1))[:, None]
    ramp = top[None, :] * (1 - t) + bottom[None, :] * t
    grad = np.repeat(ramp[:, None, :], S, axis=1)
    return Image.fromarray(grad.astype(np.uint8), "RGB")


def orb(size: int, dots: int = 210) -> Image.Image:
    """Fibonacci sphere, drawn back to front so nearer dots sit on top."""
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    golden = math.pi * (3.0 - math.sqrt(5.0))
    pts = []
    for i in range(dots):
        # y from 1 to -1, evenly spaced, giving equal-area bands
        yy = 1 - (i / (dots - 1)) * 2
        radius = math.sqrt(max(0.0, 1 - yy * yy))
        theta = golden * i
        pts.append((math.cos(theta) * radius, yy, math.sin(theta) * radius))

    # Tilt so the pole is not dead centre; reads as a sphere rather than a disc.
    tilt = math.radians(-18)
    rotated = []
    for x, y, z in pts:
        y2 = y * math.cos(tilt) - z * math.sin(tilt)
        z2 = y * math.sin(tilt) + z * math.cos(tilt)
        rotated.append((x, y2, z2))
    rotated.sort(key=lambda p: p[2])          # painter's algorithm

    for x, y, z in rotated:
        depth = (z + 1) / 2                   # 0 = far, 1 = near
        px = CX + x * size / 2
        py = CY + y * size / 2
        r = 3.0 + 11.5 * depth                # nearer dots are much larger
        t = depth ** 1.25
        col = tuple(
            int(BRASS[i] * (1 - t) + BRASS_LIT[i] * t) for i in range(3)
        )
        alpha = int(26 + 229 * (depth ** 1.7))
        d.ellipse([px - r, py - r, px + r, py + r], fill=col + (alpha,))
    return layer


def build() -> Image.Image:
    img = background().convert("RGBA")

    # A soft brass bloom behind the orb, so the mark sits in light rather than
    # floating on flat colour.
    bloom = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(bloom).ellipse(
        [CX - 340, CY - 340, CX + 340, CY + 340], fill=BRASS + (58,)
    )
    img = Image.alpha_composite(img, bloom.filter(ImageFilter.GaussianBlur(120)))
    img = Image.alpha_composite(img, orb(660 if FULL_BLEED else 470))

    # Top rim light, the same cue the indicator pill uses. Only meaningful on a
    # self-drawn tile; the system container draws its own edge treatment.
    if FULL_BLEED:
        return img
    rim = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(rim).ellipse(
        [CX - BODY / 2, CY - BODY / 2 - 26, CX + BODY / 2, CY + BODY / 2],
        outline=(255, 246, 228, 60), width=5,
    )
    img = Image.alpha_composite(img, rim.filter(ImageFilter.GaussianBlur(9)))

    if not FULL_BLEED:
        img.putalpha(squircle_mask())
    return img


def main() -> None:
    out = Path(__file__).resolve().parent.parent
    master = build()
    iconset = out / "AppIcon.iconset"
    if iconset.exists():
        shutil.rmtree(iconset)
    iconset.mkdir()
    for pt in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = pt * scale
            suffix = f"{pt}x{pt}" + ("@2x" if scale == 2 else "")
            master.resize((px, px), Image.LANCZOS).save(iconset / f"icon_{suffix}.png")
    subprocess.run(
        ["iconutil", "-c", "icns", str(iconset), "-o", str(out / "AppIcon.icns")],
        check=True,
    )
    shutil.rmtree(iconset)
    master.save(out / "icon" / "AppIcon-1024.png")
    print(f"wrote {out/'AppIcon.icns'} and Packaging/icon/AppIcon-1024.png")


if __name__ == "__main__":
    main()
