#!/usr/bin/env python3
"""Adversarial REAL-content ladder for MILESTONE 4 / FORCE_SCALE / link ceiling.

rd-review: promotion soaks were synthetic + bank-exact 624x480. Existing
"Real BBB" library files are real content but encoded ~2.1–2.9 Mbit/s — above
the measured MiSTer path (~107 KB/s ≈ 0.86 Mbit/s). This ladder re-encodes
from a glass-ID-burned real master so axes are isolated at **deliverable** rates.

Axes (one property at a time)
-----------------------------
A. GEOM @ fixed v=500 kbit/s, ref=1, 24/1, AAC48k@48k, 300 s:
     624x480 (bank control), 624x352, 640x480, 720x480, 704x396
B. REFS @ fixed 624x480, v=500, 300 s: ref=1 vs ref=3
C. BITRATE @ fixed 624x480, ref=1, 300 s: 400 / 500 / 800 / 1200 / 1800
D. LONG SOAK: 624x480, v=500, ref=1, **900 s** (15 min) real content

Master default: existing Real BBB GlassAV 624x480 1200s (IDs already burned).

Encoder: H.264 Constrained Baseline, level 3.0, B=0, AAC 48 kHz.
Every output verified with ffprobe + SPS max_num_ref_frames.

Usage:
  python3 scripts/gen_adversarial_real_ladder.py --copy-media
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
FPS_STR = "24"
A_BITRATE = "48k"

DEFAULT_MASTER = (
    Path.home()
    / "plex/media/movies/MiSTerPlex Real BBB GlassAV 624x480 24fps 1200s (2026).mp4"
)

# (axis, w, h, v_kbit, refs, duration_s)
JOBS: list[tuple[str, int, int, int, int, float]] = [
    # D long soak first (most valuable)
    ("long_soak_500_ref1", 624, 480, 500, 1, 900.0),
    # A geometry
    ("geom_bank_624x480", 624, 480, 500, 1, 300.0),
    ("geom_624x352", 624, 352, 500, 1, 300.0),
    ("geom_640x480", 640, 480, 500, 1, 300.0),
    ("geom_720x480", 720, 480, 500, 1, 300.0),
    ("geom_704x396", 704, 396, 500, 1, 300.0),
    # B refs
    ("refs_ref3_500", 624, 480, 500, 3, 300.0),
    # C bitrate (ref1 bank) — 500 already as geom_bank; add others
    ("br_400", 624, 480, 400, 1, 300.0),
    ("br_800", 624, 480, 800, 1, 300.0),
    ("br_1200", 624, 480, 1200, 1, 300.0),
    ("br_1800", 624, 480, 1800, 1, 300.0),
]


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
        "v_codec": st.get("codec_name"),
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


def title_for(w, h, v_kbit, refs, duration_s) -> str:
    ds = int(round(duration_s))
    return (
        f"MiSTerPlex AdvReal {w}x{h} 24fps {v_kbit}kbit "
        f"ref{refs} {ds}s (2026).mp4"
    )


def stem_for(w, h, v_kbit, refs, duration_s) -> str:
    ds = int(round(duration_s))
    return f"adv_real_{w}x{h}_24_{v_kbit}k_ref{refs}_{ds}s"


def reencode(
    src: Path,
    out: Path,
    *,
    w: int,
    h: int,
    v_kbit: int,
    refs: int,
    duration_s: float,
) -> dict:
    vb = f"{v_kbit}k"
    buf = f"{v_kbit * 2}k"
    out.parent.mkdir(parents=True, exist_ok=True)
    x264 = (
        f"cabac=0:ref={refs}:bframes=0:keyint=48:level=30:"
        f"vbv-maxrate={v_kbit}:vbv-bufsize={v_kbit * 2}"
    )
    # Always scale to target (identity scale if already 624x480) so SAR clean
    vf = f"scale={w}:{h}:flags=bicubic,setsar=1/1,fps={FPS_STR}"
    cmd = [
        "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
        "-i", str(src),
        "-t", str(duration_s),
        "-vf", vf,
        "-c:v", "libx264", "-profile:v", "baseline", "-level:v", "3.0", "-bf", "0",
        "-x264-params", x264,
        "-pix_fmt", "yuv420p",
        "-b:v", vb, "-maxrate", vb, "-bufsize", buf,
        "-r", FPS_STR,
        "-c:a", "aac", "-b:a", A_BITRATE, "-ar", "48000", "-ac", "1",
        "-movflags", "+faststart",
        str(out),
    ]
    print(
        f"REENCODE {out.name} {w}x{h} v={vb} ref={refs} t={duration_s}s",
        flush=True,
    )
    p = subprocess.run(cmd, capture_output=True, text=True)
    print(f"  ffmpeg_rc={p.returncode}", flush=True)
    if p.returncode != 0:
        sys.stderr.write(p.stderr[-2500:] if p.stderr else "")
        raise SystemExit(f"encode failed rc={p.returncode}")
    m = ffprobe_full(out)
    return {"cmd": cmd, "ffmpeg_rc": p.returncode, "measured": m}


def spec_ok(m: dict, *, w: int, h: int, refs: int, v_kbit: int, duration_s: float) -> list[str]:
    fails = []
    if m.get("width") != w or m.get("height") != h:
        fails.append(f"geom {m.get('width')}x{m.get('height')}")
    if m.get("r_frame_rate") != "24/1":
        fails.append(f"rate={m.get('r_frame_rate')}")
    if m.get("profile") != "Constrained Baseline":
        fails.append(f"profile={m.get('profile')}")
    if int(m.get("level") or 99) > 30:
        fails.append(f"level={m.get('level')}")
    if int(m.get("has_b_frames") or 0) != 0:
        fails.append(f"B={m.get('has_b_frames')}")
    sps = m.get("sps") or {}
    if sps.get("max_num_ref_frames") != refs:
        fails.append(f"refs={sps.get('max_num_ref_frames')}!={refs}")
    if m.get("a_codec") != "aac" or str(m.get("a_sample_rate")) != "48000":
        fails.append("audio")
    vk = m.get("v_bit_rate_k")
    if vk is None or not (v_kbit * 0.80 <= vk <= v_kbit * 1.25):
        fails.append(f"v_k={vk} vs {v_kbit}")
    try:
        dur = float(m.get("format_duration") or 0)
        if abs(dur - duration_s) > 0.15:
            fails.append(f"dur={dur}")
    except ValueError:
        fails.append("dur")
    return fails


def prereg_row(axis: str, v_kbit: int, total_k_approx: float) -> dict:
    """Device expectations given parent link ~107 KB/s ≈ 856 kbit/s."""
    link = 856.0
    # margin: healthy if total << link; edge near; collapse if total > link
    if total_k_approx <= 600:
        band = "healthy"
        pfps, drops, supply = "≈23.5–24.0", "low (<50/300s)", "≈0.97–1.00"
    elif total_k_approx <= 850:
        band = "edge"
        pfps, drops, supply = "≈20–24 or dip", "moderate", "≈0.85–0.99"
    else:
        band = "collapse_risk"
        pfps, drops, supply = "<<24 (e.g. ~13)", "high (hundreds+)", "≈0.7–0.9 diverging"
    # geometry/refs at 500: same band as bitrate if link is root cause
    note = ""
    if axis.startswith("geom_") or axis.startswith("refs_"):
        note = "If link-bound: match 500k bank arm. If FORCE_SCALE/ref fault: diverge."
    if axis.startswith("long_"):
        note = "15 min real soak under link — expect sustained healthy if 500k holds."
    return {
        "band": band,
        "expected_pfps": pfps,
        "expected_drops": drops,
        "expected_supply_ratio": supply,
        "note": note,
        "link_kbit_s_assumed": link,
    }


def write_doc(rows: list[dict], path: Path, media_dir: Path, master: Path) -> None:
    lines = [
        "# Adversarial real-content ladder (MILESTONE 4 / link / FORCE_SCALE)",
        "",
        "**Problem:** promotion package used synthetic bank-exact soaks; prior",
        "Real BBB library files are real picture but **~2.1–2.9 Mbit/s total** —",
        "above the measured device path (**~107 KB/s ≈ 856 kbit/s**). Collapse",
        "vs healthy on rk=9 confounds geometry, refs, bitrate, complexity.",
        "",
        f"**Master (glass ID already burned):** `{master}`",
        "",
        "## Link assumption (parent-measured)",
        "",
        "| quantity | value |",
        "|----------|------:|",
        "| path rate | ~107 KB/s ≈ **856 kbit/s** |",
        "| audio pin | AAC 48 kHz **48 kbit/s** mono |",
        "| healthy video budget | **≲ 700–750 kbit/s** |",
        "",
        "## PRE-REGISTER (device cast — parent runs)",
        "",
        "Single-run confirm/miss. If link is root cause:",
        "",
        "| band | total bitrate | expected pfps | drops | supply_ratio |",
        "|------|--------------:|---------------|-------|--------------|",
        "| healthy | ≤ ~600 kbit/s | ≈23.5–24.0 | low | ≈0.97–1.00 |",
        "| edge | ~600–850 | dip or unstable | moderate | ≈0.85–0.99 |",
        "| collapse | ≥ ~900 | <<24 (e.g. ~13) | high | ≈0.7–0.9 diverging |",
        "",
        "- **Geom arms @ 500k ref1:** all **healthy and mutually similar** if bitrate",
        "  dominates; if 624x352/640/720/704 diverge from bank → FORCE_SCALE/geometry.",
        "- **ref3 @ 500k:** healthy like ref1 if refs not causal; worse → refs load.",
        "- **br_1800:** **collapse** (like rk=9 class). **br_400/500:** healthy.",
        "- **long 900s @ 500k:** sustained healthy; no late cliff.",
        "",
        "Publish misses.",
        "",
        "## Fixed contract (all clips)",
        "",
        "- Real BBB-derived full-frame picture + burned glass ID (from master)",
        "- fps **24/1** (measured)",
        "- H.264 **Constrained Baseline**, **level ≤ 3.0**, **B=0**",
        "- AAC **48 kHz**, **48 kbit/s** mono (pinned)",
        "- CBR-ish `-b:v = -maxrate`, bufsize 2×",
        "",
        "## Measured table",
        "",
        "| title | axis | W×H | fps | tgt_v | meas_v | total_k | refs | prof/L/B | nb | dur | bank | prereg | spec |",
        "|-------|------|-----|-----|------:|-------:|--------:|-----:|----------|---:|----:|------|--------|------|",
    ]
    for r in rows:
        m = r["measured"]
        sps = m.get("sps") or {}
        pr = r["prereg"]
        bank = "favourable" if (m.get("width"), m.get("height")) == (624, 480) else "adversarial"
        lines.append(
            "| `{t}` | {ax} | **{w}×{h}** | **{fps}** | {tv} | **{mv}** | **{tot}** | **{rf}** | {p}/L{lv}/B{b} | {nb} | {d} | {bank} | {band} | {ok} |".format(
                t=r["title"],
                ax=r["axis"],
                w=m.get("width"),
                h=m.get("height"),
                fps=m.get("r_frame_rate"),
                tv=r["target_v_kbit"],
                mv=f"{m.get('v_bit_rate_k'):.1f}" if m.get("v_bit_rate_k") else "?",
                tot=f"{m.get('format_bit_rate_k'):.1f}" if m.get("format_bit_rate_k") else "?",
                rf=sps.get("max_num_ref_frames"),
                p=m.get("profile"),
                lv=m.get("level"),
                b=m.get("has_b_frames"),
                nb=m.get("nb_frames"),
                d=m.get("format_duration"),
                bank=bank,
                band=pr["band"],
                ok="YES" if not r["fails"] else "NO:" + ";".join(r["fails"]),
            )
        )
    lines += [
        "",
        "### Per-clip device prereg detail",
        "",
        "| title | expected_pfps | expected_drops | expected_supply | note |",
        "|-------|---------------|----------------|-----------------|------|",
    ]
    for r in rows:
        pr = r["prereg"]
        lines.append(
            f"| `{r['title']}` | {pr['expected_pfps']} | {pr['expected_drops']} | "
            f"{pr['expected_supply_ratio']} | {pr['note']} |"
        )
    lines += [
        "",
        "## Parent PMS ingest (§2 only)",
        "",
        "```bash",
        f"ls -1 {media_dir}/MiSTerPlex\\ AdvReal*",
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
        "    if 'AdvReal' in t:",
        "        print(f\"rk={v.get('ratingKey')} dur_ms={v.get('duration')} br={v.get('bitrate')} fr={v.get('frameRate')} | {t}\")",
        "PY",
        "```",
        "",
        "PMS `frameRate`/`bitrate` are **claims** — trust ffprobe table above.",
        "Prefer Direct Play. Agent does not touch the MiSTer.",
        "",
        "## Reproduce",
        "",
        "```bash",
        "python3 scripts/gen_adversarial_real_ladder.py --copy-media \\",
        f"  --master \"{master}\"",
        "```",
        "",
        "Generator: `scripts/gen_adversarial_real_ladder.py`",
        "Probe: `docs/adversarial_real_ladder_probe.json`",
        "",
        "## Related ladders",
        "",
        "- Synthetic bitrate/ref/geom (no real picture): `docs/BITRATE_LADDER.md`",
        "- Cadence/judder GT: `docs/CADENCE_DEFECT_LADDER.md`",
        "- PromoScoreable (real but ~2.5 Mbit — **over link**): `docs/PROMO_SCOREABLE_FIXTURES.md`",
        "",
    ]
    path.write_text("\n".join(lines) + "\n")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--master", type=Path, default=DEFAULT_MASTER)
    ap.add_argument("--out-dir", type=Path, default=ROOT / "assets" / "avsync")
    ap.add_argument(
        "--media-dir",
        type=Path,
        default=Path.home() / "plex" / "media" / "movies",
    )
    ap.add_argument("--copy-media", action="store_true")
    ap.add_argument("--only", default="", help="comma axes substring filter")
    args = ap.parse_args()

    if not args.master.is_file():
        raise SystemExit(f"missing master {args.master}")

    master_m = ffprobe_full(args.master)
    print(
        f"MASTER {args.master} {master_m.get('width')}x{master_m.get('height')} "
        f"r={master_m.get('r_frame_rate')} v_k={master_m.get('v_bit_rate_k')} "
        f"refs={master_m.get('sps',{}).get('max_num_ref_frames')} "
        f"dur={master_m.get('format_duration')}",
        flush=True,
    )

    only = {x.strip() for x in args.only.split(",") if x.strip()}
    rows = []
    for axis, w, h, vk, refs, dur in JOBS:
        if only and not any(o in axis for o in only):
            continue
        # skip duplicate 500/ref1/300 bank if long soak covers — keep both (diff duration)
        stem = stem_for(w, h, vk, refs, dur)
        out = args.out_dir / f"{stem}.mp4"
        title = title_for(w, h, vk, refs, dur)
        info = reencode(args.master, out, w=w, h=h, v_kbit=vk, refs=refs, duration_s=dur)
        m = info["measured"]
        fails = spec_ok(m, w=w, h=h, refs=refs, v_kbit=vk, duration_s=dur)
        tot = m.get("format_bit_rate_k") or (vk + 50)
        pr = prereg_row(axis, vk, float(tot))
        print(
            f"  MEASURED {m.get('width')}x{m.get('height')} r={m.get('r_frame_rate')} "
            f"v={m.get('v_bit_rate_k')} tot={m.get('format_bit_rate_k')} "
            f"refs={m.get('sps',{}).get('max_num_ref_frames')} "
            f"{m.get('profile')} L{m.get('level')} B={m.get('has_b_frames')} "
            f"prereg={pr['band']} ok={not fails} fails={fails}",
            flush=True,
        )
        meta = {
            "title": title,
            "axis": axis,
            "target_v_kbit": vk,
            "target_refs": refs,
            "target_w": w,
            "target_h": h,
            "duration_s_design": dur,
            "fps_rational": "24/1",
            "master": str(args.master),
            "content": "real_BBB_glass_id_from_master",
            "bank_fit": "favourable" if (w, h) == (624, 480) else "adversarial",
            "measured": m,
            "fails": fails,
            "prereg": pr,
            "ffmpeg_cmd": info["cmd"],
        }
        (out.with_suffix(out.suffix + ".meta.json")).write_text(
            json.dumps(meta, indent=2) + "\n"
        )
        if args.copy_media:
            dest = args.media_dir / title
            args.media_dir.mkdir(parents=True, exist_ok=True)
            shutil.copy2(out, dest)
            print(f"  COPIED {dest}", flush=True)
            meta["media_path"] = str(dest)
        rows.append(meta)

    docs = ROOT / "docs"
    docs.mkdir(exist_ok=True)
    write_doc(rows, docs / "ADVERSARIAL_REAL_LADDER.md", args.media_dir, args.master)
    blob = {
        "link_kbit_s_parent": 856,
        "link_note": "107 KB/s ≈ 856 kbit/s",
        "master_measured": master_m,
        "clips": rows,
    }
    (docs / "adversarial_real_ladder_probe.json").write_text(
        json.dumps(blob, indent=2) + "\n"
    )
    n_fail = sum(1 for r in rows if r["fails"])
    print(f"DONE n={len(rows)} spec_fail={n_fail}", flush=True)
    return 1 if n_fail else 0


if __name__ == "__main__":
    raise SystemExit(main())
