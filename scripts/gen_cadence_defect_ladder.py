#!/usr/bin/env python3
"""Cadence / judder ground-truth fixtures for w-instr glass_motion_judder.

Closes the gap lipsync fixtures cannot: presentation-interval judder
(holds / ~83 ms IFI), not flash↔beep phase.

Per-frame identity (EVERY frame, no enable= guard)
--------------------------------------------------
  - Glass ID band: G n=DDDDDD c=C + Grey bars (tools/glass_frame_id.py)
  - Full-frame structure: black-lift checker + large moving block keyed by n
  - Binary tick row of n (high contrast) — MAD-distinct neighbours by construction
  - Not pure black (ERROR 13); not "any noise = motion" (ERROR 8)

Defect model (ground truth recorded, never inferred)
----------------------------------------------------
  Fixed presentation timeline at fps=24/1 unless mode=drop_* shortens it.

  control     : id[i]=i for i in 0..N-1; dups=0 drops=0
  dup_K       : K holds — id repeated at known slot indices; N slots; unique=N-K
  drop_K      : K content skips — id jumps +2 at known indices; duration shortens
                by K/24 s (frame omitted from CFR stream). unique = frames.
  periodic_h24: hold once every 24 slots (≈1 Hz) — strong bimodal IFI

Hold/dup is what glass_motion_judder's IFI histogram sees (~83 ms mass).
drop_K is for identity-jump recovery (glass n); MAD still changes every frame
on drop (double-step bar) — document both.

Anti-beat note
--------------
  Content advances every 1 source frame (period 1/24 s = 41.666… ms).
  There is NO independent flash period that could beat against 30/60 capture.
  24.000:30.000 = 4:5 commensurate — healthy capture holds are DISCRETE {1,2};
  see w-instr glass_motion_beat_ifi (reject T_cap/sqrt(12) continuous floor).

Encoder: H.264 Constrained Baseline, bf=0, AAC 48 kHz silence+click optional,
rate 24/1. Tiers: 624x480 (user DECODE conf) and 320x240 control.

Usage:
  python3 scripts/gen_cadence_defect_ladder.py --duration 300 --copy-media
  python3 scripts/gen_cadence_defect_ladder.py --only 624x480:control --host-floor-dir .agent-work/cadence-floor
"""
from __future__ import annotations

import argparse
import json
import math
import subprocess
import sys
import wave
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from glass_frame_id import draw_id_band, format_text, geometry_for  # noqa: E402

FPS_NUM = 24
FPS_DEN = 1
SR = 48000
BLACK_LIFT = 48

# (mode, K or period, label_suffix)
LADDER = [
    ("control", 0, "control_d0"),
    ("dup", 1, "dup1"),
    ("dup", 5, "dup5"),
    ("dup", 20, "dup20"),
    ("drop", 1, "drop1"),
    ("drop", 5, "drop5"),
    ("drop", 20, "drop20"),
    ("periodic", 24, "periodic_hold_every24"),
]

TIERS = [
    (624, 480, "bank480"),
    (320, 240, "p240"),
]


