"""Cuts the brand logo (violet on white) into white-on-transparent pieces the app can tint and animate.

Usage: python scripts/extract_logo.py Resources/brand/logo.jpg Sources/Naddaf/Resources/Brand
Writes mark.png (whole symbol), mark-ball.png and mark-swoosh.png (its two shapes, same canvas
as mark.png so they line up when stacked) and wordmark.png.
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage

src, out = Path(sys.argv[1]), Path(sys.argv[2])
out.mkdir(parents=True, exist_ok=True)
rgb = np.asarray(Image.open(src).convert("RGB")).astype(np.float32)

# White paper has green ~255, the violet ink (#6035F5) ~53: green gives a clean coverage ramp.
alpha = np.clip((250 - rgb[..., 1]) / (250 - 60), 0, 1)

# The symbol and the wordmark are separated by the widest empty band of rows.
rows = np.where(alpha.max(axis=1) > 0.5)[0]
gaps = np.diff(rows)
split = rows[np.argmax(gaps)] + gaps.max() // 2


def save(a: np.ndarray, name: str) -> None:
    img = np.zeros((*a.shape, 4), dtype=np.uint8)
    img[..., :3] = 255
    img[..., 3] = (a * 255).round().astype(np.uint8)
    Image.fromarray(img, "RGBA").save(out / name)
    print(name, a.shape)


def tight(a: np.ndarray, pad: int = 24) -> tuple[slice, slice]:
    ys, xs = np.where(a > 0.02)
    return (slice(max(ys.min() - pad, 0), ys.max() + pad + 1),
            slice(max(xs.min() - pad, 0), xs.max() + pad + 1))


top, bottom = alpha.copy(), alpha.copy()
top[split:] = 0
bottom[:split] = 0

box = tight(top)
mark = top[box]
save(mark, "mark.png")

# Two shapes: label the solid core, then give every soft edge pixel to its nearest shape.
labels, count = ndimage.label(mark > 0.5)
sizes = ndimage.sum(np.ones_like(mark), labels, range(1, count + 1))
keep = np.argsort(sizes)[::-1][:2] + 1
_, (iy, ix) = ndimage.distance_transform_edt(~np.isin(labels, keep), return_indices=True)
owner = labels[iy, ix]
# The ball sits higher than the swoosh.
centres = {k: ndimage.center_of_mass(labels == k)[0] for k in keep}
ball, swoosh = sorted(keep, key=lambda k: centres[k])
save(np.where(owner == ball, mark, 0), "mark-ball.png")
save(np.where(owner == swoosh, mark, 0), "mark-swoosh.png")

save(bottom[tight(bottom)], "wordmark.png")
