#!/usr/bin/env python3
"""S5/B6 promotion fixtures — real BBB glass soaks + non-bank geometry ladder.

Closes:
  S5: long (≥20 min) full-frame real content with glass ID (not bank-only).
  B6: geometry ladder that does NOT match 624x480 bank:
       624x352, 640x480, 720x480, 704x396
  Rate honesty: both 24/1 and 24000/1001, labelled in filename + plate.

Host-side only. Does not cast or touch MiSTer.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GEN = ROOT / "scripts" / "gen_real_bbb_avsync_soak.py"
DEFAULT_SRC = Path("/home/flynnsbit/Projects/MisterPlex/.agent-work/fixtures-real/bbb_720p_src.mp4")
DEFAULT_OUT_DIR = ROOT / ".agent-work" / "s5b6_fixtures"
DEFAULT_MEDIA = Path("/home/flynnsbit/plex/media/movies")

# (name_stem, w, h, fps_num, fps_den, duration_s, vbitrate, rate_tag)
# Long non-bank soaks first; ladder second.
ARMS: list[tuple] = [
    # --- S5 long real soaks (non-bank) ---
    ("S5_RealGlass_720x480_24_1_1200s", 720, 480, 24, 1, 1200.0, "2500k", "24/1"),
    ("S5_RealGlass_720x480_24000_1001_1200s", 720, 480, 24000, 1001, 1200.0, "2500k", "24000/1001"),
    # --- B6 geometry ladder @ 24/1 (300s — FORCE_SCALE stress, glass) ---
    ("B6_RealGlass_624x352_24_1_300s", 624, 352, 24, 1, 300.0, "2000k", "24/1"),
    ("B6_RealGlass_640x480_24_1_300s", 640, 480, 24, 1, 300.0, "2000k", "24/1"),
    ("B6_RealGlass_720x480_24_1_300s", 720, 480, 24, 1, 300.0, "2000k", "24/1"),
    ("B6_RealGlass_704x396_24_1_300s", 704, 396, 24, 1, 300.0, "2000k", "24/1"),
    # --- B6 geometry ladder @ 24000/1001 ---
    ("B6_RealGlass_624x352_24000_1001_300s", 624, 352, 24000, 1001, 300.0, "2000k", "24000/1001"),
    ("B6_RealGlass_640x480_24000_1001_300s", 640, 480, 24000, 1001, 300.0, "2000k", "24000/1001"),
    ("B6_RealGlass_720x480_24000_1001_300s", 720, 480, 24000, 1001, 300.0, "2000k", "24000/1001"),
    ("B6_RealGlass_704x396_24000_1001_300s", 704, 396, 24000, 1001, 300.0, "2000k", "24000/1001"),
]


def media_name(stem: str, w: int, h: int, rate_tag: str, duration_s: float) -> str:
    # Human filename: unambiguous rate (24fps vs 23976fps), never bare "24" for 23.976
    if rate_tag == "24/1":
        rate_fn = "24fps"
    elif rate_tag == "24000/1001":
        rate_fn = "23976fps"
    else:
        rate_fn = rate_tag.replace("/", "_") + "fps"
    dur = int(round(duration_s))
    return f"MiSTerPlex {stem.split('_')[0]} RealGlass {w}x{h} {rate_fn} {dur}s (2026).mp4"


def ffprobe_summary(path: Path) -> dict:
    cmd = [
        "ffprobe", "-v", "error",
        "-show_entries",
        "stream=codec_type,codec_name,width,height,r_frame_rate,avg_frame_rate,"
        "profile,level,has_b_frames,bit_rate,nb_frames,sample_rate,channels",
        "-show_entries", "format=duration,bit_rate,size",
        "-of", "json", str(path),
    ]
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        return {"error": p.stderr, "rc": p.returncode}
    return json.loads(p.stdout)


def run_one(arm: tuple, src: Path, out_dir: Path, media_dir: Path | None, skip_existing: bool) -> dict:
    stem, w, h, fn, fd, dur, vbr, rate_tag = arm
    out = out_dir / f"{stem}.mp4"
    mname = media_name(stem, w, h, rate_tag, dur)
    result = {
        "stem": stem,
        "media_name": mname,
        "planned": {
            "w": w, "h": h, "fps_num": fn, "fps_den": fd,
            "duration_s": dur, "vbitrate": vbr, "rate_tag": rate_tag,
        },
        "out": str(out),
    }
    if skip_existing and out.is_file() and out.stat().st_size > 1_000_000:
        print(f"SKIP existing {out}", flush=True)
        result["skipped"] = True
    else:
        cmd = [
            sys.executable, str(GEN),
            "--src", str(src),
            "--out", str(out),
            "--width", str(w),
            "--height", str(h),
            "--duration", str(dur),
            "--fps-num", str(fn),
            "--fps-den", str(fd),
            "--rate-tag", rate_tag,
            "--vbitrate", vbr,
            "--period", "2.0",
            "--work", str(out_dir / f"work_{stem}"),
        ]
        print(f"RUN {' '.join(cmd)}", flush=True)
        t0 = time.time()
        p = subprocess.run(cmd)
        result["gen_rc"] = p.returncode
        result["gen_wall_s"] = round(time.time() - t0, 1)
        print(f"DONE stem={stem} rc={p.returncode} wall_s={result['gen_wall_s']}", flush=True)
        if p.returncode != 0:
            result["status"] = "GEN_FAIL"
            return result

    if not out.is_file():
        result["status"] = "MISSING_OUT"
        return result

    probe = ffprobe_summary(out)
    result["ffprobe"] = probe
    # Validate critical fields
    vs = next((s for s in probe.get("streams", []) if s.get("codec_type") == "video"), {})
    as_ = next((s for s in probe.get("streams", []) if s.get("codec_type") == "audio"), {})
    want_r = f"{fn}/{fd}"
    ok = (
        vs.get("width") == w
        and vs.get("height") == h
        and vs.get("r_frame_rate") == want_r
        and vs.get("profile") == "Constrained Baseline"
        and int(vs.get("has_b_frames") or 0) == 0
        and as_.get("codec_name") == "aac"
        and str(as_.get("sample_rate")) == "48000"
    )
    result["spec_ok"] = ok
    result["measured"] = {
        "width": vs.get("width"),
        "height": vs.get("height"),
        "r_frame_rate": vs.get("r_frame_rate"),
        "avg_frame_rate": vs.get("avg_frame_rate"),
        "profile": vs.get("profile"),
        "level": vs.get("level"),
        "has_b_frames": vs.get("has_b_frames"),
        "v_bit_rate": vs.get("bit_rate"),
        "nb_frames": vs.get("nb_frames"),
        "duration": probe.get("format", {}).get("duration"),
        "a_codec": as_.get("codec_name"),
        "a_sample_rate": as_.get("sample_rate"),
        "format_bit_rate": probe.get("format", {}).get("bit_rate"),
    }
    if not ok:
        result["status"] = "SPEC_MISMATCH"
        print(f"SPEC_MISMATCH {stem}: {result['measured']}", flush=True)
        return result

    if media_dir is not None:
        media_dir.mkdir(parents=True, exist_ok=True)
        dest = media_dir / mname
        # hardlink if possible else copy
        if dest.exists():
            dest.unlink()
        try:
            dest.hardlink_to(out)
        except OSError:
            import shutil
            shutil.copy2(out, dest)
        result["media_path"] = str(dest)
        print(f"MEDIA {dest} size={dest.stat().st_size}", flush=True)

    result["status"] = "OK"
    return result


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--src", type=Path, default=DEFAULT_SRC)
    ap.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR)
    ap.add_argument("--media-dir", type=Path, default=DEFAULT_MEDIA)
    ap.add_argument("--no-media", action="store_true")
    ap.add_argument("--skip-existing", action="store_true", default=True)
    ap.add_argument("--only", default="", help="comma substrings of stem to run")
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args()

    arms = ARMS
    if args.only:
        keys = [k.strip() for k in args.only.split(",") if k.strip()]
        arms = [a for a in ARMS if any(k in a[0] for k in keys)]
    if args.list:
        for a in arms:
            print(a[0], media_name(a[0], a[1], a[2], a[7], a[5]))
        return 0

    args.out_dir.mkdir(parents=True, exist_ok=True)
    media = None if args.no_media else args.media_dir
    report = {"src": str(args.src), "arms": []}
    t0 = time.time()
    for arm in arms:
        r = run_one(arm, args.src, args.out_dir, media, args.skip_existing)
        report["arms"].append(r)
        rep_path = args.out_dir / "s5b6_batch_report.json"
        rep_path.write_text(json.dumps(report, indent=2))
    report["total_wall_s"] = round(time.time() - t0, 1)
    n_ok = sum(1 for a in report["arms"] if a.get("status") == "OK")
    report["n_ok"] = n_ok
    report["n_total"] = len(report["arms"])
    outp = args.out_dir / "s5b6_batch_report.json"
    outp.write_text(json.dumps(report, indent=2))
    print(json.dumps({"n_ok": n_ok, "n_total": report["n_total"], "report": str(outp)}, indent=2))
    return 0 if n_ok == report["n_total"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
