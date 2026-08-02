#!/usr/bin/env python3
"""Promo “scoreable” fixtures — hostile to bad instruments, real load.

Properties (every frame, no enable= guards):
  - Real-content body (BBB loop) with black-lift + subtle motion checker so
    there are NO long pure-black stretches (closes ERROR 13 class traps).
  - Glass frame ID burned on EVERY frame (tools/glass_frame_id.draw_id_band).
  - Known-hue colour patches at contract coords (docs/colour_patch_contract.md).
  - Flash + 1 kHz beep @ period 2.000 s (designed A/V offset configurable).
  - H.264 Constrained Baseline, bf=0, AAC 48 kHz, rate 24/1 exactly.

Geometry ladder (non-bank + optional bank control):
  624x352, 640x480, 720x480, 720x404, 1440x1080 [, 624x480]

Example:
  python3 scripts/gen_promo_scoreable_fixture.py \\
    --src .agent-work/fixtures-real/bbb_720p_src.mp4 \\
    --out assets/avsync/promo_scoreable_720x480_24_600s.mp4 \\
    --width 720 --height 480 --duration 600
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

FPS_NUM = 24
FPS_DEN = 1
SR = 48000
BEEP_S = 0.050
ATTACK_S = 0.001
BEEP_HZ = 1000.0
FLASH_FRAMES = 2
PERIOD_S = 2.0
COLOUR_CONTRACT_VERSION = 1
BLACK_LIFT = 40  # minimum per-channel floor on body (not pure black)

# Fractions of active body — must match docs/colour_patch_contract.md
PATCHES = [
    # id, RGB, fx0, fx1, fy0, fy1
    ("R", (255, 0, 0), 0.04, 0.18, 0.72, 0.94),
    ("G", (0, 255, 0), 0.20, 0.34, 0.72, 0.94),
    ("B", (0, 0, 255), 0.36, 0.50, 0.72, 0.94),
    ("Y", (255, 255, 0), 0.52, 0.66, 0.72, 0.94),
    ("C", (0, 255, 255), 0.68, 0.82, 0.72, 0.94),
    ("M", (255, 0, 255), 0.84, 0.98, 0.72, 0.94),
    ("W", (240, 240, 240), 0.04, 0.18, 0.08, 0.28),
    ("K", (32, 32, 32), 0.20, 0.34, 0.08, 0.28),
    ("N18", (46, 46, 46), 0.36, 0.50, 0.08, 0.28),
]


def ffprobe_json(path: Path) -> dict:
    cmd = [
        "ffprobe", "-v", "error",
        "-show_entries", "format=duration,size",
        "-show_entries",
        "stream=index,codec_type,codec_name,width,height,r_frame_rate,"
        "avg_frame_rate,nb_frames,duration,profile,has_b_frames,sample_rate,"
        "channels,pix_fmt",
        "-of", "json", str(path),
    ]
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        raise SystemExit(f"ffprobe failed rc={p.returncode}: {p.stderr}")
    return json.loads(p.stdout)


def even_floor(v: int) -> int:
    return v - (v % 2)


def even_ceil(v: int, limit: int) -> int:
    v = min(limit, v + (v % 2))  # push up to even if odd? for end exclusive prefer even
    if v % 2:
        v = min(limit, v + 1)
    return v


def patch_pixels(w: int, h: int, id_bottom: int) -> list[dict]:
    body_h = h - id_bottom
    out = []
    for pid, rgb, fx0, fx1, fy0, fy1 in PATCHES:
        x0 = even_floor(int(math.floor(fx0 * w)))
        x1 = even_ceil(int(math.ceil(fx1 * w)), w)
        y0 = id_bottom + even_floor(int(math.floor(fy0 * body_h)))
        y1 = id_bottom + even_ceil(int(math.ceil(fy1 * body_h)), h - id_bottom)
        y1 = min(h, y1)
        if x1 <= x0 + 4:
            x1 = min(w, x0 + 8)
        if y1 <= y0 + 4:
            y1 = min(h, y0 + 8)
        # inner 50% ROI for instruments
        ix0 = x0 + (x1 - x0) // 4
        ix1 = x1 - (x1 - x0) // 4
        iy0 = y0 + (y1 - y0) // 4
        iy1 = y1 - (y1 - y0) // 4
        out.append({
            "id": pid,
            "rgb": list(rgb),
            "fx0": fx0, "fx1": fx1, "fy0": fy0, "fy1": fy1,
            "x0": x0, "x1": x1, "y0": y0, "y1": y1,
            "inner": {"x0": ix0, "x1": ix1, "y0": iy0, "y1": iy1},
        })
    return out


def draw_patches(rgb: np.ndarray, patches: list[dict]) -> None:
    for p in patches:
        rgb[p["y0"]:p["y1"], p["x0"]:p["x1"], :] = np.array(p["rgb"], dtype=np.uint8)


def write_beep_track(
    path: Path,
    duration_s: float,
    *,
    period_s: float,
    audio_delay_s: float = 0.0,
    sample_rate: int = SR,
) -> list[float]:
    n = int(round(duration_s * sample_rate))
    onsets: list[float] = []
    k = 0
    while True:
        t_flash = k * period_s
        t0 = t_flash + audio_delay_s
        if t_flash >= duration_s:
            break
        if 0.0 <= t0 < duration_s:
            onsets.append(t0)
        k += 1
    mono = np.zeros(n, dtype=np.float64)
    t = np.arange(n, dtype=np.float64) / float(sample_rate)
    for t0 in onsets:
        i0 = int(round(t0 * sample_rate))
        i1 = min(n, i0 + int(round(BEEP_S * sample_rate)))
        if i0 >= n or i1 <= i0:
            continue
        phase = t[i0:i1] - t0
        env = np.where(phase < ATTACK_S, phase / ATTACK_S, 1.0)
        mono[i0:i1] = 0.85 * env * np.sin(2 * math.pi * BEEP_HZ * t[i0:i1])
    s16 = np.clip(mono * 32767.0, -32768, 32767).astype(np.int16)
    path.write_bytes(np.column_stack([s16, s16]).reshape(-1).tobytes())
    return onsets


def body_flash(n: int, fps: float, period_s: float) -> bool:
    t = n / float(fps)
    k = int(round(t / period_s))
    t_m = k * period_s
    dn = int(round((t - t_m) * fps))
    return 0 <= dn < FLASH_FRAMES


def composite_body(
    content: np.ndarray,
    n: int,
    id_bottom: int,
    patches: list[dict],
    *,
    flash: bool,
) -> None:
    """In-place: lift blacks, add motion structure, patches, optional flash."""
    h, w = content.shape[:2]
    body = content[id_bottom:, :, :]
    # Black lift — no pure-black body pixels
    np.maximum(body, BLACK_LIFT, out=body)
    # Moving checker (period ~32 px, scrolls with n) — freeze-visible structure
    yy = np.arange(h - id_bottom, dtype=np.int32)[:, None]
    xx = np.arange(w, dtype=np.int32)[None, :]
    phase = (n * 3) % 64
    chk = ((xx + phase) // 32 + (yy + phase // 2) // 32) & 1
    # Mix 15% checker into body so dark scenes still have edges
    mix = body.astype(np.int16)
    bump = np.where(chk[..., None] == 0, -18, 18).astype(np.int16)
    body[:] = np.clip(mix + bump, 0, 255).astype(np.uint8)
    if flash:
        content[id_bottom:, :, :] = 255
    else:
        draw_patches(content, patches)
    # Diagonal ticker bar (always-on motion independent of content)
    bar_y = id_bottom + 4 + ((n * 2) % max(8, (h - id_bottom - 20)))
    x0 = (n * 5) % max(1, w - w // 5)
    content[bar_y : bar_y + 6, x0 : x0 + w // 5, :] = (255, 255, 0)


def media_title(w: int, h: int, duration_s: float, delay_ms: float) -> str:
    dur = int(round(duration_s))
    base = f"MiSTerPlex PromoScoreable {w}x{h} 24fps {dur}s (2026).mp4"
    if abs(delay_ms) > 0.5:
        base = (
            f"MiSTerPlex PromoScoreable {w}x{h} 24fps {dur}s "
            f"audioPlus{int(round(delay_ms))}ms (2026).mp4"
        )
    return base


def gen(
    *,
    src: Path,
    out: Path,
    width: int,
    height: int,
    duration_s: float,
    period_s: float,
    audio_delay_ms: float,
    vbitrate: str,
    work: Path | None,
) -> dict:
    if not src.is_file():
        raise SystemExit(f"missing src {src}")
    w, h = width, height
    if w % 2 or h % 2:
        raise SystemExit(f"yuv420 needs even WxH, got {w}x{h}")
    fps = FPS_NUM / float(FPS_DEN)
    fps_str = f"{FPS_NUM}/{FPS_DEN}" if FPS_DEN != 1 else str(FPS_NUM)
    n_frames = int(round(duration_s * fps))
    geom = geometry_for(w, h)
    id_bottom = geom.bar_y1
    patches = patch_pixels(w, h, id_bottom)
    audio_delay_s = float(audio_delay_ms) / 1000.0
    bufsize = (
        str(int(vbitrate[:-1]) * 2) + "k" if vbitrate[-1] in "kK" else vbitrate
    )
    td = work or Path(tempfile.mkdtemp(prefix="promo_sc_"))
    td.mkdir(parents=True, exist_ok=True)
    out.parent.mkdir(parents=True, exist_ok=True)

    beep_pcm = td / "beep.s16"
    onsets = write_beep_track(
        beep_pcm, duration_s, period_s=period_s, audio_delay_s=audio_delay_s
    )
    print(
        f"OUT_PLAN w={w} h={h} fps={fps_str} duration_s={duration_s} "
        f"n_frames={n_frames} period_s={period_s} id_bottom={id_bottom} "
        f"designed_av_offset_ms={audio_delay_ms} patches={len(patches)} "
        f"text0={format_text(0)} black_lift={BLACK_LIFT} "
        f"colour_contract_v={COLOUR_CONTRACT_VERSION}",
        flush=True,
    )
    print(f"beep_onsets_n={len(onsets)} first={onsets[:3]}", flush=True)

    dec_cmd = [
        "ffmpeg", "-hide_banner", "-loglevel", "error",
        "-stream_loop", "-1", "-i", str(src), "-an",
        "-vf", f"scale={w}:{h}:flags=bicubic,fps={fps_str},format=rgb24",
        "-f", "rawvideo", "-pix_fmt", "rgb24",
        "-frames:v", str(n_frames), "pipe:1",
    ]
    enc_cmd = [
        "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
        "-f", "rawvideo", "-pix_fmt", "rgb24",
        "-s", f"{w}x{h}", "-r", fps_str, "-i", "pipe:0",
        "-stream_loop", "-1", "-i", str(src),
        "-f", "s16le", "-ar", str(SR), "-ac", "2", "-i", str(beep_pcm),
        "-filter_complex",
        f"[1:a]aresample={SR},aformat=sample_fmts=fltp:channel_layouts=stereo,"
        f"atrim=0:{duration_s},asetpts=PTS-STARTPTS,volume=0.75[a0];"
        f"[2:a]aformat=sample_fmts=fltp:channel_layouts=stereo,"
        f"atrim=0:{duration_s},asetpts=PTS-STARTPTS[a1];"
        f"[a0][a1]amix=inputs=2:duration=first:dropout_transition=0,"
        f"atrim=0:{duration_s},asetpts=PTS-STARTPTS[aout]",
        "-map", "0:v:0", "-map", "[aout]",
        "-c:v", "libx264", "-profile:v", "baseline", "-bf", "0",
        "-x264-params", "cabac=0:ref=1:bframes=0:keyint=48",
        "-pix_fmt", "yuv420p",
        "-b:v", vbitrate, "-maxrate", vbitrate, "-bufsize", bufsize,
        "-r", fps_str,
        "-c:a", "aac", "-b:a", "160k", "-ar", str(SR), "-ac", "2",
        "-t", str(duration_s),
        "-movflags", "+faststart",
        str(out),
    ]
    print("DEC", " ".join(dec_cmd), flush=True)
    print("ENC", " ".join(enc_cmd), flush=True)

    dec = subprocess.Popen(dec_cmd, stdout=subprocess.PIPE)
    enc = subprocess.Popen(enc_cmd, stdin=subprocess.PIPE)
    assert dec.stdout and enc.stdin
    frame_bytes = w * h * 3
    n = 0
    try:
        while n < n_frames:
            buf = dec.stdout.read(frame_bytes)
            if len(buf) < frame_bytes:
                print(f"WARN short read n={n} got={len(buf)}", flush=True)
                break
            rgb = np.frombuffer(buf, dtype=np.uint8).reshape((h, w, 3)).copy()
            flash = body_flash(n, fps, period_s)
            composite_body(rgb, n, id_bottom, patches, flash=flash)
            # Glass ID LAST — every frame, no enable= guard (contract)
            draw_id_band(rgb, n, geom)
            enc.stdin.write(rgb.tobytes())
            n += 1
            if n % 500 == 0 or n == n_frames:
                print(f"  burned {n}/{n_frames}", flush=True)
    finally:
        enc.stdin.close()
        erc = enc.wait()
        dec.stdout.close()
        drc = dec.wait()

    print(f"decode_rc={drc} encode_rc={erc} frames_burned={n}", flush=True)
    if erc != 0 or n != n_frames:
        raise SystemExit(f"encode failed erc={erc} frames={n}/{n_frames}")

    measured = ffprobe_json(out)
    # host patch sample on one mid frame
    patch_check = verify_patches_host(out, w, h, patches, t=min(5.5, duration_s * 0.1))
    report = {
        "out": str(out),
        "src": str(src),
        "colour_patch_contract_version": COLOUR_CONTRACT_VERSION,
        "colour_patch_doc": "docs/colour_patch_contract.md",
        "glass_id_doc": "docs/glass_frame_id_contract.md",
        "id_every_frame": True,
        "id_enable_guard": False,
        "caller_supplied": {
            "width": w,
            "height": h,
            "fps_rational": f"{FPS_NUM}/{FPS_DEN}",
            "duration_s": duration_s,
            "period_s": period_s,
            "designed_av_offset_ms": float(audio_delay_ms),
            "flash_frames": FLASH_FRAMES,
            "beep_s": BEEP_S,
            "beep_hz": BEEP_HZ,
            "black_lift": BLACK_LIFT,
            "id_bottom_y": id_bottom,
            "id_text_example": format_text(0),
            "vbitrate": vbitrate,
            "profile": "Constrained Baseline (baseline + cabac=0)",
            "bf": 0,
            "audio": "aac 48k mix(src+beep)",
        },
        "colour_patches_px": patches,
        "measured_ffprobe": measured,
        "host_patch_check": patch_check,
        "frames_burned": n,
        "beep_onsets_n": len(onsets),
        "size_bytes": out.stat().st_size,
        "bank_fit": "favourable" if (w, h) == (624, 480) else "adversarial",
    }
    meta_path = out.with_suffix(out.suffix + ".meta.json")
    meta_path.write_text(json.dumps(report, indent=2) + "\n")
    print(f"OK {out} size={out.stat().st_size} meta={meta_path}", flush=True)
    print(f"host_patch_check={json.dumps(patch_check)}", flush=True)
    return report


def verify_patches_host(
    path: Path, w: int, h: int, patches: list[dict], t: float
) -> dict:
    """Decode one frame; measure inner ROI mean RGB vs contract."""
    fr = subprocess.run(
        [
            "ffmpeg", "-v", "error", "-ss", f"{t:.3f}", "-i", str(path),
            "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1",
        ],
        capture_output=True,
    )
    if fr.returncode != 0 or len(fr.stdout) < w * h * 3:
        return {"ok": False, "reason": f"decode_rc={fr.returncode}"}
    rgb = np.frombuffer(fr.stdout, dtype=np.uint8).reshape((h, w, 3))
    results = []
    all_ok = True
    for p in patches:
        inn = p["inner"]
        tile = rgb[inn["y0"]:inn["y1"], inn["x0"]:inn["x1"], :]
        if tile.size == 0:
            results.append({"id": p["id"], "ok": False, "reason": "empty"})
            all_ok = False
            continue
        mean = tile.reshape(-1, 3).mean(axis=0)
        mr, mg, mb = (float(mean[0]), float(mean[1]), float(mean[2]))
        pid = p["id"]
        ok = True
        reason = "ok"
        if pid == "R":
            ok = (mr - max(mg, mb)) >= 60
        elif pid == "G":
            ok = (mg - max(mr, mb)) >= 60
        elif pid == "B":
            ok = (mb - max(mr, mg)) >= 60
        elif pid == "Y":
            ok = (min(mr, mg) - mb) >= 60
        elif pid == "C":
            ok = (min(mg, mb) - mr) >= 60
        elif pid == "M":
            ok = (min(mr, mb) - mg) >= 60
        elif pid == "W":
            ok = mean.mean() >= 180 and (mean.max() - mean.min()) <= 40
        elif pid in ("K", "N18"):
            ok = 10 <= mean.mean() <= 90
        if not ok:
            all_ok = False
            reason = "assert_fail"
        results.append({
            "id": pid,
            "ok": bool(ok),
            "reason": reason,
            "mean_rgb": [round(mr, 1), round(mg, 1), round(mb, 1)],
        })
    return {"ok": bool(all_ok), "t": t, "patches": results}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--src", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--width", type=int, required=True)
    ap.add_argument("--height", type=int, required=True)
    ap.add_argument("--duration", type=float, default=600.0)
    ap.add_argument("--period", type=float, default=PERIOD_S)
    ap.add_argument("--audio-delay-ms", type=float, default=0.0)
    ap.add_argument("--vbitrate", default="2500k")
    ap.add_argument("--work", type=Path, default=None)
    ap.add_argument("--copy-media", action="store_true")
    ap.add_argument(
        "--media-dir",
        type=Path,
        default=Path.home() / "plex" / "media" / "movies",
    )
    args = ap.parse_args()
    rep = gen(
        src=args.src,
        out=args.out,
        width=args.width,
        height=args.height,
        duration_s=args.duration,
        period_s=args.period,
        audio_delay_ms=args.audio_delay_ms,
        vbitrate=args.vbitrate,
        work=args.work,
    )
    if args.copy_media:
        title = media_title(
            args.width, args.height, args.duration, args.audio_delay_ms
        )
        dest = args.media_dir / title
        args.media_dir.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(args.out.read_bytes())
        print(f"COPIED {dest}", flush=True)
        rep["media_filename"] = title
        rep["media_host_path"] = str(dest)
        meta = args.out.with_suffix(args.out.suffix + ".meta.json")
        meta.write_text(json.dumps(rep, indent=2) + "\n")
    return 0 if rep.get("host_patch_check", {}).get("ok") else 2


if __name__ == "__main__":
    raise SystemExit(main())
