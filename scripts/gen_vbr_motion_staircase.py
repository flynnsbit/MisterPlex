#!/usr/bin/env python3
"""VBR motion-staircase fixtures — force path starvation deterministically.

Parent hypothesis (post-retraction): rk=9 collapses when VBR spikes toward the
Plex 2000 kbit/s cap on high-motion scenes, while low-motion fits the path.
Sustained path capability (parent, corrected): median ~84 KB/s ≈ **670 kbit/s**,
not the retracted long-window ~107 KB/s mean.

This generator builds:
  1. STAIRCASE — alternating LOW-motion / HIGH-motion segments (default 20 s),
     encoded **VBR under maxVideoBitrate-like cap** (CRF + maxrate=2000k) so
     instantaneous bitrate swings. Transition timestamps published in meta.
  2. CBR_MEAN — CBR at the *measured mean* of the staircase (same content).
     Discriminator: if staircase collapses at HIGH transitions and CBR does not
     → VBR spiking confirmed.
  3. CBR_LOW — CBR well under path (~400 kbit/s video) — must never collapse.
  4. Optional non-bank twin (640x480) of staircase for FORCE_SCALE residual.

Every frame: glass ID ``G n=DDDDDD c=C`` (draw_id_band, no enable=).
Contract: H.264 Constrained Baseline, level 3.0, B=0, AAC 48 kHz stereo.
Rate: **24/1** exactly (measured, never assumed 23.976).

Usage:
  python3 scripts/gen_vbr_motion_staircase.py --duration 360 --copy-media
"""
from __future__ import annotations

import argparse
import json
import math
import re
import shutil
import subprocess
import sys
import wave
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from glass_frame_id import draw_id_band, format_text, geometry_for  # noqa: E402

FPS_NUM, FPS_DEN = 24, 1
FPS_STR = "24"
SR = 48000
A_BITRATE = "96k"  # stereo AAC — pin; not the axis
SEG_S_DEFAULT = 20.0
VBR_MAXRATE_K = 2000  # plex_resolve 480p floor maxVideoBitrate
VBR_CRF = 23
CBR_LOW_K = 400
# path sustained ~670 kbit/s total → video budget ~550 after audio; low=400 safe


def segment_kind(t: float, seg_s: float) -> str:
    """Even segments LOW (static), odd HIGH (full entropy)."""
    idx = int(math.floor(t / seg_s + 1e-12))
    return "LOW" if (idx % 2 == 0) else "HIGH"


def transition_times(duration_s: float, seg_s: float) -> list[dict]:
    out = []
    t = 0.0
    idx = 0
    while t < duration_s - 1e-9:
        t1 = min(duration_s, t + seg_s)
        kind = "LOW" if (idx % 2 == 0) else "HIGH"
        out.append(
            {
                "index": idx,
                "kind": kind,
                "t0_s": round(t, 6),
                "t1_s": round(t1, 6),
                "duration_s": round(t1 - t, 6),
            }
        )
        t = t1
        idx += 1
    return out


