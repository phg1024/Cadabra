# Put a transparent cutout on the Cadabra stage: the mark gradient, pale (docs/visual-language.md).
import sys, numpy as np
from PIL import Image, ImageFilter
STOPS = [(0.0, (0xD1, 0xE8, 0xFE)), (0.5, (0xD4, 0xDA, 0xFE)), (1.0, (0xE7, 0xD4, 0xFC))]
def stage(w, h):
    y, x = np.mgrid[0:h, 0:w].astype(np.float32)
    t = (x / (w - 1) + y / (h - 1)) / 2
    out = np.zeros((h, w, 3), np.float32)
    for (t0, c0), (t1, c1) in zip(STOPS, STOPS[1:]):
        m = (t >= t0) & (t <= t1); u = ((t - t0) / (t1 - t0))[..., None]
        out[m] = (np.array(c0) * (1 - u) + np.array(c1) * u)[m]
    # dither: a triangular ±1 level of noise breaks the 8-bit steps into a smooth-looking gradient
    rng = np.random.default_rng(0)
    out += rng.random(out.shape, np.float32) - rng.random(out.shape, np.float32)
    return Image.fromarray(np.clip(out.round(), 0, 255).astype(np.uint8))
def compose(cut_path, out_path):
    cut = Image.open(cut_path).convert("RGBA"); w, h = cut.size
    bg = stage(w, h).convert("RGBA")
    a = cut.getchannel("A")
    # soft shadow: the silhouette, blurred, dropped a little, in a deep violet
    sh = Image.new("RGBA", (w, h), (61, 50, 112, 0))
    sa = a.filter(ImageFilter.GaussianBlur(18)).point(lambda v: int(v * 0.22))
    sh.putalpha(sa)
    bg.alpha_composite(sh, (0, 16))
    bg.alpha_composite(cut)
    bg.convert("RGB").save(out_path)
if __name__ == "__main__":
    compose(sys.argv[1], sys.argv[2])
