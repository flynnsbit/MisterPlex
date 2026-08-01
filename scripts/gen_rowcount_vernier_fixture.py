#!/usr/bin/env python3
"""Precision row-count fixture: discriminate 480 vs ~475 delivered content rows.

Problem (rd-review / parent): product ARM vf
  scale=618:480:flags=fast_bilinear:force_original_aspect_ratio=decrease,
  pad=624:480:0+(618-iw)/2:0+(480-ih)/2:color=black
maps a 624x480 source → 618x475 then pads to 624x480 with **2 top + 3 bottom**
black rows (host-measured). Direct FFT pitch cannot separate 475 vs 480 on glass.

This fixture makes the difference **countable**:

A. **Edge pad probes** — full-width bright bars on source rows 0–3 and 476–479.
   After FORCE_SCALE pad they sit *inside* the active band; true 1:1 keeps them on
   the extreme rows. Metric: count of near-black rows at top/bottom of frame.

B. **Numbered fiducial ladder** — 4-row-thick white ticks at known source Y with a
   large-cell binary ID of the source row in a side strip (survives H.264 + bilinear).

C. **Vernier pair** — vertical square waves period 19 and 20 in adjacent body columns.
   Beat length L=19*20=380 source rows. After scale s=475/480, L' = 380*s ≈ 375.4.
   ΔL ≈ 4.6 source rows → after ~2× present/capture scale, tens of capture pixels.

Also: glass ID band, A/V flash+beep @2s (w-avsync), SAR 1:1, CB no-B, AAC 48k.

Host self-check applies identity vs product ARM vf and prints predicted metrics.
"""
from __future__ import annotations

import argparse
import json
import math
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from glass_frame_id import draw_id_band, format_text, geometry_for  # noqa: E402

W, H = 624, 480
FPS_NUM, FPS_DEN = 24, 1
SR = 48000
PERIOD_S = 2.0
FLASH_FRAMES = 2
BEEP_S = 0.050
ATTACK_S = 0.001
BEEP_HZ = 1000.0

# Product ARM vf (matches tests/unit/test_force_scale_sws_cost.sh)
ARM_VF = (
    "scale=618:480:flags=fast_bilinear:force_original_aspect_ratio=decrease,"
    "pad=624:480:0+(618-iw)/2:0+(480-ih)/2:color=black"
)

# Fiducial source centers (body-friendly + edges). 4-row thick bar centered on y.
# All fiducials at y>=100 so glass ID (y0..88) never covers them; edges separate.
FIDUCIAL_YS = [100, 130, 160, 190, 220, 250, 280, 310, 340, 370, 400, 430, 460]
VERN_P1, VERN_P2 = 19, 20  # beat 380
BIT_X0 = 8
BIT_CELL_W = 12
N_BITS = 9  # row index 0..511
VERN_X0 = 200
VERN_X1 = 360
VERN_X2 = 520


def write_beep(path: Path, duration_s: float) -> int:
    n = int(round(duration_s * SR))
    mono = np.zeros(n, dtype=np.float64)
    t = np.arange(n, dtype=np.float64) / SR
    k = 0
    n_on = 0
    while True:
        t0 = k * PERIOD_S
        if t0 >= duration_s:
            break
        i0 = int(round(t0 * SR))
        i1 = min(n, i0 + int(round(BEEP_S * SR)))
        if i0 < n and i1 > i0:
            phase = t[i0:i1] - t0
            env = np.where(phase < ATTACK_S, phase / ATTACK_S, 1.0)
            mono[i0:i1] = 0.9 * env * np.sin(2 * math.pi * BEEP_HZ * t[i0:i1])
            n_on += 1
        k += 1
    s16 = np.clip(mono * 32767.0, -32768, 32767).astype(np.int16)
    path.write_bytes(np.column_stack([s16, s16]).reshape(-1).tobytes())
    return n_on


def paint_row_bits(rgb: np.ndarray, y: int, value: int) -> None:
    """Paint N_BITS large cells encoding `value` on row y (and caller duplicates)."""
    for b in range(N_BITS):
        bit = (value >> (N_BITS - 1 - b)) & 1
        x0 = BIT_X0 + b * BIT_CELL_W
        x1 = x0 + BIT_CELL_W - 2
        rgb[y, x0:x1, :] = 240 if bit else 20


