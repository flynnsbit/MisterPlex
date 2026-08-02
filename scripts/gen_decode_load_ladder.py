#!/usr/bin/env python3
"""Decode-load ladder + DP-control asset (fixed 624x480 @ 24/1).

Context (parent 2026-08-02):
  - CBR bitrate ladder RETIRED as session-level instrument (intermittent ~25%).
  - PMS was re-encoding every cast because daemon maxVideoBitrate floor forced
    universal (w-cpu-1 owns floor RCA — do not change plex_resolve here).
  - Live hypothesis: ARM handed more *decode work* than it can sustain.
  - This ladder varies codec tools / picture density at FIXED geom+fps+target
    bitrate so the axis is decode cost, not source kbit (PMS rewrites kbit).

Also emits one **DP-Control** clip: product-legal Constrained Baseline / L3.0 /
no-B / ref1 / CAVLC / AAC48k stereo / SAR1:1 / ~400 kbit video — the asset that
should Direct-Play once preferDirect+floor allow Part.

Acceptance ladder mapping: docs/DP_CONTROL_AND_DECODE_LOAD.md
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
OUT_DIR = ROOT / "assets" / "avsync"
MEDIA = Path.home() / "plex" / "media" / "movies"
FPS = "24"
W, H = 624, 480
# Fixed target video bitrate — NOT the experimental axis.
V_KBIT = 800
A_BITRATE = "128k"
DEFAULT_MASTER = MEDIA / "MiSTerPlex Real BBB GlassAV 624x480 24fps 1200s (2026).mp4"


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
        "constraint_set0_flag": grab("constraint_set0_flag"),
        "constraint_set1_flag": grab("constraint_set1_flag"),
        "level_idc": grab("level_idc"),
        "max_num_ref_frames": grab("max_num_ref_frames"),
        "entropy_coding_mode_flag": grab("entropy_coding_mode_flag"),
    }


def ffprobe_full(path: Path) -> dict:
    pv = subprocess.run(
        [
            "ffprobe", "-v", "error", "-select_streams", "v:0",
            "-show_entries",
            "stream=width,height,r_frame_rate,avg_frame_rate,nb_frames,"
            "profile,level,has_b_frames,codec_name,bit_rate,"
            "sample_aspect_ratio,display_aspect_ratio",
            "-show_entries", "format=duration,size,bit_rate",
            "-of", "json", str(path),
        ],
        capture_output=True,
        text=True,
    )
    pa = subprocess.run(
        [
            "ffprobe", "-v", "error", "-select_streams", "a:0",
            "-show_entries", "stream=codec_name,sample_rate,channels,bit_rate",
            "-of", "json", str(path),
        ],
        capture_output=True,
        text=True,
    )
    data = json.loads(pv.stdout) if pv.stdout.strip() else {}
    adata = json.loads(pa.stdout) if pa.stdout.strip() else {}
    st = (data.get("streams") or [{}])[0]
    fmt = data.get("format") or {}
    ast = (adata.get("streams") or [{}])[0]

    def ik(x):
        if x in (None, "N/A"):
            return None
        try:
            return int(x)
        except (TypeError, ValueError):
            return None

    v_br, a_br, f_br = ik(st.get("bit_rate")), ik(ast.get("bit_rate")), ik(fmt.get("bit_rate"))
    return {
        "ffprobe_v_rc": pv.returncode,
        "ffprobe_a_rc": pa.returncode,
        "width": st.get("width"),
        "height": st.get("height"),
        "r_frame_rate": st.get("r_frame_rate"),
        "avg_frame_rate": st.get("avg_frame_rate"),
        "nb_frames": st.get("nb_frames"),
        "profile": st.get("profile"),
        "level": st.get("level"),
        "has_b_frames": st.get("has_b_frames"),
        "v_codec": st.get("codec_name"),
        "sar": st.get("sample_aspect_ratio"),
        "dar": st.get("display_aspect_ratio"),
        "v_bit_rate": v_br,
        "v_bit_rate_k": (v_br / 1000.0) if v_br else None,
        "format_duration": fmt.get("duration"),
        "format_bit_rate_k": (f_br / 1000.0) if f_br else None,
        "size_bytes": ik(fmt.get("size")),
        "a_codec": ast.get("codec_name"),
        "a_sample_rate": ast.get("sample_rate"),
        "a_channels": ast.get("channels"),
        "a_bit_rate_k": (a_br / 1000.0) if a_br else None,
        "sps": sps_trace(path),
    }


# axis, key, title_tag, product_legal, encode kwargs extras
# product_legal: OK for FPGA/STREAM recon contract (CB, no B, CAVLC)
RUNGS = [
    {
        "axis": "baseline",
        "key": "cb_ref1_cavlc",
        "tag": "DecLoad cb_ref1_cavlc",
        "product_legal": True,
        "profile": "baseline",
        "level": "3.0",
        "bf": 0,
        "refs": 1,
        "cabac": 0,
        "deblock": "1:0:0",
        "content": "bbb",
        "note": "product baseline; decode floor",
        "prereg_supply_iv": "≥0.95 if DP and path ok",
        "prereg_pfps": "23.5–24.5",
    },
    {
        "axis": "refs",
        "key": "cb_ref3_cavlc",
        "tag": "DecLoad cb_ref3_cavlc",
        "product_legal": True,
        "profile": "baseline",
        "level": "3.0",
        "bf": 0,
        "refs": 3,
        "cabac": 0,
        "deblock": "1:0:0",
        "content": "bbb",
        "note": "refFrames=3 (rk9-class stress; product CB)",
        "prereg_supply_iv": "may dip vs ref1 if DPB/MC bound",
        "prereg_pfps": "if healthy 23.5–24.5; if DPB-bound lower",
    },
    {
        "axis": "refs",
        "key": "cb_ref5_cavlc",
        "tag": "DecLoad cb_ref5_cavlc",
        "product_legal": True,
        "profile": "baseline",
        "level": "3.0",
        "bf": 0,
        "refs": 5,
        "cabac": 0,
        "deblock": "1:0:0",
        "content": "bbb",
        "note": "refFrames=5 — higher MC cost, still CB",
        "prereg_supply_iv": "≤ ref3 if refs dominate",
        "prereg_pfps": "expect worse than ref1 if ARM MC-bound",
    },
    {
        "axis": "bframes",
        "key": "main_bf2_cavlc",
        "tag": "DecLoad main_bf2_cavlc",
        "product_legal": False,
        "profile": "main",
        "level": "3.0",
        "bf": 2,
        # x264 raises DPB with B-frames; request 2, measure often 3–4 — accept >=2
        "refs": 2,
        "refs_min": 2,
        "cabac": 0,
        "deblock": "1:0:0",
        "content": "bbb",
        "note": "B-frames=2 Main — STREAM recon may fail; FFmpeg STREAM=0 OK; SPS refs often 4",
        "prereg_supply_iv": "FFmpeg path: compare to baseline; recon path: UNSCORED",
        "prereg_pfps": "FFmpeg: ~24 if supply ok",
    },
    {
        "axis": "entropy",
        "key": "high_cabac_ref1",
        "tag": "DecLoad high_cabac_ref1",
        "product_legal": False,
        "profile": "high",
        "level": "3.0",
        "bf": 0,
        "refs": 1,
        "cabac": 1,
        "deblock": "1:0:0",
        "content": "bbb",
        "note": "CABAC High — sticky skip risk on STREAM recon; FFmpeg OK",
        "prereg_supply_iv": "FFmpeg: ~baseline; recon: often fail/skip",
        "prereg_pfps": "FFmpeg ~24; recon UNSCORED if CABAC skip",
    },
    {
        "axis": "deblock",
        "key": "cb_deblock_off",
        "tag": "DecLoad cb_deblock_off",
        "product_legal": True,
        "profile": "baseline",
        "level": "3.0",
        "bf": 0,
        "refs": 1,
        "cabac": 0,
        "deblock": "0:0:0",
        "content": "bbb",
        "note": "in-loop deblock disabled — lower filter cost",
        "prereg_supply_iv": "≥ baseline if deblock was costly",
        "prereg_pfps": "≥ baseline",
    },
    {
        "axis": "deblock",
        "key": "cb_deblock_strong",
        "tag": "DecLoad cb_deblock_strong",
        "product_legal": True,
        "profile": "baseline",
        "level": "3.0",
        "bf": 0,
        "refs": 1,
        "cabac": 0,
        "deblock": "1:-3:-3",
        "content": "bbb",
        "note": "stronger deblock offsets (more filter work)",
        "prereg_supply_iv": "≤ deblock_off if filter-bound",
        "prereg_pfps": "≤ deblock_off if filter-bound",
    },
    {
        "axis": "mb_density",
        "key": "cb_noise_dense",
        "tag": "DecLoad cb_noise_dense",
        "product_legal": True,
        "profile": "baseline",
        "level": "3.0",
        "bf": 0,
        "refs": 1,
        "cabac": 0,
        "deblock": "1:0:0",
        "content": "noise",
        "note": "full-frame noise — max residual/MB density at fixed CBR",
        "prereg_supply_iv": "worst product-legal if residual-bound",
        "prereg_pfps": "most likely <24 if decode-bound",
    },
]


def title_for(tag: str, duration_s: int) -> str:
    return f"MiSTerPlex {tag} 624x480 24fps {V_KBIT}k {duration_s}s (2026).mp4"


def stem_for(key: str, duration_s: int) -> str:
    return f"decload_{key}_{W}x{H}_24_{V_KBIT}k_{duration_s}s"


def build_x264_params(r: dict, v_kbit: int) -> str:
    parts = [
        f"cabac={r['cabac']}",
        f"ref={r['refs']}",
        f"bframes={r['bf']}",
        f"deblock={r['deblock']}",
        "keyint=48",
        "min-keyint=24",
        "scenecut=0",
        f"level={30}",
        f"vbv-maxrate={v_kbit}",
        f"vbv-bufsize={v_kbit * 2}",
    ]
    if r["cabac"] == 0:
        parts.append("no-cabac=1")
    if r["bf"] == 0:
        parts.append("bframes=0")
    return ":".join(parts)


def encode_rung(
    *,
    master: Path,
    out: Path,
    r: dict,
    duration_s: float,
    v_kbit: int,
) -> dict:
    out.parent.mkdir(parents=True, exist_ok=True)
    x264 = build_x264_params(r, v_kbit)
    vb, buf = f"{v_kbit}k", f"{v_kbit * 2}k"
    # Square samples — avoid rk6 SAR 16:9 → 350-row delivery trap
    if r["content"] == "noise":
        # lavfi noise + silent-ish tone; glass-free synthetic (density axis)
        # Use testsrc2 + geq noise for full entropy; burn simple frame counter via drawtext
        # text= uses ffmpeg %{eif\:n\:d\:6}; backslashes are for ffmpeg, not shell
        # (argv list — no shell).
        vf = (
            f"scale={W}:{H}:flags=neighbor,setsar=1/1,"
            f"geq=lum='random(1)*255':cb=128:cr=128,"
            f"drawbox=x=0:y=0:w=iw:h=56:color=black:t=fill,"
            f"drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf:"
            f"fontsize=36:fontcolor=white:x=8:y=8:text='G n=%{{eif\\:n\\:d\\:6}}'"
        )
        cmd = [
            "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
            "-f", "lavfi", "-i", f"testsrc2=size={W}x{H}:rate={FPS}",
            "-f", "lavfi", "-i", f"sine=f=440:r=48000:sample_rate=48000",
            "-t", str(duration_s),
            "-vf", vf,
            "-c:v", "libx264", "-profile:v", r["profile"], "-level:v", r["level"],
            "-bf", str(r["bf"]),
            "-x264-params", x264,
            "-pix_fmt", "yuv420p",
            "-b:v", vb, "-minrate", vb, "-maxrate", vb, "-bufsize", buf,
            "-r", FPS,
            "-c:a", "aac", "-b:a", A_BITRATE, "-ar", "48000", "-ac", "2",
            "-shortest", "-movflags", "+faststart",
            str(out),
        ]
    else:
        vf = f"scale={W}:{H}:flags=bicubic,setsar=1/1,fps={FPS}"
        cmd = [
            "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
            "-i", str(master),
            "-t", str(duration_s),
            "-vf", vf,
            "-c:v", "libx264", "-profile:v", r["profile"], "-level:v", r["level"],
            "-bf", str(r["bf"]),
            "-x264-params", x264,
            "-pix_fmt", "yuv420p",
            "-b:v", vb, "-minrate", vb, "-maxrate", vb, "-bufsize", buf,
            "-r", FPS,
            "-c:a", "aac", "-b:a", A_BITRATE, "-ar", "48000", "-ac", "2",
            "-movflags", "+faststart",
            str(out),
        ]
    print(f"ENCODE {out.name} axis={r['axis']} {r['key']}", flush=True)
    p = subprocess.run(cmd, capture_output=True, text=True)
    print(f"  ffmpeg_rc={p.returncode}", flush=True)
    if p.returncode != 0:
        sys.stderr.write(p.stderr[-3000:] if p.stderr else "")
        raise SystemExit(f"encode failed {out.name} rc={p.returncode}")
    m = ffprobe_full(out)
    return {"cmd": cmd, "ffmpeg_rc": p.returncode, "measured": m, "rung": r}


def encode_dp_control(*, master: Path, out: Path, duration_s: float) -> dict:
    """Product-legal DP control: CB L3.0 ref1 no-B CAVLC ~400k, SAR 1:1."""
    v_kbit = 400
    r = {
        "axis": "dp_control",
        "key": "dp_control_cb400",
        "profile": "baseline",
        "level": "3.0",
        "bf": 0,
        "refs": 1,
        "cabac": 0,
        "deblock": "1:0:0",
        "content": "bbb",
        "product_legal": True,
    }
    out.parent.mkdir(parents=True, exist_ok=True)
    x264 = build_x264_params(r, v_kbit)
    vb, buf = f"{v_kbit}k", f"{v_kbit * 2}k"
    vf = f"scale={W}:{H}:flags=bicubic,setsar=1/1,fps={FPS}"
    cmd = [
        "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
        "-i", str(master),
        "-t", str(duration_s),
        "-vf", vf,
        "-c:v", "libx264", "-profile:v", "baseline", "-level:v", "3.0", "-bf", "0",
        "-x264-params", x264,
        "-pix_fmt", "yuv420p",
        "-b:v", vb, "-minrate", vb, "-maxrate", vb, "-bufsize", buf,
        "-r", FPS,
        "-c:a", "aac", "-b:a", A_BITRATE, "-ar", "48000", "-ac", "2",
        "-movflags", "+faststart",
        str(out),
    ]
    print(f"ENCODE DP-Control {out.name}", flush=True)
    p = subprocess.run(cmd, capture_output=True, text=True)
    print(f"  ffmpeg_rc={p.returncode}", flush=True)
    if p.returncode != 0:
        sys.stderr.write(p.stderr[-3000:] if p.stderr else "")
        raise SystemExit(f"dp-control encode failed rc={p.returncode}")
    m = ffprobe_full(out)
    return {"cmd": cmd, "ffmpeg_rc": p.returncode, "measured": m, "rung": r, "v_kbit": v_kbit}


def check_common(
    m: dict,
    *,
    expect_profile_substr: str,
    bf: int,
    refs: int,
    level_max: int = 30,
    refs_min: int | None = None,
) -> list[str]:
    fails = []
    if m.get("width") != W or m.get("height") != H:
        fails.append(f"geom={m.get('width')}x{m.get('height')}")
    if m.get("r_frame_rate") != "24/1":
        fails.append(f"rate={m.get('r_frame_rate')}")
    prof = (m.get("profile") or "")
    if expect_profile_substr.lower() not in prof.lower():
        fails.append(f"profile={prof}")
    if int(m.get("level") or 99) > level_max:
        fails.append(f"level={m.get('level')}")
    if int(m.get("has_b_frames") or 0) != bf and not (bf > 0 and int(m.get("has_b_frames") or 0) >= 1):
        # has_b_frames is max B-pyramid delay; for bf=2 expect >=1
        if bf == 0 and int(m.get("has_b_frames") or 0) != 0:
            fails.append(f"B={m.get('has_b_frames')}")
        elif bf > 0 and int(m.get("has_b_frames") or 0) < 1:
            fails.append(f"B={m.get('has_b_frames')} expected B-frames")
    sps = m.get("sps") or {}
    got_refs = sps.get("max_num_ref_frames")
    if got_refs is not None:
        if refs_min is not None:
            if got_refs < int(refs_min):
                fails.append(f"refs={got_refs}<min{refs_min}")
        elif got_refs != refs:
            fails.append(f"refs={got_refs}!={refs}")
    if m.get("a_codec") != "aac" or str(m.get("a_sample_rate")) != "48000":
        fails.append(f"audio={m.get('a_codec')}/{m.get('a_sample_rate')}")
    if int(m.get("a_channels") or 0) != 2:
        fails.append(f"ach={m.get('a_channels')}")
    # SAR: prefer 1:1 or N/A
    sar = m.get("sar")
    if sar not in (None, "N/A", "1:1", "1/1"):
        fails.append(f"sar={sar}")
    return fails


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--master", type=Path, default=DEFAULT_MASTER)
    ap.add_argument("--duration", type=float, default=180.0)
    ap.add_argument("--dp-duration", type=float, default=300.0)
    ap.add_argument("--copy-media", action="store_true")
    ap.add_argument("--only", default="", help="comma keys or 'dp'")
    args = ap.parse_args()
    only = {x.strip() for x in args.only.split(",") if x.strip()}

    if not args.master.is_file() and (not only or any(k != "dp" and k != "dp_control_cb400" for k in only) or not only):
        # noise-only can skip master
        need_master = True
        if only and only <= {"cb_noise_dense"}:
            need_master = False
        if need_master and "dp" not in only and "dp_control_cb400" not in only:
            pass
        if need_master and not args.master.is_file():
            print(f"missing master {args.master}", file=sys.stderr)
            return 2

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    results = []
    dur = int(round(args.duration))
    dp_dur = int(round(args.dp_duration))

    # DP control first
    if not only or "dp" in only or "dp_control_cb400" in only:
        if not args.master.is_file():
            print(f"missing master for DP control: {args.master}", file=sys.stderr)
            return 2
        title = f"MiSTerPlex DP-Control 624x480 24fps 400kbit ref1 {dp_dur}s (2026).mp4"
        stem = f"dp_control_624x480_24_400k_ref1_{dp_dur}s"
        out = OUT_DIR / f"{stem}.mp4"
        rec = encode_dp_control(master=args.master, out=out, duration_s=args.dp_duration)
        m = rec["measured"]
        fails = check_common(
            m, expect_profile_substr="Baseline", bf=0, refs=1
        )
        vk = m.get("v_bit_rate_k")
        if vk is None or not (320 <= vk <= 500):
            fails.append(f"v_k={vk}")
        try:
            if abs(float(m.get("format_duration") or 0) - args.dp_duration) > 0.2:
                fails.append(f"dur={m.get('format_duration')}")
        except ValueError:
            fails.append("dur")
        # CABAC off
        if (m.get("sps") or {}).get("entropy_coding_mode_flag") not in (0, None):
            if (m.get("sps") or {}).get("entropy_coding_mode_flag") != 0:
                fails.append("cabac_on")
        row = {
            "title": title,
            "stem": stem,
            "path": str(out),
            "role": "dp_control",
            "product_legal": True,
            "v_kbit_target": 400,
            "fails": fails,
            "spec_ok": len(fails) == 0,
            **rec,
        }
        results.append(row)
        print(
            f"  DP-Control spec_ok={row['spec_ok']} fails={fails} "
            f"prof={m.get('profile')} L{m.get('level')} B={m.get('has_b_frames')} "
            f"refs={m.get('sps',{}).get('max_num_ref_frames')} v_k={m.get('v_bit_rate_k')}",
            flush=True,
        )
        if args.copy_media:
            dest = MEDIA / title
            MEDIA.mkdir(parents=True, exist_ok=True)
            shutil.copy2(out, dest)
            print(f"  copied {dest}", flush=True)
        meta = OUT_DIR / f"{stem}.mp4.meta.json"
        meta.write_text(json.dumps(row, indent=2, default=str) + "\n")

    for r in RUNGS:
        if only and r["key"] not in only and r["axis"] not in only:
            continue
        if r["content"] == "bbb" and not args.master.is_file():
            print(f"skip {r['key']}: no master", file=sys.stderr)
            continue
        title = title_for(r["tag"], dur)
        stem = stem_for(r["key"], dur)
        out = OUT_DIR / f"{stem}.mp4"
        rec = encode_rung(
            master=args.master, out=out, r=r, duration_s=args.duration, v_kbit=V_KBIT
        )
        m = rec["measured"]
        exp_prof = {
            "baseline": "Baseline",
            "main": "Main",
            "high": "High",
        }[r["profile"]]
        fails = check_common(
            m,
            expect_profile_substr=exp_prof,
            bf=r["bf"],
            refs=r["refs"],
            refs_min=r.get("refs_min"),
        )
        vk = m.get("v_bit_rate_k")
        if vk is None or not (V_KBIT * 0.75 <= vk <= V_KBIT * 1.3):
            fails.append(f"v_k={vk}")
        # entropy flag
        ent = (m.get("sps") or {}).get("entropy_coding_mode_flag")
        if r["cabac"] == 0 and ent not in (0, None) and ent != 0:
            fails.append(f"entropy={ent}")
        if r["cabac"] == 1 and ent not in (1, None) and ent != 1:
            # High may still report via profile
            pass
        row = {
            "title": title,
            "stem": stem,
            "path": str(out),
            "role": "decode_load",
            "axis": r["axis"],
            "key": r["key"],
            "product_legal": r["product_legal"],
            "note": r["note"],
            "prereg_supply_iv": r["prereg_supply_iv"],
            "prereg_pfps": r["prereg_pfps"],
            "v_kbit_target": V_KBIT,
            "fails": fails,
            "spec_ok": len(fails) == 0,
            **rec,
        }
        results.append(row)
        print(
            f"  {r['key']} spec_ok={row['spec_ok']} fails={fails} "
            f"prof={m.get('profile')} refs={m.get('sps',{}).get('max_num_ref_frames')} "
            f"B={m.get('has_b_frames')} v_k={m.get('v_bit_rate_k')}",
            flush=True,
        )
        if args.copy_media:
            dest = MEDIA / title
            MEDIA.mkdir(parents=True, exist_ok=True)
            shutil.copy2(out, dest)
            print(f"  copied {dest}", flush=True)
        (OUT_DIR / f"{stem}.mp4.meta.json").write_text(
            json.dumps(row, indent=2, default=str) + "\n"
        )

    probe = {
        "fixed": {"w": W, "h": H, "fps": "24/1", "v_kbit_ladder": V_KBIT},
        "master": str(args.master),
        "results": [
            {
                "title": x["title"],
                "role": x.get("role"),
                "key": x.get("key") or x.get("role"),
                "axis": x.get("axis"),
                "product_legal": x.get("product_legal"),
                "spec_ok": x.get("spec_ok"),
                "fails": x.get("fails"),
                "measured": x.get("measured"),
                "prereg_supply_iv": x.get("prereg_supply_iv"),
                "prereg_pfps": x.get("prereg_pfps"),
                "note": x.get("note"),
            }
            for x in results
        ],
    }
    (ROOT / "docs" / "decode_load_ladder_probe.json").write_text(
        json.dumps(probe, indent=2, default=str) + "\n"
    )
    bad = [x["title"] for x in results if not x.get("spec_ok")]
    print(f"DONE n={len(results)} fails={len(bad)}")
    if bad:
        print("FAILED:", bad)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
