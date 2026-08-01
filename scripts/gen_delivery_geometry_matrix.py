#!/usr/bin/env python3
"""Generate the *delivered-geometry* OCRProof matrix for FORCE_SCALE / PMS upperBounds.

Why this matrix exists
----------------------
PMS ``upperBounds`` is a ceiling, not an exact size. Live measured-delivery
has included at least ``624x480``, ``624x350``, and ``426x240``. Bank-exact
``624x480`` is the *favourable* control; the others force real scale/pad.

Matrix (caller_supplied design — always re-probe with ffprobe):

  geometries:
    624x350  — observed live delivery (session evidence)
    426x240  — observed live delivery
    624x480  — DDR bank-exact control
    640x480  — non-bank width (PresentedMistake class / stride)
    720x480  — NTSC DV width
    624x352  — +2 rows vs 350; I420 chroma H/2 discriminator

  rates (exact rationals, NOT 24000/1001):
    24/1, 30/1

Encoding contract (FPGA decoder): H.264 Constrained Baseline, no B-frames,
AAC 48 kHz stereo. Burned-in glass frame ID on every frame
(``docs/glass_frame_id_contract.md``).

Outputs land under ``assets/avsync/`` (gitignored mp4) and optionally
``~/plex/media/movies/`` for local PMS section 2.

Usage:
  python3 scripts/gen_delivery_geometry_matrix.py
  python3 scripts/gen_delivery_geometry_matrix.py --duration 90 --copy-media
  python3 scripts/gen_delivery_geometry_matrix.py --only 624x350@24/1
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from gen_glass_ledger_fixture import gen  # noqa: E402

GEOMS = [
    (624, 350, "observed_delivery_624x350"),
    (426, 240, "observed_delivery_426x240"),
    (624, 480, "bank_exact_control"),
    (640, 480, "width_640_stride"),
    (720, 480, "ntsc_dv_width"),
    (624, 352, "chroma_neighbor_of_350"),
]
RATES = [(24, 1), (30, 1)]


def media_title(w: int, h: int, fps_num: int, fps_den: int, duration_s: float) -> str:
    fps_tag = f"{fps_num}fps" if fps_den == 1 else f"{fps_num}_{fps_den}fps"
    dur = int(round(duration_s))
    return f"MiSTerPlex DeliveryGeom {w}x{h} {fps_tag} {dur}s (2026).mp4"


def asset_name(w: int, h: int, fps_num: int, fps_den: int, duration_s: float) -> str:
    fps_tag = f"{fps_num}" if fps_den == 1 else f"{fps_num}_{fps_den}"
    dur = int(round(duration_s))
    return f"delivery_geom_{w}x{h}_{fps_tag}_{dur}s.mp4"


def vbitrate_for(w: int, h: int, fps_num: int, fps_den: int) -> str:
    fps = fps_num / float(fps_den)
    # ~0.12 bit/pixel/frame ballpark, clamp
    bpp = 0.12
    bps = int(w * h * fps * bpp)
    kb = max(800, min(4500, bps // 1000))
    return f"{kb}k"


def ffprobe_measured(path: Path) -> dict:
    cmd_v = [
        "ffprobe", "-v", "error",
        "-select_streams", "v:0",
        "-show_entries",
        "stream=width,height,r_frame_rate,avg_frame_rate,nb_frames,"
        "duration,profile,has_b_frames,codec_name,pix_fmt,"
        "sample_aspect_ratio,display_aspect_ratio",
        "-show_entries", "format=duration,size",
        "-of", "json", str(path),
    ]
    pv = subprocess.run(cmd_v, capture_output=True, text=True)
    vrc = pv.returncode
    data = json.loads(pv.stdout) if pv.stdout.strip() else {}
    cmd_a = [
        "ffprobe", "-v", "error", "-select_streams", "a:0",
        "-show_entries", "stream=codec_name,sample_rate,channels",
        "-of", "json", str(path),
    ]
    pa = subprocess.run(cmd_a, capture_output=True, text=True)
    arc = pa.returncode
    adata = json.loads(pa.stdout) if pa.stdout.strip() else {}
    st = (data.get("streams") or [{}])[0]
    fmt = data.get("format") or {}
    ast = (adata.get("streams") or [{}])[0]
    return {
        "ffprobe_v_rc": vrc,
        "ffprobe_a_rc": arc,
        "width": st.get("width"),
        "height": st.get("height"),
        "r_frame_rate": st.get("r_frame_rate"),
        "avg_frame_rate": st.get("avg_frame_rate"),
        "nb_frames": st.get("nb_frames"),
        "v_duration": st.get("duration"),
        "profile": st.get("profile"),
        "has_b_frames": st.get("has_b_frames"),
        "v_codec": st.get("codec_name"),
        "pix_fmt": st.get("pix_fmt"),
        "sar": st.get("sample_aspect_ratio"),
        "dar": st.get("display_aspect_ratio"),
        "format_duration": fmt.get("duration"),
        "size_bytes": int(fmt["size"]) if fmt.get("size") else path.stat().st_size,
        "a_codec": ast.get("codec_name"),
        "a_sample_rate": ast.get("sample_rate"),
        "a_channels": ast.get("channels"),
    }


def parse_only(s: str) -> tuple[int, int, int, int]:
    # 624x350@24/1
    wh, rate = s.split("@", 1)
    w_s, h_s = wh.lower().split("x")
    n_s, d_s = rate.split("/")
    return int(w_s), int(h_s), int(n_s), int(d_s)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--duration", type=float, default=90.0,
                    help="seconds (default 90 — geometry probe, not soak)")
    ap.add_argument("--out-dir", type=Path,
                    default=ROOT / "assets" / "avsync")
    ap.add_argument("--media-dir", type=Path,
                    default=Path.home() / "plex" / "media" / "movies")
    ap.add_argument("--copy-media", action="store_true",
                    help="copy finished mp4 into local PMS media mount")
    ap.add_argument("--skip-existing", action="store_true",
                    help="skip encode if out path already exists")
    ap.add_argument("--only", action="append", default=[],
                    help="limit to WxH@N/D (repeatable)")
    ap.add_argument("--manifest", type=Path,
                    default=ROOT / "docs" / "DELIVERY_GEOMETRY_MATRIX.md")
    ap.add_argument("--manifest-json", type=Path,
                    default=ROOT / "docs" / "delivery_geometry_matrix_probe.json")
    args = ap.parse_args()

    only_set = {parse_only(x) for x in args.only} if args.only else None
    args.out_dir.mkdir(parents=True, exist_ok=True)

    rows: list[dict] = []
    for w, h, role in GEOMS:
        for fps_num, fps_den in RATES:
            if only_set is not None and (w, h, fps_num, fps_den) not in only_set:
                continue
            aname = asset_name(w, h, fps_num, fps_den, args.duration)
            out = args.out_dir / aname
            mtitle = media_title(w, h, fps_num, fps_den, args.duration)
            vbr = vbitrate_for(w, h, fps_num, fps_den)
            bank_fit = (
                "favourable" if (w, h) == (624, 480)
                else "adversarial"
            )
            entry = {
                "role": role,
                "bank_fit": bank_fit,
                "requested_width": w,
                "requested_height": h,
                "requested_fps": f"{fps_num}/{fps_den}",
                "requested_duration_s": args.duration,
                "asset_path": str(out),
                "media_filename": mtitle,
                "vbitrate": vbr,
                "glass_id": "docs/glass_frame_id_contract.md",
                "generator": "scripts/gen_delivery_geometry_matrix.py",
                "encoder": "scripts/gen_glass_ledger_fixture.py",
            }
            if args.skip_existing and out.is_file():
                print(f"SKIP encode exists {out}", flush=True)
            else:
                print(f"ENCODE {w}x{h} @{fps_num}/{fps_den} -> {out}", flush=True)
                gen(
                    out,
                    duration_s=args.duration,
                    fps_num=fps_num,
                    fps_den=fps_den,
                    width=w,
                    height=h,
                    vbitrate=vbr,
                )
            measured = ffprobe_measured(out)
            entry["measured"] = measured
            # hard checks (report, do not silently pass)
            fails = []
            if measured.get("ffprobe_v_rc") != 0:
                fails.append(f"ffprobe_v_rc={measured.get('ffprobe_v_rc')}")
            if measured.get("width") != w or measured.get("height") != h:
                fails.append(
                    f"geom {measured.get('width')}x{measured.get('height')} != {w}x{h}"
                )
            want_rate = f"{fps_num}/{fps_den}"
            if measured.get("r_frame_rate") != want_rate:
                fails.append(
                    f"r_frame_rate {measured.get('r_frame_rate')} != {want_rate}"
                )
            if measured.get("profile") not in ("Constrained Baseline", "Baseline"):
                fails.append(f"profile={measured.get('profile')}")
            if str(measured.get("has_b_frames")) not in ("0", "0.0"):
                fails.append(f"has_b_frames={measured.get('has_b_frames')}")
            if measured.get("a_codec") != "aac":
                fails.append(f"a_codec={measured.get('a_codec')}")
            if str(measured.get("a_sample_rate")) != "48000":
                fails.append(f"a_rate={measured.get('a_sample_rate')}")
            entry["spec_check_fails"] = fails
            entry["spec_ok"] = len(fails) == 0
            print(
                f"  MEASURED {measured.get('width')}x{measured.get('height')} "
                f"r={measured.get('r_frame_rate')} prof={measured.get('profile')} "
                f"b={measured.get('has_b_frames')} a={measured.get('a_codec')}/"
                f"{measured.get('a_sample_rate')} ok={entry['spec_ok']} fails={fails}",
                flush=True,
            )
            if args.copy_media:
                args.media_dir.mkdir(parents=True, exist_ok=True)
                dest = args.media_dir / mtitle
                shutil.copy2(out, dest)
                entry["media_host_path"] = str(dest)
                print(f"  COPIED {dest}", flush=True)
            rows.append(entry)

    args.manifest_json.parent.mkdir(parents=True, exist_ok=True)
    args.manifest_json.write_text(json.dumps(rows, indent=2) + "\n")
    write_markdown(args.manifest, rows, args.duration)
    print(f"MANIFEST_MD {args.manifest}", flush=True)
    print(f"MANIFEST_JSON {args.manifest_json}", flush=True)
    n_fail = sum(1 for r in rows if not r["spec_ok"])
    print(f"DONE n={len(rows)} spec_fail={n_fail}", flush=True)
    return 1 if n_fail else 0


def write_markdown(path: Path, rows: list[dict], duration_s: float) -> None:
    lines = [
        "# Delivery-geometry fixture matrix",
        "",
        "**Purpose:** cover geometries PMS actually delivers under `upperBounds`,",
        "not only bank-exact 624×480. Live session observed **624×480**, **624×350**,",
        "**426×240**. `DDR_YUV_FORCE_SCALE=1` must be scored on adversarial sizes.",
        "",
        "**Contract:** H.264 Constrained Baseline, `has_b_frames=0`, AAC 48 kHz,",
        "glass frame ID every frame (`G n=DDDDDD c=C`). Rates are **24/1** and **30/1**",
        "only (never assume 24000/1001 — ERROR 17).",
        "",
        f"**Default duration:** {duration_s:g} s (geometry probe). Generator:",
        "`scripts/gen_delivery_geometry_matrix.py`.",
        "",
        "## Measured table (ffprobe — not intent)",
        "",
        "| media filename | role | bank_fit | measured WxH | r_frame_rate | avg | nb_frames | "
        "profile | B | audio | dur_s | size_MB | spec_ok |",
        "|----------------|------|----------|--------------|--------------|-----|-----------|"
        "---------|---|-------|------:|--------:|---------|",
    ]
    for r in rows:
        m = r["measured"]
        size_mb = (m.get("size_bytes") or 0) / 1e6
        dur = m.get("format_duration") or m.get("v_duration") or "?"
        lines.append(
            f"| `{r['media_filename']}` | {r['role']} | {r['bank_fit']} | "
            f"**{m.get('width')}×{m.get('height')}** | **{m.get('r_frame_rate')}** | "
            f"{m.get('avg_frame_rate')} | {m.get('nb_frames')} | {m.get('profile')} | "
            f"{m.get('has_b_frames')} | {m.get('a_codec')}/{m.get('a_sample_rate')} | "
            f"{dur} | {size_mb:.2f} | {'YES' if r['spec_ok'] else 'NO ' + str(r['spec_check_fails'])} |"
        )
    lines += [
        "",
        "## bank_fit legend",
        "",
        "| value | meaning |",
        "|-------|---------|",
        "| favourable | coded **624×480** — exact DDR bank; easiest 480p path |",
        "| adversarial | any other coded size — forces ARM scale/pad/crop |",
        "",
        "### Why 624×352 sits next to 624×350",
        "",
        "I420 chroma height is `H/2`. A bug that mis-aligns chroma plane base",
        "by one luma row (or mishandles odd/near-odd active heights after pad)",
        "can pass on one neighbor and fail on the other. **350 vs 352 is the",
        "discriminator pair** for that class; both are adversarial vs the bank.",
        "",
        "## Reproduce",
        "",
        "```bash",
        "python3 scripts/gen_delivery_geometry_matrix.py --duration 90 --copy-media",
        "# or one cell:",
        "python3 scripts/gen_delivery_geometry_matrix.py --only 624x350@24/1 --copy-media",
        "```",
        "",
        "## Local PMS ingest (parent runs — section 2 only)",
        "",
        "Media root on host: `~/plex/media/movies/` (container `/data/movies`).",
        "Server: `http://192.168.1.24:32400` · library **MiSTerPlex Tests** · section **2**.",
        "Token: `$TOK` from lab file — **never commit or print**.",
        "",
        "```bash",
        "# 1) ensure files are present (generator --copy-media does this)",
        "ls -1 ~/plex/media/movies/MiSTerPlex\\ DeliveryGeom*",
        "",
        "# 2) refresh section 2",
        "curl -sS -o /dev/null -w 'refresh_http=%{http_code}\\n' \\",
        '  "http://192.168.1.24:32400/library/sections/2/refresh?X-Plex-Token=$TOK"',
        "echo \"refresh true rc=$?\"",
        "",
        "# 3) enumerate until DeliveryGeom rows appear (poll ~5–30s)",
        'curl -sS "http://192.168.1.24:32400/library/sections/2/all?X-Plex-Token=$TOK" \\',
        "  > .agent-work/w-asset480/pms_after_delivery_geom.xml",
        "echo \"all true rc=$?\"",
        "python3 - <<'PY'",
        "import xml.etree.ElementTree as ET",
        "root = ET.parse('.agent-work/w-asset480/pms_after_delivery_geom.xml').getroot()",
        "for v in sorted(root.findall('.//Video'), key=lambda e: int(e.get('ratingKey',0))):",
        "    t = v.get('title') or ''",
        "    if 'DeliveryGeom' in t or 'delivery_geom' in t.lower():",
        "        print(f\"rk={v.get('ratingKey')} dur_ms={v.get('duration')} | {t}\")",
        "PY",
        "```",
        "",
        "Cast by **ratingKey** after index. Prefer Direct Play so coded size == delivered",
        "size (otherwise PMS may transcode and defeat the geometry probe).",
        "",
        "## Related",
        "",
        "- Full library inventory: `docs/FIXTURE_MANIFEST.md`",
        "- Glass ID contract: `docs/glass_frame_id_contract.md`",
        "- Playbook: `docs/PLAYBOOK_LOCAL_PMS_FIXTURES.md`",
        "",
    ]
    path.write_text("\n".join(lines))


if __name__ == "__main__":
    sys.exit(main())
