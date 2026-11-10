#!/usr/bin/env python3
"""Redraw the Fetch app icon from the approved reference.

Midnight-indigo squircle, coral/magenta/violet aurora, a glass video frame,
and a white down arrow. Transparent outside the squircle. Small sizes are
redrawn (not just scaled) so the arrow stays crisp.
"""

from __future__ import annotations

import math
import random
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
ICONSET = ROOT / "Fetch" / "AppIcon.iconset"
APPICONSET = ROOT / "Fetch" / "AppIcon.appiconset"
PREVIEW = ROOT / "design" / "icon-preview.png"

# macOS squircle is a superellipse. n=5 matches the system mask closely.
SQUIRCLE_N = 5.0


def squircle_mask(size: int, inset: float = 0.0, n: float = SQUIRCLE_N) -> np.ndarray:
    """Antialiased superellipse mask in 0..1. inset is a fraction of half-size."""
    scale = 4 if size < 256 else 2
    s = size * scale
    y, x = np.ogrid[0:s, 0:s]
    center = (s - 1) / 2.0
    radius = center * (1.0 - inset)
    xn = np.abs((x - center) / radius)
    yn = np.abs((y - center) / radius)
    field = xn**n + yn**n
    # ~1px of the final image, in supersampled units
    aa = (n / max(radius, 1.0)) * scale * 1.15
    mask = np.clip((1.0 - field) / max(aa, 1e-6) + 0.5, 0.0, 1.0).astype(np.float32)
    img = Image.fromarray((mask * 255).astype(np.uint8), mode="L")
    img = img.resize((size, size), Image.Resampling.LANCZOS)
    return np.asarray(img).astype(np.float32) / 255.0


def screen(base: np.ndarray, color: tuple[float, float, float], alpha: np.ndarray) -> None:
    a = alpha[..., None]
    rgb = np.array(color, dtype=np.float32)[None, None, :]
    base[:] = 1.0 - (1.0 - base) * (1.0 - np.clip(rgb * a, 0.0, 1.0))