def build_slot_ids(
    n_slots: int,
    mode: str,
    k: int,
    *,
    seed: int = 1,
) -> tuple[list[int], dict]:
    """Return content_id per encoded frame + ground-truth record."""
    rng = np.random.default_rng(seed)
    gt: dict = {
        "mode": mode,
        "k_param": k,
        "seed": seed,
        "n_slots_requested": n_slots,
        "dup_slot_indices": [],
        "drop_after_indices": [],
        "n_dups": 0,
        "n_drops": 0,
        "content_id_first": 0,
        "content_id_last": None,
        "n_unique_ids": None,
        "n_encoded_frames": None,
    }

    if mode == "control":
        ids = list(range(n_slots))
        gt["n_dups"] = 0
        gt["n_drops"] = 0
    elif mode == "dup":
        if k < 0 or k >= n_slots:
            raise ValueError(f"dup k={k} invalid for n_slots={n_slots}")
        # unique content runs for n_slots-k steps; insert k holds at random slots>0
        n_unique = n_slots - k
        hold_at = sorted(
            rng.choice(np.arange(1, n_slots), size=k, replace=False).tolist()
        ) if k else []
        ids = []
        cid = 0
        hold_set = set(hold_at)
        for slot in range(n_slots):
            if slot in hold_set and ids:
                ids.append(ids[-1])  # hold
            else:
                ids.append(cid)
                cid += 1
        # cid should be n_unique
        assert cid == n_unique, (cid, n_unique)
        assert sum(1 for i in range(1, len(ids)) if ids[i] == ids[i - 1]) == k
        gt["dup_slot_indices"] = hold_at
        gt["n_dups"] = k
        gt["n_drops"] = 0
    elif mode == "drop":
        if k < 0 or k >= n_slots:
            raise ValueError(f"drop k={k} invalid")
        # Omit k frames from a (n_slots+k)-long ideal sequence → n_slots encoded,
        # duration same as control... wait parent wants known drops.
        # Duration-shortening model: start from n_slots ideal, delete k frames.
        n_enc = n_slots - k
        delete_at = sorted(
            rng.choice(np.arange(1, n_slots - 1), size=k, replace=False).tolist()
        ) if k else []
        ids = []
        for i in range(n_slots):
            if i in delete_at:
                continue
            ids.append(i)
        # After delete, ids are non-contiguous — good. Length n_enc.
        assert len(ids) == n_enc
        gt["drop_after_indices"] = delete_at  # original indices removed
        gt["n_dups"] = 0
        gt["n_drops"] = k
        gt["n_slots_requested"] = n_slots
        gt["duration_shorten_s"] = k / (FPS_NUM / FPS_DEN)
    elif mode == "periodic":
        period = max(2, int(k))
        ids = []
        cid = 0
        hold_slots = []
        for slot in range(n_slots):
            if slot > 0 and slot % period == 0:
                ids.append(ids[-1])
                hold_slots.append(slot)
            else:
                ids.append(cid)
                cid += 1
        gt["dup_slot_indices"] = hold_slots
        gt["n_dups"] = len(hold_slots)
        gt["n_drops"] = 0
        gt["periodic_hold_period_slots"] = period
    else:
        raise ValueError(mode)

    gt["n_encoded_frames"] = len(ids)
    gt["n_unique_ids"] = len(set(ids))
    gt["content_id_last"] = ids[-1] if ids else None
    gt["content_id_first"] = ids[0] if ids else None
    # Hold count by consecutive equality
    holds = sum(1 for i in range(1, len(ids)) if ids[i] == ids[i - 1])
    gt["measured_consecutive_holds"] = holds
    jumps = sum(1 for i in range(1, len(ids)) if ids[i] - ids[i - 1] > 1)
    gt["measured_id_jumps_gt1"] = jumps
    return ids, gt


