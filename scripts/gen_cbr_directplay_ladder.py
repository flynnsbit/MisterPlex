#!/usr/bin/env python3
"""CBR direct-play ladder — dose-response vs measured path ceiling 1.15 Mbit/s.

Primary test (supersedes staircase as first deliverable):
  Identical content/geometry/codec; CBR rungs 400/800/1200/1600/2000 kbit/s video.
  Sources already match plex_resolve accept rules (h264 baseline level≤3.0 aac) so
  PMS **should** Direct Play — delivered bitrate == source bitrate (no transcoder).
  Parent verifies GEOM ``transcoded=0``; agent cannot cast.

Parent pre-reg (greedy goodput 1.153 Mbit/s):
  400/800 ≥0.95; 1200 knee 0.90–1.00; 1600≈0.72; 2000≈0.58.
  All five ≥0.95 ⇒ VBR/bitrate account dead.

supply_ratio (parent metric): audio_s / wall_s
  audio_s = audioBytes / (48000*4)   # media_player.cpp audible PCM seconds
  wall_s  = wall_ms/1000
  (supply_bucket.hpp tracks supply_gap = expected_frames - d_frames; parent
   scores ratio from the media: audio_s/wall_s pair.)

Also: one non-bank twin at 1200k (640x480).

Every frame: glass ID. Rate 24/1. CB L3.0 B=0 AAC 48k stereo.
True CBR: -b:v=-minrate=-maxrate, nal-hrd=cbr.
"""
from __future__ import annotations

import argparse
import json
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

FPS_STR = "24"
FPS = 24.0
SR = 48000
A_BITRATE = "128k"
RUNGS_K = [400, 800, 1200, 1600, 2000]
# Parent path: GREEDY GOODPUT 1.153 Mbit/s; capacity p95 1.292
PATH_GOODPUT_KBIT = 1153.0


