#!/usr/bin/env python3
"""Resolution-preserve knee calibration assets + optional DecLoad slice/GOP arms.

Parent fact (2026-08-02): requested maxVideoBitrate changes DELIVERED geometry
  request 397 → 312x240; request 2000 → 624x480 (source was 624x480 @ ~397k).
A bitrate ladder is confounded with pixels. These assets hold SOURCE geometry
fixed at 624x480 (or explicit controls) so the parent can sweep REQUEST bitrate
and/or cross source bitrate × request.

Does NOT modify plex_resolve floor (w-cpu-1). Host-side only.
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "assets" / "avsync"
MEDIA = Path.home() / "plex" / "media" / "movies"
MASTER = MEDIA / "MiSTerPlex Real BBB GlassAV 624x480 24fps 1200s (2026).mp4"
FPS = "24"
A_BR = "128k"

# Source video kbit — NOT the request arm. Parent sweeps request separately.
RESKNEE_SRC_K = [400, 800, 1200, 1600, 2000, 2500]
DURATION_S = 90.0  # geometry is known from ffmpeg banner in first seconds


def sps_refs(path: Path) -> int | None:
    p = subprocess.run(
        [
            "ffmpeg", "-hide_banner", "-i", str(path),
            "-c:v", "copy", "-bsf:v", "trace_headers", "-frames:v", "1",
            "-f", "null", "-",
        ],
        capture_output=True,
        text=True,
    )
    m = re.search(r"max_num_ref_frames\s+[01]+\s+=\s+(\d+)", (p.stderr or "") + (p.stdout or ""))
    return int(m.group(1)) if m else None


def ffprobe(path: Path) -> dict:
    p = subprocess.run(
        [
            "ffprobe", "-v", "error", "-select_streams", "v:0",
            "-show_entries",
            "stream=width,height,r_frame_rate,profile,level,has_b_frames,bit_rate,"
            "sample_aspect_ratio",
            "-show_entries", "format=duration,bit_rate",
            "-of", "json", str(path),
        ],
        capture_output=True,
        text=True,
    )
    pa = subprocess.run(
        [
            "ffprobe", "-v", "error", "-select_streams", "a:0",
            "-show_entries", "stream=codec_name,sample_rate,channels",
            "-of", "json", str(path),
        ],
        capture_output=True,
        text=True,
    )
    d = json.loads(p.stdout) if p.stdout.strip() else {}
    a = json.loads(pa.stdout) if pa.stdout.strip() else {}
    st = (d.get("streams") or [{}])[0]
    fmt = d.get("format") or {}
    ast = (a.get("streams") or [{}])[0]
    vbr = st.get("bit_rate")
    try:
        vbr_k = int(vbr) / 1000.0 if vbr and vbr != "N/A" else None
    except ValueError:
        vbr_k = None
    try:
        fbr_k = int(fmt["bit_rate"]) / 1000.0 if fmt.get("bit_rate") not in (None, "N/A") else None
    except (ValueError, KeyError, TypeError):
        fbr_k = None
    return {
        "ffprobe_rc": p.returncode,
        "width": st.get("width"),
        "height": st.get("height"),
        "r_frame_rate": st.get("r_frame_rate"),
        "profile": st.get("profile"),
        "level": st.get("level"),
        "has_b_frames": st.get("has_b_frames"),
        "sar": st.get("sample_aspect_ratio"),
        "v_k": vbr_k,
        "total_k": fbr_k,
        "duration": fmt.get("duration"),
        "a_codec": ast.get("codec_name"),
        "a_rate": ast.get("sample_rate"),
        "a_ch": ast.get("channels"),
        "refs": sps_refs(path),
    }


def encode_cb(
    src: Path,
    out: Path,
    *,
    w: int,
    h: int,
    v_k: int,
    duration_s: float,
    refs: int = 1,
    keyint: int = 48,
    slices: int = 1,
    bf: int = 0,
    profile: str = "baseline",
    cabac: int = 0,
    extra_x264: str = "",
) -> dict:
    out.parent.mkdir(parents=True, exist_ok=True)
    x264 = (
        f"cabac={cabac}:ref={refs}:bframes={bf}:keyint={keyint}:min-keyint={max(1,keyint//2)}:"
        f"scenecut=0:level=30:vbv-maxrate={v_k}:vbv-bufsize={v_k*2}:slice-max-size=0:"
        f"slices={slices}"
    )
    if cabac == 0:
        x264 += ":no-cabac=1"
    if extra_x264:
        x264 += ":" + extra_x264
    vb, buf = f"{v_k}k", f"{v_k*2}k"
    vf = f"scale={w}:{h}:flags=bicubic,setsar=1/1,fps={FPS}"
    cmd = [
        "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
        "-i", str(src), "-t", str(duration_s), "-vf", vf,
        "-c:v", "libx264", "-profile:v", profile, "-level:v", "3.0",
        "-bf", str(bf), "-x264-params", x264, "-pix_fmt", "yuv420p",
        "-b:v", vb, "-minrate", vb, "-maxrate", vb, "-bufsize", buf, "-r", FPS,
        "-c:a", "aac", "-b:a", A_BR, "-ar", "48000", "-ac", "2",
        "-movflags", "+faststart", str(out),
    ]
    print(f"ENC {out.name} {w}x{h} v={v_k}k ref={refs} ki={keyint} sl={slices}", flush=True)
    p = subprocess.run(cmd, capture_output=True, text=True)
    print(f"  ffmpeg_rc={p.returncode}", flush=True)
    if p.returncode != 0:
        sys.stderr.write(p.stderr[-2000:] if p.stderr else "")
        raise SystemExit(p.returncode)
    m = ffprobe(out)
    return {"cmd": cmd, "ffmpeg_rc": p.returncode, "measured": m}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--master", type=Path, default=MASTER)
    ap.add_argument("--duration", type=float, default=DURATION_S)
    ap.add_argument("--copy-media", action="store_true")
    ap.add_argument("--skip-resknee", action="store_true")
    ap.add_argument("--skip-decload-extra", action="store_true")
    args = ap.parse_args()
    if not args.master.is_file():
        print(f"missing master {args.master}", file=sys.stderr)
        return 2
    OUT.mkdir(parents=True, exist_ok=True)
    MEDIA.mkdir(parents=True, exist_ok=True)
    rows = []
    dur = int(round(args.duration))

    if not args.skip_resknee:
        for vk in RESKNEE_SRC_K:
            title = f"MiSTerPlex ResKnee 624x480 24fps src{vk}k CB ref1 {dur}s (2026).mp4"
            stem = f"resknee_624x480_24_src{vk}k_ref1_{dur}s"
            out = OUT / f"{stem}.mp4"
            rec = encode_cb(args.master, out, w=624, h=480, v_k=vk, duration_s=args.duration)
            m = rec["measured"]
            fails = []
            if m.get("width") != 624 or m.get("height") != 480:
                fails.append("geom")
            if m.get("r_frame_rate") != "24/1":
                fails.append(f"fps={m.get('r_frame_rate')}")
            if "Baseline" not in (m.get("profile") or ""):
                fails.append(f"prof={m.get('profile')}")
            if int(m.get("has_b_frames") or 0) != 0:
                fails.append("B")
            if m.get("refs") not in (1, None):
                fails.append(f"refs={m.get('refs')}")
            if m.get("a_codec") != "aac" or str(m.get("a_rate")) != "48000":
                fails.append("audio")
            vk_m = m.get("v_k")
            if vk_m is None or not (vk * 0.75 <= vk_m <= vk * 1.3):
                fails.append(f"v_k={vk_m}")
            row = {
                "family": "ResKnee",
                "title": title,
                "stem": stem,
                "src_v_kbit_target": vk,
                "role": "source_bitrate_rung_for_request_cross",
                "fails": fails,
                "spec_ok": not fails,
                **rec,
            }
            rows.append(row)
            print(f"  ok={row['spec_ok']} fails={fails} meas_v={vk_m} refs={m.get('refs')}", flush=True)
            (OUT / f"{stem}.mp4.meta.json").write_text(json.dumps(row, indent=2, default=str) + "\n")
            if args.copy_media:
                shutil.copy2(out, MEDIA / title)
                print(f"  -> media {title}", flush=True)

        # Native 320x240 control (request high should NOT invent 480 rows)
        title = f"MiSTerPlex ResKnee 320x240 24fps src400k CB ref1 {dur}s (2026).mp4"
        stem = f"resknee_320x240_24_src400k_ref1_{dur}s"
        out = OUT / f"{stem}.mp4"
        rec = encode_cb(args.master, out, w=320, h=240, v_k=400, duration_s=args.duration)
        m = rec["measured"]
        fails = []
        if (m.get("width"), m.get("height")) != (320, 240):
            fails.append("geom")
        if "Baseline" not in (m.get("profile") or ""):
            fails.append("prof")
        row = {
            "family": "ResKnee",
            "title": title,
            "stem": stem,
            "src_v_kbit_target": 400,
            "role": "native_240_control",
            "fails": fails,
            "spec_ok": not fails,
            **rec,
        }
        rows.append(row)
        (OUT / f"{stem}.mp4.meta.json").write_text(json.dumps(row, indent=2, default=str) + "\n")
        if args.copy_media:
            shutil.copy2(out, MEDIA / title)

        # Non-bank 624x352 mid source
        title = f"MiSTerPlex ResKnee 624x352 24fps src800k CB ref1 {dur}s (2026).mp4"
        stem = f"resknee_624x352_24_src800k_ref1_{dur}s"
        out = OUT / f"{stem}.mp4"
        rec = encode_cb(args.master, out, w=624, h=352, v_k=800, duration_s=args.duration)
        m = rec["measured"]
        fails = []
        if (m.get("width"), m.get("height")) != (624, 352):
            fails.append("geom")
        row = {
            "family": "ResKnee",
            "title": title,
            "stem": stem,
            "src_v_kbit_target": 800,
            "role": "nonbank_624x352",
            "fails": fails,
            "spec_ok": not fails,
            **rec,
        }
        rows.append(row)
        (OUT / f"{stem}.mp4.meta.json").write_text(json.dumps(row, indent=2, default=str) + "\n")
        if args.copy_media:
            shutil.copy2(out, MEDIA / title)

    if not args.skip_decload_extra:
        # Fixed 800k 624x480 — slice count and GOP only
        extras = [
            ("cb_slices4", dict(slices=4, keyint=48, refs=1), "slice count 4"),
            ("cb_slices8", dict(slices=8, keyint=48, refs=1), "slice count 8"),
            ("cb_gop24", dict(slices=1, keyint=24, refs=1), "GOP keyint=24"),
            ("cb_gop240", dict(slices=1, keyint=240, refs=1), "GOP keyint=240"),
        ]
        for key, kw, note in extras:
            title = f"MiSTerPlex DecLoad {key} 624x480 24fps 800k 180s (2026).mp4"
            stem = f"decload_{key}_624x480_24_800k_180s"
            out = OUT / f"{stem}.mp4"
            # use 180s for parity with existing DecLoad
            rec = encode_cb(
                args.master, out, w=624, h=480, v_k=800, duration_s=180.0, **kw
            )
            m = rec["measured"]
            fails = []
            if (m.get("width"), m.get("height")) != (624, 480):
                fails.append("geom")
            if m.get("r_frame_rate") != "24/1":
                fails.append("fps")
            if "Baseline" not in (m.get("profile") or ""):
                fails.append("prof")
            if int(m.get("has_b_frames") or 0) != 0:
                fails.append("B")
            row = {
                "family": "DecLoad",
                "title": title,
                "stem": stem,
                "key": key,
                "note": note,
                "encoder": kw,
                "product_legal": True,
                "fails": fails,
                "spec_ok": not fails,
                "prereg_supply_iv": "compare to rk115 cb_ref1 at same delivered geom",
                "prereg_pfps": "23.5–24.5 if not decode-bound",
                **rec,
            }
            rows.append(row)
            print(f"  {key} ok={row['spec_ok']} fails={fails}", flush=True)
            (OUT / f"{stem}.mp4.meta.json").write_text(json.dumps(row, indent=2, default=str) + "\n")
            if args.copy_media:
                shutil.copy2(out, MEDIA / title)

    probe_path = ROOT / "docs" / "respreserve_knee_probe.json"
    probe_path.write_text(json.dumps({"rows": rows}, indent=2, default=str) + "\n")
    bad = [r["title"] for r in rows if not r.get("spec_ok")]
    print(f"DONE n={len(rows)} bad={len(bad)}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
