"""Bring the solid purple clay wave in a cutout to the palette's clay purple (#8B74E8), keeping its shading.

  python3 tools/clay_purple.py cut.png out.png
"""
import cv2, numpy as np, sys
src, out = sys.argv[1], sys.argv[2]
target = np.array([0xE8, 0x74, 0x8B], np.uint8)  # BGR of #8B74E8
im = cv2.imread(src, cv2.IMREAD_UNCHANGED)
bgr, a = im[..., :3], im[..., 3]
hsv = cv2.cvtColor(bgr, cv2.COLOR_BGR2HSV)
wave = (hsv[..., 0] > 118) & (hsv[..., 0] < 152) & (hsv[..., 1] > 75) & (a > 40)
lab = cv2.cvtColor(bgr, cv2.COLOR_BGR2Lab).astype(np.float32)
tl = cv2.cvtColor(target.reshape(1, 1, 3), cv2.COLOR_BGR2Lab).astype(np.float32)[0, 0]
mean = lab[wave].mean(0)
shift = tl - mean
# feather the edge so the anti-aliased rim follows
w = cv2.GaussianBlur(wave.astype(np.float32), (0, 0), 1.2)[..., None]
lab2 = lab + shift * w
out_bgr = cv2.cvtColor(np.clip(lab2, 0, 255).astype(np.uint8), cv2.COLOR_Lab2BGR)
im[..., :3] = out_bgr
cv2.imwrite(out, im)
print("was", "#%02X%02X%02X" % tuple(cv2.cvtColor(mean.astype(np.uint8).reshape(1,1,3), cv2.COLOR_Lab2BGR)[0,0][::-1]))
