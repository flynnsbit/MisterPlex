#!/usr/bin/env python3
"""Self-verify A/V marker alignment on a glass-sync fixture FILE (no device).

Measures:
  - ffprobe geometry/rate/nb_frames/profile (src=measured)
  - body-luma flash thr-crossings vs designed marker times
  - audio beep onsets vs designed times
  - median offset_ms = (t_audio - t_video)*1000  (same sign as avsync_measure_hdmi)

PASS if measured median offset within --tol-ms of --expect-offset-ms.
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
from glass_frame_id import BAR_Y1, decode_bars_from_rgb  # noqa: E402


def run(cmd: list[str]) -> tuple[int, str, str]:
    p = subprocess.run(cmd, capture_output=True, text=True)
    return p.returncode, p.stdout, p.stderr


def ffprobe(path: Path) -> dict:
    rc, out, err = run([
        "ffprobe", "-v", "error",
        "-show_entries",
        "stream=codec_type,width,height,r_frame_rate,avg_frame_rate,nb_frames,"
        "profile,has_b_frames,codec_name,sample_rate,duration",
        "-show_entries", "format=duration,size",
        "-of", "json", str(path),
    ])
    if rc != 0:
        raise SystemExit(f"ffprobe failed true_rc={rc} err={err[:300]}")
    return json.loads(out)


def load_body_luma_series(path: Path, id_bottom: int = BAR_Y1) -> tuple[np.ndarray, np.ndarray, float]:
    """Return (t_s, body_mean_luma, fps) by decoding raw frames."""
    meta = ffprobe(path)
    vs = next(s for s in meta["streams"] if s.get("codec_type") == "video")
    w, h = int(vs["width"]), int(vs["height"])
    r = vs["r_frame_rate"]
    num, den = (int(x) for x in r.split("/")) if "/" in r else (int(r), 1)
    fps = num / float(den)
    proc = subprocess.Popen(
        ["ffmpeg", "-hide_banner", "-loglevel", "error",
         "-i", str(path), "-f", "rawvideo", "-pix_fmt", "rgb24", "-an", "pipe:1"],
        stdout=subprocess.PIPE,
    )
    assert proc.stdout
    fb = w * h * 3
    lumas = []
    while True:
        buf = proc.stdout.read(fb)
        if len(buf) < fb:
            break
        rgb = np.frombuffer(buf, dtype=np.uint8).reshape((h, w, 3))
        body = rgb[id_bottom:, :, :].astype(np.float64)
        lumas.append(float(body.mean()))
    proc.wait()
    lu = np.asarray(lumas, dtype=np.float64)
    t = np.arange(lu.size, dtype=np.float64) / fps
    return t, lu, fps


def detect_flash_onsets(t: np.ndarray, lu: np.ndarray, min_sep: float = 1.0) -> tuple[list[float], dict]:
    """Same thr rule as avsync_measure_hdmi (floor_p20+0.5*contrast), step/interp."""
    meta: dict = {}
    if lu.size < 3:
        return [], {"reason": "too_few"}
    floor = float(np.percentile(lu, 20))
    peak = float(np.percentile(lu, 99.5))
    contrast = peak - floor
    meta["luma_floor"] = floor
    meta["luma_peak"] = peak
    meta["luma_contrast"] = contrast
    if contrast < 40:
        meta["reason"] = "insufficient_contrast"
        return [], meta
    thr = floor + 0.50 * contrast
    meta["threshold"] = thr
    STEP_RISE_FRAC = 0.70
    hot = lu > thr
    onsets: list[float] = []
    n_step = n_interp = 0
    i = 0
    while i < hot.size:
        if not hot[i]:
            i += 1
            continue
        if i == 0 or not hot[i - 1]:
            if i == 0:
                ts = float(t[i])
            else:
                y0, y1 = float(lu[i - 1]), float(lu[i])
                t0, t1 = float(t[i - 1]), float(t[i])
                rise = y1 - y0
                if rise >= STEP_RISE_FRAC * contrast and t1 > t0:
                    ts = t1
                    n_step += 1
                elif y1 > y0 and t1 > t0:
                    frac = (thr - y0) / (y1 - y0)
                    frac = max(0.0, min(1.0, frac))
                    ts = t0 + frac * (t1 - t0)
                    n_interp += 1
                else:
                    ts = t1
                    n_step += 1
            if not onsets or (ts - onsets[-1]) >= min_sep:
                onsets.append(ts)
        while i < hot.size and hot[i]:
            i += 1
    meta["n_flashes"] = len(onsets)
    meta["flash_onset_n_step"] = n_step
    meta["flash_onset_n_interp"] = n_interp
    return onsets, meta


def load_audio_pcm(path: Path, sr: int = 48000) -> np.ndarray:
    """Mono float64 -1..1 from file audio, resampled to sr."""
    with tempfile.NamedTemporaryFile(suffix=".f32", delete=False) as tmp:
        tmp_path = Path(tmp.name)
    try:
        rc, _, err = run([
            "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
            "-i", str(path), "-ac", "1", "-ar", str(sr),
            "-f", "f32le", str(tmp_path),
        ])
        if rc != 0:
            raise SystemExit(f"audio extract failed true_rc={rc} {err[:200]}")
        raw = tmp_path.read_bytes()
        return np.frombuffer(raw, dtype=np.float32).astype(np.float64)
    finally:
        tmp_path.unlink(missing_ok=True)


def detect_beep_onsets(audio: np.ndarray, sr: int, min_sep: float = 1.0) -> tuple[list[float], dict]:
    """Envelope onset: 1 ms hop energy, thr mid floor/peak, 1 kHz-ish via broadband env."""
    hop = max(1, int(sr * 0.001))  # 1 ms
    n = audio.size
    if n < hop * 4:
        return [], {"reason": "short_audio"}
    # RMS env
    n_h = n // hop
    env = np.zeros(n_h, dtype=np.float64)
    for i in range(n_h):
        block = audio[i * hop : (i + 1) * hop]
        env[i] = float(np.sqrt(np.mean(block * block)) + 1e-12)
    floor = float(np.percentile(env, 20))
    peak = float(np.percentile(env, 99.5))
    contrast = peak - floor
    meta = {
        "env_floor": floor,
        "env_peak": peak,
        "env_contrast": contrast,
        "hop_s": hop / sr,
        "hop_s_src": "caller_supplied",
    }
    if contrast < 1e-4:
        meta["reason"] = "no_audio_contrast"
        return [], meta
    thr = floor + 0.30 * contrast  # attack is sharp; 30% catches early onset
    meta["threshold"] = thr
    hot = env > thr
    onsets: list[float] = []
    i = 0
    while i < hot.size:
        if not hot[i]:
            i += 1
            continue
        if i == 0 or not hot[i - 1]:
            # linear interp on env for sub-hop
            if i == 0:
                ts = 0.0
            else:
                y0, y1 = float(env[i - 1]), float(env[i])
                t0 = (i - 1) * hop / sr
                t1 = i * hop / sr
                if y1 > y0:
                    frac = (thr - y0) / (y1 - y0)
                    frac = max(0.0, min(1.0, frac))
                    ts = t0 + frac * (t1 - t0)
                else:
                    ts = t1
            if not onsets or (ts - onsets[-1]) >= min_sep:
                onsets.append(ts)
        while i < hot.size and hot[i]:
            i += 1
    meta["n_beeps"] = len(onsets)
    return onsets, meta


def pair_offsets(t_v: list[float], t_a: list[float], max_abs: float = 0.5) -> list[float]:
    """For each video onset, nearest audio within max_abs s → offset a-v."""
    offs = []
    for tv in t_v:
        if not t_a:
            break
        ta = min(t_a, key=lambda x: abs(x - tv))
        d = ta - tv
        if abs(d) <= max_abs:
            offs.append(d * 1000.0)
    return offs


def spot_bars(path: Path, indices: list[int]) -> list[dict]:
    out = []
    with tempfile.TemporaryDirectory() as td:
        for n in indices:
            png = Path(td) / f"f{n}.png"
            rc, _, _ = run([
                "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
                "-i", str(path), "-vf", f"select=eq(n\\,{n})",
                "-vsync", "0", "-vframes", "1", str(png),
            ])
            if rc != 0 or not png.exists():
                out.append({"n": n, "ok": False, "reason": "extract"})
                continue
            from PIL import Image
            rgb = np.array(Image.open(png).convert("RGB"))
            r = decode_bars_from_rgb(rgb)
            out.append({"n": n, "ok": r.ok, "decoded": r.n, "status": r.status, "reason": r.reason})
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--mp4", type=Path, required=True)
    ap.add_argument("--expect-offset-ms", type=float, required=True)
    ap.add_argument("--tol-ms", type=float, default=5.0,
                    help="PASS if |median_meas - expect| <= tol (file-level)")
    ap.add_argument("--period-s", type=float, default=2.0)
    ap.add_argument("--json-out", type=Path, default=None)
    args = ap.parse_args()

    report: dict = {
        "mp4": str(args.mp4),
        "expect_offset_ms": args.expect_offset_ms,
        "expect_offset_ms_src": "caller_supplied",
        "tol_ms": args.tol_ms,
    }

    # ffprobe
    meta = ffprobe(args.mp4)
    vs = next(s for s in meta["streams"] if s.get("codec_type") == "video")
    aus = [s for s in meta["streams"] if s.get("codec_type") == "audio"]
    a0 = aus[0] if aus else {}
    report["ffprobe"] = {
        "width": vs.get("width"),
        "height": vs.get("height"),
        "r_frame_rate": vs.get("r_frame_rate"),
        "avg_frame_rate": vs.get("avg_frame_rate"),
        "nb_frames": vs.get("nb_frames"),
        "profile": vs.get("profile"),
        "has_b_frames": vs.get("has_b_frames"),
        "duration_v": vs.get("duration"),
        "audio_codec": a0.get("codec_name"),
        "sample_rate": a0.get("sample_rate"),
        "format_duration": meta.get("format", {}).get("duration"),
        "src": "measured",
    }
    print("FFPROBE", json.dumps(report["ffprobe"]))

    # video flashes
    print("decode body luma...", flush=True)
    t, lu, fps = load_body_luma_series(args.mp4)
    report["fps_from_r_frame_rate"] = fps
    report["fps_src"] = "measured_r_frame_rate"
    report["n_frames_decoded"] = int(lu.size)
    flashes, fmeta = detect_flash_onsets(t, lu, min_sep=args.period_s * 0.5)
    report["flash"] = {"onsets_s_head": flashes[:5], "n": len(flashes), **fmeta, "src": "measured"}
    print(f"FLASH n={len(flashes)} n_interp={fmeta.get('flash_onset_n_interp')} "
          f"n_step={fmeta.get('flash_onset_n_step')} contrast={fmeta.get('luma_contrast')}")

    # audio
    print("decode audio...", flush=True)
    audio = load_audio_pcm(args.mp4, 48000)
    beeps, bmeta = detect_beep_onsets(audio, 48000, min_sep=args.period_s * 0.5)
    report["beep"] = {"onsets_s_head": beeps[:5], "n": len(beeps), **bmeta, "src": "measured"}
    print(f"BEEP n={len(beeps)} hop_s={bmeta.get('hop_s')}")

    offs = pair_offsets(flashes, beeps, max_abs=0.5)
    report["n_pairs"] = len(offs)
    if offs:
        med = float(np.median(offs))
        report["offset_ms_median"] = med
        report["offset_ms_mean"] = float(np.mean(offs))
        report["offset_ms_min"] = float(np.min(offs))
        report["offset_ms_max"] = float(np.max(offs))
        report["offset_ms_src"] = "measured"
    else:
        med = None
        report["offset_ms_median"] = None
        report["offset_ms_src"] = "measured_empty"

    # bar spot-check on a few frames including a flash-neighbour
    bar_idx = [0, 48, 2358 if lu.size > 2358 else lu.size // 2, max(0, lu.size - 1)]
    bars = spot_bars(args.mp4, bar_idx)
    report["bar_spot"] = bars
    bar_ok = all(b.get("ok") and b.get("decoded") == b.get("n") for b in bars)
    report["bar_spot_ok"] = bar_ok
    print("BAR_SPOT", bars, "ok", bar_ok)

    # verdict
    fail = []
    if report["ffprobe"].get("width") != 624 or report["ffprobe"].get("height") != 480:
        fail.append(f"geom {report['ffprobe'].get('width')}x{report['ffprobe'].get('height')}")
    if report["ffprobe"].get("r_frame_rate") != "24/1":
        fail.append(f"r_frame_rate={report['ffprobe'].get('r_frame_rate')}")
    if str(report["ffprobe"].get("profile")) != "Constrained Baseline":
        fail.append(f"profile={report['ffprobe'].get('profile')}")
    hb = report["ffprobe"].get("has_b_frames")
    if hb is None or int(hb) != 0:
        fail.append("has_b_frames")
    if not offs:
        fail.append("no_pairs")
    else:
        err = abs(med - args.expect_offset_ms)
        report["offset_abs_err_ms"] = err
        if err > args.tol_ms:
            fail.append(f"offset_median={med:.3f} expect={args.expect_offset_ms} err={err:.3f}>{args.tol_ms}")
    if not bar_ok:
        fail.append("bar_spot")
    # flash count roughly duration/period
    dur = float(report["ffprobe"].get("format_duration") or 0)
    expect_n = int(math.floor((dur - 1e-6) / args.period_s)) + (1 if dur > 0 else 0)
    # markers at 0.. while < duration; last at floor((D-eps)/P)*P
    report["expect_n_markers_approx"] = expect_n
    if len(flashes) < max(1, expect_n - 2):
        fail.append(f"flash_count={len(flashes)} expect~{expect_n}")

    report["fail"] = fail
    report["pass"] = len(fail) == 0
    print(
        f"OFFSET_MS median={med} expect={args.expect_offset_ms} "
        f"tol={args.tol_ms} n_pairs={len(offs)} src=measured"
    )
    if args.json_out:
        args.json_out.write_text(json.dumps(report, indent=2))
        print("JSON", args.json_out)

    if fail:
        print("AVSYNC_GLASS_FIXTURE_FAIL", fail)
        return 1
    print("AVSYNC_GLASS_FIXTURE_OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
