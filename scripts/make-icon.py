#!/usr/bin/env python3
"""Turns assets/logo.png into Resources/AppIcon.icns. Needs Pillow and macOS's iconutil.

The logo is a full-bleed square, so it is placed on Apple's icon grid: a rounded square
of 824 points on a 1024 canvas, leaving the usual margin for the system's shadow.
"""
import pathlib
import subprocess
import tempfile

from PIL import Image, ImageDraw

root = pathlib.Path(__file__).resolve().parent.parent
canvas, body, radius = 1024, 824, 185

logo = Image.open(root / "assets/logo.png").convert("RGBA").resize((body, body), Image.LANCZOS)
mask = Image.new("L", (body * 4, body * 4), 0)
ImageDraw.Draw(mask).rounded_rectangle((0, 0, body * 4 - 1, body * 4 - 1), radius=radius * 4, fill=255)
logo.putalpha(mask.resize((body, body), Image.LANCZOS))

icon = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
offset = (canvas - body) // 2
icon.alpha_composite(logo, (offset, offset))

with tempfile.TemporaryDirectory() as temporary:
    iconset = pathlib.Path(temporary) / "AppIcon.iconset"
    iconset.mkdir()
    for size in (16, 32, 128, 256, 512):
        icon.resize((size, size), Image.LANCZOS).save(iconset / f"icon_{size}x{size}.png")
        icon.resize((size * 2, size * 2), Image.LANCZOS).save(iconset / f"icon_{size}x{size}@2x.png")
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(root / "Resources/AppIcon.icns")], check=True)

print("Wrote Resources/AppIcon.icns")
