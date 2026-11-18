#!/usr/bin/env python3
"""
MacPi live wallpaper renderer.

Renders a seamless, silently-looping nature scene (aurora over a mountain lake)
straight to H.264. Every moving element is driven by sin(2*pi*k*t) or a noise
field sampled on a circle in time, so frame N wraps to frame 0 exactly - no
crossfade, no visible cut.

    python3 tools/render_livewall.py --scene aurora --out assets/livewall/aurora-lake-1080p.mp4

Requires: numpy, pillow, ffmpeg on PATH.
"""
import argparse, math, os, subprocess, sys
import numpy as np
from PIL import Image, ImageFilter

TAU = 2.0 * math.pi
RNG = np.random.default_rng(20261117)


# ---------------------------------------------------------------- helpers
def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def value_noise(h, w, cells, seed):
    """Smooth 2D value noise in [0,1]: random grid -> bicubic upsample."""
    r = np.random.default_rng(seed)
    small = r.random((cells_h := max(2, int(cells * h / w)), int(cells))).astype(np.float32)
    im = Image.fromarray((small * 255).astype(np.uint8), "L").resize((w, h), Image.BICUBIC)
    return np.asarray(im, dtype=np.float32) / 255.0


def horizontal_gradient(w, stops):
    """stops: [(pos0..1, (r,g,b)), ...] -> (1,w,3) float 0..1"""
    pos = np.array([s[0] for s in stops], dtype=np.float32)
    cols = np.array([s[1] for s in stops], dtype=np.float32)
    x = np.linspace(0, 1, w, dtype=np.float32)
    out = np.stack([np.interp(x, pos, cols[:, i]) for i in range(3)], axis=-1)
    return out[None, :, :]


def vertical_gradient(h, stops):
    pos = np.array([s[0] for s in stops], dtype=np.float32)
    cols = np.array([s[1] for s in stops], dtype=np.float32)
    y = np.linspace(0, 1, h, dtype=np.float32)
    out = np.stack([np.interp(y, pos, cols[:, i]) for i in range(3)], axis=-1)
    return out[:, None, :]


def blur(a, radius):
    """Gaussian blur a float HxW or HxWx3 array via PIL."""
    if a.ndim == 2:
        im = Image.fromarray((np.clip(a, 0, 1) * 255).astype(np.uint8), "L")
        return np.asarray(im.filter(ImageFilter.GaussianBlur(radius)), dtype=np.float32) / 255.0
    chans = [blur(a[..., i], radius) for i in range(a.shape[-1])]
    return np.stack(chans, axis=-1)


