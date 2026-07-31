#!/usr/bin/env python3
"""Overlay STRING READ-BACK instrument for MiSTerPlex transport OSD.

Acceptance criterion for the user's #1 open bug (low-res player overlay):
  render a known string → capture → template-match glyphs → assert EXACT recovery.

Why not lattice-pitch
---------------------
Parent killed the lattice-pitch metric: its vertical arm is vacuous (DE pitch is
1 by construction for both perfect and catastrophic renders) and its horizontal
arm is defeated by anti-aliasing. Read-back is immune to AA, nearest-neighbour
and emboldening — it catches the specific corruption mode:

  present_core.sv STORE_Y_SCALE = 131072 (= 2.0) so only even store rows are
  fetched; drawText (playback_overlay.hpp) emits scale×scale blocks from a
  7-row 5-wide glyph. At scale=1, alternate glyph rows are DELETED:
    '8' → looks like '0', '6' → looks like 'C', "STOPPED" becomes mush.

Glyph source of truth
---------------------
host/libmisterplex/playback_overlay.hpp :: PlaybackOverlay::glyph / drawText
  5×7 bitmaps, advance 6*scale, white-ish on dark translucent panel.

Verdicts / exit codes
---------------------
  READBACK_OK     rc=0   expected string recovered exactly (score ≥ threshold)
  READBACK_FAIL   rc=1   string present enough to attempt, recovery wrong/weak
  UNSCORED        rc=77  no panel / no legible glyphs — never a pass

This tool does NOT touch hardware. Parent supplies PNGs.

Usage
-----
  tools/overlay_string_readback.py FRAME.png --expect STOPPED
  tools/overlay_string_readback.py DIR/ --expect STOPPED
  tools/overlay_string_readback.py --self-test
  tools/overlay_string_readback.py --synth-row-delete --expect STOPPED  # RED proof
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any

import numpy as np
from PIL import Image

RC_OK = 0
RC_FAIL = 1
RC_UNSCORED = 77

# Exact 5×7 glyphs from playback_overlay.hpp (MSB = left column bit 4).
GLYPHS: dict[str, tuple[int, ...]] = {
    " ": (0, 0, 0, 0, 0, 0, 0),
    "0": (0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E),
    "1": (0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E),
    "2": (0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F),
    "3": (0x1E, 0x01, 0x01, 0x0E, 0x01, 0x01, 0x1E),
    "4": (0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02),
    "5": (0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E),
    "6": (0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E),
    "7": (0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08),
    "8": (0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E),
    "9": (0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C),
    ":": (0x00, 0x04, 0x04, 0x00, 0x04, 0x04, 0x00),
    "A": (0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11),
    "D": (0x1E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1E),
    "E": (0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F),
    "G": (0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0F),
    "I": (0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E),
    "L": (0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F),
    "N": (0x11, 0x19, 0x15, 0x13, 0x11, 0x11, 0x11),
    "O": (0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E),
    "P": (0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10),
    "S": (0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E),
    "T": (0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04),
    "U": (0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E),
    "Y": (0x11, 0x11, 0x0A, 0x04, 0x04, 0x04, 0x04),
}

# Default alphabet for free decode (state labels + digits + colon).
DEFAULT_ALPHABET = "0123456789:ADEILNOPSTUY "

# Match thresholds (design). Perfect synthetic scores ~1.0; low-res evidence
# must fall well below. Never weaken to pass a broken frame.
CELL_SCORE_MIN = 0.55  # per-glyph NCC-like score to accept a cell
STRING_SCORE_MIN = 0.72  # mean cell score for READBACK_OK
STRING_COVER_MIN = 0.85  # fraction of non-space cells accepted


def render_glyph_mask(ch: str, scale: int = 1) -> np.ndarray:
    """Render one glyph as uint8 mask {0,255}, shape (7*scale, 5*scale)."""
    g = GLYPHS.get(ch, GLYPHS[" "])
    h, w = 7 * scale, 5 * scale
    out = np.zeros((h, w), dtype=np.uint8)
    for row in range(7):
        bits = g[row]
        for col in range(5):
            if bits & (1 << (4 - col)):
                y0, x0 = row * scale, col * scale
                out[y0 : y0 + scale, x0 : x0 + scale] = 255
    return out


def render_string_mask(text: str, scale: int = 1) -> np.ndarray:
    """Render text as binary mask; advance = 6*scale (matches drawText)."""
    if not text:
        return np.zeros((7 * scale, 1), dtype=np.uint8)
    advance = 6 * scale
    gw = 5 * scale
    gh = 7 * scale
    # last glyph has no trailing gap in textWidth, but drawText still advances;
    # for matching we include full advance * n for search window simplicity.
    width = advance * len(text) - scale  # matches textWidth
    width = max(gw, width)
    out = np.zeros((gh, width), dtype=np.uint8)
    x = 0
    for ch in text:
        g = render_glyph_mask(ch, scale)
        out[:, x : x + gw] = np.maximum(out[:, x : x + gw], g)
        x += advance
    return out


def apply_store_y_scale_delete(rgb: np.ndarray, factor: int = 2) -> np.ndarray:
    """Simulate STORE_Y_SCALE row-delete: keep every factor-th row, nearest upsample.

    factor=2 matches STORE_Y_SCALE=131072 (=2.0) — odd store rows never fetched.
    """
    h, w = rgb.shape[:2]
    kept = rgb[::factor].copy()
    # Nearest-neighbour stretch back to original height (what a 2.0 store map does).
    ys = (np.arange(h) // factor).clip(0, kept.shape[0] - 1)
    return kept[ys]


def panel_roi(rgb: np.ndarray) -> tuple[int, int, int, int]:
    """Bottom transport panel bounds matching playback_overlay panelBounds."""
    h, w = rgb.shape[:2]
    margin = max(8, w // 32)
    ph = min(72, max(54, h // 4))
    x0 = margin
    y0 = h - ph - margin
    return x0, y0, w - margin * 2, ph


def _ncc(a: np.ndarray, b: np.ndarray) -> float:
    """Normalized correlation on float arrays same shape. Returns [-1,1]."""
    af = a.astype(np.float64).ravel()
    bf = b.astype(np.float64).ravel()
    af = af - af.mean()
    bf = bf - bf.mean()
    denom = float(np.linalg.norm(af) * np.linalg.norm(bf))
    if denom < 1e-9:
        # Both flat — only "match" if both near-zero ink.
        return 1.0 if (a.max() < 1 and b.max() < 1) else 0.0
    return float(np.dot(af, bf) / denom)


def _ink_iou(a: np.ndarray, b: np.ndarray, thr: float = 0.35) -> float:
    """IoU of binary ink masks after per-patch normalization."""
    af = a.astype(np.float64)
    bf = b.astype(np.float64)
    if af.max() > 0:
        af = af / af.max()
    if bf.max() > 0:
        bf = bf / bf.max()
    am = af >= thr
    bm = bf >= thr
    inter = np.logical_and(am, bm).sum()
    union = np.logical_or(am, bm).sum()
    if union == 0:
        return 1.0 if (not am.any() and not bm.any()) else 0.0
    return float(inter) / float(union)


def cell_score(patch: np.ndarray, tmpl: np.ndarray) -> float:
    """Combined score in [0,1] for a glyph cell vs template mask."""
    # patch: float luma of cell; tmpl: 0/255 mask
    if patch.shape != tmpl.shape:
        return 0.0
    t = tmpl.astype(np.float64) / 255.0
    # Invert if text is dark-on-light (shouldn't be on panel, but be safe).
    p = patch.astype(np.float64)
    if p.mean() > 127:
        p = 255.0 - p
    # Emphasize ink: high luma = candidate ink on dark panel.
    ncc = _ncc(p, t * 255.0)
    iou = _ink_iou(p, t * 255.0)
    # Map ncc [-1,1] → [0,1]
    n01 = (ncc + 1.0) * 0.5
    return 0.55 * n01 + 0.45 * iou


def extract_panel_luma(rgb: np.ndarray) -> tuple[np.ndarray, tuple[int, int, int, int]]:
    x0, y0, pw, ph = panel_roi(rgb)
    panel = rgb[y0 : y0 + ph, x0 : x0 + pw]
    luma = (
        0.2126 * panel[:, :, 0].astype(np.float64)
        + 0.7152 * panel[:, :, 1].astype(np.float64)
        + 0.0722 * panel[:, :, 2].astype(np.float64)
    )
    return luma, (x0, y0, pw, ph)


def _fast_template_response(luma: np.ndarray, tmpl: np.ndarray) -> np.ndarray:
    """Valid correlation map of tmpl over luma via FFT (same-dtype float).

    Returns array shaped (H-th+1, W-tw+1) with values in roughly [-1, 1]
    (zero-mean normalized cross-correlation approximation).
    """
    th, tw = tmpl.shape
    H, W = luma.shape
    if H < th or W < tw:
        return np.zeros((0, 0), dtype=np.float64)

    t = tmpl.astype(np.float64)
    t = t - t.mean()
    t_norm = np.linalg.norm(t)
    if t_norm < 1e-9:
        return np.zeros((H - th + 1, W - tw + 1), dtype=np.float64)
    t = t / t_norm

    # Integral images for local mean / energy of luma patches.
    img = luma.astype(np.float64)
    # pad for easy window sums
    s = np.pad(img, ((1, 0), (1, 0)), mode="constant")
    s2 = np.pad(img * img, ((1, 0), (1, 0)), mode="constant")
    cs = s.cumsum(0).cumsum(1)
    cs2 = s2.cumsum(0).cumsum(1)

    def win_sum(csum: np.ndarray) -> np.ndarray:
        # csum is (H+1, W+1)
        return (
            csum[th:, tw:]
            - csum[:-th, tw:]
            - csum[th:, :-tw]
            + csum[:-th, :-tw]
        )

    sum_p = win_sum(cs)
    sum_p2 = win_sum(cs2)
    n = float(th * tw)
    mean_p = sum_p / n
    # var * n = sum(x^2) - n*mean^2
    var_n = np.maximum(sum_p2 - n * mean_p * mean_p, 0.0)
    norm_p = np.sqrt(var_n)
    norm_p = np.maximum(norm_p, 1e-9)

    # Cross-correlation via FFT
    out_h = H - th + 1
    out_w = W - tw + 1
    fft_h = 1 << int(np.ceil(np.log2(H + th - 1)))
    fft_w = 1 << int(np.ceil(np.log2(W + tw - 1)))
    F = np.fft.rfft2(img, s=(fft_h, fft_w))
    # Flip template for correlation
    T = np.fft.rfft2(t[::-1, ::-1], s=(fft_h, fft_w))
    corr_full = np.fft.irfft2(F * T, s=(fft_h, fft_w))
    # Alignment: after flip, valid top-left is at (th-1, tw-1)
    corr = corr_full[th - 1 : th - 1 + out_h, tw - 1 : tw - 1 + out_w]
    # Subtract mean contribution: sum(patch)*0 since t is zero-mean already
    # NCC ≈ corr / norm_p  (t already unit norm)
    ncc = corr / norm_p
    return ncc


def find_string(
    luma: np.ndarray,
    expect: str,
    *,
    scale: int = 1,
    alphabet: str | None = None,
) -> dict[str, Any]:
    """Locate `expect` in panel luma via FFT coarse match + per-cell decode.

    Geometry (playback_overlay.hpp):
      panelBounds → label at (iconX+24, panel.y+10) = roughly left-upper panel.
    """
    expect = expect.upper()
    alphabet = alphabet or (expect + DEFAULT_ALPHABET)
    seen: set[str] = set()
    chars: list[str] = []
    for c in alphabet.upper():
        if c not in seen and c in GLYPHS:
            seen.add(c)
            chars.append(c)

    gh = 7 * scale
    gw = 5 * scale
    advance = 6 * scale
    tw = max(gw, advance * len(expect) - scale)

    H, W = luma.shape
    # Prefer the canonical label band; fall back to full upper panel if needed.
    y_lo = max(0, min(H - gh, 4 * scale))
    y_hi = min(H - gh, max(y_lo, int(H * 0.65)))
    x_lo = max(0, int(W * 0.01))
    x_hi = min(W - tw, max(x_lo, int(W * 0.60)))

    region = luma[y_lo : y_hi + gh, x_lo : x_hi + tw]
    templates = {c: render_glyph_mask(c, scale).astype(np.float64) for c in chars}
    full_tmpl = render_string_mask(expect, scale).astype(np.float64)

    best: dict[str, Any] = {
        "score": -1.0,
        "mean_cell": 0.0,
        "cover": 0.0,
        "x": 0,
        "y": 0,
        "decoded": "",
        "cell_scores": [],
        "scale": scale,
    }

    if region.shape[0] < gh or region.shape[1] < tw:
        return best

    # Coarse: FFT NCC of full string template over region.
    ncc_map = _fast_template_response(region, full_tmpl)
    if ncc_map.size == 0:
        return best

    # Take top-K peaks (and a few geometry priors near icon+label).
    flat = ncc_map.ravel()
    k = min(40, flat.size)
    if k <= 0:
        return best
    # argpartition top-k
    idx = np.argpartition(flat, -k)[-k:]
    peaks = [(int(i // ncc_map.shape[1]), int(i % ncc_map.shape[1]), float(flat[i])) for i in idx]
    # Geometry prior (panel-local): icon cx = 22, label at iconX+24 → x≈46, y≈10.
    label_x_panel = 22 + 24  # matches drawText(iconX+24, labelY, ...)
    label_y_panel = 10
    prior_x = max(0, min(ncc_map.shape[1] - 1, label_x_panel - x_lo))
    prior_y = max(0, min(ncc_map.shape[0] - 1, label_y_panel - y_lo))
    peaks.append((prior_y, prior_x, float(ncc_map[prior_y, prior_x])))
    # Seed a small grid around prior (handles mild letterbox / scale drift).
    for dy in range(-6, 7):
        for dx in range(-12, 13, 2):
            yy = prior_y + dy
            xx = prior_x + dx
            if 0 <= yy < ncc_map.shape[0] and 0 <= xx < ncc_map.shape[1]:
                peaks.append((yy, xx, float(ncc_map[yy, xx])))

    # Dedup peaks
    seen_xy: set[tuple[int, int]] = set()
    cand_xy: list[tuple[int, int, float]] = []
    for yy, xx, sc in sorted(peaks, key=lambda t: -t[2]):
        key = (yy, xx)
        if key in seen_xy:
            continue
        seen_xy.add(key)
        cand_xy.append((yy, xx, sc))
        if len(cand_xy) >= 60:
            break

    def decode_at(x_abs: int, y_abs: int) -> dict[str, Any]:
        cell_scores: list[float] = []
        decoded_chars: list[str] = []
        ok_cells = 0
        scored_cells = 0
        for i, ch in enumerate(expect):
            cx = x_abs + i * advance
            cell = luma[y_abs : y_abs + gh, cx : cx + gw]
            if cell.shape != (gh, gw):
                cell_scores.append(0.0)
                decoded_chars.append("?")
                continue
            local_best_ch = "?"
            local_best_s = -1.0
            for cand in chars:
                s = cell_score(cell, templates[cand])
                if s > local_best_s:
                    local_best_s = s
                    local_best_ch = cand
            decoded_chars.append(local_best_ch)
            if ch != " ":
                scored_cells += 1
                s_exp = cell_score(cell, templates[ch])
                cell_scores.append(s_exp)
                if s_exp >= CELL_SCORE_MIN and local_best_ch == ch:
                    ok_cells += 1
            else:
                cell_scores.append(local_best_s)
        if scored_cells == 0:
            return {"score": -1.0, "mean_cell": 0.0, "cover": 0.0, "decoded": ""}
        mean_s = float(np.mean([s for s, c in zip(cell_scores, expect) if c != " "]))
        cover = ok_cells / scored_cells
        place = 0.6 * mean_s + 0.4 * cover
        return {
            "score": place,
            "mean_cell": mean_s,
            "cover": cover,
            "x": x_abs,
            "y": y_abs,
            "decoded": "".join(decoded_chars),
            "cell_scores": [round(s, 3) for s in cell_scores],
            "scale": scale,
        }

    for yy, xx, _sc in cand_xy:
        # Refine ±1 around coarse peak
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                y_abs = y_lo + yy + dy
                x_abs = x_lo + xx + dx
                if y_abs < 0 or x_abs < 0 or y_abs + gh > H or x_abs + tw > W:
                    continue
                got = decode_at(x_abs, y_abs)
                if got["score"] > best["score"]:
                    best = got

    return best


def score_frame(
    path: str | Path,
    expect: str,
    *,
    scales: tuple[int, ...] = (1, 2),
) -> dict[str, Any]:
    path = Path(path)
    rgb = np.array(Image.open(path).convert("RGB"))
    luma, roi = extract_panel_luma(rgb)
    # Panel must be darkish with some bright ink — otherwise UNSCORED.
    if float(luma.mean()) > 80 and float(luma.std()) < 8:
        return {
            "path": str(path),
            "verdict": "UNSCORED",
            "rc": RC_UNSCORED,
            "reason": "panel_not_dark_overlay",
            "expect": expect,
            "decoded": "",
            "roi": roi,
        }
    if float(luma.max()) - float(luma.min()) < 15:
        return {
            "path": str(path),
            "verdict": "UNSCORED",
            "rc": RC_UNSCORED,
            "reason": "panel_flat_no_ink",
            "expect": expect,
            "decoded": "",
            "roi": roi,
        }

    best: dict[str, Any] | None = None
    for sc in scales:
        got = find_string(luma, expect, scale=sc)
        if best is None or got["score"] > best["score"]:
            best = got
    assert best is not None

    decoded = str(best.get("decoded") or "")
    mean_cell = float(best.get("mean_cell") or 0.0)
    cover = float(best.get("cover") or 0.0)
    exact = decoded == expect.upper()
    strong = (
        exact
        and mean_cell >= STRING_SCORE_MIN
        and cover >= STRING_COVER_MIN
    )
    weak_attempt = mean_cell >= 0.35 or cover >= 0.4 or best["score"] >= 0.35

    if strong:
        verdict, rc = "READBACK_OK", RC_OK
        reason = (
            f"exact_recovery decoded={decoded!r} mean_cell={mean_cell:.3f} "
            f"cover={cover:.3f} scale={best['scale']}"
        )
    elif weak_attempt:
        verdict, rc = "READBACK_FAIL", RC_FAIL
        reason = (
            f"recovery_failed expect={expect!r} decoded={decoded!r} "
            f"mean_cell={mean_cell:.3f} cover={cover:.3f} "
            f"score={best['score']:.3f} scale={best['scale']} "
            f"(row-delete/AA-corrupt class)"
        )
    else:
        verdict, rc = "UNSCORED", RC_UNSCORED
        reason = (
            f"insufficient_glyph_signal expect={expect!r} decoded={decoded!r} "
            f"score={best['score']:.3f}"
        )

    return {
        "path": str(path),
        "verdict": verdict,
        "rc": rc,
        "reason": reason,
        "expect": expect.upper(),
        "decoded": decoded,
        "mean_cell": round(mean_cell, 4),
        "cover": round(cover, 4),
        "score": round(float(best["score"]), 4),
        "cell_scores": best.get("cell_scores"),
        "scale": best.get("scale"),
        "xy": (best.get("x"), best.get("y")),
        "roi": roi,
        "exact": exact,
    }


def synth_clean_overlay(
    w: int = 640,
    h: int = 480,
    text: str = "STOPPED",
    scale: int = 1,
) -> np.ndarray:
    """Synthesize a panel+label matching drawText geometry (clean GREEN fixture)."""
    rgb = np.zeros((h, w, 3), dtype=np.uint8)
    rgb[:, :] = (32, 34, 38)
    margin = max(8, w // 32)
    ph = min(72, max(54, h // 4))
    x0 = margin
    y0 = h - ph - margin
    pw = w - margin * 2
    # Panel
    rgb[y0 : y0 + ph, x0 : x0 + pw] = (8, 8, 10)
    # Amber stop icon (square)
    icx, icy = x0 + 22, y0 + 20
    rgb[icy - 9 : icy + 9, icx - 9 : icx + 9] = (255, 178, 32)
    # Label
    lx = icx + 24
    ly = y0 + 10
    mask = render_string_mask(text, scale)
    gh, gw = mask.shape
    # White text
    for yy in range(gh):
        for xx in range(gw):
            if mask[yy, xx]:
                y, x = ly + yy, lx + xx
                if 0 <= y < h and 0 <= x < w:
                    rgb[y, x] = (235, 238, 244)
    # Timecodes
    tmask = render_string_mask("0:00", scale)
    ty = y0 + 34
    for yy in range(tmask.shape[0]):
        for xx in range(tmask.shape[1]):
            if tmask[yy, xx]:
                y, x = ty + yy, x0 + 16 + xx
                if 0 <= y < h and 0 <= x < w:
                    rgb[y, x] = (235, 238, 244)
    return rgb


def _self_test() -> int:
    import tempfile

    # Keep scratch inside the repo (agent rule: never write /tmp for our artifacts).
    scratch_root = Path(__file__).resolve().parents[1] / ".agent-work" / "overlay-readback"
    scratch_root.mkdir(parents=True, exist_ok=True)

    # 1) Clean synthetic STOPPED → READBACK_OK
    clean = synth_clean_overlay(640, 480, "STOPPED", 1)
    with tempfile.TemporaryDirectory(prefix="ovl_rb_", dir=str(scratch_root)) as td:
        tdp = Path(td)
        p_clean = tdp / "clean.png"
        Image.fromarray(clean).save(p_clean)
        r0 = score_frame(p_clean, "STOPPED")
        assert r0["rc"] == RC_OK, r0
        assert r0["decoded"] == "STOPPED", r0

        # 2) STORE_Y_SCALE=2 row-delete on clean → READBACK_FAIL (RED proof)
        broken = apply_store_y_scale_delete(clean, factor=2)
        p_brk = tdp / "rowdel.png"
        Image.fromarray(broken).save(p_brk)
        r1 = score_frame(p_brk, "STOPPED")
        assert r1["rc"] == RC_FAIL, r1
        assert r1["decoded"] != "STOPPED" or r1["mean_cell"] < STRING_SCORE_MIN, r1

        # 3) Digit corruption class: clean "8" vs row-deleted reads as not-8
        eight = synth_clean_overlay(320, 240, "8", 1)
        eight_b = apply_store_y_scale_delete(eight, 2)
        Image.fromarray(eight).save(tdp / "e.png")
        Image.fromarray(eight_b).save(tdp / "eb.png")
        re = score_frame(tdp / "e.png", "8")
        reb = score_frame(tdp / "eb.png", "8")
        assert re["rc"] == RC_OK, re
        assert reb["rc"] == RC_FAIL, reb

    # 4) Glyph bitmaps match known 'S' / 'O' ink counts
    s = render_glyph_mask("S", 1)
    assert s.shape == (7, 5)
    assert int(s.sum() // 255) > 5

    print("SELF_TEST_OK")
    return 0


def _print_human(rep: dict[str, Any]) -> None:
    print(f"src={rep.get('path')}")
    print(
        f"expect={rep.get('expect')!r} decoded={rep.get('decoded')!r} "
        f"exact={rep.get('exact')} mean_cell={rep.get('mean_cell')} "
        f"cover={rep.get('cover')} score={rep.get('score')} "
        f"scale={rep.get('scale')} xy={rep.get('xy')}"
    )
    print(f"reason={rep.get('reason')}")
    print(f"VERDICT={rep.get('verdict')} rc={rep.get('rc')}")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("inputs", nargs="*", help="PNG frame(s) or directory")
    ap.add_argument(
        "--expect",
        default="STOPPED",
        help="exact string that must be recovered (default STOPPED)",
    )
    ap.add_argument(
        "--scale",
        type=int,
        default=0,
        help="force glyph scale (0=try 1 then 2)",
    )
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument(
        "--synth-row-delete",
        action="store_true",
        help="synthesize clean STOPPED, apply STORE_Y_SCALE=2 row-delete, score it (expect FAIL)",
    )
    ap.add_argument(
        "--synth-clean",
        action="store_true",
        help="synthesize clean STOPPED and score it (expect OK)",
    )
    ap.add_argument(
        "--write-synth",
        default=None,
        help="optional path to write the synthetic RGB used by --synth-*",
    )
    args = ap.parse_args(argv)

    if args.self_test:
        return _self_test()

    scales: tuple[int, ...]
    if args.scale and args.scale > 0:
        scales = (args.scale,)
    else:
        scales = (1, 2)

    if args.synth_clean or args.synth_row_delete:
        rgb = synth_clean_overlay(1920, 1080, args.expect.upper(), 1)
        if args.synth_row_delete:
            rgb = apply_store_y_scale_delete(rgb, 2)
        if args.write_synth:
            Image.fromarray(rgb).save(args.write_synth)
        import tempfile

        scratch_root = Path(__file__).resolve().parents[1] / ".agent-work" / "overlay-readback"
        scratch_root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="ovl_rb_run_", dir=str(scratch_root)) as td:
            p = Path(td) / "frame.png"
            Image.fromarray(rgb).save(p)
            rep = score_frame(p, args.expect, scales=scales)
        if args.json:
            print(json.dumps(rep, indent=2))
        else:
            _print_human(rep)
        return int(rep["rc"])

    if not args.inputs:
        ap.error("provide PNG inputs (or --self-test / --synth-*)")

    frames: list[str] = []
    for inp in args.inputs:
        p = Path(inp)
        if p.is_dir():
            found = sorted({str(x) for x in list(p.glob("*.png")) + list(p.glob("f_*.png"))})
            frames.extend(found)
        elif p.is_file():
            frames.append(str(p))
        else:
            print(f"ERROR: not found: {inp}", file=sys.stderr)
            return RC_UNSCORED

    if not frames:
        print("ERROR: no PNG frames", file=sys.stderr)
        return RC_UNSCORED

    # Multi-frame: worst hard fail wins; all-unscored → 77; any OK without fail → 0.
    reports = [score_frame(f, args.expect, scales=scales) for f in frames]
    fails = [r for r in reports if r["rc"] == RC_FAIL]
    oks = [r for r in reports if r["rc"] == RC_OK]
    if fails:
        rep = fails[0]
        # Prefer the lowest mean_cell fail as representative.
        rep = min(fails, key=lambda r: float(r.get("mean_cell") or 0))
        rep = dict(rep)
        rep["frames"] = len(frames)
        rep["fail_frames"] = len(fails)
        rep["ok_frames"] = len(oks)
    elif oks:
        rep = dict(oks[0])
        rep["frames"] = len(frames)
        rep["ok_frames"] = len(oks)
    else:
        rep = dict(reports[0])
        rep["frames"] = len(frames)

    if args.json:
        print(json.dumps({"summary": rep, "per_frame": reports}, indent=2))
    else:
        if len(frames) > 1:
            print(
                f"frames={len(frames)} ok={len(oks)} fail={len(fails)} "
                f"unscored={len(frames) - len(oks) - len(fails)}"
            )
        _print_human(rep)
    return int(rep["rc"])


if __name__ == "__main__":
    sys.exit(main())
