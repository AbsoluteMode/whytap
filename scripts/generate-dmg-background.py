#!/usr/bin/env python3
# generate-dmg-background.py — Render the DMG drag-to-install background PNG.
#
# Outputs Resources/dmg-background.png at 1320x880 (2x retina; rendered behind
# a Finder window sized 660x440 logical via the AppleScript layout in
# build-dmg.sh). Finder places the Whytap.app icon at logical (180, 220) and
# the /Applications symlink at logical (480, 220) on top of this image; we
# render the dark editorial canvas behind them.
#
# Design source: Downloads/Sidekey DMG source/dmg.{jsx,css} — keep this script
# visually aligned with the interactive mockup so what the user previews in
# the browser is what they get on the real DMG.
#
# Usage:
#   python3 scripts/generate-dmg-background.py
#
# Requires Pillow (PIL). On macOS Pillow ships with the homebrew python3 install.

from __future__ import annotations

import math
import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

# Logical 660x440 (= Finder window bounds 1060-400, 540-100 in build-dmg.sh).
# Rendered at 2x for HiDPI.
SCALE = 2
LOGICAL_W = 660
LOGICAL_H = 440
WIDTH = LOGICAL_W * SCALE
HEIGHT = LOGICAL_H * SCALE

# Dark canvas — same gradient as `.style-dark .dmg-canvas` in dmg.css.
BG_TOP = (0x15, 0x15, 0x1C)
BG_BOTTOM = (0x0E, 0x0E, 0x14)

# Accent (Whytap violet) for the two radial glows.
ACCENT = (0x8B, 0x5C, 0xF6)

# Text colours — match css var(--ink) at ~0.55 opacity for muted bits and
# ~0.96 for the title.
INK_FULL = (0xF0, 0xEC, 0xF8)
INK_MUTED = (0xC9, 0xC3, 0xD8)

# Where Finder will place the two icons (logical coords from build-dmg.sh).
# We don't draw the icons — Finder lays them on top — but we use these to
# place the dashed connector between them.
ICON_LEFT_LOGICAL = (180, 220)
ICON_RIGHT_LOGICAL = (480, 220)
ICON_HALF_LOGICAL = 64  # half of Finder icon size 128

# Finder owns icon-label rendering and some macOS releases choose black text
# even over a dark custom DMG background. Pale plates beneath the two labels
# keep that system-controlled text readable without trying to paint duplicate
# labels into the bitmap.
LABEL_PLATE_Y_LOGICAL = 286
LABEL_PLATE_W_LOGICAL = 164
LABEL_PLATE_H_LOGICAL = 30


# ---------------------------------------------------------------------------
# Gradient helpers
# ---------------------------------------------------------------------------

def vertical_gradient(width: int, height: int,
                      top: tuple[int, int, int],
                      bottom: tuple[int, int, int]) -> Image.Image:
    """Vertical linear gradient produced by stretching a single 1-px-wide
    column. Cheap and matches `linear-gradient(180deg, top 0%, bottom 100%)`
    in CSS."""
    column = Image.new("RGB", (1, height), top)
    pixels = column.load()
    for y in range(height):
        t = y / max(height - 1, 1)
        pixels[0, y] = (
            int(top[0] + (bottom[0] - top[0]) * t),
            int(top[1] + (bottom[1] - top[1]) * t),
            int(top[2] + (bottom[2] - top[2]) * t),
        )
    return column.resize((width, height))


def radial_glow_overlay(width: int, height: int,
                        cx: float, cy: float,
                        rx: float, ry: float,
                        colour: tuple[int, int, int],
                        peak_alpha: int,
                        falloff_stop: float = 0.60) -> Image.Image:
    """Soft radial glow centred on (cx, cy) with elliptical falloff (rx, ry).
    Mirrors `radial-gradient(rx ry at cx cy, colour peak, transparent stop%)`.

    Falloff is a smoothstep from full alpha at the centre to 0 at
    `falloff_stop * radius`."""
    overlay = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    pixels = overlay.load()
    cutoff = falloff_stop
    for y in range(height):
        ny = (y - cy) / ry
        for x in range(width):
            nx = (x - cx) / rx
            d = math.sqrt(nx * nx + ny * ny)
            if d >= cutoff:
                continue
            t = 1.0 - (d / cutoff)
            # smoothstep — softer edge than linear.
            t = t * t * (3.0 - 2.0 * t)
            a = int(peak_alpha * t)
            if a > 0:
                pixels[x, y] = (colour[0], colour[1], colour[2], a)
    return overlay


