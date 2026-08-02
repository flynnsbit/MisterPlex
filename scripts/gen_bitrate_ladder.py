#!/usr/bin/env python3
"""Bitrate / refFrames / geometry one-variable ladder for link-ceiling soaks.

Parent measured MiSTer link ~1.56 Mbit/s and saw rk=9 (~2154 kbit/s, ref=3,
624x352) collapse while rk=27 (~456 kbit/s, ref=1, 624x480) stayed healthy —
three confounded variables. This ladder isolates each axis.

Axes
----
1. Bitrate sweep @ fixed 624x480, 24/1, CB level 3.0, ref=1, AAC 48k @ 48 kbit/s:
   video targets 400,700,1000,1400,1800,2200,2600 kbit/s (CBR-ish maxrate=b:v).
2. refFrames pair @ 700 kbit/s 624x480: ref=1 vs ref=3.
3. Geometry pair @ 700 kbit/s ref=1: 624x480 vs 624x352.

Every frame: full-bleed moving content + glass ID ``G n=DDDDDD c=C`` (draw_id_band,
no enable= guard). Duration default 600 s.

Encoder contract (FPGA / plex_resolve): H.264 Constrained Baseline, level<=3.0,
no B-frames, AAC 48 kHz. Each output is ffprobe + SPS-trace verified
(profile/level/max_num_ref_frames/r_frame_rate/bit_rate).

Usage:
  python3 scripts/gen_bitrate_ladder.py --duration 600 --copy-media
"""
from __future__ import annotations

import argparse
import json
import re
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
A_BITRATE = "48k"  # pin audio — uncontrolled on rk9 vs rk27
BLACK_LIFT = 52
MASTER_VBITRATE = "5000k"

# video kbit/s targets for the main sweep (ref=1, 624x480)
SWEEP_KBIT = [400, 700, 1000, 1400, 1800, 2200, 2600]
REF_PAIR_KBIT = 700
GEOM_PAIR_KBIT = 700


