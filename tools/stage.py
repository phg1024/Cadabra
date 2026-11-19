"""The Cadabra stage: the mark's gradient, pale (docs/visual-language.md).

  python3 tools/stage.py --plates          # writes the 16-bit master plates in docs/images/stage/
  python3 tools/stage.py cut.png out.png   # puts a transparent cutout on the stage

The masters are 16 bits per channel, so they have no steps at all. An 8-bit picture can only show the
gradient as about 25 levels per channel, which shows as bands; out.png gets a ±1 level of dither when
it goes down to 8 bits, which hides them.
"""
import sys, os
import numpy as np, cv2

STOPS = [(0.0, (0xD1, 0xE8, 0xFE)), (0.5, (0xD4, 0xDA, 0xFE)), (1.0, (0xE7, 0xD4, 0xFC))]
PLATES = {"stage-16x10.png": (1920, 1200), "stage-2x1.png": (1920, 960)}
HERE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "docs", "images", "stage")

def gradient(w, h):
    """The stage as float RGB, 0...255, diagonal from the top-left to the bottom-right."""
    y, x = np.mgrid[0:h, 0:w].astype(np.float64)
    t = (x / (w - 1) + y / (h - 1)) / 2
    out = np.zeros((h, w, 3))
    for (t0, c0), (t1, c1) in zip(STOPS, STOPS[1:]):
        m = (t >= t0) & (t <= t1)
        u = ((t - t0) / (t1 - t0))[..., None]
        out[m] = (np.array(c0) * (1 - u) + np.array(c1) * u)[m]
    return out

def write_plates():
    os.makedirs(HERE, exist_ok=True)
    for name, (w, h) in PLATES.items():
        rgb16 = np.round(gradient(w, h) * 257).astype(np.uint16)
        cv2.imwrite(os.path.join(HERE, name), rgb16[..., ::-1])

def plate(w, h):
    """The master closest in shape, scaled to w×h, as float RGB 0...255."""
    name = min(PLATES, key=lambda n: abs(PLATES[n][0] / PLATES[n][1] - w / h))
    path = os.path.join(HERE, name)
    if not os.path.exists(path):
        return gradient(w, h)
    big = cv2.imread(path, cv2.IMREAD_UNCHANGED)[..., ::-1].astype(np.float64) / 257
    return cv2.resize(big, (w, h), interpolation=cv2.INTER_AREA)

def compose(cut_path, out_path):
    cut = cv2.imread(cut_path, cv2.IMREAD_UNCHANGED)
    rgb, a = cut[..., 2::-1].astype(np.float64), cut[..., 3:].astype(np.float64) / 255
    h, w = a.shape[:2]
    out = plate(w, h)
    # A soft shadow: the silhouette, blurred, dropped a little, in a deep violet.
    shadow = cv2.GaussianBlur(a[..., 0], (0, 0), 18) * 0.22
    shadow = np.roll(shadow, 16, axis=0)[..., None]
    out = out * (1 - shadow) + np.array([61, 50, 112]) * shadow
    out = out * (1 - a) + rgb * a
    rng = np.random.default_rng(0)
    out += rng.random(out.shape) - rng.random(out.shape)
    cv2.imwrite(out_path, np.clip(np.round(out), 0, 255).astype(np.uint8)[..., ::-1])

if __name__ == "__main__":
    if sys.argv[1:] == ["--plates"]:
        write_plates()
    else:
        compose(sys.argv[1], sys.argv[2])
