#!/usr/bin/env python3
"""Host simulation of present_core store fetch + dual resample (not HDMI-measured).

Live product constraint (parent-verified on RBF, cited present_core / QSF):
  H_DE = 529 columns of FRAME_W (640) via STORE_X_SCALE
  Legacy / measured emission: V_STORE=240, STORE_Y_SCALE=2 → even store rows only
    (50% of 480 rows never fetched). Tree may show NATIVE_V_1TO1 for FRAME_H=480;
    fixtures must still survive the *measured* even-row path.

Then ascal → 1920x1440 and grabber → 1920x1080 (same model as glass_frame_id).
All geometry here is caller_supplied model unless labelled measured.
"""
from __future__ import annotations

import numpy as np
from PIL import Image

H_DE = 529
FRAME_W_PRODUCT = 640  # QSF FRAME_W
FRAME_H_CONTENT = 480  # coded bank content height we write


def even_row_cull(rgb: np.ndarray) -> np.ndarray:
    """STORE_Y_SCALE=2 path: keep even rows only → H/2 rows."""
    return rgb[0::2, :, :].copy()


def column_subsample_529(rgb: np.ndarray, frame_w: int = FRAME_W_PRODUCT) -> np.ndarray:
    """Sample 529 columns across width as present_core store_x ≈ hc * FRAME_W/529.

    Input may be content width 624; map x_content → approximate product columns.
    Model: for hc in 0..528, store_x = floor(hc * width / 529), clamped.
    """
    h, w, _ = rgb.shape
    out = np.zeros((h, H_DE, 3), dtype=rgb.dtype)
    for hc in range(H_DE):
        sx = min(w - 1, (hc * w) // H_DE)
        out[:, hc, :] = rgb[:, sx, :]
    return out


def dual_resample_to_grabber(rgb: np.ndarray) -> np.ndarray:
    """Bilinear to 1920x1440 then 1920x1080 (caller_supplied capture model)."""
    im = Image.fromarray(rgb, mode="RGB")
    im = im.resize((1920, 1440), Image.Resampling.BILINEAR)
    im = im.resize((1920, 1080), Image.Resampling.BILINEAR)
    return np.array(im)


def full_chain_legacy240(rgb_content: np.ndarray) -> np.ndarray:
    """Content (any WxH) → even-row cull → 529 cols → dual resample."""
    # If taller than 240 after cull path: cull first on full frame
    if rgb_content.shape[0] >= 2:
        y = even_row_cull(rgb_content)
    else:
        y = rgb_content
    y = column_subsample_529(y)
    return dual_resample_to_grabber(y)


def vertical_row_energy(rgb: np.ndarray) -> dict:
    """Row-mean luma series stats — high freq → large adjacent-row diff."""
    # mean luma per row
    lu = rgb.astype(np.float64).mean(axis=(1, 2))
    d = np.abs(np.diff(lu))
    # period-2 energy: compare even vs odd row means
    even_m = float(lu[0::2].mean()) if lu.size >= 2 else float(lu.mean())
    odd_m = float(lu[1::2].mean()) if lu.size >= 2 else even_m
    return {
        "n_rows": int(lu.size),
        "luma_mean": float(lu.mean()),
        "luma_std": float(lu.std()),
        "rowdiff_mean": float(d.mean()) if d.size else 0.0,
        "rowdiff_max": float(d.max()) if d.size else 0.0,
        "even_odd_abs": abs(even_m - odd_m),
        "even_mean": even_m,
        "odd_mean": odd_m,
        "src": "measured_on_array",
    }