def radial_alpha(size: int, cx: float, cy: float, rx: float, ry: float, power: float = 1.35) -> np.ndarray:
    y, x = np.ogrid[0:size, 0:size]
    d = np.sqrt(((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2)
    return np.clip(1.0 - d**power, 0.0, 1.0).astype(np.float32)


def linear_gradient(size: int, c0, c1, angle_deg: float) -> np.ndarray:
    y, x = np.mgrid[0:size, 0:size].astype(np.float32)
    ang = math.radians(angle_deg)
    t = ((x / max(size - 1, 1)) * math.cos(ang) + (y / max(size - 1, 1)) * math.sin(ang))
    t = np.clip(t, 0.0, 1.0)[..., None]
    a = np.array(c0, dtype=np.float32)
    b = np.array(c1, dtype=np.float32)
    return a + (b - a) * t


def rounded_rect_mask(size: int, box: tuple[float, float, float, float], radius: float) -> Image.Image:
    img = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(img)
    draw.rounded_rectangle(box, radius=radius, fill=255)
    return img


def rounded_arrow_head(cx: float, top: float, tip: float, half: float, corner: float) -> list[tuple[float, float]]:
    """Triangle pointing down, with the shoulders and the tip rounded off."""
    # Sharp corners, clockwise from the left shoulder.
    corners = [(cx - half, top), (cx + half, top), (cx, tip)]
    points: list[tuple[float, float]] = []
    count = len(corners)
    for i, cur in enumerate(corners):
        prev = corners[(i - 1) % count]
        nxt = corners[(i + 1) % count]
        v1 = (prev[0] - cur[0], prev[1] - cur[1])
        v2 = (nxt[0] - cur[0], nxt[1] - cur[1])
        l1 = math.hypot(*v1) or 1
        l2 = math.hypot(*v2) or 1
        r = min(corner, l1 * 0.4, l2 * 0.4)
        u1 = (v1[0] / l1, v1[1] / l1)
        u2 = (v2[0] / l2, v2[1] / l2)
        start = (cur[0] + u1[0] * r, cur[1] + u1[1] * r)
        end = (cur[0] + u2[0] * r, cur[1] + u2[1] * r)
        # Bisector gives a center so the arc stays outside the corner.
        bis = (u1[0] + u2[0], u1[1] + u2[1])
        bl = math.hypot(*bis) or 1
        bis = (bis[0] / bl, bis[1] / bl)
        dot = max(-1.0, min(1.0, u1[0] * u2[0] + u1[1] * u2[1]))
        half_angle = math.acos(dot) / 2
        dist = r / max(math.sin(half_angle), 0.2)
        center = (cur[0] + bis[0] * dist, cur[1] + bis[1] * dist)
        a0 = math.atan2(start[1] - center[1], start[0] - center[0])
        a1 = math.atan2(end[1] - center[1], end[0] - center[0])
        # Sweep the short way from start to end.
        delta = (a1 - a0 + math.pi) % (2 * math.pi) - math.pi
        steps = 8
        for s in range(steps + 1):
            a = a0 + delta * (s / steps)
            points.append((center[0] + math.cos(a) * r, center[1] + math.sin(a) * r))
    return points


def draw_arrow_mask(size: int) -> Image.Image:
    """Crisp download arrow, fully inside the glass frame."""
    canvas = 1024
    img = Image.new("L", (canvas, canvas), 0)
    draw = ImageDraw.Draw(img)
    cx = canvas / 2
    stem_w = 148
    draw.rounded_rectangle([cx - stem_w / 2, 348, cx + stem_w / 2, 590], radius=74, fill=255)
    head = rounded_arrow_head(cx, top=530, tip=698, half=176, corner=36)
    draw.polygon(head, fill=255)
    # Just enough blur to antialias. The shape itself stays an arrow.
    img = img.filter(ImageFilter.GaussianBlur(radius=1.4))
    return img.resize((size, size), Image.Resampling.LANCZOS)


def render(size: int, *, shadow: bool) -> Image.Image:
    """Render one icon. `shadow` adds the macOS-style drop shadow inside the canvas."""
    detail = size >= 128
    tiny = size <= 32
    # Apple's icon grid: the opaque squircle is 824 px on a 1024 canvas.
    if shadow:
        center = (size - 1) / 2.0
        radius = (824.0 / 1024.0) * size / 2.0
        inset = 1.0 - (radius / center)
    else:
        inset = 0.0
    mask = squircle_mask(size, inset=inset)

    base = linear_gradient(size, (0.027, 0.043, 0.11), (0.012, 0.016, 0.05), 112)
    # Deepen the corners.
    y, x = np.ogrid[0:size, 0:size]
    cx = (size - 1) / 2
    vignette = np.sqrt(((x - cx) / (size * 0.62)) ** 2 + ((y - cx) / (size * 0.62)) ** 2)
    vignette = np.clip(vignette, 0, 1)[..., None]
    base = base * (1.0 - 0.45 * vignette) + np.array((0.008, 0.01, 0.03)) * (0.45 * vignette)

    # Midnight navy with a coral streak and a violet edge, matching the approved reference.
    glows = [
        (0.30, 0.40, 0.20, 0.24, (1.00, 0.40, 0.32), 0.58, 1.4),
        (0.46, 0.56, 0.14, 0.18, (0.78, 0.26, 0.52), 0.36, 1.55),
        (0.70, 0.46, 0.24, 0.28, (0.40, 0.20, 0.90), 0.55, 1.3),
    ]
    for fx, fy, frx, fry, color, strength, power in glows:
        alpha = radial_alpha(size, fx * size, fy * size, frx * size, fry * size, power)
        screen(base, color, alpha * strength)

    # A brighter core where the glass will sit, so the frame reads as lit.
    core = radial_alpha(size, 0.50 * size, 0.50 * size, 0.28 * size, 0.26 * size, 1.6)
    screen(base, (0.72, 0.55, 0.82), core * 0.08)

    rgb = np.clip(base, 0, 1)
    artwork = np.dstack([rgb, np.ones((size, size), dtype=np.float32)])

    # Sparkles. Seeded so the icon is stable. Skip them when they'd be noise.
    if detail:
        rng = random.Random(7)
        spark = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        sdraw = ImageDraw.Draw(spark)
        count = 70 if size >= 512 else 36
        for _ in range(count):
            px = rng.uniform(0.16, 0.84) * size
            py = rng.uniform(0.16, 0.84) * size
            # Keep sparkles out of the glass frame.
            if 0.30 * size < px < 0.70 * size and 0.30 * size < py < 0.70 * size:
                continue
            r = rng.choice([0.6, 0.8, 1.1, 1.4]) * (size / 1024) * 3.2
            alpha = rng.randint(90, 210)
            sdraw.ellipse([px - r, py - r, px + r, py + r], fill=(255, 255, 255, alpha))
        spark = spark.filter(ImageFilter.GaussianBlur(radius=max(0.4, size / 1024)))
        artwork = np.asarray(Image.alpha_composite(Image.fromarray((artwork * 255).astype(np.uint8), "RGBA"), spark)).astype(np.float32) / 255.0

    # Glass video frame. On tiny icons the frame disappears, so draw only the arrow.
    glass_box = (0.27 * size, 0.28 * size, 0.73 * size, 0.72 * size)
    radius = 0.075 * size
    if not tiny:
        gmask = rounded_rect_mask(size, glass_box, radius)
        gmask_arr = np.asarray(gmask).astype(np.float32) / 255.0
        # Translucent fill, brighter at the top.
        gy = np.linspace(0.22, 0.06, size, dtype=np.float32)[:, None]
        fill_a = gmask_arr * gy
        artwork[..., 0:3] = artwork[..., 0:3] * (1 - fill_a[..., None]) + fill_a[..., None]
        artwork[..., 3] = np.maximum(artwork[..., 3], gmask_arr)

        # Specular streak along the top inside of the glass.
        streak = Image.new("L", (size, size), 0)
        sd = ImageDraw.Draw(streak)
        sd.rounded_rectangle(
            (glass_box[0] + size * 0.02, glass_box[1] + size * 0.012, glass_box[2] - size * 0.02, glass_box[1] + size * 0.07),
            radius=radius * 0.8,
            fill=255,
        )
        streak = streak.filter(ImageFilter.GaussianBlur(radius=max(1.0, size * 0.008)))
        streak_a = (np.asarray(streak).astype(np.float32) / 255.0) * 0.55
        artwork[..., 0:3] = np.clip(artwork[..., 0:3] + streak_a[..., None], 0, 1)

        # Rim. Draw a slightly smaller hole so the stroke follows the rounded rect.
        rim = Image.new("L", (size, size), 0)
        rd = ImageDraw.Draw(rim)
        stroke = max(2.0, size * 0.012)
        rd.rounded_rectangle(glass_box, radius=radius, outline=255, width=int(round(stroke)))
        rim = rim.filter(ImageFilter.GaussianBlur(radius=max(0.4, size * 0.0015)))
        rim_a = np.asarray(rim).astype(np.float32) / 255.0
        # Cool-white rim, a touch stronger on the top half.
        rim_strength = rim_a * np.linspace(0.95, 0.55, size, dtype=np.float32)[:, None]
        artwork[..., 0:3] = np.clip(artwork[..., 0:3] * (1 - rim_strength[..., None]) + rim_strength[..., None], 0, 1)

    # Arrow, centered in the glass (or in the icon, when tiny).
    arrow = draw_arrow_mask(size)
    arrow_arr = np.asarray(arrow).astype(np.float32) / 255.0
    if tiny:
        # Redraw a heavier arrow that survives 16px.
        arrow_img = Image.new("L", (size, size), 0)
        ad = ImageDraw.Draw(arrow_img)
        cx = size / 2
        stem_w = max(2, size * 0.16)
        ad.rounded_rectangle([cx - stem_w / 2, size * 0.28, cx + stem_w / 2, size * 0.58], radius=stem_w / 2, fill=255)
        ad.polygon(
            [
                (cx - size * 0.26, size * 0.52),
                (cx + size * 0.26, size * 0.52),
                (cx, size * 0.78),
            ],
            fill=255,
        )
        arrow_arr = np.asarray(arrow_img).astype(np.float32) / 255.0

    # Soft shadow under the arrow, then the arrow itself.
    shadow_layer = Image.fromarray((arrow_arr * 255).astype(np.uint8), mode="L")
    shadow_layer = shadow_layer.filter(ImageFilter.GaussianBlur(radius=max(0.8, size * 0.012)))
    sh = np.asarray(shadow_layer).astype(np.float32) / 255.0
    # Offset the shadow down a hair.
    shifted = np.zeros_like(sh)
    off = max(1, int(round(size * 0.008)))
    shifted[off:, :] = sh[:-off, :]
    artwork[..., 0:3] = artwork[..., 0:3] * (1 - shifted[..., None] * 0.35)

    # White arrow with a faint cool gradient, top slightly brighter.
    ay = np.linspace(1.0, 0.90, size, dtype=np.float32)[:, None]
    arrow_rgb = np.dstack([ay, ay, np.clip(ay + 0.02, 0, 1)])
    a = arrow_arr[..., None]
    artwork[..., 0:3] = artwork[..., 0:3] * (1 - a) + arrow_rgb * a

    # Inner top sheen on the squircle, very restrained.
    sheen = np.clip(1.0 - (y / max(size * 0.55, 1)), 0, 1) * 0.10
    artwork[..., 0:3] = np.clip(artwork[..., 0:3] + sheen[..., None], 0, 1)

    # Apply the squircle.
    artwork[..., 3] = mask
    icon = Image.fromarray((np.clip(artwork, 0, 1) * 255).astype(np.uint8), mode="RGBA")

    if not shadow:
        return icon

    # Drop shadow on a transparent canvas. The squircle already includes its inset.
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    shadow_src = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    shadow_alpha = Image.fromarray((mask * 180).astype(np.uint8), mode="L")
    black = Image.new("RGBA", (size, size), (6, 8, 20, 255))
    shadow_src = Image.composite(black, shadow_src, shadow_alpha)
    blur = max(1, int(round(size * 0.035)))
    shadow_src = shadow_src.filter(ImageFilter.GaussianBlur(radius=blur))
    # Sit the shadow slightly below the squircle.
    dy = int(round(size * 0.018))
    canvas.alpha_composite(shadow_src, (0, dy))
    canvas.alpha_composite(icon)
    return canvas


def save_png(image: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, format="PNG", optimize=True)


def main() -> None:
    # Installed icons include the icon-grid inset and a soft shadow, with a
    # transparent background outside the squircle. 512@2x is the 1024 image.
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
    for name, px in sizes.items():
        image = render(px, shadow=True)
        save_png(image, ICONSET / name)
        save_png(image, APPICONSET / name)
        print(f"wrote {name} ({px})")

    contents = """{
  "images" : [
    { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""
    (APPICONSET / "Contents.json").write_text(contents)

    # A presentation render on the reference's warm paper, for the README.
    icon = render(1024, shadow=True)
    paper = Image.new("RGB", (1280, 1280), (246, 242, 238))
    paper.paste(icon, (128, 96), icon)
    save_png(paper.convert("RGBA"), PREVIEW)
    print(f"wrote {PREVIEW}")


if __name__ == "__main__":
    main()