def render_frame(n: int, w: int, h: int, geom) -> np.ndarray:
    """Bright, MAD-distinct neighbours; glass ID last (no enable=)."""
    rgb = np.zeros((h, w, 3), dtype=np.uint8)
    # base lift + slow gradient (never pure black body)
    yy = np.linspace(BLACK_LIFT, 90, h, dtype=np.float32)[:, None]
    xx = np.linspace(0, 40, w, dtype=np.float32)[None, :]
    base = np.clip(yy + xx, 0, 255).astype(np.uint8)
    rgb[:, :, 0] = base
    rgb[:, :, 1] = np.clip(base.astype(np.int16) + 8, 0, 255).astype(np.uint8)
    rgb[:, :, 2] = np.clip(base.astype(np.int16) + 16, 0, 255).astype(np.uint8)

    # checker phase locked to n (neighbour frames differ)
    phase = (n * 3) % 64
    ys = np.arange(h)[:, None]
    xs = np.arange(w)[None, :]
    chk = ((xs + phase) // 16 + (ys + phase // 2) // 16) & 1
    rgb = np.where(chk[..., None] == 0, np.clip(rgb.astype(np.int16) - 20, 0, 255),
                   np.clip(rgb.astype(np.int16) + 20, 0, 255)).astype(np.uint8)

    id_bottom = geom.bar_y1
    # large moving block — primary MAD signal
    bw = max(48, w // 8)
    bh = max(40, (h - id_bottom) // 4)
    x = 8 + (n * max(3, w // 200)) % max(1, w - bw - 8)
    y = id_bottom + 8 + (n * 2) % max(1, h - id_bottom - bh - 16)
    rgb[y : y + bh, x : x + bw, :] = (250, 230, 40)

    # binary ticks of n (12 bits) — second MAD channel
    tick_h = max(12, (h - id_bottom) // 10)
    tick_y0 = h - tick_h - 4
    bit_w = max(8, w // 16)
    for bit in range(12):
        on = (n >> bit) & 1
        x0 = 4 + bit * bit_w
        x1 = min(w, x0 + bit_w - 2)
        rgb[tick_y0 : tick_y0 + tick_h, x0:x1, :] = (
            (240, 240, 240) if on else (40, 40, 40)
        )

    # red reference bar (chroma sanity)
    ry0 = id_bottom + max(4, (h - id_bottom) // 20)
    rgb[ry0 : ry0 + max(8, h // 40), w // 10 : 9 * w // 10, :] = (220, 30, 30)

    draw_id_band(rgb, n, geom)  # EVERY frame — no enable= guard
    return rgb


def write_silent_aac_wav(path: Path, duration_s: float, click_period_s: float = 2.0) -> None:
    """PCM wav then ffmpeg aac; soft click optional for A/V lanes (not required)."""
    n = int(round(duration_s * SR))
    mono = np.zeros(n, dtype=np.float32)
    # rare soft ticks — not the cadence marker (cadence is visual-only)
    k = 0
    while True:
        t0 = k * click_period_s
        if t0 >= duration_s:
            break
        i0 = int(t0 * SR)
        i1 = min(n, i0 + int(0.01 * SR))
        if i0 < n:
            mono[i0:i1] = 0.2
        k += 1
    s16 = (mono * 32767).astype(np.int16)
    with wave.open(str(path), "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(s16.tobytes())


def encode_ids(
    ids: list[int],
    *,
    w: int,
    h: int,
    out: Path,
    vbitrate: str,
) -> dict:
    fps = FPS_NUM / float(FPS_DEN)
    fps_str = f"{FPS_NUM}/{FPS_DEN}" if FPS_DEN != 1 else str(FPS_NUM)
    geom = geometry_for(w, h)
    n_frames = len(ids)
    duration_s = n_frames / fps
    out.parent.mkdir(parents=True, exist_ok=True)
    work = out.parent / f".work_{out.stem}"
    work.mkdir(parents=True, exist_ok=True)
    wav = work / "a.wav"
    write_silent_aac_wav(wav, duration_s)

    bufsize = str(int(vbitrate[:-1]) * 2) + "k" if vbitrate[-1] in "kK" else vbitrate
    enc = [
        "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
        "-f", "rawvideo", "-pix_fmt", "rgb24",
        "-s", f"{w}x{h}", "-r", fps_str, "-i", "pipe:0",
        "-i", str(wav),
        "-map", "0:v:0", "-map", "1:a:0",
        "-c:v", "libx264", "-profile:v", "baseline", "-bf", "0",
        "-x264-params", "cabac=0:ref=1:bframes=0:keyint=48",
        "-pix_fmt", "yuv420p",
        "-b:v", vbitrate, "-maxrate", vbitrate, "-bufsize", bufsize,
        "-r", fps_str,
        "-c:a", "aac", "-b:a", "96k", "-ar", str(SR), "-ac", "1",
        "-shortest", "-movflags", "+faststart",
        str(out),
    ]
    proc = subprocess.Popen(enc, stdin=subprocess.PIPE)
    assert proc.stdin
    try:
        step = max(1, n_frames // 20)
        for i, cid in enumerate(ids):
            fr = render_frame(int(cid), w, h, geom)
            proc.stdin.write(fr.tobytes())
            if (i + 1) % step == 0:
                print(f"  {out.name} frames {i+1}/{n_frames}", flush=True)
    finally:
        proc.stdin.close()
        rc = proc.wait()
    if rc != 0:
        raise SystemExit(f"ffmpeg rc={rc} for {out}")

    # cleanup work wav
    try:
        wav.unlink(missing_ok=True)
        work.rmdir()
    except OSError:
        pass

    probe = ffprobe(out)
    return {
        "out": str(out),
        "n_frames_encoded": n_frames,
        "duration_s_design": duration_s,
        "fps_rational": fps_str,
        "ffmpeg_rc": rc,
        "measured": probe,
    }


def ffprobe(path: Path) -> dict:
    cmd = [
        "ffprobe", "-v", "error",
        "-select_streams", "v:0",
        "-show_entries",
        "stream=width,height,r_frame_rate,avg_frame_rate,nb_frames,duration,"
        "profile,has_b_frames,codec_name",
        "-show_entries", "format=duration,size",
        "-of", "json", str(path),
    ]
    p = subprocess.run(cmd, capture_output=True, text=True)
    vrc = p.returncode
    data = json.loads(p.stdout) if p.stdout.strip() else {}
    ca = subprocess.run(
        [
            "ffprobe", "-v", "error", "-select_streams", "a:0",
            "-show_entries", "stream=codec_name,sample_rate,channels",
            "-of", "json", str(path),
        ],
        capture_output=True,
        text=True,
    )
    adata = json.loads(ca.stdout) if ca.stdout.strip() else {}
    st = (data.get("streams") or [{}])[0]
    fmt = data.get("format") or {}
    ast = (adata.get("streams") or [{}])[0]
    return {
        "ffprobe_v_rc": vrc,
        "ffprobe_a_rc": ca.returncode,
        "width": st.get("width"),
        "height": st.get("height"),
        "r_frame_rate": st.get("r_frame_rate"),
        "avg_frame_rate": st.get("avg_frame_rate"),
        "nb_frames": st.get("nb_frames"),
        "profile": st.get("profile"),
        "has_b_frames": st.get("has_b_frames"),
        "v_codec": st.get("codec_name"),
        "format_duration": fmt.get("duration"),
        "size_bytes": int(fmt["size"]) if fmt.get("size") else path.stat().st_size,
        "a_codec": ast.get("codec_name"),
        "a_sample_rate": ast.get("sample_rate"),
    }


def media_name(w: int, h: int, label: str, duration_s: float) -> str:
    dur = int(round(duration_s))
    return f"MiSTerPlex Cadence {w}x{h} 24fps {label} {dur}s (2026).mp4"


def verify_hold_count(ids: list[int], expect_dups: int) -> bool:
    holds = sum(1 for i in range(1, len(ids)) if ids[i] == ids[i - 1])
    return holds == expect_dups


def emit_host_floor(out_dir: Path, duration_s: float = 300.0) -> dict:
    """Host-playable control for MS2109 floor (non-device source)."""
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    w, h = 1280, 720  # easy for host display → HDMI
    n_slots = int(round(duration_s * FPS_NUM / FPS_DEN))
    ids, gt = build_slot_ids(n_slots, "control", 0, seed=0)
    out = out_dir / "cadence_24.000_control_300s.mp4"
    enc = encode_ids(ids, w=w, h=h, out=out, vbitrate="4000k")
    # also short static
    static = out_dir / "static_frame.png"
    try:
        from PIL import Image
        Image.fromarray(render_frame(n_slots // 2, w, h, geometry_for(w, h))).save(static)
    except Exception as e:
        static = None
        print("static_fail", e, flush=True)
    readme = out_dir / "README_PARENT_FLOOR.txt"
    readme.write_text(
        f"""PARENT — MS2109 instrument-floor capture (agent does NOT touch /dev/video0)

Fixture (host-playable exact CFR 24/1 control):
  {out.name}
  measured: see ground_truth_floor.json
  duration_s≈{duration_s}  fps=24/1  mode=control  n_dups=0 n_drops=0

PRE_REGISTER:
  Play this file on the display that feeds the MS2109 HDMI input.
  Capture PNG burst; score with w-instr glass_motion_judder.py --role instrument_floor.
  Healthy 24→30: hold mass on {{1,2}}. Floor TAIL = instrument envelope.
  Device claims require device tail exceeding floor (see w-instr --floor-json).

A) CADENCE FLOOR
  1. fuser -v /dev/video0   # must be free
  2. mpv --fs --no-osc --loop=no {out.name}
     # or: ffplay -fs -autoexit {out.name}
  3. Concurrent capture:
       mkdir -p floor_cap_cadence
       ffmpeg -v error -f v4l2 -input_format mjpeg -video_size 1920x1080 \\
         -i /dev/video0 -frames:v 300 -y floor_cap_cadence/f_%04d.png
       echo "capture true rc=$?"
  4. Score:
       python3 tools/glass_motion_judder.py floor_cap_cadence --warmup-skip 15 \\
         --source-fps 24 --source-fps-src caller_supplied_measured \\
         --capture-fps 30 --role instrument_floor
       echo "true rc=$?"

B) STATIC FLOOR (optional)
  mpv --fs --loop=inf {static.name if static else 'static_frame.png'}
  # capture ~120 frames; expect single long hold after warmup

true rc MUST be captured directly — never through a pipe.
"""
    )
    gt_path = out_dir / "ground_truth_floor.json"
    doc = {
        "role": "instrument_floor_host_playable",
        "ground_truth": gt,
        "encode": enc,
        "play_command": f"mpv --fs --no-osc --loop=no {out.name}",
        "anti_beat": {
            "content_step_period_s": 1.0 / 24.0,
            "independent_marker_period_s": None,
            "note": (
                "Identity advances every source frame (1/24 s). No flash period. "
                "24:30=4:5 commensurate — discrete holds {1,2} expected, not continuous beat."
            ),
        },
    }
    gt_path.write_text(json.dumps(doc, indent=2) + "\n")
    print(f"HOST_FLOOR {out} gt={gt_path}", flush=True)
    return doc


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--duration", type=float, default=300.0)
    ap.add_argument("--out-dir", type=Path, default=ROOT / "assets" / "avsync")
    ap.add_argument("--media-dir", type=Path,
                    default=Path.home() / "plex" / "media" / "movies")
    ap.add_argument("--copy-media", action="store_true")
    ap.add_argument("--host-floor-dir", type=Path, default=None,
                    help="also emit host-playable floor pack here")
    ap.add_argument("--only", action="append", default=[],
                    help="WxH:label e.g. 624x480:dup5 (repeatable)")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--manifest", type=Path,
                    default=ROOT / "docs" / "CADENCE_DEFECT_LADDER.md")
    ap.add_argument("--manifest-json", type=Path,
                    default=ROOT / "docs" / "cadence_defect_ladder_probe.json")
    args = ap.parse_args()

    n_slots = int(round(args.duration * FPS_NUM / float(FPS_DEN)))
    args.out_dir.mkdir(parents=True, exist_ok=True)

    only_set = set()
    for o in args.only:
        wh, lab = o.split(":", 1)
        only_set.add((wh, lab))

    rows = []
    for w, h, tier in TIERS:
        vbr = "2500k" if h >= 480 else "1200k"
        for mode, k, label in LADDER:
            if only_set and (f"{w}x{h}", label) not in only_set:
                continue
            ids, gt = build_slot_ids(n_slots, mode, k, seed=args.seed + w + h)
            if mode in ("dup", "periodic"):
                if not verify_hold_count(ids, gt["n_dups"]):
                    raise SystemExit(f"hold count mismatch {label}")
            dur_design = len(ids) / 24.0
            fname = f"cadence_{w}x{h}_24_{label}_{int(round(dur_design))}s.mp4"
            out = args.out_dir / fname
            print(f"ENCODE {tier} {label} -> {out} frames={len(ids)} "
                  f"dups={gt['n_dups']} drops={gt['n_drops']}", flush=True)
            enc = encode_ids(ids, w=w, h=h, out=out, vbitrate=vbr)
            m = enc["measured"]
            fails = []
            if m.get("width") != w or m.get("height") != h:
                fails.append("geom")
            if m.get("r_frame_rate") != "24/1":
                fails.append(f"rate={m.get('r_frame_rate')}")
            if m.get("profile") not in ("Constrained Baseline", "Baseline"):
                fails.append(f"prof={m.get('profile')}")
            if str(m.get("has_b_frames")) not in ("0", "0.0"):
                fails.append("bframes")
            # nb_frames must match encoded
            if m.get("nb_frames") and int(m["nb_frames"]) != len(ids):
                fails.append(f"nb_frames={m.get('nb_frames')}!={len(ids)}")

            mtitle = media_name(w, h, label, dur_design)
            entry = {
                "tier": tier,
                "label": label,
                "mode": mode,
                "media_filename": mtitle,
                "asset_path": str(out),
                "ground_truth": gt,
                "encode": enc,
                "spec_ok": len(fails) == 0,
                "spec_fails": fails,
                "anti_beat": {
                    "content_identity_period_s": 1.0 / 24.0,
                    "independent_marker_period_s": None,
                    "capture_30_note": (
                        "24:30=4:5 commensurate; healthy holds {1,2} on capture grid; "
                        "injected dups add hold>=2 mass / ~83ms content IFI"
                    ),
                    "capture_60_note": (
                        "24:60=2:5; healthy holds {2,3}; injected dups lengthen holds"
                    ),
                },
                "w_instr": {
                    "consumer": "tools/glass_motion_judder.py",
                    "source_fps": 24,
                    "source_fps_src": "caller_supplied_measured",
                    "expect_n_dups": gt["n_dups"],
                    "expect_n_drops": gt["n_drops"],
                    "red_before_green": (
                        "Score dup20/periodic BEFORE control; instrument must "
                        "recover elevated outlier/hold tail on known-N clips"
                    ),
                },
            }
            meta = out.with_suffix(out.suffix + ".meta.json")
            meta.write_text(json.dumps(entry, indent=2) + "\n")
            if args.copy_media:
                args.media_dir.mkdir(parents=True, exist_ok=True)
                dest = args.media_dir / mtitle
                dest.write_bytes(out.read_bytes())
                entry["media_host_path"] = str(dest)
                print(f"  COPIED {dest}", flush=True)
            print(
                f"  MEASURED {m.get('width')}x{m.get('height')} r={m.get('r_frame_rate')} "
                f"n={m.get('nb_frames')} dups={gt['n_dups']} drops={gt['n_drops']} "
                f"ok={entry['spec_ok']} fails={fails}",
                flush=True,
            )
            rows.append(entry)

    if args.host_floor_dir:
        emit_host_floor(args.host_floor_dir, duration_s=args.duration)

    args.manifest_json.write_text(json.dumps(rows, indent=2) + "\n")
    write_md(args.manifest, rows, args.duration)
    n_fail = sum(1 for r in rows if not r["spec_ok"])
    print(f"DONE n={len(rows)} spec_fail={n_fail} md={args.manifest}", flush=True)
    return 1 if n_fail else 0


def write_md(path: Path, rows: list[dict], duration_s: float) -> None:
    lines = [
        "# Cadence / judder defect ladder (w-instr ground truth)",
        "",
        "**Symptom channel:** presentation-interval judder (holds / IFI), **not** lipsync.",
        "Lipsync fixtures are blind to constant-offset irregular cadence.",
        "",
        f"**Design duration:** {duration_s:g} s @ **24/1** (control). "
        "drop_K shortens by K/24 s.",
        "",
        "## Per-frame identity (no enable= guard)",
        "",
        "- Glass ID `G n=DDDDDD c=C` + Grey bars every frame (`draw_id_band`)",
        "- Moving yellow block + 12-bit tick row + checker (MAD-distinct neighbours)",
        "- Black-lift ≥ 48 — not ERROR 13 black; not ERROR 8 noise-only motion",
        "",
        "## Anti-beat",
        "",
        "Content identity period = **1/24 s**. No independent marker period.",
        "24.000:30.000 = **4:5** commensurate → healthy capture holds **{1,2}** ",
        "(w-instr `glass_motion_beat_ifi`). Injected **dups** add long-hold / ~83 ms IFI mass.",
        "",
        "## Measured ladder",
        "",
        "| media | tier | mode | n_dups (GT) | n_drops (GT) | measured WxH | rate | nb_frames | dur_s | CB/B/aac | spec |",
        "|-------|------|------|------------:|-------------:|--------------|------|----------:|------:|----------|------|",
    ]
    for r in rows:
        m = r["encode"]["measured"]
        gt = r["ground_truth"]
        lines.append(
            f"| `{r['media_filename']}` | {r['tier']} | {r['label']} | "
            f"**{gt['n_dups']}** | **{gt['n_drops']}** | "
            f"**{m.get('width')}×{m.get('height')}** | **{m.get('r_frame_rate')}** | "
            f"{m.get('nb_frames')} | {m.get('format_duration')} | "
            f"{m.get('profile')}/b={m.get('has_b_frames')}/{m.get('a_codec')} | "
            f"{'YES' if r['spec_ok'] else 'NO '+str(r['spec_fails'])} |"
        )
    lines += [
        "",
        "## Ground-truth semantics",
        "",
        "| mode | what is injected | w-instr expectation |",
        "|------|------------------|---------------------|",
        "| control d0 | nothing | healthy hold mass only |",
        "| dup_K | K single-frame holds at recorded slots | recover **K** extra long holds / elevated ≥83 ms IFI |",
        "| drop_K | K omitted source indices (shorter file) | n_frames=N-K; id jumps; MAD still steps each frame |",
        "| periodic_hold_every24 | hold on every 24th slot | n_dups≈duration; strong bimodal IFI |",
        "",
        "**Red-before-green:** score `dup20` or `periodic_hold_every24` **before** control. "
        "An instrument that never detects known-N cannot report absence on device.",
        "",
        "## Host instrument floor (non-device)",
        "",
        "Directory from `--host-floor-dir` (default agent emit):",
        "`.agent-work/cadence-floor/cadence_24.000_control_300s.mp4`",
        "",
        "See `README_PARENT_FLOOR.txt` there for mpv + ffmpeg capture commands.",
        "",
        "## PMS ingest (parent — section 2 only)",
        "",
        "```bash",
        "ls -1 ~/plex/media/movies/MiSTerPlex\\ Cadence*",
        "curl -sS -o /dev/null -w 'refresh_http=%{http_code}\\n' \\",
        '  "http://192.168.1.24:32400/library/sections/2/refresh?X-Plex-Token=$TOK"',
        "echo \"refresh true rc=$?\"",
        'curl -sS "http://192.168.1.24:32400/library/sections/2/all?X-Plex-Token=$TOK" -o /tmp/pms_s2.xml',
        "echo \"all true rc=$?\"",
        "python3 - <<'PY'",
        "import xml.etree.ElementTree as ET",
        "root=ET.parse('/tmp/pms_s2.xml').getroot()",
        "for v in sorted(root.findall('.//Video'), key=lambda e:int(e.get('ratingKey',0))):",
        "    t=v.get('title') or ''",
        "    if 'Cadence' in t:",
        "        print(f\"rk={v.get('ratingKey')} dur_ms={v.get('duration')} | {t}\")",
        "PY",
        "```",
        "",
        "ratingKeys: **after your refresh only**. Prefer Direct Play.",
        "PMS geometry tags are claims — trust ffprobe / this table.",
        "",
        "## Reproduce",
        "",
        "```bash",
        "python3 scripts/gen_cadence_defect_ladder.py --duration 300 --copy-media \\",
        "  --host-floor-dir .agent-work/cadence-floor",
        "```",
        "",
        "Generator: `scripts/gen_cadence_defect_ladder.py`  ",
        "Consumer: `tools/glass_motion_judder.py` (w-instr)  ",
        "Probe JSON: `docs/cadence_defect_ladder_probe.json`",
        "",
    ]
    path.write_text("\n".join(lines))


if __name__ == "__main__":
    raise SystemExit(main())
