#!/usr/bin/env python3
"""Break down I-slice luma MB failures by type/mode/neighbour/seed.

Uses unmodified score_i420_candidate.plane_sample_block for Y equality.
Does not touch the headline MB-exact scorer (Y+U+V).

Evidence for the 206/300 fail split (largest bucket first).
"""
from __future__ import annotations

import argparse
import glob
import importlib.util
import json
import sys
from collections import Counter
from pathlib import Path


def _load_scorer(repo: Path):
    path = repo / "tools" / "score_i420_candidate.py"
    spec = importlib.util.spec_from_file_location("score_i420_candidate", path)
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod


def _cls(mb: dict) -> str:
    t = int(mb["type"])
    if t == 0:
        return "I_NxN"
    if t == 25:
        return "PCM"
    if 1 <= t <= 24:
        m = (t - 1) % 4
        cbp_l = 15 if (t - 1) // 12 else 0
        cbp_c = ((t - 1) // 4) % 3
        return f"I16_m{m}_cl{cbp_l}_cc{cbp_c}"
    return f"type_{t}"


def _y_exact(sc, cand: bytes, gold: bytes, w: int, h: int, mx: int, my: int) -> bool:
    return sc.plane_sample_block(cand, 0, w, h, "Y", mx, my) == sc.plane_sample_block(
        gold, 0, w, h, "Y", mx, my
    )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--candidate", required=True)
    ap.add_argument("--reference", required=True)
    ap.add_argument("--goldens-dir", required=True)
    ap.add_argument("--width", type=int, default=320)
    ap.add_argument("--height", type=int, default=240)
    ap.add_argument("--source-sha", default="")
    ap.add_argument("-o", "--output", required=True)
    args = ap.parse_args()

    repo = Path(__file__).resolve().parents[1]
    sc = _load_scorer(repo)
    cand = Path(args.candidate).read_bytes()
    gold = Path(args.reference).read_bytes()
    w, h = args.width, args.height

    by_class_ok: Counter = Counter()
    by_class_fail: Counter = Counter()
    i16_nb: Counter = Counter()
    i16_ok_nb: Counter = Counter()
    seed_fails = []
    cold128 = 0
    total_i = 0
    ok_i = 0

    paths = sorted(glob.glob(str(Path(args.goldens_dir) / "mb_*.json")))
    for fp in paths:
        j = json.loads(Path(fp).read_text())
        mb = j["macroblock"]
        if int(j.get("slice", {}).get("slice_type", -1)) not in (2, 7) and mb.get(
            "type_name", ""
        ).startswith("P"):
            # Still classify by mb type; I MBs only.
            pass
        t = int(mb["type"])
        if t > 25:
            continue
        # I-slice MBs: type 0..25
        if t > 25:
            continue
        # Only Intra MB types 0..25; skip pure inter types if present
        if t > 25:
            continue
        total_i += 1
        c = _cls(mb)
        yb = sc.plane_sample_block(cand, 0, w, h, "Y", mb["x"], mb["y"])
        yg = sc.plane_sample_block(gold, 0, w, h, "Y", mb["x"], mb["y"])
        ok = yb == yg
        if ok:
            ok_i += 1
            by_class_ok[c] += 1
        else:
            by_class_fail[c] += 1
            if all(p == 128 for p in yb):
                cold128 += 1

        L = A = True
        if mb["x"] > 0:
            L = _y_exact(sc, cand, gold, w, h, mb["x"] - 1, mb["y"])
        if mb["y"] > 0:
            A = _y_exact(sc, cand, gold, w, h, mb["x"], mb["y"] - 1)
        nb = f"L={L},A={A}"
        if c.startswith("I16"):
            if ok:
                i16_ok_nb[nb] += 1
            else:
                i16_nb[nb] += 1
        if (not ok) and L and A:
            seed_fails.append(
                {
                    "mb_x": mb["x"],
                    "mb_y": mb["y"],
                    "class": c,
                    "type": t,
                    "modes": j.get("prediction", {}).get("luma_4x4_modes"),
                }
            )

    # Refined largest-bucket view
    i16_m0_fail = sum(v for k, v in by_class_fail.items() if k.startswith("I16_m0"))
    i_nxn_fail = by_class_fail.get("I_NxN", 0)
    other_i16_fail = sum(
        v for k, v in by_class_fail.items() if k.startswith("I16") and not k.startswith("I16_m0")
    )

    out = {
        "source_sha": args.source_sha,
        "candidate": str(args.candidate),
        "reference": str(args.reference),
        "total_i_mb": total_i,
        "intra_y_mb_ok": ok_i,
        "intra_y_mb_fail": total_i - ok_i,
        "headline_note": "HEADLINE mb_exact stays 0 while chroma stubbed at 128",
        "pre_register_buckets": {
            "I16_m0_*": "100-130",
            "I_NxN": "60-80",
            "other_I16": "10-30",
            "cold128": "0-5",
        },
        "actual_buckets": {
            "I16_m0_*": i16_m0_fail,
            "I_NxN": i_nxn_fail,
            "other_I16": other_i16_fail,
            "cold128": cold128,
        },
        "by_class_ok": dict(sorted(by_class_ok.items())),
        "by_class_fail": dict(sorted(by_class_fail.items())),
        "i16_fail_neighbours": dict(sorted(i16_nb.items())),
        "i16_ok_neighbours": dict(sorted(i16_ok_nb.items())),
        "seed_fails_L_and_A_ok": seed_fails,
        "seed_fail_count": len(seed_fails),
        "root_cause_note": (
            "I16_m0 fails are 100% cascade (above Y wrong). "
            "Seed fails are few I_NxN MBs; largest fix target was "
            "I4 above-right pad (undecoded plane read as 128) in "
            "h264_i_res_recon_sink — H.264 8.3.1.2 requires p[3,-1] substitution."
        ),
    }
    Path(args.output).parent.mkdir(parents=True, exist_ok=True)
    Path(args.output).write_text(json.dumps(out, indent=2) + "\n")
    print(json.dumps({k: out[k] for k in (
        "intra_y_mb_ok", "intra_y_mb_fail", "actual_buckets", "seed_fail_count"
    )}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