# ---------------------------------------------------------------------------
# Fonts
# ---------------------------------------------------------------------------

def project_root() -> str:
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def font_instrument_italic(size_pt: int) -> ImageFont.FreeTypeFont:
    """Editorial display italic — same font the SwiftUI onboarding uses for
    headlines. Falls back to system italic if the bundled TTF is missing."""
    path = os.path.join(project_root(), "Resources", "Fonts",
                        "InstrumentSerif-Italic.ttf")
    if os.path.exists(path):
        return ImageFont.truetype(path, size_pt)
    for fallback in [
        "/System/Library/Fonts/Supplemental/Times New Roman Italic.ttf",
        "/Library/Fonts/Times New Roman Italic.ttf",
    ]:
        if os.path.exists(fallback):
            return ImageFont.truetype(fallback, size_pt)
    return ImageFont.load_default()


def font_instrument_regular(size_pt: int) -> ImageFont.FreeTypeFont:
    path = os.path.join(project_root(), "Resources", "Fonts",
                        "InstrumentSerif-Regular.ttf")
    if os.path.exists(path):
        return ImageFont.truetype(path, size_pt)
    for fallback in [
        "/System/Library/Fonts/Supplemental/Times New Roman.ttf",
        "/System/Library/Fonts/Times.ttc",
    ]:
        if os.path.exists(fallback):
            return ImageFont.truetype(fallback, size_pt)
    return ImageFont.load_default()


def font_sans(size_pt: int) -> ImageFont.FreeTypeFont:
    for path in [
        "/System/Library/Fonts/HelveticaNeue.ttc",
        "/System/Library/Fonts/Helvetica.ttc",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
    ]:
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size_pt)
            except OSError:
                continue
    return ImageFont.load_default()


# ---------------------------------------------------------------------------
# Drawing primitives
# ---------------------------------------------------------------------------

def draw_text_with_opacity(canvas: Image.Image,
                           xy: tuple[int, int],
                           text: str,
                           font: ImageFont.FreeTypeFont,
                           colour: tuple[int, int, int],
                           opacity: float) -> None:
    """Render text into a transparent layer at `opacity`, then composite onto
    the canvas. PIL has no per-call alpha for `text()`, so we use a layer."""
    layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    a = max(0, min(255, int(opacity * 255)))
    draw.text(xy, text, fill=(colour[0], colour[1], colour[2], a), font=font)
    canvas.alpha_composite(layer)


def text_size(font: ImageFont.FreeTypeFont, text: str) -> tuple[int, int]:
    """Width/height of a string in pixels for layout maths.
    Uses textbbox so descenders are included."""
    # ImageDraw needs an image to compute textbbox; reuse a 1x1 scratch.
    scratch = Image.new("RGBA", (1, 1))
    bbox = ImageDraw.Draw(scratch).textbbox((0, 0), text, font=font)
    return bbox[2] - bbox[0], bbox[3] - bbox[1]


def draw_dashed_curve(canvas: Image.Image,
                      start: tuple[int, int],
                      end: tuple[int, int],
                      arch: int,
                      colour: tuple[int, int, int],
                      opacity: float,
                      stroke: int,
                      dash_on: int,
                      dash_off: int) -> None:
    """Dashed quadratic arch from `start` to `end`, bowing upward by `arch`
    pixels at the midpoint. Mirrors the SVG path in dmg.jsx
    `M 8 30 Q 60 -10, 100 30 T 188 30` (two arches), simplified to one arch
    because at the DMG @2x scale the second hump reads as noise."""

    # Sample the curve densely so dash spacing is uniform along arc length.
    sx, sy = start
    ex, ey = end
    cx = (sx + ex) / 2.0
    cy = (sy + ey) / 2.0 - arch  # control point sits `arch` px above midline

    samples = []
    steps = 600
    last = (sx, sy)
    accum = 0.0
    samples.append((0.0, sx, sy))
    for i in range(1, steps + 1):
        t = i / steps
        # Quadratic Bezier B(t) = (1-t)^2 P0 + 2(1-t)t C + t^2 P1
        u = 1.0 - t
        x = u * u * sx + 2 * u * t * cx + t * t * ex
        y = u * u * sy + 2 * u * t * cy + t * t * ey
        accum += math.hypot(x - last[0], y - last[1])
        samples.append((accum, x, y))
        last = (x, y)

    # Walk samples emitting dash_on / dash_off segments.
    total = samples[-1][0]
    layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    a = max(0, min(255, int(opacity * 255)))
    fill = (colour[0], colour[1], colour[2], a)

    pos = 0.0
    drawing = True
    while pos < total:
        seg_len = dash_on if drawing else dash_off
        seg_end = min(pos + seg_len, total)
        if drawing:
            # Find sample indices for `pos` and `seg_end`.
            p_start = _sample_at(samples, pos)
            p_end = _sample_at(samples, seg_end)
            draw.line([p_start, p_end], fill=fill, width=stroke)
            # round caps
            r = stroke // 2
            for px, py in (p_start, p_end):
                draw.ellipse([(px - r, py - r), (px + r, py + r)], fill=fill)
        pos = seg_end
        drawing = not drawing

    canvas.alpha_composite(layer)