def render_frame(n: int, fps: float, id_bottom: int) -> np.ndarray:
    rgb = np.zeros((H, W, 3), dtype=np.uint8)
    # base mid grey full frame (no letterbox in source)
    rgb[:, :, :] = 64

    # --- Binary row index column (2-row paint) full height ---
    for y in range(H):
        paint_row_bits(rgb, y, y)
    for y in range(1, H, 2):
        rgb[y, BIT_X0 : BIT_X0 + N_BITS * BIT_CELL_W, :] = rgb[
            y - 1, BIT_X0 : BIT_X0 + N_BITS * BIT_CELL_W, :
        ]

    # --- Vernier: period 19 vs 20 (body + edges; ID may cover top later) ---
    ys = np.arange(H)[:, None]
    v19 = np.where((ys % VERN_P1) < (VERN_P1 // 2), 255, 30).astype(np.uint8)
    v20 = np.where((ys % VERN_P2) < (VERN_P2 // 2), 255, 30).astype(np.uint8)
    rgb[:, VERN_X0:VERN_X1, 0] = v19
    rgb[:, VERN_X0:VERN_X1, 1] = v19
    rgb[:, VERN_X0:VERN_X1, 2] = v19
    rgb[:, VERN_X1:VERN_X2, 0] = v20
    rgb[:, VERN_X1:VERN_X2, 1] = v20
    rgb[:, VERN_X1:VERN_X2, 2] = v20
    beat = np.where(v19 != v20, 255, 40).astype(np.uint8)
    rgb[:, VERN_X2 : VERN_X2 + 40, 0] = beat
    rgb[:, VERN_X2 : VERN_X2 + 40, 1] = (beat // 3).astype(np.uint8)
    rgb[:, VERN_X2 : VERN_X2 + 40, 2] = 40

    # --- Fiducial ticks (y>=100 only): 4-row white, full width except bit strip ---
    for yc in FIDUCIAL_YS:
        y0 = max(0, yc - 2)
        y1 = min(H, yc + 2)
        rgb[y0:y1, BIT_X0 + N_BITS * BIT_CELL_W :, :] = 255

    # A/V flash on vernier body only (not edges)
    t = n / fps
    k = int(round(t / PERIOD_S))
    t_m = k * PERIOD_S
    dn = int(round((t - t_m) * fps))
    if 0 <= dn < FLASH_FRAMES:
        rgb[id_bottom:H, VERN_X0:VERN_X2 + 40, :] = 255

    # Glass ID (overwrites y0..88)
    draw_id_band(rgb, n, geometry_for(W, H))

    # --- Edge pad probes LAST — must win over ID band ---
    # Full-width white on source rows 0–3 and 476–479. After product ARM vf these
    # sit inside the active band; pad inserts pure black outside them.
    rgb[0:4, :, :] = 255
    rgb[H - 4 : H, :, :] = 255
    return rgb

def encode(out: Path, duration_s: float, vbitrate: str, work: Path) -> dict:
    fps = FPS_NUM / float(FPS_DEN)
    fps_str = str(FPS_NUM)
    n_frames = int(round(duration_s * fps))
    geom = geometry_for(W, H)
    id_bottom = geom.bar_y1
    bufsize = str(int(vbitrate[:-1]) * 2) + "k" if vbitrate[-1] in "kK" else vbitrate
    work.mkdir(parents=True, exist_ok=True)
    out.parent.mkdir(parents=True, exist_ok=True)
    pcm = work / "beep.s16"
    n_beeps = write_beep(pcm, duration_s)

    enc = subprocess.Popen(
        [
            "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
            "-f", "rawvideo", "-pix_fmt", "rgb24",
            "-s", f"{W}x{H}", "-r", fps_str, "-i", "pipe:0",
            "-f", "s16le", "-ar", str(SR), "-ac", "2", "-i", str(pcm),
            "-filter_complex", "[0:v]setsar=1/1,setdar=624/480,format=yuv420p[v]",
            "-map", "[v]", "-map", "1:a:0",
            "-c:v", "libx264", "-profile:v", "baseline", "-bf", "0",
            "-x264-params", "cabac=0:ref=1:bframes=0:keyint=48",
            "-b:v", vbitrate, "-maxrate", vbitrate, "-bufsize", bufsize,
            "-r", fps_str,
            "-c:a", "aac", "-b:a", "128k", "-ar", str(SR), "-ac", "2",
            "-t", str(duration_s),
            "-movflags", "+faststart",
            str(out),
        ],
        stdin=subprocess.PIPE,
    )
    assert enc.stdin
    for i in range(n_frames):
        enc.stdin.write(render_frame(i, fps, id_bottom).tobytes())
        if (i + 1) % 500 == 0:
            print(f"  wrote {i+1}/{n_frames}", flush=True)
    enc.stdin.close()
    erc = enc.wait()
    print(f"encode_rc={erc} frames={n_frames} beeps={n_beeps}", flush=True)
    if erc != 0:
        raise SystemExit(erc)
    return {
        "n_frames": n_frames,
        "n_beeps": n_beeps,
        "id_bottom": id_bottom,
        "fiducial_ys": FIDUCIAL_YS,
        "vernier_periods": [VERN_P1, VERN_P2],
        "beat_source_rows": VERN_P1 * VERN_P2,
    }


def ffprobe(path: Path) -> dict:
    p = subprocess.run(
        [
            "ffprobe", "-v", "error", "-select_streams", "v:0",
            "-show_entries",
            "stream=width,height,sample_aspect_ratio,display_aspect_ratio,"
            "r_frame_rate,nb_frames,duration,profile,has_b_frames",
            "-of", "json", str(path),
        ],
        capture_output=True, text=True,
    )
    print(f"ffprobe_v true rc={p.returncode}", flush=True)
    return json.loads(p.stdout) if p.returncode == 0 else {"error": p.stderr, "rc": p.returncode}


def grab_decoded_gray(mp4: Path, n: int, work: Path) -> np.ndarray:
    png = work / f"dec_{n}.png"
    r = subprocess.run(
        [
            "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
            "-i", str(mp4), "-vf", f"select=eq(n\\,{n})",
            "-vsync", "0", "-vframes", "1", str(png),
        ]
    )
    print(f"grab_n{n} true rc={r.returncode}", flush=True)
    if r.returncode != 0:
        raise SystemExit(r.returncode)
    from PIL import Image
    rgb = np.array(Image.open(png).convert("RGB"))
    return (0.299 * rgb[:, :, 0] + 0.587 * rgb[:, :, 1] + 0.114 * rgb[:, :, 2]).astype(
        np.float64
    )


def apply_vf_gray(gray: np.ndarray, vf: str | None, work: Path, tag: str) -> np.ndarray:
    """gray HxW float → uint8 → ffmpeg vf → gray out."""
    raw_in = work / f"{tag}_in.gray"
    raw_out = work / f"{tag}_out.gray"
    g = np.clip(gray, 0, 255).astype(np.uint8)
    raw_in.write_bytes(g.tobytes())
    if vf is None:
        return gray.copy()
    cmd = [
        "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
        "-f", "rawvideo", "-pix_fmt", "gray", "-s", f"{W}x{H}", "-i", str(raw_in),
        "-vf", vf,
        "-frames:v", "1",
        "-f", "rawvideo", "-pix_fmt", "gray", str(raw_out),
    ]
    r = subprocess.run(cmd)
    print(f"vf_{tag} true rc={r.returncode}", flush=True)
    if r.returncode != 0:
        raise SystemExit(r.returncode)
    out = np.frombuffer(raw_out.read_bytes(), dtype=np.uint8)
    # pad guarantees 624x480
    return out.reshape(H, W).astype(np.float64)


def measure(gray: np.ndarray) -> dict:
    rm = gray.mean(axis=1)
    # pad: near-black rows from edges
    thr_pad = 24.0
    pad_top = 0
    for v in rm:
        if v < thr_pad:
            pad_top += 1
        else:
            break
    pad_bot = 0
    for v in rm[::-1]:
        if v < thr_pad:
            pad_bot += 1
        else:
            break
    active = np.where(rm >= thr_pad)[0]
    active_count = int(len(active))
    active_first = int(active[0]) if len(active) else None
    active_last = int(active[-1]) if len(active) else None

    # fiducial peaks: high row-mean local maxima
    # smooth slightly
    kernel = np.ones(3) / 3.0
    sm = np.convolve(rm, kernel, mode="same")
    peaks = []
    for y in range(2, H - 2):
        if sm[y] >= 200 and sm[y] >= sm[y - 1] and sm[y] >= sm[y + 1]:
            # subpixel centroid in ±2
            w = sm[y - 2 : y + 3]
            xs = np.arange(y - 2, y + 3)
            if w.sum() > 0:
                cy = float((xs * w).sum() / w.sum())
            else:
                cy = float(y)
            peaks.append(cy)
    # merge peaks closer than 3 rows
    merged = []
    for p in peaks:
        if not merged or p - merged[-1] > 3.0:
            merged.append(p)
        else:
            merged[-1] = 0.5 * (merged[-1] + p)

    span = (merged[-1] - merged[0]) if len(merged) >= 2 else None

    # vernier periods via acf on column means
    def acf_period(x0, x1):
        # Body-only: below glass ID / edge probes, above bottom edge probes
        y0b, y1b = 100, 460
        prof = gray[y0b:y1b, x0:x1].mean(axis=1)
        p0 = prof - prof.mean()
        if p0.std() < 1e-6:
            return None, float(p0.std())
        acf = np.correlate(p0, p0, mode="full")
        acf = acf[len(p0) - 1 :]
        acf = acf / (acf[0] + 1e-12)
        lim = min(80, len(acf) - 1)
        lag = int(np.argmax(acf[1:lim])) + 1
        return lag, float(prof.std())
    lag19, std19 = acf_period(VERN_X0, VERN_X1)
    lag20, std20 = acf_period(VERN_X1, VERN_X2)
    # beat profile
    beat_prof = gray[:, VERN_X2 : VERN_X2 + 40].mean(axis=1)
    if active_first is not None and active_last is not None:
        bp = beat_prof[active_first : active_last + 1]
    else:
        bp = beat_prof
    bp0 = bp - bp.mean()
    beat_lag = None
    if bp0.std() > 1e-6:
        acf = np.correlate(bp0, bp0, mode="full")
        acf = acf[len(bp0) - 1 :]
        acf = acf / (acf[0] + 1e-12)
        lim = min(len(acf) - 1, 450)
        # beat is long — search lag 200..450
        lo, hi = 200, min(450, lim)
        if hi > lo:
            beat_lag = int(np.argmax(acf[lo:hi])) + lo

    return {
        "pad_top_rows": pad_top,
        "pad_bot_rows": pad_bot,
        "pad_total": pad_top + pad_bot,
        "active_row_count": active_count,
        "active_first": active_first,
        "active_last": active_last,
        "n_fiducial_peaks": len(merged),
        "fiducial_peaks": [round(p, 3) for p in merged],
        "fiducial_span": None if span is None else round(span, 3),
        "vernier_lag19": lag19,
        "vernier_std19": round(std19, 2),
        "vernier_lag20": lag20,
        "vernier_std20": round(std20, 2),
        "beat_lag": beat_lag,
        "row_mean_head": [round(float(v), 2) for v in rm[:8]],
        "row_mean_tail": [round(float(v), 2) for v in rm[-8:]],
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--duration", type=float, default=120.0,
                    help="default 120s — precision test, not multi-hour soak")
    ap.add_argument("--vbitrate", default="3500k")
    ap.add_argument("--work", type=Path, default=None)
    args = ap.parse_args()
    work = args.work or Path(tempfile.mkdtemp(prefix="rowcount_"))
    work.mkdir(parents=True, exist_ok=True)

    print(
        f"PLAN 624x480 SAR1:1 fps=24/1 dur={args.duration} "
        f"fiducials={FIDUCIAL_YS} vernier={VERN_P1}/{VERN_P2} beat={VERN_P1*VERN_P2}",
        flush=True,
    )
    meta_enc = encode(args.out, args.duration, args.vbitrate, work)
    vmeta = ffprobe(args.out)

    # Host predictions on decoded frame 100 (non-flash)
    n = 100
    gray = grab_decoded_gray(args.out, n, work)
    m_id = measure(gray)
    m_arm = measure(apply_vf_gray(gray, ARM_VF, work, "arm"))

    # Theoretical beat
    beat_src = VERN_P1 * VERN_P2
    s_arm = 475 / 480.0
    pred = {
        "identity_no_force_scale": {
            "pad_top": 0,
            "pad_bot": 0,
            "active_rows": 480,
            "beat_lag_source_rows": beat_src,
            "fiducial_span_expect_approx": float(FIDUCIAL_YS[-1] - FIDUCIAL_YS[0]),
            "measured_on_decoded": m_id,
        },
        "product_arm_force_scale": {
            "pad_top": 2,
            "pad_bot": 3,
            "active_rows": 475,
            "scale_box": "618x480 decrease → 618x475 (ffprobe-measured)",
            "beat_lag_source_rows": beat_src * s_arm,
            "fiducial_span_expect_approx": (FIDUCIAL_YS[-1] - FIDUCIAL_YS[0]) * s_arm,
            "measured_after_arm_vf_on_decoded": m_arm,
            "arm_vf": ARM_VF,
        },
        "separation": {
            "delta_pad_total": 5,  # 0 vs 5
            "delta_active_rows": 5,  # 480 vs 475
            "delta_beat_rows": beat_src * (1 - s_arm),  # ~3.96
            "delta_fiducial_span_rows": (FIDUCIAL_YS[-1] - FIDUCIAL_YS[0]) * (1 - s_arm),
            "primary_metric": "pad_top+pad_bot black row count (0 vs 5) — unambiguous integers",
            "secondary_metric": "fiducial_span and n_fiducial_peaks",
            "tertiary_metric": "vernier beat_lag (~380 vs ~376)",
            "note_glass": (
                "Grabber/ascal rescale absolute row indices; prefer pad_total and "
                "relative span. Integer pad 0 vs 5 survives if coded edges reach glass."
            ),
        },
        "approach_evaluation": {
            "vernier_moire": (
                "WORKS as tertiary: Δbeat≈4 src rows. After ~2× to capture ~8 px — "
                "tight but countable with centroiding; host beat_lag may be noisy."
            ),
            "counted_fiducials": (
                "WORKS as secondary: 13 thick ticks; span shrinks by ~1% under ARM; "
                "peak count should stay 13 if none lost to pad (edge ticks may clip)."
            ),
            "edge_pad_probes": (
                "WORKS as PRIMARY: host-measured ARM pad_top=2 pad_bot=3. "
                "Identity pad=0. Integers far apart for grabber."
            ),
            "binary_row_column": (
                "PARTIAL: large 12px cells + 2-row paint survive H.264 better than 1px; "
                "bilinear merge under 475-scale blurs LSB — use for coarse confirm only."
            ),
        },
    }

    report = {
        "out": str(args.out),
        "size_bytes": args.out.stat().st_size,
        "caller_supplied": {
            "width": W,
            "height": H,
            "sar": "1:1",
            "fps": "24/1",
            "duration_s": args.duration,
            "arm_vf": ARM_VF,
            "fiducial_ys": FIDUCIAL_YS,
            "vernier": [VERN_P1, VERN_P2],
            **meta_enc,
        },
        "measured_ffprobe": vmeta,
        "predictions": pred,
        "frame_measured": n,
    }
    meta_path = args.out.with_suffix(args.out.suffix + ".meta.json")
    meta_path.write_text(json.dumps(report, indent=2))
    print(json.dumps({"predictions": pred, "ffprobe": vmeta}, indent=2), flush=True)
    print(f"OK {args.out} meta={meta_path}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
