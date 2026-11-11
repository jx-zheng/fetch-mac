#!/usr/bin/env python3
"""Build the macOS icon from the approved artwork.

The pixels come from design/icon-approved.png. This script cuts that squircle
off the off-white paper, drops the baked-in shadow, fits the body to Apple's
824/1024 grid, and downscales. It does not repaint the art.
"""

from __future__ import annotations

from collections import deque
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
APPROVED = ROOT / "design" / "icon-approved.png"
ICONSET = ROOT / "Fetch" / "AppIcon.iconset"
APPICONSET = ROOT / "Fetch" / "AppIcon.appiconset"
MASTER = ROOT / "design" / "icon-master.png"
SHEET = ROOT / "design" / "icon-sizes.png"

CANVAS = 1024
BODY = 824


def extract_squircle(source: Image.Image) -> Image.Image:
    """Antialiased cut-out. The mask is the artwork's own edge, not a redraw."""
    rgb = np.asarray(source.convert("RGB"))
    height, width = rgb.shape[:2]
    chroma = rgb.max(axis=2).astype(np.int16) - rgb.min(axis=2).astype(np.int16)
    # The paper and the baked shadow are nearly neutral. The squircle is not.
    foreground = chroma > 18
    outside = np.zeros((height, width), np.uint8)
    queue: deque[tuple[int, int]] = deque(((0, 0), (0, width - 1), (height - 1, 0), (height - 1, width - 1)))
    while queue:
        y, x = queue.popleft()
        if y < 0 or x < 0 or y >= height or x >= width or outside[y, x] or foreground[y, x]:
            continue
        outside[y, x] = 1
        queue.append((y - 1, x))
        queue.append((y + 1, x))
        queue.append((y, x - 1))
        queue.append((y, x + 1))
    inside = outside == 0
    hard = Image.fromarray(inside.astype(np.uint8) * 255, mode="L")
    # One pixel of blur follows the raster edge without inventing a new curve.
    alpha = np.asarray(hard.filter(ImageFilter.GaussianBlur(radius=0.55))).astype(np.float32) / 255.0
    paper = np.median(rgb[:24, :24].reshape(-1, 3), axis=0).astype(np.float32)
    color = rgb.astype(np.float32)
    edge = (alpha > 0.02) & (alpha < 0.98)
    if edge.any():
        uncovered = (color - (1.0 - alpha)[..., None] * paper) / np.clip(alpha, 0.02, 1.0)[..., None]
        color[edge] = np.clip(uncovered[edge], 0, 255)
    out = np.dstack([color, alpha * 255.0]).astype(np.uint8)
    ys, xs = np.where(alpha > 0.5)
    pad = 2
    crop = (
        max(0, xs.min() - pad),
        max(0, ys.min() - pad),
        min(width, xs.max() + 1 + pad),
        min(height, ys.max() + 1 + pad),
    )
    return Image.fromarray(out, mode="RGBA").crop(crop)


def fit_to_grid(icon: Image.Image) -> Image.Image:
    """Centre the squircle at about 824 px on a 1024 canvas and add a light shadow."""
    core = np.asarray(icon.split()[-1]) > 128
    ys, xs = np.where(core)
    body_w = int(xs.max() - xs.min() + 1)
    body_h = int(ys.max() - ys.min() + 1)
    scale = BODY / max(body_w, body_h)
    resized = icon.resize((max(1, round(icon.width * scale)), max(1, round(icon.height * scale))), Image.Resampling.LANCZOS)
    alpha = resized.split()[-1]
    shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    blurred = alpha.filter(ImageFilter.GaussianBlur(radius=14))
    shade = Image.new("RGBA", resized.size, (0, 0, 0, 0))
    shade.putalpha(blurred.point(lambda p: int(p * 0.28)))
    left = (CANVAS - resized.width) // 2
    top = (CANVAS - resized.height) // 2
    shadow.alpha_composite(shade, (left, top + 10))
    shadow.alpha_composite(resized, (left, top))
    return shadow


def downscale(master: Image.Image, size: int) -> Image.Image:
    if size == master.width:
        return master.copy()
    return master.resize((size, size), Image.Resampling.LANCZOS)


def contact_sheet(approved: Image.Image, master: Image.Image, sized: dict[int, Image.Image]) -> Image.Image:
    checker_a = (236, 236, 236, 255)
    checker_b = (210, 210, 210, 255)

    def checker(width: int, height: int, cell: int = 16) -> Image.Image:
        tile = Image.new("RGBA", (width, height), checker_a)
        draw = ImageDraw.Draw(tile)
        for y in range(0, height, cell):
            for x in range(0, width, cell):
                if (x // cell + y // cell) % 2:
                    draw.rectangle([x, y, x + cell, y + cell], fill=checker_b)
        return tile

    thumb = 360
    approved_thumb = approved.convert("RGBA").resize((thumb, thumb), Image.Resampling.LANCZOS)
    master_thumb = master.resize((thumb, thumb), Image.Resampling.LANCZOS)
    header = checker(thumb * 2 + 48, thumb + 36)
    header.alpha_composite(approved_thumb, (12, 28))
    plate = checker(thumb, thumb, 12)
    plate.alpha_composite(master_thumb)
    header.alpha_composite(plate, (thumb + 36, 28))

    sizes = [16, 32, 64, 128, 256, 512, 1024]
    row_h = 280
    row = checker(1400, row_h, 12)
    x = 24
    for size in sizes:
        image = sized[size]
        shown = image if size <= 256 else image.resize((256, 256), Image.Resampling.LANCZOS)
        y = (row_h - shown.height) // 2
        row.alpha_composite(shown, (x, y))
        x += shown.width + 28
    sheet = Image.new("RGBA", (max(header.width, row.width), header.height + row.height + 16), (250, 248, 246, 255))
    sheet.alpha_composite(header, (0, 0))
    sheet.alpha_composite(row, (0, header.height + 8))
    return sheet


def main() -> None:
    approved = Image.open(APPROVED)
    if approved.size != (1024, 1024):
        raise SystemExit(f"expected 1024x1024 approved art, got {approved.size}")
    cut = extract_squircle(approved)
    master = fit_to_grid(cut)
    master.save(MASTER, format="PNG")
    sizes = {
        "icon_16x16.png": 16,
        "icon_16x16@2x.png": 32,
        "icon_32x32.png": 32,
        "icon_32x32@2x.png": 64,
        "icon_128x128.png": 128,
        "icon_128x128@2x.png": 256,
        "icon_256x256.png": 256,
        "icon_256x256@2x.png": 512,
        "icon_512x512.png": 512,
        "icon_512x512@2x.png": 1024,
    }
    by_px: dict[int, Image.Image] = {}
    for name, px in sizes.items():
        image = downscale(master, px)
        by_px[px] = image
        for folder in (ICONSET, APPICONSET):
            folder.mkdir(parents=True, exist_ok=True)
            image.save(folder / name, format="PNG")
        print(f"wrote {name} ({px})")
    contact_sheet(approved, master, by_px).save(SHEET, format="PNG")
    paper = Image.new("RGB", (1280, 1280), (246, 242, 238))
    preview = master.resize((1024, 1024), Image.Resampling.LANCZOS)
    paper.paste(preview, (128, 96), preview)
    paper.save(ROOT / "design" / "icon-preview.png", format="PNG")
    print(f"wrote {MASTER}")
    print(f"wrote {SHEET}")


if __name__ == "__main__":
    main()