def render_frame(n: int, w: int, h: int, geom) -> np.ndarray:
    """Full-bleed, always-bright, MAD-distinct; glass ID every frame."""
    rgb = np.zeros((h, w, 3), dtype=np.uint8)
    id_bottom = geom.bar_y1
    body_h = max(1, h - id_bottom)

    yy = np.linspace(BLACK_LIFT, 110, h, dtype=np.float32)[:, None]
    xx = np.linspace(0, 50, w, dtype=np.float32)[None, :]
    base = np.clip(yy + xx, 0, 255).astype(np.uint8)
    rgb[:, :, 0] = base
    rgb[:, :, 1] = np.clip(base.astype(np.int16) + 12, 0, 255).astype(np.uint8)
    rgb[:, :, 2] = np.clip(base.astype(np.int16) + 24, 0, 255).astype(np.uint8)

    phase = (n * 5) % 64
    ys = np.arange(h)[:, None]
    xs = np.arange(w)[None, :]
    chk = ((xs + phase) // 12 + (ys + phase // 2) // 12) & 1
    rgb = np.where(
        chk[..., None] == 0,
        np.clip(rgb.astype(np.int16) - 28, 0, 255),
        np.clip(rgb.astype(np.int16) + 28, 0, 255),
    ).astype(np.uint8)

    # left Nyquist vertical stripes (decode/load)
    alt = np.where((np.arange(body_h) % 2) == 0, 240, 40).astype(np.uint8)
    x1 = w // 4
    rgb[id_bottom:, :x1, 0] = alt[:, None]
    rgb[id_bottom:, :x1, 1] = alt[:, None]
    rgb[id_bottom:, :x1, 2] = alt[:, None]

    # moving block
    bw = max(56, w // 7)
    bh = max(48, body_h // 4)
    x = 8 + (n * max(4, w // 160)) % max(1, w - bw - 8)
    y = id_bottom + 8 + (n * 3) % max(1, body_h - bh - 16)
    rgb[y : y + bh, x : x + bw] = (250, 220, 30)

    # binary ticks of n
    tick_h = max(14, body_h // 12)
    tick_y0 = h - tick_h - 4
    bit_w = max(10, w // 18)
    for bit in range(14):
        on = (n >> bit) & 1
        x0 = 4 + bit * bit_w
        x1b = min(w - 4, x0 + bit_w - 2)
        rgb[tick_y0 : tick_y0 + tick_h, x0:x1b] = (
            (245, 245, 245) if on else (30, 30, 30)
        )

    # red chroma bar
    ry0 = id_bottom + max(6, body_h // 18)
    rgb[ry0 : ry0 + max(10, h // 36), w // 8 : 7 * w // 8] = (220, 28, 28)

    draw_id_band(rgb, n, geom)  # EVERY frame — no enable= guard
    return rgb


def write_low_audio_wav(path: Path, duration_s: float) -> None:
    """Constant soft tone bed + rare tick — low energy, fixed length."""
    n = int(round(duration_s * SR))
    t = np.arange(n, dtype=np.float64) / float(SR)
    mono = 0.05 * np.sin(2 * np.pi * 220.0 * t)
    # 2 s tick (not the experimental axis — visual ID is motion evidence)
    k = 0
    while True:
        t0 = k * 2.0
        if t0 >= duration_s:
            break
        i0 = int(t0 * SR)
        i1 = min(n, i0 + int(0.02 * SR))
        if i0 < n:
            mono[i0:i1] = 0.25
        k += 1
    s16 = np.clip(mono * 32767.0, -32768, 32767).astype(np.int16)
    with wave.open(str(path), "w") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(SR)
        wf.writeframes(s16.tobytes())


def sps_trace(path: Path) -> dict:
    """Parse first SPS via ffmpeg trace_headers (profile/level/refs)."""
    cmd = [
        "ffmpeg", "-hide_banner", "-i", str(path),
        "-c:v", "copy", "-bsf:v", "trace_headers",
        "-frames:v", "2", "-f", "null", "-",
    ]
    p = subprocess.run(cmd, capture_output=True, text=True)
    text = (p.stderr or "") + (p.stdout or "")
    out = {"trace_rc": p.returncode}
    def grab(name: str) -> int | None:
        m = re.search(rf"{name}\s+[01]+\s+=\s+(\d+)", text)
        return int(m.group(1)) if m else None
    out["profile_idc"] = grab("profile_idc")
    out["constraint_set0_flag"] = grab("constraint_set0_flag")
    out["constraint_set1_flag"] = grab("constraint_set1_flag")
    out["level_idc"] = grab("level_idc")
    out["max_num_ref_frames"] = grab("max_num_ref_frames")
    return out


def ffprobe_full(path: Path) -> dict:
    cmd = [
        "ffprobe", "-v", "error",
        "-select_streams", "v:0",
        "-show_entries",
        "stream=width,height,r_frame_rate,avg_frame_rate,nb_frames,"
        "profile,level,has_b_frames,codec_name,bit_rate",
        "-show_entries", "format=duration,size,bit_rate",
        "-of", "json", str(path),
    ]
    p = subprocess.run(cmd, capture_output=True, text=True)
    vrc = p.returncode
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
    sps = sps_trace(path)
    v_br = int(st["bit_rate"]) if st.get("bit_rate") not in (None, "N/A") else None
    a_br = int(ast["bit_rate"]) if ast.get("bit_rate") not in (None, "N/A") else None
    f_br = int(fmt["bit_rate"]) if fmt.get("bit_rate") not in (None, "N/A") else None
    return {
        "ffprobe_v_rc": vrc,
        "ffprobe_a_rc": ca.returncode,
        "width": st.get("width"),
        "height": st.get("height"),
        "r_frame_rate": st.get("r_frame_rate"),
        "avg_frame_rate": st.get("avg_frame_rate"),
        "nb_frames": st.get("nb_frames"),
        "profile": st.get("profile"),
        "level": st.get("level"),
        "has_b_frames": st.get("has_b_frames"),
        "v_codec": st.get("codec_name"),
        "v_bit_rate": v_br,
        "v_bit_rate_k": (v_br / 1000.0) if v_br else None,
        "format_duration": fmt.get("duration"),
        "format_bit_rate": f_br,
        "format_bit_rate_k": (f_br / 1000.0) if f_br else None,
        "size_bytes": int(fmt["size"]) if fmt.get("size") else None,
        "a_codec": ast.get("codec_name"),
        "a_sample_rate": ast.get("sample_rate"),
        "a_channels": ast.get("channels"),
        "a_bit_rate": a_br,
        "a_bit_rate_k": (a_br / 1000.0) if a_br else None,
        "sps": sps,
    }


def encode_master(out: Path, duration_s: float, w: int, h: int) -> dict:
    fps = FPS_NUM / float(FPS_DEN)
    n_frames = int(round(duration_s * fps))
    geom = geometry_for(w, h)
    out.parent.mkdir(parents=True, exist_ok=True)
    work = out.parent / f".work_{out.stem}"
    work.mkdir(parents=True, exist_ok=True)
    wav = work / "a.wav"
    write_low_audio_wav(wav, duration_s + 1.0)

    vb = MASTER_VBITRATE
    buf = str(int(vb[:-1]) * 2) + "k"
    enc = [
        "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
        "-f", "rawvideo", "-pix_fmt", "rgb24",
        "-s", f"{w}x{h}", "-r", FPS_STR, "-i", "pipe:0",
        "-i", str(wav),
        "-map", "0:v:0", "-map", "1:a:0",
        "-c:v", "libx264", "-profile:v", "baseline", "-level:v", "3.0", "-bf", "0",
        "-x264-params", "cabac=0:ref=1:bframes=0:keyint=48:level=30",
        "-pix_fmt", "yuv420p",
        "-b:v", vb, "-maxrate", vb, "-bufsize", buf,
        "-r", FPS_STR,
        "-c:a", "aac", "-b:a", A_BITRATE, "-ar", str(SR), "-ac", "1",
        "-t", str(duration_s),
        "-movflags", "+faststart",
        str(out),
    ]
    print(
        f"MASTER render {w}x{h} n={n_frames} dur={duration_s}s -> {out}",
        flush=True,
    )
    print(f"  text0={format_text(0)} id every frame", flush=True)
    proc = subprocess.Popen(enc, stdin=subprocess.PIPE)
    assert proc.stdin
    try:
        step = max(1, n_frames // 20)
        for i in range(n_frames):
            proc.stdin.write(render_frame(i, w, h, geom).tobytes())
            if (i + 1) % step == 0:
                print(f"  master frames {i+1}/{n_frames}", flush=True)
    finally:
        proc.stdin.close()
        rc = proc.wait()
    print(f"  master ffmpeg_rc={rc}", flush=True)
    if rc != 0:
        raise SystemExit(f"master encode failed rc={rc}")
    try:
        wav.unlink(missing_ok=True)
        work.rmdir()
    except OSError:
        pass
    m = ffprobe_full(out)
    return {"ffmpeg_rc": rc, "n_frames": n_frames, "measured": m}


def reencode(
    src: Path,
    out: Path,
    *,
    w: int,
    h: int,
    v_kbit: int,
    refs: int,
    scale: bool,
) -> dict:
    """CBR-ish reencode from master. scale=True → vf scale to w:h."""
    vb = f"{v_kbit}k"
    buf = f"{v_kbit * 2}k"
    out.parent.mkdir(parents=True, exist_ok=True)
    x264 = f"cabac=0:ref={refs}:bframes=0:keyint=48:level=30:vbv-maxrate={v_kbit}:vbv-bufsize={v_kbit * 2}"
    cmd = [
        "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
        "-i", str(src),
    ]
    if scale:
        # force exact coded size; SAR 1:1
        cmd += ["-vf", f"scale={w}:{h}:flags=bicubic,setsar=1/1"]
    cmd += [
        "-c:v", "libx264", "-profile:v", "baseline", "-level:v", "3.0", "-bf", "0",
        "-x264-params", x264,
        "-pix_fmt", "yuv420p",
        "-b:v", vb, "-maxrate", vb, "-bufsize", buf,
        "-r", FPS_STR,
        "-c:a", "aac", "-b:a", A_BITRATE, "-ar", str(SR), "-ac", "1",
        "-movflags", "+faststart",
        str(out),
    ]
    print(
        f"REENCODE -> {out.name} target_v={vb} refs={refs} {w}x{h} scale={scale}",
        flush=True,
    )
    p = subprocess.run(cmd, capture_output=True, text=True)
    print(f"  ffmpeg_rc={p.returncode}", flush=True)
    if p.returncode != 0:
        print(p.stderr[-2000:] if p.stderr else "", flush=True)
        raise SystemExit(f"reencode failed {out} rc={p.returncode}")
    m = ffprobe_full(out)
    return {
        "ffmpeg_rc": p.returncode,
        "cmd": cmd,
        "target_v_kbit": v_kbit,
        "target_refs": refs,
        "target_w": w,
        "target_h": h,
        "measured": m,
    }


def title_for(w: int, h: int, v_kbit: int, refs: int, duration_s: float) -> str:
    ds = int(round(duration_s))
    return (
        f"MiSTerPlex BitrateLadder {w}x{h} 24fps {v_kbit}kbit "
        f"ref{refs} {ds}s (2026).mp4"
    )


def stem_for(w: int, h: int, v_kbit: int, refs: int, duration_s: float) -> str:
    ds = int(round(duration_s))
    return f"bitrate_ladder_{w}x{h}_24_{v_kbit}k_ref{refs}_{ds}s"


def spec_ok(m: dict, *, w: int, h: int, refs: int, v_kbit: int) -> list[str]:
    fails = []
    if m.get("width") != w or m.get("height") != h:
        fails.append(f"geom {m.get('width')}x{m.get('height')} != {w}x{h}")
    if m.get("r_frame_rate") != "24/1":
        fails.append(f"r_frame_rate={m.get('r_frame_rate')} != 24/1")
    if m.get("profile") != "Constrained Baseline":
        fails.append(f"profile={m.get('profile')}")
    if m.get("level") not in (30, "30", 3.0):
        # ffprobe level is 30 for 3.0
        if int(m.get("level") or 0) > 30:
            fails.append(f"level={m.get('level')} > 30")
    if int(m.get("has_b_frames") or 0) != 0:
        fails.append(f"has_b_frames={m.get('has_b_frames')}")
    sps = m.get("sps") or {}
    if sps.get("max_num_ref_frames") != refs:
        fails.append(
            f"max_num_ref_frames={sps.get('max_num_ref_frames')} != {refs}"
        )
    if sps.get("level_idc") not in (30, None) and sps.get("level_idc") and sps["level_idc"] > 30:
        fails.append(f"level_idc={sps.get('level_idc')}")
    if m.get("a_codec") != "aac":
        fails.append(f"a_codec={m.get('a_codec')}")
    if str(m.get("a_sample_rate")) != "48000":
        fails.append(f"a_sr={m.get('a_sample_rate')}")
    # bitrate: allow ±15% on video stream bit_rate (CBR overshoot common)
    vk = m.get("v_bit_rate_k")
    if vk is None:
        fails.append("v_bit_rate missing")
    else:
        lo, hi = v_kbit * 0.85, v_kbit * 1.20
        if not (lo <= vk <= hi):
            fails.append(f"v_bit_rate_k={vk:.1f} outside [{lo:.0f},{hi:.0f}] vs target {v_kbit}")
    return fails


def write_docs(rows: list[dict], path: Path, media_dir: Path) -> None:
    lines = [
        "# Bitrate / refFrames / geometry ladder (link ceiling)",
        "",
        "**Purpose:** isolate the variables confounded in rk=9 vs rk=27 so the",
        "parent can measure the MiSTer link ceiling as a **curve**.",
        "",
        "Parent measured link (direct download, no transcode): **1.56 Mbit/s**.",
        "",
        "## PRE-REGISTER (before device measure)",
        "",
        "| claim | prediction |",
        "|-------|------------|",
        "| collapse threshold (video kbit/s) | **between 1400 and 1800** |",
        "| rationale | link 1560 kbit/s − audio≈48 − mux ≈ **~1450–1500** video headroom |",
        "| shape | **sharp cliff** once sustained demand > link (buffer underrun), not smooth A/V drift |",
        "| 400/700/1000 | healthy (desync_risk=0, glass n advances) |",
        "| 1400 | edge / intermittent |",
        "| 1800+ | collapse (stalls / drops / freeze-looking holds) |",
        "| ref1 vs ref3 @ 700 | **no** material difference if bitrate is the cause |",
        "| 624x480 vs 624x352 @ 700 | **no** material difference if bitrate is the cause |",
        "",
        "Publish miss if wrong — valued here.",
        "",
        "## Fixed axes (all clips unless noted)",
        "",
        "- fps **24/1** (not 24000/1001) — measured per row",
        "- H.264 **Constrained Baseline**, **level 3.0**, **B=0**",
        "- AAC **48 kHz**, **48 kbit/s** mono (pinned; not an axis)",
        "- Duration **≥ 600 s**",
        "- Glass ID every frame: `G n=DDDDDD c=C` + Grey bars (`draw_id_band`, no enable=)",
        "- Full-bleed moving body (not mean-luma-black)",
        "- Encode: CBR-ish `-b:v=maxrate`, `bufsize=2×`",
        "",
        "## Measured table",
        "",
        "| file | axis | W×H | fps | target_v | meas_v_k | meas_total_k | refs SPS | profile/level | B | aac_k | nb | dur | spec |",
        "|------|------|-----|-----|---------:|---------:|-------------:|---------:|---------------|---|------:|---:|----:|------|",
    ]
    for r in rows:
        m = r["measured"]
        sps = m.get("sps") or {}
        lines.append(
            "| `{title}` | {axis} | **{w}×{h}** | **{fps}** | {tv} | **{mv}** | **{mt}** | **{refs}** | {prof}/L{lev} | {b} | {ak} | {nb} | {dur} | {ok} |".format(
                title=r["title"],
                axis=r["axis"],
                w=m.get("width"),
                h=m.get("height"),
                fps=m.get("r_frame_rate"),
                tv=r["target_v_kbit"],
                mv=f"{m.get('v_bit_rate_k'):.1f}" if m.get("v_bit_rate_k") else "?",
                mt=f"{m.get('format_bit_rate_k'):.1f}" if m.get("format_bit_rate_k") else "?",
                refs=sps.get("max_num_ref_frames"),
                prof=m.get("profile"),
                lev=m.get("level"),
                b=m.get("has_b_frames"),
                ak=f"{m.get('a_bit_rate_k'):.1f}" if m.get("a_bit_rate_k") else "?",
                nb=m.get("nb_frames"),
                dur=m.get("format_duration"),
                ok="YES" if not r.get("fails") else "NO:" + ";".join(r["fails"]),
            )
        )
    lines += [
        "",
        "## Parent PMS ingest (section 2 only — you run)",
        "",
        "```bash",
        f"ls -1 {media_dir}/MiSTerPlex\\ BitrateLadder*",
        'curl -sS -o /dev/null -w \'refresh_http=%{http_code}\\n\' \\',
        '  "http://192.168.1.24:32400/library/sections/2/refresh?X-Plex-Token=$TOK"',
        'echo "refresh true rc=$?"',
        "# enumerate ratingKeys after scan:",
        'curl -sS "http://192.168.1.24:32400/library/sections/2/all?X-Plex-Token=$TOK" -o /tmp/pms_s2.xml',
        'echo "all true rc=$?"',
        "python3 - <<'PY'",
        "import xml.etree.ElementTree as ET",
        "root=ET.parse('/tmp/pms_s2.xml').getroot()",
        "for v in sorted(root.findall('.//Video'), key=lambda e:int(e.get('ratingKey',0))):",
        "    t=v.get('title') or ''",
        "    if 'BitrateLadder' in t or 'Bitrate' in t:",
        "        print(f\"rk={v.get('ratingKey')} dur_ms={v.get('duration')} | {t}\")",
        "PY",
        "```",
        "",
        "PMS geometry/bitrate tags are **claims** — trust ffprobe / this table.",
        "Prefer Direct Play. Agent does not cast or touch 192.168.1.183.",
        "",
        "## Reproduce",
        "",
        "```bash",
        "python3 scripts/gen_bitrate_ladder.py --duration 600 --copy-media",
        "```",
        "",
        "Generator: `scripts/gen_bitrate_ladder.py`",
        "Probe JSON: `docs/bitrate_ladder_probe.json`",
        "",
    ]
    path.write_text("\n".join(lines) + "\n")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--duration", type=float, default=600.0)
    ap.add_argument("--out-dir", type=Path, default=ROOT / "assets" / "avsync")
    ap.add_argument("--work-dir", type=Path, default=None)
    ap.add_argument(
        "--media-dir",
        type=Path,
        default=Path.home() / "plex" / "media" / "movies",
    )
    ap.add_argument("--copy-media", action="store_true")
    ap.add_argument(
        "--skip-master-if-exists",
        action="store_true",
        help="reuse existing master mp4 if present",
    )
    args = ap.parse_args()

    out_dir: Path = args.out_dir
    out_dir.mkdir(parents=True, exist_ok=True)
    work = args.work_dir or (ROOT / ".agent-work" / "bitrate-ladder")
    work.mkdir(parents=True, exist_ok=True)
    master = work / f"master_624x480_24_{int(args.duration)}s.mp4"

    if args.skip_master_if_exists and master.is_file():
        print(f"REUSE master {master}", flush=True)
        master_info = {"measured": ffprobe_full(master)}
    else:
        master_info = encode_master(master, args.duration, 624, 480)

    # Build job list: (axis, w, h, v_kbit, refs, scale_from_master)
    jobs: list[tuple[str, int, int, int, int, bool]] = []
    for k in SWEEP_KBIT:
        jobs.append((f"bitrate_sweep_{k}", 624, 480, k, 1, False))
    # ref pair: ref3 at 700 (ref1 already in sweep)
    jobs.append(("ref_pair_ref3", 624, 480, REF_PAIR_KBIT, 3, False))
    # geom pair: 624x352 at 700 ref1
    jobs.append(("geom_pair_624x352", 624, 352, GEOM_PAIR_KBIT, 1, True))

    rows = []
    probe_blob = {
        "pre_register": {
            "link_kbit_s_measured_by_parent": 1560,
            "collapse_video_kbit_predicted": "1400-1800",
            "shape": "sharp_cliff",
            "ref_pair_at_700_expected": "no_material_diff_if_bitrate_cause",
            "geom_pair_at_700_expected": "no_material_diff_if_bitrate_cause",
        },
        "master": master_info,
        "clips": [],
    }

    for axis, w, h, vk, refs, scale in jobs:
        stem = stem_for(w, h, vk, refs, args.duration)
        out = out_dir / f"{stem}.mp4"
        title = title_for(w, h, vk, refs, args.duration)
        info = reencode(master, out, w=w, h=h, v_kbit=vk, refs=refs, scale=scale)
        m = info["measured"]
        fails = spec_ok(m, w=w, h=h, refs=refs, v_kbit=vk)
        print(
            f"  MEASURED {m.get('width')}x{m.get('height')} r={m.get('r_frame_rate')} "
            f"v_k={m.get('v_bit_rate_k')} total_k={m.get('format_bit_rate_k')} "
            f"refs={m.get('sps',{}).get('max_num_ref_frames')} "
            f"prof={m.get('profile')} L={m.get('level')} B={m.get('has_b_frames')} "
            f"ok={not fails} fails={fails}",
            flush=True,
        )
        meta = {
            "title": title,
            "axis": axis,
            "target_v_kbit": vk,
            "target_refs": refs,
            "target_w": w,
            "target_h": h,
            "fps_rational": "24/1",
            "duration_s_design": args.duration,
            "audio": f"aac {A_BITRATE} 48kHz mono",
            "content": "fullbleed_moving+glass_id_every_frame",
            "measured": m,
            "fails": fails,
            "ffmpeg_cmd": info["cmd"],
        }
        meta_path = out.with_suffix(out.suffix + ".meta.json")
        meta_path.write_text(json.dumps(meta, indent=2) + "\n")
        if args.copy_media:
            dest = args.media_dir / title
            args.media_dir.mkdir(parents=True, exist_ok=True)
            subprocess.run(["cp", "-f", str(out), str(dest)], check=True)
            print(f"  COPIED {dest}", flush=True)
            meta["media_path"] = str(dest)
        rows.append(meta)
        probe_blob["clips"].append(meta)

    docs = ROOT / "docs"
    docs.mkdir(exist_ok=True)
    write_docs(rows, docs / "BITRATE_LADDER.md", args.media_dir)
    (docs / "bitrate_ladder_probe.json").write_text(
        json.dumps(probe_blob, indent=2) + "\n"
    )
    n_fail = sum(1 for r in rows if r.get("fails"))
    print(
        f"DONE n={len(rows)} spec_fail={n_fail} md={docs / 'BITRATE_LADDER.md'}",
        flush=True,
    )
    return 1 if n_fail else 0


if __name__ == "__main__":
    raise SystemExit(main())