def _sample_at(samples: list[tuple[float, float, float]],
               arc_pos: float) -> tuple[float, float]:
    """Linearly interpolate between the two samples bracketing arc_pos."""
    lo, hi = 0, len(samples) - 1
    while lo < hi:
        mid = (lo + hi) // 2
        if samples[mid][0] < arc_pos:
            lo = mid + 1
        else:
            hi = mid
    if lo == 0:
        return samples[0][1], samples[0][2]
    a = samples[lo - 1]
    b = samples[lo]
    span = b[0] - a[0]
    if span <= 0:
        return b[1], b[2]
    t = (arc_pos - a[0]) / span
    return a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t


# ---------------------------------------------------------------------------
# Composition
# ---------------------------------------------------------------------------

def main() -> int:
    out_path = os.path.join(project_root(), "Resources", "dmg-background.png")

    # 1. Base gradient.
    img = vertical_gradient(WIDTH, HEIGHT, BG_TOP, BG_BOTTOM).convert("RGBA")

    # 2. Two accent glows — top-centre and bottom-right, same axis math as
    # the two radial-gradient layers in `.style-dark .dmg-canvas`.
    top_glow = radial_glow_overlay(
        WIDTH, HEIGHT,
        cx=WIDTH * 0.50,
        cy=HEIGHT * -0.10,
        rx=720 * SCALE,
        ry=480 * SCALE,
        colour=ACCENT,
        peak_alpha=int(0.38 * 255),
        falloff_stop=0.60,
    )
    img.alpha_composite(top_glow)

    bottom_glow = radial_glow_overlay(
        WIDTH, HEIGHT,
        cx=WIDTH * 0.90,
        cy=HEIGHT * 1.10,
        rx=580 * SCALE,
        ry=420 * SCALE,
        colour=ACCENT,
        peak_alpha=int(0.26 * 255),
        falloff_stop=0.60,
    )
    img.alpha_composite(bottom_glow)

    # 3. Header — `Welcome to` (italic, muted) above `Whytap.` headline.
    marquee_font = font_instrument_italic(16 * SCALE)
    marquee_text = "Welcome to"
    mw, _ = text_size(marquee_font, marquee_text)
    marquee_y = 16 * SCALE
    draw_text_with_opacity(
        img,
        ((WIDTH - mw) // 2, marquee_y),
        marquee_text,
        marquee_font,
        INK_FULL,
        opacity=0.55,
    )

    # `Why` in regular, `tap.` in italic — same two-style title as dmg.jsx.
    title_size = 44 * SCALE
    title_regular = font_instrument_regular(title_size)
    title_italic = font_instrument_italic(title_size)
    part_a = "Why"
    part_b = "tap."
    aw, ah = text_size(title_regular, part_a)
    bw, _ = text_size(title_italic, part_b)
    title_total_w = aw + bw
    title_y = marquee_y + int(16 * SCALE * 1.05) + 4 * SCALE
    title_x = (WIDTH - title_total_w) // 2
    draw_text_with_opacity(
        img,
        (title_x, title_y),
        part_a,
        title_regular,
        INK_FULL,
        opacity=0.96,
    )
    draw_text_with_opacity(
        img,
        (title_x + aw, title_y),
        part_b,
        title_italic,
        INK_FULL,
        opacity=0.96,
    )

    # 4. Dashed connector between the two icon positions Finder will paint.
    # Start just to the right of the app icon, end just to the left of the
    # Applications folder. Bow upward so it doesn't overlap the icons or
    # their labels.
    sx = (ICON_LEFT_LOGICAL[0] + ICON_HALF_LOGICAL + 8) * SCALE
    sy = ICON_LEFT_LOGICAL[1] * SCALE
    ex = (ICON_RIGHT_LOGICAL[0] - ICON_HALF_LOGICAL - 8) * SCALE
    ey = ICON_RIGHT_LOGICAL[1] * SCALE
    arch = 16 * SCALE
    draw_dashed_curve(
        img,
        start=(sx, sy),
        end=(ex, ey),
        arch=arch,
        colour=INK_FULL,
        opacity=0.55,
        stroke=int(1.5 * SCALE),
        dash_on=4 * SCALE,
        dash_off=5 * SCALE,
    )

    # Finder icon labels sit directly below the 128pt icons. Give both labels
    # a stable light surface: their colour is not configurable through Finder
    # AppleScript and is black on affected macOS builds.
    plate_layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    plate_draw = ImageDraw.Draw(plate_layer)
    for centre_x in (ICON_LEFT_LOGICAL[0], ICON_RIGHT_LOGICAL[0]):
        left = (centre_x - LABEL_PLATE_W_LOGICAL // 2) * SCALE
        top = LABEL_PLATE_Y_LOGICAL * SCALE
        right = (centre_x + LABEL_PLATE_W_LOGICAL // 2) * SCALE
        bottom = (LABEL_PLATE_Y_LOGICAL + LABEL_PLATE_H_LOGICAL) * SCALE
        plate_draw.rounded_rectangle(
            [(left, top), (right, bottom)],
            radius=8 * SCALE,
            fill=(0xE8, 0xE4, 0xEF, 238),
            outline=(0xFF, 0xFF, 0xFF, 64),
            width=SCALE,
        )
    img.alpha_composite(plate_layer)

    # 5. Footer hint — uppercase tracked label, with a tiny dot on each side.
    hint_font = font_sans(int(11.5 * SCALE))
    hint_text = "DRAG  WHYTAP  TO  APPLICATIONS"
    hw, hh = text_size(hint_font, hint_text)
    hint_y = HEIGHT - 26 * SCALE - hh

    # Two dots.
    dot_r = 2 * SCALE
    dot_layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    dot_draw = ImageDraw.Draw(dot_layer)
    dot_alpha = int(0.5 * 255)
    dot_colour = (INK_MUTED[0], INK_MUTED[1], INK_MUTED[2], dot_alpha)
    centre_y = hint_y + hh // 2
    left_dot_x = (WIDTH - hw) // 2 - 10 * SCALE
    right_dot_x = (WIDTH - hw) // 2 + hw + 10 * SCALE
    dot_draw.ellipse(
        [(left_dot_x - dot_r, centre_y - dot_r),
         (left_dot_x + dot_r, centre_y + dot_r)],
        fill=dot_colour,
    )
    dot_draw.ellipse(
        [(right_dot_x - dot_r, centre_y - dot_r),
         (right_dot_x + dot_r, centre_y + dot_r)],
        fill=dot_colour,
    )
    img.alpha_composite(dot_layer)

    draw_text_with_opacity(
        img,
        ((WIDTH - hw) // 2, hint_y),
        hint_text,
        hint_font,
        INK_MUTED,
        opacity=0.62,
    )

    # 6. Save. Use RGB (no need for alpha in the on-disk PNG; Finder paints
    # it as an opaque background image) so the file is smaller.
    #
    # Embed a 144-DPI pHYs chunk so Finder treats the image as @2x retina
    # (1 point = 2 pixels). Without this hint the default 72-DPI assumption
    # makes Finder render the 1320x880 image at 1320x880 *points*, so the
    # 660x440 DMG window only shows the top-left ~50% x 50% — the centred
    # title slides off the right edge and the bottom hint is clipped. With
    # the hint Finder shrinks the image to 660x440 logical points and the
    # full background is visible inside the window. Apple's HiDPI DMG
    # background convention is documented in the "Building a Disk Image
    # Installer" guides (PNG pHYs chunk + 144 DPI = HiDPI marker).
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    img.convert("RGB").save(out_path, "PNG", optimize=True, dpi=(144, 144))
    print(f"wrote {out_path} ({WIDTH}x{HEIGHT}, 144 DPI = @2x)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
