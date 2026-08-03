#!/usr/bin/env python3
"""Vertical unique-row scorer — direct row-pair comparison (NOT FFT).

WHY NOT FFT (parent, precision claim DROPPED)
--------------------------------------------
Measured period 3.988 sits BETWEEN bins (k=239→4.0000, k=240→3.9833);
±4 rows of active-height error ⇒ ±0.017. Bin-limited FFT is not a gate.

WHAT THIS MEASURES (direct row pairs)
-------------------------------------
On the active picture (letterbox stripped):

  adj_mae[i] = mean |row[i] - row[i-1]|   (luma)
  row i is a NEW unique chain step if adj_mae[i] >= tau
  n_unique_rows = 1 + count(new steps)
  unique_frac   = n_unique_rows / n_active

  frac_adjacent_dup = fraction of consecutive pairs with mae < tau
    (line-doubling signature of V_STORE=240 → store_y=py*2)

BEFORE ceiling (even-store-only, line-doubled on glass):
  high frac_adjacent_dup, unique_frac near ~0.5 of active (content-dependent floor).

AFTER T7 full 480 unique store rows (with vertically detailed content):
  frac_adjacent_dup collapses; unique_frac rises toward 1.0.

Pre-registered gates (caller chooses one expect mode):
  --expect-ceiling-240  PASS if unique_frac <= max_unique_frac_240
                        AND frac_adjacent_dup >= min_dup_frac_240
  --expect-full-480     PASS if unique_frac >= min_unique_frac_480
                        AND frac_adjacent_dup <= max_dup_frac_480
  default report-only   always needs artifact pair; no PASS without --expect-*

CONTROL: solid field / near-zero vertical energy → UNSCORED (cannot discriminate).

Fleet rule: RBF md5 + daemon md5 required or UNSCORED.
decode_src recorded; never pool across decode_src.

Exit: 0 PASS, 2 FAIL, 77 UNSCORED, 1 usage.
true rc: cmd; echo "true rc=$?" — never through a pipe.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

import numpy as np

try:
    from PIL import Image
except ImportError as e:
    raise SystemExit(f"Pillow required: {e}") from e

# Allow `python3 tools/foo.py` imports
_TOOLS = Path(__file__).resolve().parent
if str(_TOOLS) not in sys.path:
    sys.path.insert(0, str(_TOOLS))

from artifact_stamp import (  # noqa: E402
    RC_FAIL,
    RC_OK,
    RC_UNSCORED,
    RC_USAGE,
    add_stamp_args,
    require_stamp,
    stamp_from_namespace,
)

# Defaults pre-registered for gate modes (content with vertical detail).
# Solid/flat content is rejected as UNSCORED before these apply.
DEFAULT_TAU = 2.0  # mean |Δluma| per pixel; MJPG noise floor ~1
DEFAULT_MAX_UNIQUE_FRAC_240 = 0.62
DEFAULT_MIN_DUP_FRAC_240 = 0.35
DEFAULT_MIN_UNIQUE_FRAC_480 = 0.80
DEFAULT_MAX_DUP_FRAC_480 = 0.25
DEFAULT_MIN_ACTIVE_ROWS = 100
DEFAULT_MIN_VERT_ENERGY = 1.5  # mean adj mae; below => flat/unscoreable


def load_luma(path: Path) -> np.ndarray:
    rgb = np.asarray(Image.open(path).convert("RGB"), dtype=np.float64)
    return 0.299 * rgb[:, :, 0] + 0.587 * rgb[:, :, 1] + 0.114 * rgb[:, :, 2]


def active_row_slice(luma: np.ndarray, black_mean: float = 12.0, min_run: int = 8) -> slice:
    """Letterbox strip: longest run of rows with mean luma > black_mean or row std > 2."""
    h = luma.shape[0]
    row_mean = luma.mean(axis=1)
    row_std = luma.std(axis=1)
    active = (row_mean > black_mean) | (row_std > 2.0)
    # longest True run
    best = (0, 0)
    i = 0
    while i < h:
        if not active[i]:
            i += 1
            continue
        j = i
        while j < h and active[j]:
            j += 1
        if j - i > best[1] - best[0]:
            best = (i, j)
        i = j
    if best[1] - best[0] < min_run:
        # fall back to full frame
        return slice(0, h)
    return slice(best[0], best[1])


def score_unique_rows(
    luma: np.ndarray,
    *,
    tau: float = DEFAULT_TAU,
    black_mean: float = 12.0,
) -> dict[str, Any]:
    sl = active_row_slice(luma, black_mean=black_mean)
    active = luma[sl]
    n = int(active.shape[0])
    if n < 2:
        return {
            "verdict": "UNSCORED",
            "rc": RC_UNSCORED,
            "reason": "n_active_rows<2 — NO-DATA not zero",
            "n_active_rows": n,
            "n_active_rows_tag": "measured",
        }

    # Direct consecutive row MAE (mean abs diff across columns)
    d = np.abs(np.diff(active, axis=0)).mean(axis=1)  # (n-1,)
    new_step = d >= tau
    n_unique = 1 + int(new_step.sum())
    unique_frac = n_unique / float(n)
    frac_dup = float((~new_step).mean()) if len(d) else 0.0
    mean_adj = float(d.mean())
    median_adj = float(np.median(d))
    p10 = float(np.percentile(d, 10))
    p90 = float(np.percentile(d, 90))

    # Even/odd pair identity (line-double fingerprint)
    even_odd_mae = []
    for i in range(0, n - 1, 2):
        even_odd_mae.append(float(np.abs(active[i] - active[i + 1]).mean()))
    eo = np.asarray(even_odd_mae, dtype=np.float64) if even_odd_mae else np.asarray([0.0])
    frac_eo_dup = float((eo < tau).mean()) if len(eo) else 0.0
    mean_eo_mae = float(eo.mean())

    rep: dict[str, Any] = {
        "n_active_rows": n,
        "n_active_rows_der": "letterbox_strip_longest_nonblack_run",
        "n_active_rows_tag": "measured",
        "active_y0": int(sl.start),
        "active_y1": int(sl.stop),
        "tau": tau,
        "tau_der": "mean_abs_row_delta_threshold",
        "tau_tag": "caller_or_default",
        "n_unique_rows": n_unique,
        "n_unique_rows_der": "1+count(adj_mae>=tau)_chain",
        "n_unique_rows_tag": "measured",
        "unique_frac": unique_frac,
        "unique_frac_der": "n_unique_rows/n_active_rows",
        "unique_frac_tag": "derived",
        "frac_adjacent_dup": frac_dup,
        "frac_adjacent_dup_der": "frac(adj_mae<tau)",
        "frac_adjacent_dup_tag": "measured",
        "frac_even_odd_dup": frac_eo_dup,
        "frac_even_odd_dup_der": "frac(mae(row_2k,row_2k+1)<tau)",
        "frac_even_odd_dup_tag": "measured",
        "mean_adj_mae": mean_adj,
        "mean_adj_mae_tag": "measured",
        "median_adj_mae": median_adj,
        "median_adj_mae_tag": "measured",
        "p10_adj_mae": p10,
        "p90_adj_mae": p90,
        "mean_even_odd_mae": mean_eo_mae,
        "mean_even_odd_mae_tag": "measured",
        "method": "direct_row_pair_NOT_fft",
        "fft_note": "FFT bin-limit weakness acknowledged; not used for gate",
    }

    if n < DEFAULT_MIN_ACTIVE_ROWS:
        rep["verdict"] = "UNSCORED"
        rep["rc"] = RC_UNSCORED
        rep["reason"] = f"n_active_rows={n}<{DEFAULT_MIN_ACTIVE_ROWS}"
        return rep
    if mean_adj < DEFAULT_MIN_VERT_ENERGY:
        rep["verdict"] = "UNSCORED"
        rep["rc"] = RC_UNSCORED
        rep["reason"] = (
            f"mean_adj_mae={mean_adj:.3f}<{DEFAULT_MIN_VERT_ENERGY} "
            f"— flat/control field; cannot score unique-row ceiling"
        )
        return rep

    rep["verdict"] = "SCORED"
    rep["rc"] = RC_OK
    return rep


def apply_expect(rep: dict[str, Any], mode: str | None, ns: argparse.Namespace) -> dict[str, Any]:
    if rep.get("verdict") == "UNSCORED":
        return rep
    if not mode:
        rep["verdict"] = "REPORT_ONLY"
        rep["rc"] = RC_OK
        rep["reason"] = "no --expect-* gate; numbers reported only"
        return rep

    uf = float(rep["unique_frac"])
    fd = float(rep["frac_adjacent_dup"])
    if mode == "ceiling_240":
        ok_u = uf <= ns.max_unique_frac_240
        ok_d = fd >= ns.min_dup_frac_240
        rep["gate"] = "expect_ceiling_240"
        rep["gate_der"] = (
            f"unique_frac<={ns.max_unique_frac_240} AND "
            f"frac_adjacent_dup>={ns.min_dup_frac_240}"
        )
        if ok_u and ok_d:
            rep["verdict"] = "CEILING_240_HOLD"
            rep["rc"] = RC_OK
        else:
            rep["verdict"] = "CEILING_240_FAIL"
            rep["rc"] = RC_FAIL
            rep["reason"] = f"unique_frac={uf:.4f} frac_dup={fd:.4f} vs gate"
        return rep
    if mode == "full_480":
        ok_u = uf >= ns.min_unique_frac_480
        ok_d = fd <= ns.max_dup_frac_480
        rep["gate"] = "expect_full_480"
        rep["gate_der"] = (
            f"unique_frac>={ns.min_unique_frac_480} AND "
            f"frac_adjacent_dup<={ns.max_dup_frac_480}"
        )
        if ok_u and ok_d:
            rep["verdict"] = "FULL_480_OK"
            rep["rc"] = RC_OK
        else:
            rep["verdict"] = "FULL_480_FAIL"
            rep["rc"] = RC_FAIL
            rep["reason"] = f"unique_frac={uf:.4f} frac_dup={fd:.4f} vs gate"
        return rep
    rep["verdict"] = "UNSCORED"
    rep["rc"] = RC_UNSCORED
    rep["reason"] = f"unknown expect mode {mode}"
    return rep


def synth_line_double(h: int = 480, w: int = 640, unique: int = 240, seed: int = 0) -> np.ndarray:
    rng = np.random.default_rng(seed)
    base = rng.uniform(20, 220, size=(unique, w))
    if unique * 2 == h:
        rows = np.repeat(base, 2, axis=0)
    else:
        # stretch
        idx = (np.arange(h) * unique) // h
        rows = base[idx]
    return rows


def synth_full_unique(h: int = 480, w: int = 640, seed: int = 1) -> np.ndarray:
    rng = np.random.default_rng(seed)
    return rng.uniform(20, 220, size=(h, w))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("image", type=Path, nargs="?", help="captured PNG/JPG")
    ap.add_argument("--tau", type=float, default=DEFAULT_TAU)
    ap.add_argument("--expect-ceiling-240", action="store_true")
    ap.add_argument("--expect-full-480", action="store_true")
    ap.add_argument("--max-unique-frac-240", type=float, default=DEFAULT_MAX_UNIQUE_FRAC_240)
    ap.add_argument("--min-dup-frac-240", type=float, default=DEFAULT_MIN_DUP_FRAC_240)
    ap.add_argument("--min-unique-frac-480", type=float, default=DEFAULT_MIN_UNIQUE_FRAC_480)
    ap.add_argument("--max-dup-frac-480", type=float, default=DEFAULT_MAX_DUP_FRAC_480)
    ap.add_argument("--json-out", type=Path, default=None)
    ap.add_argument("--self-test", action="store_true")
    add_stamp_args(ap)
    args = ap.parse_args()

    if args.self_test:
        print("PRE-REGISTER vertical unique-row (direct pair, NOT FFT)")
        ok = True
        # stamp required
        st = stamp_from_namespace(args)
        if st.pair_ok:
            print("FAIL self-test should start unstamped"); ok = False

        ld = synth_line_double()
        r240 = score_unique_rows(ld, tau=args.tau)
        print("line_double", {k: r240[k] for k in (
            "n_unique_rows", "unique_frac", "frac_adjacent_dup", "mean_adj_mae", "verdict")})
        # Force expect
        class NS:
            max_unique_frac_240 = DEFAULT_MAX_UNIQUE_FRAC_240
            min_dup_frac_240 = DEFAULT_MIN_DUP_FRAC_240
            min_unique_frac_480 = DEFAULT_MIN_UNIQUE_FRAC_480
            max_dup_frac_480 = DEFAULT_MAX_DUP_FRAC_480
        r240g = apply_expect(dict(r240), "ceiling_240", NS())
        print("gate240", r240g["verdict"], r240g["rc"])
        if r240g["rc"] != RC_OK or r240g["verdict"] != "CEILING_240_HOLD":
            print("FAIL line-double should HOLD 240"); ok = False
        else:
            print("PASS line-double CEILING_240_HOLD")

        fu = synth_full_unique()
        r480 = score_unique_rows(fu, tau=args.tau)
        print("full_unique", {k: r480[k] for k in (
            "n_unique_rows", "unique_frac", "frac_adjacent_dup", "mean_adj_mae", "verdict")})
        r480g = apply_expect(dict(r480), "full_480", NS())
        print("gate480", r480g["verdict"], r480g["rc"])
        if r480g["rc"] != RC_OK or r480g["verdict"] != "FULL_480_OK":
            print("FAIL full unique should FULL_480_OK"); ok = False
        else:
            print("PASS full unique FULL_480_OK")

        # cross-fail: line-double must FAIL full_480 expect
        cross = apply_expect(dict(r240), "full_480", NS())
        if cross["rc"] != RC_FAIL:
            print("FAIL cross expect"); ok = False
        else:
            print("PASS line-double fails expect-full-480")

        flat = np.full((480, 640), 128.0)
        rf = score_unique_rows(flat, tau=args.tau)
        if rf["rc"] != RC_UNSCORED:
            print("FAIL flat should UNSCORED"); ok = False
        else:
            print("PASS flat UNSCORED", rf.get("reason"))

        # stamped path
        args.rbf_md5 = "c5382bee73cecdee8220b811e529c297"
        args.daemon_md5 = "7c991e47aaaaaaaaaaaaaaaaaaaaaaaa"
        args.decode_src = "caller_supplied"
        st2 = stamp_from_namespace(args)
        o, _, rc = require_stamp(st2)
        if not o or rc != RC_OK:
            print("FAIL stamp"); ok = False
        else:
            print("PASS stamp", st2.header_kv()[:120])

        print("SELF_TEST_OK" if ok else "SELF_TEST_FAIL")
        return RC_OK if ok else RC_FAIL

    if not args.image or not args.image.is_file():
        print("NO_DATA image missing — empty is not zero")
        return RC_UNSCORED

    st = stamp_from_namespace(args)
    print("STAMP", st.header_kv())
    ok_pair, reason, rc_pair = require_stamp(st)
    if not ok_pair and not args.allow_unstamped:
        print(f"VERDICT=UNSCORED rc={RC_UNSCORED} reason={reason}")
        return RC_UNSCORED
    if not ok_pair and args.allow_unstamped:
        print(
            "WARN allow_unstamped — forensic only; product claim FORBIDDEN "
            f"reason={reason}"
        )

    if args.expect_ceiling_240 and args.expect_full_480:
        print("usage: only one --expect-*")
        return RC_USAGE
    mode = None
    if args.expect_ceiling_240:
        mode = "ceiling_240"
    elif args.expect_full_480:
        mode = "full_480"

    luma = load_luma(args.image)
    rep = score_unique_rows(luma, tau=args.tau)
    rep = apply_expect(rep, mode, args)
    rep["image"] = str(args.image)
    rep["image_tag"] = "caller_supplied"
    rep["stamp"] = st.to_dict()
    rep["decode_src"] = st.decode_src
    rep["decode_src_partition"] = "results_must_not_pool_across_decode_src"

    print(
        f"VERDICT={rep.get('verdict')} rc={rep.get('rc')} "
        f"n_active_rows={rep.get('n_active_rows')} "
        f"n_unique_rows={rep.get('n_unique_rows')} "
        f"unique_frac={rep.get('unique_frac')} "
        f"unique_frac_der={rep.get('unique_frac_der')} "
        f"frac_adjacent_dup={rep.get('frac_adjacent_dup')} "
        f"frac_even_odd_dup={rep.get('frac_even_odd_dup')} "
        f"mean_adj_mae={rep.get('mean_adj_mae')} "
        f"method={rep.get('method')} "
        f"gate={rep.get('gate')} "
        f"artifact_pair={st.artifact_pair} "
        f"decode_src={st.decode_src}"
    )
    if rep.get("reason"):
        print(f"reason={rep['reason']}")

    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(json.dumps(rep, indent=2, sort_keys=True) + "\n")

    # Unstamped always 77 even if geometry would pass
    if not ok_pair:
        return RC_UNSCORED
    return int(rep.get("rc", RC_UNSCORED))


if __name__ == "__main__":
    sys.exit(main())