def render_frame(n: int, w: int, h: int, geom, seg_s: float, fps: float) -> np.ndarray:
    """LOW: near-static lifted field. HIGH: full-frame high-entropy motion."""
    t = n / fps
    kind = segment_kind(t, seg_s)
    rgb = np.empty((h, w, 3), dtype=np.uint8)
    id_bottom = geom.bar_y1
    body = slice(id_bottom, h)

    if kind == "LOW":
        # near-static: slow vertical gradient + tiny drift (encodes cheap)
        phase = (n // 48) % 8  # changes ~0.3 Hz
        base = 70 + phase * 2
        yy = np.linspace(base, base + 25, h, dtype=np.float32)[:, None]
        rgb[:, :, 0] = np.clip(yy, 0, 255).astype(np.uint8)
        rgb[:, :, 1] = np.clip(yy + 8, 0, 255).astype(np.uint8)
        rgb[:, :, 2] = np.clip(yy + 16, 0, 255).astype(np.uint8)
        # one slow bar so freeze still detectable without bitrate spike
        x = (n // 4) % max(1, w - 40)
        rgb[body, x : x + 40, :] = (200, 180, 40)
    else:
        # HIGH: independent high-contrast noise every frame + sweeping bars
        rng = np.random.default_rng(n * 2654435761 & 0xFFFFFFFF)
        noise = rng.integers(0, 256, size=(h, w, 3), dtype=np.uint8)
        rgb[:, :, :] = noise
        # structured motion on top (edges / diagonals) — hard for P-skip
        ys = np.arange(h)[:, None]
        xs = np.arange(w)[None, :]
        stripe = ((xs + n * 17 + ys * 3) % 32) < 10
        rgb[stripe] = (255, 255, 255)
        rgb[~stripe & (noise[:, :, 0] > 200)] = (0, 0, 0)
        # large bouncing block
        bw, bh = max(80, w // 5), max(60, (h - id_bottom) // 3)
        x = int(abs((n * 11) % (2 * max(1, w - bw)) - max(1, w - bw)))
        y = id_bottom + int(abs((n * 7) % (2 * max(1, h - id_bottom - bh)) - max(1, h - id_bottom - bh)))
        rgb[y : y + bh, x : x + bw] = (255, 40, 40)

    # red chroma bar always (low impact on HIGH already red-ish)
    ry0 = id_bottom + 4
    rgb[ry0 : ry0 + 8, w // 10 : 9 * w // 10] = (220, 30, 30)

    draw_id_band(rgb, n, geom)  # EVERY frame — no enable=
    return rgb


def write_audio_wav(path: Path, duration_s: float) -> None:
    n = int(round(duration_s * SR))
    t = np.arange(n, dtype=np.float64) / float(SR)
    mono = 0.04 * np.sin(2 * np.pi * 440.0 * t)
    # soft tick every 2 s (not experimental axis)
    k = 0
    while True:
        t0 = k * 2.0
        if t0 >= duration_s:
            break
        i0 = int(t0 * SR)
        i1 = min(n, i0 + int(0.015 * SR))
        if i0 < n:
            mono[i0:i1] = 0.2
        k += 1
    s16 = np.clip(mono * 32767.0, -32768, 32767).astype(np.int16)
    stereo = np.column_stack([s16, s16])
    with wave.open(str(path), "w") as wf:
        wf.setnchannels(2)
        wf.setsampwidth(2)
        wf.setframerate(SR)
        wf.writeframes(stereo.astype(np.int16).tobytes())


def sps_trace(path: Path) -> dict:
    p = subprocess.run(
        [
            "ffmpeg", "-hide_banner", "-i", str(path),
            "-c:v", "copy", "-bsf:v", "trace_headers",
            "-frames:v", "2", "-f", "null", "-",
        ],
        capture_output=True,
        text=True,
    )
    text = (p.stderr or "") + (p.stdout or "")

    def grab(name: str):
        m = re.search(rf"{name}\s+[01]+\s+=\s+(\d+)", text)
        return int(m.group(1)) if m else None

    return {
        "trace_rc": p.returncode,
        "profile_idc": grab("profile_idc"),
        "level_idc": grab("level_idc"),
        "max_num_ref_frames": grab("max_num_ref_frames"),
        "constraint_set0_flag": grab("constraint_set0_flag"),
        "constraint_set1_flag": grab("constraint_set1_flag"),
    }


def ffprobe_full(path: Path) -> dict:
    p = subprocess.run(
        [
            "ffprobe", "-v", "error", "-select_streams", "v:0",
            "-show_entries",
            "stream=width,height,r_frame_rate,avg_frame_rate,nb_frames,"
            "profile,level,has_b_frames,codec_name,bit_rate",
            "-show_entries", "format=duration,size,bit_rate",
            "-of", "json", str(path),
        ],
        capture_output=True,
        text=True,
    )
    data = json.loads(p.stdout) if p.stdout.strip() else {}
    ca = subprocess.run(
        [
            "ffprobe", "-v", "error", "-select_streams", "a:0",
            "-show_entries", "stream=codec_name,sample_rate,channels,bit_rate",
            "-of", "json", str(path),
        ],
        capture_output=True,
        text=True,
    )
    adata = json.loads(ca.stdout) if ca.stdout.strip() else {}
    st = (data.get("streams") or [{}])[0]
    fmt = data.get("format") or {}
    ast = (adata.get("streams") or [{}])[0]

    def ik(x):
        if x in (None, "N/A"):
            return None
        return int(x)

    v_br, a_br, f_br = ik(st.get("bit_rate")), ik(ast.get("bit_rate")), ik(fmt.get("bit_rate"))
    return {
        "ffprobe_v_rc": p.returncode,
        "ffprobe_a_rc": ca.returncode,
        "width": st.get("width"),
        "height": st.get("height"),
        "r_frame_rate": st.get("r_frame_rate"),
        "avg_frame_rate": st.get("avg_frame_rate"),
        "nb_frames": st.get("nb_frames"),
        "profile": st.get("profile"),
        "level": st.get("level"),
        "has_b_frames": st.get("has_b_frames"),
        "v_bit_rate": v_br,
        "v_bit_rate_k": (v_br / 1000.0) if v_br else None,
        "format_duration": fmt.get("duration"),
        "format_bit_rate": f_br,
        "format_bit_rate_k": (f_br / 1000.0) if f_br else None,
        "size_bytes": ik(fmt.get("size")),
        "a_codec": ast.get("codec_name"),
        "a_sample_rate": ast.get("sample_rate"),
        "a_channels": ast.get("channels"),
        "a_bit_rate": a_br,
        "a_bit_rate_k": (a_br / 1000.0) if a_br else None,
        "sps": sps_trace(path),
    }


def measure_segment_bitrates(path: Path, transitions: list[dict]) -> list[dict]:
    """Per-segment mean video bitrate via packet sizes (ffprobe -show_packets)."""
    p = subprocess.run(
        [
            "ffprobe", "-v", "error", "-select_streams", "v:0",
            "-show_entries", "packet=pts_time,size,flags",
            "-of", "csv=p=0", str(path),
        ],
        capture_output=True,
        text=True,
    )
    if p.returncode != 0:
        return [{"error": f"packets_rc={p.returncode}"}]
    rows = []
    for line in p.stdout.splitlines():
        parts = line.strip().split(",")
        if len(parts) < 2:
            continue
        try:
            # pts_time,size or size may be N/A
            t = float(parts[0]) if parts[0] not in ("N/A", "") else None
            sz = int(parts[1]) if parts[1] not in ("N/A", "") else 0
        except ValueError:
            continue
        if t is None:
            continue
        rows.append((t, sz))
    out = []
    for seg in transitions:
        t0, t1 = seg["t0_s"], seg["t1_s"]
        bytes_ = sum(sz for t, sz in rows if t0 <= t < t1)
        dur = max(1e-6, t1 - t0)
        kbit = (bytes_ * 8 / dur) / 1000.0
        out.append({**seg, "meas_v_kbit_s": round(kbit, 2), "packet_bytes": bytes_})
    return out


def encode_raw_pipe(
    out: Path,
    *,
    w: int,
    h: int,
    n_frames: int,
    seg_s: float,
    mode: str,
    cbr_k: int | None,
    vbr_max_k: int,
    vbr_crf: int,
) -> dict:
    fps = FPS_NUM / float(FPS_DEN)
    geom = geometry_for(w, h)
    duration_s = n_frames / fps
    out.parent.mkdir(parents=True, exist_ok=True)
    work = out.parent / f".work_{out.stem}"
    work.mkdir(parents=True, exist_ok=True)
    wav = work / "a.wav"
    write_audio_wav(wav, duration_s + 0.5)

    if mode == "vbr":
        # CRF + maxrate cap ≈ Plex VBR under maxVideoBitrate
        rate_args = [
            "-crf", str(vbr_crf),
            "-maxrate", f"{vbr_max_k}k",
            "-bufsize", f"{vbr_max_k * 2}k",
        ]
        x264 = f"cabac=0:ref=1:bframes=0:keyint=48:level=30:vbv-maxrate={vbr_max_k}:vbv-bufsize={vbr_max_k * 2}"
    elif mode == "cbr":
        assert cbr_k is not None
        rate_args = [
            "-b:v", f"{cbr_k}k",
            "-maxrate", f"{cbr_k}k",
            "-bufsize", f"{cbr_k * 2}k",
        ]
        x264 = f"cabac=0:ref=1:bframes=0:keyint=48:level=30:vbv-maxrate={cbr_k}:vbv-bufsize={cbr_k * 2}"
    else:
        raise ValueError(mode)

    enc = [
        "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
        "-f", "rawvideo", "-pix_fmt", "rgb24",
        "-s", f"{w}x{h}", "-r", FPS_STR, "-i", "pipe:0",
        "-i", str(wav),
        "-map", "0:v:0", "-map", "1:a:0",
        "-c:v", "libx264", "-profile:v", "baseline", "-level:v", "3.0", "-bf", "0",
        "-x264-params", x264,
        "-pix_fmt", "yuv420p",
        *rate_args,
        "-r", FPS_STR,
        "-c:a", "aac", "-b:a", A_BITRATE, "-ar", str(SR), "-ac", "2",
        "-shortest", "-movflags", "+faststart",
        str(out),
    ]
    print(f"ENCODE {mode} {out.name} {w}x{h} n={n_frames}", flush=True)
    print("  CMD", " ".join(enc), flush=True)
    proc = subprocess.Popen(enc, stdin=subprocess.PIPE)
    assert proc.stdin
    try:
        step = max(1, n_frames // 20)
        for i in range(n_frames):
            proc.stdin.write(render_frame(i, w, h, geom, seg_s, fps).tobytes())
            if (i + 1) % step == 0:
                print(f"  frames {i+1}/{n_frames}", flush=True)
    finally:
        proc.stdin.close()
        rc = proc.wait()
    print(f"  ffmpeg_rc={rc}", flush=True)
    if rc != 0:
        raise SystemExit(f"encode failed rc={rc}")
    try:
        wav.unlink(missing_ok=True)
        work.rmdir()
    except OSError:
        pass
    return {"ffmpeg_rc": rc, "cmd": enc, "mode": mode}


def reencode_cbr_from(src: Path, out: Path, cbr_k: int, w: int, h: int) -> dict:
    """Same content timeline → true CBR (minrate=maxrate, nal-hrd=cbr)."""
    x264 = (
        f"cabac=0:ref=1:bframes=0:keyint=48:level=30:nal-hrd=cbr:force-cfr=1:"
        f"vbv-maxrate={cbr_k}:vbv-bufsize={cbr_k}"
    )
    cmd = [
        "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
        "-i", str(src),
        "-vf", f"scale={w}:{h}:flags=bicubic,setsar=1/1",
        "-c:v", "libx264", "-profile:v", "baseline", "-level:v", "3.0", "-bf", "0",
        "-x264-params", x264,
        "-pix_fmt", "yuv420p",
        "-b:v", f"{cbr_k}k", "-minrate", f"{cbr_k}k", "-maxrate", f"{cbr_k}k",
        "-bufsize", f"{cbr_k}k",
        "-r", FPS_STR,
        "-c:a", "aac", "-b:a", A_BITRATE, "-ar", str(SR), "-ac", "2",
        "-movflags", "+faststart",
        str(out),
    ]
    print(f"REENCODE CBR {out.name} {cbr_k}k", flush=True)
    print("  CMD", " ".join(cmd), flush=True)
    p = subprocess.run(cmd, capture_output=True, text=True)
    print(f"  ffmpeg_rc={p.returncode}", flush=True)
    if p.returncode != 0:
        sys.stderr.write(p.stderr[-2000:] if p.stderr else "")
        raise SystemExit(f"cbr reencode rc={p.returncode}")
    return {"ffmpeg_rc": p.returncode, "cmd": cmd, "mode": "cbr"}


def spec_ok(m: dict, *, w: int, h: int) -> list[str]:
    fails = []
    if m.get("width") != w or m.get("height") != h:
        fails.append("geom")
    if m.get("r_frame_rate") != "24/1":
        fails.append(f"fps={m.get('r_frame_rate')}")
    if m.get("profile") != "Constrained Baseline":
        fails.append(f"prof={m.get('profile')}")
    if int(m.get("level") or 99) > 30:
        fails.append(f"L={m.get('level')}")
    if int(m.get("has_b_frames") or 0) != 0:
        fails.append("B")
    if (m.get("sps") or {}).get("max_num_ref_frames") not in (1, None):
        if (m.get("sps") or {}).get("max_num_ref_frames") != 1:
            fails.append(f"refs={m.get('sps',{}).get('max_num_ref_frames')}")
    if m.get("a_codec") != "aac" or str(m.get("a_sample_rate")) != "48000":
        fails.append("audio")
    if int(m.get("a_channels") or 0) != 2:
        fails.append(f"ach={m.get('a_channels')}")
    return fails


def prereg(role: str, mean_k: float | None, low_seg_k: float | None, high_seg_k: float | None) -> dict:
    """Path sustained ~670 kbit/s (84 KB/s median)."""
    path = 670.0
    if role == "staircase_vbr":
        return {
            "role": role,
            "expected": (
                "HEALTHY on LOW segments (supply≈0.95–1.0, pfps≈23–24, drops flat); "
                "COLLAPSE or stress on HIGH segments if high_seg instantaneous > path "
                "(supply dips, drops climb, pfps falls) aligned to published t0 transitions."
            ),
            "expected_supply_ratio_LOW": "≈0.95–1.00",
            "expected_supply_ratio_HIGH": "≪1 if high_seg_kbit ≫ 670 (e.g. 0.7–0.9)",
            "expected_pfps_LOW": "≈23.3–24.0",
            "expected_pfps_HIGH": "dip if starved",
            "expected_drops_trend": "flat on LOW; climb during HIGH if hypothesis holds",
            "path_kbit_s": path,
            "note": "Align collapse clock to HIGH t0_s in transitions table.",
        }
    if role == "cbr_mean":
        return {
            "role": role,
            "expected": (
                "If VBR-spike hypothesis TRUE: CBR at staircase mean stays healthier than "
                "staircase during HIGH windows (no transition-locked collapse). "
                "If FALSE: CBR behaves like staircase (both collapse or neither)."
            ),
            "expected_supply_ratio": "stable near 1.0 if mean≪path; stressed if mean≳path",
            "expected_pfps": "≈23–24 if mean under path",
            "expected_drops_trend": "no HIGH-transition-locked climb if VBR is the cause",
            "mean_v_kbit_target": mean_k,
            "path_kbit_s": path,
            "discriminator": "staircase collapses @ HIGH AND cbr_mean does not → VBR confirmed",
        }
    if role == "cbr_low":
        return {
            "role": role,
            "expected": "NEVER collapse: supply≈0.97–1.0, pfps≈23.5–24, drops flat entire run",
            "expected_supply_ratio": "≈0.97–1.00",
            "expected_pfps": "≈23.5–24.0",
            "expected_drops_trend": "flat / near-zero growth",
            "cbr_v_kbit": CBR_LOW_K,
            "path_kbit_s": path,
        }
    return {"role": role, "expected": "unknown"}


def title(w, h, tag, duration_s) -> str:
    ds = int(round(duration_s))
    return f"MiSTerPlex VBRStair {w}x{h} 24fps {tag} {ds}s (2026).mp4"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--duration", type=float, default=360.0, help="seconds (≥ several segments)")
    ap.add_argument("--seg", type=float, default=SEG_S_DEFAULT, help="segment length seconds")
    ap.add_argument("--out-dir", type=Path, default=ROOT / "assets" / "avsync")
    ap.add_argument("--media-dir", type=Path, default=Path.home() / "plex" / "media" / "movies")
    ap.add_argument("--copy-media", action="store_true")
    ap.add_argument("--vbr-maxrate-k", type=int, default=VBR_MAXRATE_K)
    ap.add_argument("--vbr-crf", type=int, default=VBR_CRF)
    ap.add_argument("--cbr-low-k", type=int, default=CBR_LOW_K)
    ap.add_argument("--skip-nonbank", action="store_true")
    args = ap.parse_args()

    fps = FPS_NUM / float(FPS_DEN)
    n_frames = int(round(args.duration * fps))
    duration_s = n_frames / fps
    transitions = transition_times(duration_s, args.seg)
    args.out_dir.mkdir(parents=True, exist_ok=True)

    clips = []

    # --- 1) bank staircase VBR ---
    w, h = 624, 480
    stem = f"vbr_stair_{w}x{h}_24_vbrmax{args.vbr_maxrate_k}_{int(duration_s)}s"
    stair_path = args.out_dir / f"{stem}.mp4"
    enc = encode_raw_pipe(
        stair_path,
        w=w, h=h, n_frames=n_frames, seg_s=args.seg,
        mode="vbr", cbr_k=None,
        vbr_max_k=args.vbr_maxrate_k, vbr_crf=args.vbr_crf,
    )
    m = ffprobe_full(stair_path)
    seg_br = measure_segment_bitrates(stair_path, transitions)
    low_ks = [s["meas_v_kbit_s"] for s in seg_br if s.get("kind") == "LOW" and "meas_v_kbit_s" in s]
    high_ks = [s["meas_v_kbit_s"] for s in seg_br if s.get("kind") == "HIGH" and "meas_v_kbit_s" in s]
    mean_low = float(np.mean(low_ks)) if low_ks else None
    mean_high = float(np.mean(high_ks)) if high_ks else None
    mean_all = m.get("v_bit_rate_k")
    # CBR mean target = round measured mean video bitrate
    cbr_mean_k = int(round(mean_all)) if mean_all else 800
    fails = spec_ok(m, w=w, h=h)
    print(
        f"  STAIR meas mean_v={mean_all} low_seg≈{mean_low} high_seg≈{mean_high} "
        f"→ cbr_mean_k={cbr_mean_k} fails={fails}",
        flush=True,
    )
    t_stair = title(w, h, f"stairVBR_max{args.vbr_maxrate_k}", duration_s)
    meta = {
        "title": t_stair,
        "role": "staircase_vbr",
        "seg_s": args.seg,
        "transitions": transitions,
        "segment_bitrates": seg_br,
        "mean_v_kbit_s": mean_all,
        "mean_LOW_seg_kbit_s": mean_low,
        "mean_HIGH_seg_kbit_s": mean_high,
        "vbr_maxrate_k": args.vbr_maxrate_k,
        "vbr_crf": args.vbr_crf,
        "fps_rational": "24/1",
        "measured": m,
        "fails": fails,
        "prereg": prereg("staircase_vbr", mean_all, mean_low, mean_high),
        "ffmpeg_cmd": enc["cmd"],
        "bank_fit": "favourable",
    }
    (stair_path.with_suffix(stair_path.suffix + ".meta.json")).write_text(
        json.dumps(meta, indent=2) + "\n"
    )
    if args.copy_media:
        dest = args.media_dir / t_stair
        shutil.copy2(stair_path, dest)
        meta["media_path"] = str(dest)
        print(f"  COPIED {dest}", flush=True)
    clips.append(meta)

    # --- 2) CBR at mean (same content via reencode) ---
    stem_m = f"vbr_stair_{w}x{h}_24_cbrMean{cbr_mean_k}_{int(duration_s)}s"
    cbr_mean_path = args.out_dir / f"{stem_m}.mp4"
    enc_m = reencode_cbr_from(stair_path, cbr_mean_path, cbr_mean_k, w, h)
    mm = ffprobe_full(cbr_mean_path)
    fails_m = spec_ok(mm, w=w, h=h)
    t_mean = title(w, h, f"cbrMean{cbr_mean_k}k", duration_s)
    meta_m = {
        "title": t_mean,
        "role": "cbr_mean",
        "cbr_kbit": cbr_mean_k,
        "source_staircase": str(stair_path),
        "seg_s": args.seg,
        "transitions": transitions,
        "fps_rational": "24/1",
        "measured": mm,
        "fails": fails_m,
        "prereg": prereg("cbr_mean", cbr_mean_k, mean_low, mean_high),
        "ffmpeg_cmd": enc_m["cmd"],
        "bank_fit": "favourable",
    }
    (cbr_mean_path.with_suffix(cbr_mean_path.suffix + ".meta.json")).write_text(
        json.dumps(meta_m, indent=2) + "\n"
    )
    if args.copy_media:
        dest = args.media_dir / t_mean
        shutil.copy2(cbr_mean_path, dest)
        meta_m["media_path"] = str(dest)
        print(f"  COPIED {dest}", flush=True)
    clips.append(meta_m)
    print(f"  CBR_MEAN meas_v={mm.get('v_bit_rate_k')} fails={fails_m}", flush=True)

    # --- 3) CBR low control (same content) ---
    stem_l = f"vbr_stair_{w}x{h}_24_cbrLow{args.cbr_low_k}_{int(duration_s)}s"
    cbr_low_path = args.out_dir / f"{stem_l}.mp4"
    enc_l = reencode_cbr_from(stair_path, cbr_low_path, args.cbr_low_k, w, h)
    ml = ffprobe_full(cbr_low_path)
    fails_l = spec_ok(ml, w=w, h=h)
    t_low = title(w, h, f"cbrLow{args.cbr_low_k}k", duration_s)
    meta_l = {
        "title": t_low,
        "role": "cbr_low",
        "cbr_kbit": args.cbr_low_k,
        "source_staircase": str(stair_path),
        "seg_s": args.seg,
        "transitions": transitions,
        "fps_rational": "24/1",
        "measured": ml,
        "fails": fails_l,
        "prereg": prereg("cbr_low", args.cbr_low_k, None, None),
        "ffmpeg_cmd": enc_l["cmd"],
        "bank_fit": "favourable",
    }
    (cbr_low_path.with_suffix(cbr_low_path.suffix + ".meta.json")).write_text(
        json.dumps(meta_l, indent=2) + "\n"
    )
    if args.copy_media:
        dest = args.media_dir / t_low
        shutil.copy2(cbr_low_path, dest)
        meta_l["media_path"] = str(dest)
        print(f"  COPIED {dest}", flush=True)
    clips.append(meta_l)
    print(f"  CBR_LOW meas_v={ml.get('v_bit_rate_k')} fails={fails_l}", flush=True)

    # --- 4) non-bank staircase VBR ---
    if not args.skip_nonbank:
        w2, h2 = 640, 480
        stem2 = f"vbr_stair_{w2}x{h2}_24_vbrmax{args.vbr_maxrate_k}_{int(duration_s)}s"
        stair2 = args.out_dir / f"{stem2}.mp4"
        enc2 = encode_raw_pipe(
            stair2, w=w2, h=h2, n_frames=n_frames, seg_s=args.seg,
            mode="vbr", cbr_k=None,
            vbr_max_k=args.vbr_maxrate_k, vbr_crf=args.vbr_crf,
        )
        m2 = ffprobe_full(stair2)
        seg2 = measure_segment_bitrates(stair2, transitions)
        fails2 = spec_ok(m2, w=w2, h=h2)
        t2 = title(w2, h2, f"stairVBR_max{args.vbr_maxrate_k}", duration_s)
        meta2 = {
            "title": t2,
            "role": "staircase_vbr_nonbank",
            "seg_s": args.seg,
            "transitions": transitions,
            "segment_bitrates": seg2,
            "mean_v_kbit_s": m2.get("v_bit_rate_k"),
            "vbr_maxrate_k": args.vbr_maxrate_k,
            "vbr_crf": args.vbr_crf,
            "fps_rational": "24/1",
            "measured": m2,
            "fails": fails2,
            "prereg": prereg("staircase_vbr", m2.get("v_bit_rate_k"), None, None),
            "ffmpeg_cmd": enc2["cmd"],
            "bank_fit": "adversarial",
        }
        (stair2.with_suffix(stair2.suffix + ".meta.json")).write_text(
            json.dumps(meta2, indent=2) + "\n"
        )
        if args.copy_media:
            dest = args.media_dir / t2
            shutil.copy2(stair2, dest)
            meta2["media_path"] = str(dest)
            print(f"  COPIED {dest}", flush=True)
        clips.append(meta2)
        print(f"  NONBANK meas_v={m2.get('v_bit_rate_k')} fails={fails2}", flush=True)

    # docs
    docs = ROOT / "docs"
    docs.mkdir(exist_ok=True)
    lines = [
        "# VBR motion staircase (path starvation discriminator)",
        "",
        "**Hypothesis:** VBR spikes on high-motion toward maxVideoBitrate=2000 starve a",
        "path whose **sustained** capability is ~84 KB/s median ≈ **670 kbit/s**",
        "(parent corrected; long-window ~107 KB/s mean retracted).",
        "",
        f"**Segment length:** {args.seg} s — LOW (even idx) then HIGH (odd), repeating.",
        f"**Duration:** {duration_s} s @ **24/1**. Glass ID every frame.",
        "",
        "## Transitions (bank staircase — align device timeline here)",
        "",
        "| idx | kind | t0_s | t1_s | meas_v_kbit_s |",
        "|----:|------|-----:|-----:|--------------:|",
    ]
    for s in seg_br:
        lines.append(
            f"| {s.get('index')} | **{s.get('kind')}** | {s.get('t0_s')} | {s.get('t1_s')} | "
            f"{s.get('meas_v_kbit_s', '?')} |"
        )
    lines += [
        "",
        f"**Segment means:** LOW≈{mean_low} kbit/s  HIGH≈{mean_high} kbit/s  "
        f"file mean_v≈{mean_all} → CBR mean target **{cbr_mean_k} kbit/s**",
        "",
        "## PRE-REGISTER",
        "",
        "| clip | supply_ratio | pfps | drops trend |",
        "|------|--------------|------|-------------|",
        "| stair VBR | LOW ≈0.95–1.0; HIGH dip if starved | LOW≈23–24; HIGH dip | flat LOW; climb on HIGH t0 |",
        f"| cbrMean {cbr_mean_k}k | stable (no HIGH-locked dip if VBR-cause) | ≈23–24 if mean&lt;path | no transition-locked climb |",
        f"| cbrLow {args.cbr_low_k}k | ≈0.97–1.0 entire run | ≈23.5–24 | flat forever |",
        "| stair VBR 640x480 | same as bank stair if bitrate-cause | same | same |",
        "",
        "**Confirm VBR hypothesis:** stair collapses at HIGH transitions AND cbrMean does not.",
        "**Kill hypothesis:** both collapse alike, or neither collapses on HIGH.",
        "",
        "## Measured clips",
        "",
        "| title | role | W×H | fps | mean_v_k | total_k | refs | profile/L/B | aac | spec |",
        "|-------|------|-----|-----|---------:|--------:|-----:|-------------|-----|------|",
    ]
    for c in clips:
        m = c["measured"]
        sps = m.get("sps") or {}
        lines.append(
            "| `{t}` | {r} | **{w}×{h}** | **{fps}** | {mv} | {tot} | {rf} | {p}/L{lv}/B{b} | {ac}@{ar}/{ch}ch | {ok} |".format(
                t=c["title"],
                r=c["role"],
                w=m.get("width"),
                h=m.get("height"),
                fps=m.get("r_frame_rate"),
                mv=f"{m.get('v_bit_rate_k'):.1f}" if m.get("v_bit_rate_k") else "?",
                tot=f"{m.get('format_bit_rate_k'):.1f}" if m.get("format_bit_rate_k") else "?",
                rf=sps.get("max_num_ref_frames"),
                p=m.get("profile"),
                lv=m.get("level"),
                b=m.get("has_b_frames"),
                ac=m.get("a_codec"),
                ar=m.get("a_sample_rate"),
                ch=m.get("a_channels"),
                ok="YES" if not c["fails"] else "NO",
            )
        )
    lines += [
        "",
        "## Parent PMS (§2)",
        "",
        "```bash",
        'curl -sS -o /dev/null -w \'refresh_http=%{http_code}\\n\' \\',
        '  "http://192.168.1.24:32400/library/sections/2/refresh?X-Plex-Token=$TOK"',
        'echo "refresh true rc=$?"',
        'curl -sS "http://192.168.1.24:32400/library/sections/2/all?X-Plex-Token=$TOK" -o /tmp/pms_s2.xml',
        'echo "all true rc=$?"',
        "python3 - <<'PY'",
        "import xml.etree.ElementTree as ET",
        "root=ET.parse('/tmp/pms_s2.xml').getroot()",
        "for v in sorted(root.findall('.//Video'), key=lambda e:int(e.get('ratingKey',0))):",
        "    t=v.get('title') or ''",
        "    if 'VBRStair' in t:",
        "        print(f\"rk={v.get('ratingKey')} dur_ms={v.get('duration')} frameRate={v.get('frameRate')} | {t}\")",
        "PY",
        "```",
        "",
        "Quote PMS `frameRate` when present; **asset truth is ffprobe 24/1** above.",
        "Agent does not cast. Prefer Direct Play.",
        "",
        "## Reproduce",
        "",
        "```bash",
        f"python3 scripts/gen_vbr_motion_staircase.py --duration {int(duration_s)} --seg {args.seg} --copy-media",
        "```",
        "",
    ]
    (docs / "VBR_MOTION_STAIRCASE.md").write_text("\n".join(lines) + "\n")
    (docs / "vbr_motion_staircase_probe.json").write_text(
        json.dumps(
            {
                "path_sustained_kbit_s_parent": 670,
                "path_note": "84 KB/s median sustained; 107 KB/s mean retracted",
                "seg_s": args.seg,
                "duration_s": duration_s,
                "transitions": transitions,
                "cbr_mean_k": cbr_mean_k,
                "clips": clips,
            },
            indent=2,
        )
        + "\n"
    )
    n_fail = sum(1 for c in clips if c["fails"])
    print(f"DONE n={len(clips)} spec_fail={n_fail} cbr_mean_k={cbr_mean_k}", flush=True)
    return 1 if n_fail else 0


if __name__ == "__main__":
    raise SystemExit(main())