def render_frame(n: int, w: int, h: int, geom) -> np.ndarray:
    """Always-bright structured motion so CBR can fill high rungs."""
    rgb = np.empty((h, w, 3), dtype=np.uint8)
    id_bottom = geom.bar_y1
    # base gradient
    yy = np.linspace(60, 120, h, dtype=np.float32)[:, None]
    xx = np.linspace(0, 40, w, dtype=np.float32)[None, :]
    base = np.clip(yy + xx, 0, 255).astype(np.uint8)
    rgb[:, :, 0] = base
    rgb[:, :, 1] = np.clip(base.astype(np.int16) + 10, 0, 255).astype(np.uint8)
    rgb[:, :, 2] = np.clip(base.astype(np.int16) + 20, 0, 255).astype(np.uint8)
    # scrolling checker + noise grain (keeps encoder busy at high CBR)
    ys = np.arange(h)[:, None]
    xs = np.arange(w)[None, :]
    phase = n * 3
    chk = ((xs + phase) // 10 + (ys + phase // 2) // 10) & 1
    rgb = np.where(
        chk[..., None] == 0,
        np.clip(rgb.astype(np.int16) - 35, 0, 255),
        np.clip(rgb.astype(np.int16) + 35, 0, 255),
    ).astype(np.uint8)
    rng = np.random.default_rng((n * 1103515245 + 12345) & 0xFFFFFFFF)
    grain = rng.integers(-25, 26, size=(h, w, 1), dtype=np.int16)
    rgb = np.clip(rgb.astype(np.int16) + grain, 0, 255).astype(np.uint8)
    # moving block
    bw, bh = max(64, w // 6), max(48, (h - id_bottom) // 4)
    x = (n * 5) % max(1, w - bw)
    y = id_bottom + (n * 3) % max(1, h - id_bottom - bh)
    rgb[y : y + bh, x : x + bw] = (250, 220, 30)
    # binary ticks
    tick_h = max(12, (h - id_bottom) // 12)
    ty = h - tick_h - 2
    bit_w = max(8, w // 16)
    for bit in range(14):
        on = (n >> bit) & 1
        x0 = 4 + bit * bit_w
        rgb[ty : ty + tick_h, x0 : min(w - 2, x0 + bit_w - 2)] = (
            (240, 240, 240) if on else (30, 30, 30)
        )
    rgb[id_bottom + 4 : id_bottom + 12, w // 10 : 9 * w // 10] = (220, 30, 30)
    draw_id_band(rgb, n, geom)
    return rgb


def write_audio(path: Path, duration_s: float) -> None:
    n = int(round(duration_s * SR))
    t = np.arange(n, dtype=np.float64) / SR
    mono = 0.08 * np.sin(2 * np.pi * 440.0 * t)
    s16 = np.clip(mono * 32767, -32768, 32767).astype(np.int16)
    stereo = np.column_stack([s16, s16])
    with wave.open(str(path), "w") as wf:
        wf.setnchannels(2)
        wf.setsampwidth(2)
        wf.setframerate(SR)
        wf.writeframes(stereo.tobytes())


def sps_trace(path: Path) -> dict:
    p = subprocess.run(
        [
            "ffmpeg", "-hide_banner", "-i", str(path),
            "-c:v", "copy", "-bsf:v", "trace_headers", "-frames:v", "2",
            "-f", "null", "-",
        ],
        capture_output=True,
        text=True,
    )
    text = p.stderr or ""

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
        return int(x) if x not in (None, "N/A") else None

    v, a, f = ik(st.get("bit_rate")), ik(ast.get("bit_rate")), ik(fmt.get("bit_rate"))
    return {
        "ffprobe_v_rc": p.returncode,
        "ffprobe_a_rc": ca.returncode,
        "width": st.get("width"),
        "height": st.get("height"),
        "r_frame_rate": st.get("r_frame_rate"),
        "nb_frames": st.get("nb_frames"),
        "profile": st.get("profile"),
        "level": st.get("level"),
        "has_b_frames": st.get("has_b_frames"),
        "v_bit_rate_k": (v / 1000.0) if v else None,
        "format_duration": fmt.get("duration"),
        "format_bit_rate_k": (f / 1000.0) if f else None,
        "size_bytes": ik(fmt.get("size")),
        "a_codec": ast.get("codec_name"),
        "a_sample_rate": ast.get("sample_rate"),
        "a_channels": ast.get("channels"),
        "a_bit_rate_k": (a / 1000.0) if a else None,
        "sps": sps_trace(path),
    }


def parent_prereg(v_k: int, total_k: float | None) -> dict:
    """Mirror parent table; total includes ~128k audio."""
    # Use video rung as parent did; note total for DP delivery
    table = {
        400: ("≥ 0.95", "well under 1.15 Mbit path"),
        800: ("≥ 0.95", "under path"),
        1200: ("0.90–1.00 knee", "discriminating rung vs 1.15 Mbit goodput"),
        1600: ("≈ 0.72", "over path"),
        2000: ("≈ 0.58", "over path ~1.6×"),
    }
    sr, note = table.get(v_k, ("unknown", ""))
    return {
        "expected_supply_ratio": sr,
        "note": note,
        "path_goodput_kbit_s": PATH_GOODPUT_KBIT,
        "total_kbit_if_known": total_k,
        "kill_criterion": "all five rungs supply_ratio≥0.95 ⇒ bitrate account dead",
    }


def encode_cbr(out: Path, w: int, h: int, n_frames: int, v_k: int) -> dict:
    duration_s = n_frames / FPS
    geom = geometry_for(w, h)
    out.parent.mkdir(parents=True, exist_ok=True)
    work = out.parent / f".work_{out.stem}"
    work.mkdir(parents=True, exist_ok=True)
    wav = work / "a.wav"
    write_audio(wav, duration_s + 0.5)
    x264 = (
        f"cabac=0:ref=1:bframes=0:keyint=48:level=30:nal-hrd=cbr:force-cfr=1:"
        f"vbv-maxrate={v_k}:vbv-bufsize={v_k * 2}"
    )
    cmd = [
        "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
        "-f", "rawvideo", "-pix_fmt", "rgb24",
        "-s", f"{w}x{h}", "-r", FPS_STR, "-i", "pipe:0",
        "-i", str(wav),
        "-map", "0:v:0", "-map", "1:a:0",
        "-c:v", "libx264", "-profile:v", "baseline", "-level:v", "3.0", "-bf", "0",
        "-x264-params", x264,
        "-pix_fmt", "yuv420p",
        "-b:v", f"{v_k}k", "-minrate", f"{v_k}k", "-maxrate", f"{v_k}k",
        "-bufsize", f"{v_k * 2}k",
        "-r", FPS_STR,
        "-c:a", "aac", "-b:a", A_BITRATE, "-ar", str(SR), "-ac", "2",
        "-shortest", "-movflags", "+faststart",
        str(out),
    ]
    print(f"ENCODE CBR {v_k}k {w}x{h} -> {out.name}", flush=True)
    print("  CMD", " ".join(cmd), flush=True)
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    assert proc.stdin
    try:
        step = max(1, n_frames // 15)
        for i in range(n_frames):
            proc.stdin.write(render_frame(i, w, h, geom).tobytes())
            if (i + 1) % step == 0:
                print(f"  frames {i+1}/{n_frames}", flush=True)
    finally:
        proc.stdin.close()
        rc = proc.wait()
    print(f"  ffmpeg_rc={rc}", flush=True)
    if rc != 0:
        raise SystemExit(f"encode rc={rc}")
    try:
        wav.unlink(missing_ok=True)
        work.rmdir()
    except OSError:
        pass
    return {"cmd": cmd, "ffmpeg_rc": rc}


def spec_ok(m: dict, w: int, h: int, v_k: int) -> list[str]:
    fails = []
    if m.get("width") != w or m.get("height") != h:
        fails.append("geom")
    if m.get("r_frame_rate") != "24/1":
        fails.append(f"fps={m.get('r_frame_rate')}")
    if m.get("profile") != "Constrained Baseline":
        fails.append(f"profile={m.get('profile')}")
    if int(m.get("level") or 99) > 30:
        fails.append(f"level={m.get('level')}")
    if int(m.get("has_b_frames") or 0) != 0:
        fails.append("B")
    if (m.get("sps") or {}).get("max_num_ref_frames") != 1:
        fails.append(f"refs={m.get('sps',{}).get('max_num_ref_frames')}")
    if m.get("a_codec") != "aac" or str(m.get("a_sample_rate")) != "48000":
        fails.append("audio")
    if int(m.get("a_channels") or 0) != 2:
        fails.append("ach")
    vk = m.get("v_bit_rate_k")
    if vk is None or not (v_k * 0.92 <= vk <= v_k * 1.08):
        fails.append(f"v_k={vk} vs {v_k}")
    return fails


def title(w, h, v_k, dur_s) -> str:
    return f"MiSTerPlex CBR-DP {w}x{h} 24fps {v_k}kbit {int(dur_s)}s (2026).mp4"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--duration", type=float, default=180.0)
    ap.add_argument("--out-dir", type=Path, default=ROOT / "assets" / "avsync")
    ap.add_argument("--media-dir", type=Path, default=Path.home() / "plex/media/movies")
    ap.add_argument("--copy-media", action="store_true")
    args = ap.parse_args()

    n_frames = int(round(args.duration * FPS))
    dur = n_frames / FPS
    args.out_dir.mkdir(parents=True, exist_ok=True)

    jobs = [(624, 480, k) for k in RUNGS_K]
    jobs.append((640, 480, 1200))  # non-bank knee twin

    clips = []
    for w, h, vk in jobs:
        stem = f"cbr_dp_{w}x{h}_24_{vk}k_{int(dur)}s"
        out = args.out_dir / f"{stem}.mp4"
        enc = encode_cbr(out, w, h, n_frames, vk)
        m = ffprobe_full(out)
        fails = spec_ok(m, w, h, vk)
        t = title(w, h, vk, dur)
        pr = parent_prereg(vk, m.get("format_bit_rate_k"))
        print(
            f"  MEASURED {m.get('width')}x{m.get('height')} r={m.get('r_frame_rate')} "
            f"v={m.get('v_bit_rate_k')} tot={m.get('format_bit_rate_k')} "
            f"{m.get('profile')} L{m.get('level')} B={m.get('has_b_frames')} "
            f"refs={m.get('sps',{}).get('max_num_ref_frames')} "
            f"prereg_sr={pr['expected_supply_ratio']} fails={fails}",
            flush=True,
        )
        meta = {
            "title": t,
            "role": "cbr_directplay_ladder",
            "target_v_kbit": vk,
            "fps_rational": "24/1",
            "duration_s": dur,
            "bank_fit": "favourable" if (w, h) == (624, 480) else "adversarial",
            "direct_play_contract": {
                "videoCodec": "h264",
                "profile": "Constrained Baseline",
                "level_max": 3.0,
                "level_measured": m.get("level"),
                "b_frames": 0,
                "audio": "aac 48k stereo",
                "note": "Matches plex_resolve weak ladder accept. Parent must confirm GEOM transcoded=0.",
            },
            "supply_ratio_def": {
                "formula": "audio_s / wall_s",
                "audio_s": "audioBytes/(48000*4)  # media_player.cpp",
                "wall_s": "wall_ms/1000.0",
                "record": "primary metric per rung; 120s+ playback enough",
            },
            "prereg": pr,
            "measured": m,
            "fails": fails,
            "ffmpeg_cmd": enc["cmd"],
            "id_every_frame": True,
            "id_example": format_text(0),
        }
        (out.with_suffix(out.suffix + ".meta.json")).write_text(
            json.dumps(meta, indent=2) + "\n"
        )
        if args.copy_media:
            dest = args.media_dir / t
            args.media_dir.mkdir(parents=True, exist_ok=True)
            shutil.copy2(out, dest)
            meta["media_path"] = str(dest)
            print(f"  COPIED {dest}", flush=True)
        clips.append(meta)

    docs = ROOT / "docs"
    docs.mkdir(exist_ok=True)
    lines = [
        "# CBR Direct-Play ladder (path ceiling dose-response)",
        "",
        "**Path (parent greedy-pull, playback stopped):** goodput **1.153 Mbit/s**",
        "sustained 60 s; capacity p95 1.292 Mbit/s. Prior ~670 kbit figure was the",
        "**pacer**, not the link — retracted for sizing.",
        "",
        "**Design:** identical content; CBR-only axis; sources already satisfy",
        "`plex_resolve` h264/baseline/level≤3.0/aac → **Direct Play** expected",
        "(delivered bitrate == source). Parent confirms `transcoded=0` on GEOM.",
        "",
        "## supply_ratio (what to record)",
        "",
        "```",
        "supply_ratio = audio_s / wall_s",
        "audio_s = audioBytes / (48000 * 4)   // media_player.cpp PCM seconds",
        "wall_s  = wall_ms / 1000.0",
        "```",
        "Primary per-rung metric. 120 s playback enough.",
        "",
        "## Parent pre-registration (on record before device)",
        "",
        "| rung v | expected supply_ratio |",
        "|-------:|----------------------|",
        "| 400k | ≥ 0.95 |",
        "| 800k | ≥ 0.95 |",
        "| **1200k** | **0.90–1.00 knee** |",
        "| 1600k | ≈ 0.72 |",
        "| 2000k | ≈ 0.58 |",
        "",
        "All five ≥ 0.95 ⇒ bitrate/VBR account **dead** (publish miss).",
        "",
        "## Measured clips",
        "",
        "| title | W×H | fps | tgt_v | meas_v | total_k | refs | CB/L/B | aac | bank | prereg_sr | spec |",
        "|-------|-----|-----|------:|-------:|--------:|-----:|--------|-----|------|-----------|------|",
    ]
    for c in clips:
        m = c["measured"]
        sps = m.get("sps") or {}
        lines.append(
            "| `{t}` | **{w}×{h}** | **{fps}** | {tv} | **{mv}** | **{tot}** | **{rf}** | {p}/L{lv}/B{b} | {ak}k/{ch}ch | {bank} | {sr} | {ok} |".format(
                t=c["title"],
                w=m.get("width"),
                h=m.get("height"),
                fps=m.get("r_frame_rate"),
                tv=c["target_v_kbit"],
                mv=f"{m.get('v_bit_rate_k'):.1f}" if m.get("v_bit_rate_k") else "?",
                tot=f"{m.get('format_bit_rate_k'):.1f}" if m.get("format_bit_rate_k") else "?",
                rf=sps.get("max_num_ref_frames"),
                p=m.get("profile"),
                lv=m.get("level"),
                b=m.get("has_b_frames"),
                ak=f"{m.get('a_bit_rate_k'):.0f}" if m.get("a_bit_rate_k") else "?",
                ch=m.get("a_channels"),
                bank=c["bank_fit"],
                sr=c["prereg"]["expected_supply_ratio"],
                ok="YES" if not c["fails"] else "NO",
            )
        )
    lines += [
        "",
        "## PMS ingest",
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
        "    if 'CBR-DP' in t or 'CBR DP' in t:",
        "        print(f\"rk={v.get('ratingKey')} dur_ms={v.get('duration')} frameRate={v.get('frameRate')} | {t}\")",
        "PY",
        "```",
        "",
        "Quote PMS `frameRate` when present; asset truth is ffprobe **24/1**.",
        "Direct-play verification is **parent-only** (device GEOM `transcoded=0`).",
        "",
        "## Second deliverable (already shipped)",
        "",
        "Within-session VBR staircase: `docs/VBR_MOTION_STAIRCASE.md` (rk≈101–104).",
        "",
        "```bash",
        f"python3 scripts/gen_cbr_directplay_ladder.py --duration {int(dur)} --copy-media",
        "```",
        "",
    ]
    (docs / "CBR_DIRECTPLAY_LADDER.md").write_text("\n".join(lines) + "\n")
    (docs / "cbr_directplay_ladder_probe.json").write_text(
        json.dumps(
            {
                "path_goodput_kbit_s": PATH_GOODPUT_KBIT,
                "path_capacity_p95_kbit_s": 1292.0,
                "parent_prereg": {
                    400: ">=0.95",
                    800: ">=0.95",
                    1200: "0.90-1.00 knee",
                    1600: "~0.72",
                    2000: "~0.58",
                },
                "supply_ratio": "audio_s/wall_s",
                "clips": clips,
            },
            indent=2,
        )
        + "\n"
    )
    n_fail = sum(1 for c in clips if c["fails"])
    print(f"DONE n={len(clips)} spec_fail={n_fail}", flush=True)
    return 1 if n_fail else 0


if __name__ == "__main__":
    raise SystemExit(main())