# ---------------------------------------------------------------- scene
class AuroraLake:
    """Night aurora over a lake, with parallax ridgelines and mist."""

    def __init__(self, w, h, seed=7):
        self.w, self.h, self.seed = w, h, seed
        self.horizon = int(h * 0.615)
        self.ridge = self._ridges()
        self.stars = self._stars()
        self.vignette = self._vignette()
        self.sky = self._sky()
        self.warp = None   # lazily built: 1-D striations
        self.rock = None   # lazily built: ridge texture
        self.rays = np.random.default_rng(seed + 3).random((h, max(8, w // 3))).astype(np.float32)

    # -- static pieces -------------------------------------------------
    def _sky(self):
        h, w = self.h, self.w
        top = vertical_gradient(h, [
            (0.00, (0.012, 0.017, 0.043)),
            (0.28, (0.020, 0.033, 0.082)),
            (0.50, (0.031, 0.055, 0.125)),
            (0.62, (0.055, 0.090, 0.165)),
            (1.00, (0.070, 0.105, 0.180)),
        ])
        # faint teal airglow at the horizon, brightest at centre
        x = np.linspace(-1, 1, w, dtype=np.float32)[None, :]
        glow_x = np.exp(-(x ** 2) / 0.55)
        y = np.linspace(0, 1, h, dtype=np.float32)[:, None]
        glow_y = np.exp(-(((y - self.horizon / h) ** 2) / 0.0045))
        glow = (glow_x * glow_y)[..., None] * np.array([0.10, 0.30, 0.32], dtype=np.float32)
        return np.clip(top + glow, 0, 1)

    def _ridges(self):
        """Return list of (alpha_mask hxw, shade_rgb, parallax_px)."""
        h, w = self.h, self.w
        out = []
        specs = [
            # (base_y frac, amplitude px, colour, parallax, roughness)
            (0.615, 0.055, (0.075, 0.098, 0.150), 3.0, 0.6),
            (0.655, 0.070, (0.035, 0.052, 0.085), 7.0, 1.0),
            (0.700, 0.085, (0.012, 0.020, 0.036), 13.0, 1.7),
        ]
        x = np.arange(w, dtype=np.float32)
        for i, (base, amp, col, par, rough) in enumerate(specs):
            r = np.random.default_rng(self.seed * 31 + i)
            prof = np.zeros(w, dtype=np.float32)
            for k in range(12):
                f = (0.55 + k * 1.05) * rough
                prof += (r.random() * 2 - 1) * (amp * h) / (1.52 ** k) * np.sin(
                    TAU * f * x / w + r.random() * TAU)
            prof -= prof.min()
            prof /= (prof.max() + 1e-6)
            top = (base * h - prof * amp * h * 1.25)
            yy = np.arange(h, dtype=np.float32)[:, None]
            mask = (yy >= top[None, :]).astype(np.float32)
            # soften the crest by 1px so it does not alias when it moves
            mask = np.asarray(Image.fromarray((mask * 255).astype(np.uint8), "L")
                              .filter(ImageFilter.GaussianBlur(0.8)), dtype=np.float32) / 255.0
            out.append((mask, np.array(col, dtype=np.float32), par, top))
        return out

    def _stars(self):
        r = np.random.default_rng(self.seed + 11)
        n = int(self.w * self.h * 0.00028)
        ylo, yhi = 0, int(self.horizon * 0.98)
        ys = r.integers(ylo, yhi, n)
        xs = r.integers(0, self.w, n)
        # density falls off toward the horizon
        keep = r.random(n) < np.clip(1.0 - (ys / yhi) ** 1.6, 0.05, 1.0)
        ys, xs = ys[keep], xs[keep]
        mag = r.random(len(xs)) ** 3.2           # few bright, many dim
        twinkle = r.random(len(xs)) * TAU
        speed = r.integers(1, 3, len(xs))
        tint = r.normal(0, 1, (len(xs), 3)) * 0.12 + 1.0
        return dict(ys=ys, xs=xs, mag=mag, tw=twinkle, sp=speed, tint=tint.astype(np.float32))

    def _vignette(self):
        h, w = self.h, self.w
        y = np.linspace(-1, 1, h, dtype=np.float32)[:, None]
        x = np.linspace(-1, 1, w, dtype=np.float32)[None, :]
        v = 1.0 - 0.42 * np.clip((x ** 2 * 0.85 + y ** 2 * 0.75) - 0.12, 0, 2) ** 0.85
        return np.clip(v, 0, 1)[..., None].astype(np.float32)

    # -- per-frame -----------------------------------------------------
    def _striations(self, w):
        """Smooth 1D noise along x, used for the vertical aurora rays."""
        if self.warp is not None:
            return self.warp
        r = np.random.default_rng(self.seed + 9)
        n = r.random(max(16, w // 3)).astype(np.float32)
        k = np.hanning(7)
        k /= k.sum()
        n = np.convolve(n, k, mode="same")
        n = np.interp(np.linspace(0, 1, w), np.linspace(0, 1, n.size), n)
        self.warp = (0.25 + 1.05 * n).astype(np.float32)
        return self.warp

    def aurora(self, u):
        """Additive aurora RGB. u = 2*pi*t, so every term is periodic by design."""
        h, w = self.h, self.w
        x = np.arange(w, dtype=np.float32)[None, :]
        y = np.arange(h, dtype=np.float32)[:, None]
        stri_base = self._striations(w)

        # (centre_y, half-width, gain, phase, bottom colour, top colour)
        curtains = [
            (0.250, 0.070, 1.00, 0.00, (0.10, 0.95, 0.42), (0.22, 0.55, 0.55)),
            (0.335, 0.085, 0.72, 1.70, (0.06, 0.70, 0.62), (0.18, 0.40, 0.75)),
            (0.170, 0.055, 0.55, 3.40, (0.14, 0.80, 0.55), (0.42, 0.24, 0.72)),
            (0.440, 0.060, 0.40, 5.10, (0.10, 0.55, 0.75), (0.20, 0.34, 0.80)),
        ]
        acc = np.zeros((h, w, 3), dtype=np.float32)
        for cy, wd, gain, ph, c_lo, c_hi in curtains:
            spine = (cy * h
                     + 0.075 * h * np.sin(x / (w * 0.16) + u + ph)
                     + 0.030 * h * np.sin(x / (w * 0.44) - 2.0 * u + ph * 1.3)
                     + 0.012 * h * np.sin(x / (w * 1.10) + 3.0 * u + ph * 0.7))
            width = wd * h * (1.0 + 0.40 * np.sin(x / (w * 0.24) + 2.0 * u + ph))

            # three overlapping sheets -> folds with darker lanes between them
            for j, (off, sheet_gain, sheet_w) in enumerate(
                    ((-1.25, 0.50, 0.46), (0.15, 0.92, 0.80), (1.15, 0.36, 0.40))):
                c = spine + off * width * (0.85 + 0.15 * np.sin(u * 2 + ph))
                bw = width * sheet_w
                band = np.exp(-((y - c) ** 2) / (2.0 * bw ** 2))
                ray = np.roll(stri_base, int(round(0.040 * w * math.sin(u + ph + j))), axis=0)
                band = band * (0.20 + 0.92 * ray + 0.22 * np.roll(ray, 41 + 17 * j))[None, :]
                rel = (y - c) / (bw + 1e-3)
                t_lo = smoothstep(-1.6, 0.30, rel)
                col = (np.array(c_hi, dtype=np.float32)[None, None, :] * (1 - t_lo[..., None])
                       + np.array(c_lo, dtype=np.float32)[None, None, :] * t_lo[..., None])
                acc += band[..., None] * col * gain * sheet_gain

        # glow around the curtains, then a soft filmic tonemap so nothing clips to white
        acc = acc + blur(acc, 30) * 0.6
        acc = 1.0 - np.exp(-acc * 0.92)
        acc = acc * smoothstep(0.0, 0.05 * h, y)[..., None]
        return acc

    def frame(self, t):
        u = TAU * t
        h, w = self.h, self.w

        # ---- sky + stars
        img = self.sky.copy()
        s = self.stars
        if len(s["xs"]):
            tw = 0.62 + 0.38 * np.sin(u * s["sp"] + s["tw"])
            b = (0.25 + s["mag"] * 0.95)[:, None] * tw[:, None] * s["tint"]
            np.add.at(img, (s["ys"], s["xs"]), np.clip(b, 0, 1))

        # ---- aurora (above the horizon only, plus reflection contribution)
        aur = self.aurora(u)
        above = np.clip(1.0 - smoothstep(self.horizon - 2, self.horizon + 2,
                                        np.arange(h, dtype=np.float32))[:, None], 0, 1)
        img += aur * above[..., None]

        # ---- ridgelines (occlude aurora, slight parallax drift)
        for mask, col, par, top in self.ridge:
            shift = int(round(math.sin(u) * par))
            m = np.roll(mask, shift, axis=1)
            img = img * (1 - m[..., None]) + (col * (1.0 + 0.10 * np.sin(u))) * m[..., None]
            # faint rim light along the crest + a little granite texture
            if self.rock is None:
                self.rock = value_noise(self.h, self.w, 190, self.seed + 17) - 0.5
            rim = np.exp(-((np.arange(self.h, dtype=np.float32)[:, None] - top[None, :]) ** 2) / (2 * 1.1 ** 2))
            rim = np.roll(rim, shift, axis=1)[..., None]
            img = np.clip(img + rim * np.array([0.055, 0.085, 0.105], dtype=np.float32), 0, 1)
            img = np.clip(img + (self.rock * m)[..., None] * 0.016, 0, 1)

        # ---- mist band hugging the waterline
        y = np.arange(h, dtype=np.float32)[:, None]
        mist = np.exp(-((y - self.horizon * 1.01) ** 2) / (2 * (h * 0.030) ** 2))
        mist = mist * (0.55 + 0.45 * np.sin(np.arange(w, dtype=np.float32)[None, :] / (w * 0.09) + u))
        img = np.clip(img + mist[..., None] * np.array([0.055, 0.075, 0.085], dtype=np.float32), 0, 1)

        # ---- lake: mirrored, rippled reflection (darker, desaturated, broken up)
        yh = self.horizon
        yy = np.arange(h, dtype=np.float32)[:, None]
        src_y = np.clip(2 * yh - yy, 0, h - 1).astype(np.int32)
        xs = np.arange(w, dtype=np.float32)[None, :]
        depth = np.clip((yy - yh) / (h - yh), 0, 1)
        amp = 2.0 + 22.0 * depth ** 0.7
        disp = (amp * np.sin(yy * 0.075 + u * 2.0)
                + amp * 0.45 * np.sin(yy * 0.190 - u * 3.0)
                + amp * 0.20 * np.sin(yy * 0.410 + u * 5.0))
        src_x = np.clip(xs + disp, 0, w - 1).astype(np.int32)
        refl = img[src_y, src_x]   # both already 2-D; a [:, None] here makes a 4-D gather
        refl = blur(refl, 0.8)
        streak = 0.94 + 0.06 * np.sin(yy * 0.085 + u * 2.0)
        refl = refl * streak[..., None]
        # water absorbs and reflects only part of the light
        refl = refl * 0.55 * np.array([0.72, 0.86, 1.0], dtype=np.float32)
        refl = refl + np.array([0.008, 0.013, 0.024], dtype=np.float32)
        water = np.clip(depth * 7.0, 0, 1)[..., None]
        img = img * (1 - water) + refl * water
        # thin shoreline highlight so mountain and water read as separate planes
        shore = np.exp(-((yy - yh) ** 2) / (2 * 1.6 ** 2)) * 0.55
        img = img + shore[..., None] * np.array([0.10, 0.16, 0.18], dtype=np.float32)

        # ---- grade: vignette, cool shadows, film grain
        img = img * self.vignette
        img = np.clip(img, 0, 1) ** (1 / 1.06)
        grain = RNG.normal(0, 1, (h, w, 1)).astype(np.float32) * 0.010
        img = np.clip(img + grain, 0, 1)
        return (img * 255.0 + 0.5).astype(np.uint8)


# ---------------------------------------------------------------- clouds scene
class CloudSea:
    """Sunrise above a sea of clouds, slow drifting strata. Also seamless."""

    def __init__(self, w, h, seed=21):
        self.w, self.h, self.seed = w, h, seed
        self.horizon = int(h * 0.58)
        self.sky = vertical_gradient(h, [
            (0.00, (0.06, 0.10, 0.22)),
            (0.22, (0.28, 0.26, 0.42)),
            (0.40, (0.75, 0.46, 0.40)),
            (0.52, (0.98, 0.72, 0.45)),
            (0.60, (1.00, 0.86, 0.66)),
            (1.00, (0.55, 0.45, 0.42)),
        ])
        self.n1 = value_noise(h, w, 9, seed)
        self.n2 = value_noise(h, w, 21, seed + 1)
        self.n3 = value_noise(h, w, 47, seed + 2)
        self.ridge = AuroraLake(w, h, seed=3)._ridges()
        y = np.linspace(-1, 1, h, dtype=np.float32)[:, None]
        x = np.linspace(-1, 1, w, dtype=np.float32)[None, :]
        self.vig = np.clip(1.0 - 0.35 * np.clip((x ** 2 + y ** 2) - 0.25, 0, 2), 0, 1)[..., None]

    def frame(self, t):
        u = TAU * t
        h, w = self.h, self.w
        img = np.repeat(self.sky, w, axis=1).copy()

        # sun glow, breathing very slowly
        y = np.arange(h, dtype=np.float32)[:, None]
        x = np.arange(w, dtype=np.float32)[None, :]
        sunx, suny = self.w * 0.62, self.horizon * 0.92
        d = np.sqrt(((x - sunx) / w) ** 2 + ((y - suny) / h) ** 2)
        glow = np.exp(-(d ** 2) / 0.010) * (0.94 + 0.06 * np.sin(u))
        img = img + glow[..., None] * np.array([0.95, 0.72, 0.42], dtype=np.float32)

        # three cloud strata drifting at different speeds (wrap-safe: roll by int)
        strata = [
            (0.52, 0.075, 0.62, 1.0, (0.99, 0.86, 0.78), self.n1),
            (0.63, 0.095, 0.78, 2.0, (0.86, 0.78, 0.80), self.n2),
            (0.76, 0.130, 0.92, 3.0, (0.62, 0.56, 0.64), self.n3),
        ]
        for cy, wd, dens, speed, col, noise in strata:
            shift = int(round(math.sin(u * speed) * 0.06 * w))
            n = np.roll(np.roll(noise, (shift // 3) % w, axis=1), int(round(math.sin(u * 0.7) * 0.02 * h)), axis=0)
            band = np.exp(-((y - cy * h) ** 2) / (2 * (wd * h) ** 2))
            a = np.clip((n - (1.0 - dens) * 0.85) * 2.4, 0, 1) * band
            img = img * (1 - a[..., None]) + np.array(col, dtype=np.float32) * a[..., None]

        # distant ridge line for depth
        for mask, col, par, _top in self.ridge[-1:]:
            shift = int(round(math.sin(u) * par))
            m = np.roll(mask, shift, axis=1)
            tint = np.array([0.26, 0.22, 0.30], dtype=np.float32)
            lit = (1.0 + 0.35 * np.exp(-((x - sunx) ** 2) / (0.10 * w ** 2)))[..., None]
            img = img * (1 - m[..., None]) + tint * m[..., None] * lit

        img = np.clip(img * self.vig, 0, 1) ** (1 / 1.05)
        img = np.clip(img + RNG.normal(0, 1, (h, w, 1)).astype(np.float32) * 0.006, 0, 1)
        return (img * 255.0 + 0.5).astype(np.uint8)


SCENES = {"aurora": AuroraLake, "clouds": CloudSea}


# ---------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scene", default="aurora", choices=sorted(SCENES))
    ap.add_argument("--out", required=True)
    ap.add_argument("--width", type=int, default=1920)
    ap.add_argument("--height", type=int, default=1080)
    ap.add_argument("--fps", type=int, default=30)
    ap.add_argument("--seconds", type=float, default=20.0)
    ap.add_argument("--crf", type=int, default=20)
    ap.add_argument("--poster", default=None, help="write a JPEG poster frame here")
    ap.add_argument("--frames-only", type=int, default=0)
    a = ap.parse_args()

    scene = SCENES[a.scene](a.width, a.height)
    n = a.frames_only or int(round(a.fps * a.seconds))
    os.makedirs(os.path.dirname(os.path.abspath(a.out)) or ".", exist_ok=True)

    if a.poster:
        Image.fromarray(scene.frame(0.0)).save(a.poster, quality=92, subsampling=1)
        print("poster ->", a.poster, flush=True)

    ff = [
        "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
        "-f", "rawvideo", "-pix_fmt", "rgb24",
        "-s", f"{a.width}x{a.height}", "-r", str(a.fps), "-i", "-",
        "-an", "-c:v", "libx264", "-preset", "slow", "-crf", str(a.crf),
        "-pix_fmt", "yuv420p", "-profile:v", "high", "-tune", "film",
        "-g", str(a.fps * 2), "-movflags", "+faststart", a.out,
    ]
    p = subprocess.Popen(ff, stdin=subprocess.PIPE)
    try:
        for i in range(n):
            p.stdin.write(scene.frame(i / n).tobytes())
            if i % 30 == 0:
                print(f"  frame {i}/{n}", flush=True)
    finally:
        p.stdin.close()
        p.wait()
    if p.returncode:
        sys.exit("ffmpeg failed")
    print("wrote", a.out, round(os.path.getsize(a.out) / 1e6, 2), "MB")


if __name__ == "__main__":
    main()