#!/usr/bin/env python3
"""Generate the NOOP app icon: dark squircle + mint→emerald pulse waveform with glow."""
import os
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

S = 1024
# --- rounded-rect dark gradient background ---
inset, radius = 76, 205
top = np.array([0x0B, 0x0D, 0x12], float)
bot = np.array([0x14, 0x18, 0x24], float)
grad = np.zeros((S, S, 3), float)
for y in range(S):
    grad[y, :, :] = top + (bot - top) * (y / (S - 1))

# soft radial glow, top-left
yy, xx = np.mgrid[0:S, 0:S]
d = np.sqrt((xx - S * 0.30) ** 2 + (yy - S * 0.26) ** 2)
glow = np.clip(1 - d / (S * 0.62), 0, 1) ** 2.2
glowc = np.array([0x1B, 0x2A, 0x3A], float)
for c in range(3):
    grad[:, :, c] = np.clip(grad[:, :, c] + glow * glowc[c] * 0.5, 0, 255)

bg = Image.fromarray(grad.astype(np.uint8), "RGB").convert("RGBA")
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle([inset, inset, S - inset, S - inset], radius=radius, fill=255)
icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))
icon.paste(bg, (0, 0), mask)

# subtle top inner sheen
sheen = Image.new("RGBA", (S, S), (0, 0, 0, 0))
sd = ImageDraw.Draw(sheen)
sd.rounded_rectangle([inset, inset, S - inset, S - inset], radius=radius,
                     outline=(255, 255, 255, 26), width=2)
icon = Image.alpha_composite(icon, sheen)

# --- pulse / ECG waveform (mint -> emerald gradient), with glow ---
pts_n = [(0.16, 0.50), (0.34, 0.50), (0.41, 0.43), (0.46, 0.58),
         (0.52, 0.20), (0.58, 0.80), (0.64, 0.50), (0.84, 0.50)]
def to_px(p):
    x = inset + p[0] * (S - 2 * inset)
    y = inset + p[1] * (S - 2 * inset)
    return (x, y)
pts = [to_px(p) for p in pts_n]

# resample the polyline densely so we can color-grade along its length
def resample(points, step=3.0):
    out = []
    for a, b in zip(points, points[1:]):
        seg = np.hypot(b[0] - a[0], b[1] - a[1])
        n = max(2, int(seg / step))
        for i in range(n):
            t = i / (n - 1)
            out.append((a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t))
    return out
dense = resample(pts)

mint = np.array([0x34, 0xE5, 0xA0], float)   # emerald-mint (peak recovery)
cyan = np.array([0x5B, 0xE0, 0xC7], float)   # bright mint-cyan
def grade(t):
    c = cyan + (mint - cyan) * t
    return (int(c[0]), int(c[1]), int(c[2]), 255)

stroke = Image.new("RGBA", (S, S), (0, 0, 0, 0))
sd = ImageDraw.Draw(stroke)
w = 50
for i in range(len(dense) - 1):
    t = i / (len(dense) - 2)
    sd.line([dense[i], dense[i + 1]], fill=grade(t), width=w)
for p in dense:  # round the joints
    r = w / 2
    t = dense.index(p) / (len(dense) - 1)
    sd.ellipse([p[0] - r, p[1] - r, p[0] + r, p[1] + r], fill=grade(t))

# glow = blurred, brightened copy of the stroke under it
glow_layer = stroke.filter(ImageFilter.GaussianBlur(26))
icon = Image.alpha_composite(icon, glow_layer)
icon = Image.alpha_composite(icon, glow_layer)  # double for intensity
icon = Image.alpha_composite(icon, stroke)
# clip everything to the rounded mask
icon.putalpha(Image.composite(icon.getchannel("A"), Image.new("L", (S, S), 0), mask))

icon.save(os.path.join(os.path.dirname(os.path.abspath(__file__)), "noop_icon_1024.png"))
print("wrote noop_icon_1024.png")
