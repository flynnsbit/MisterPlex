#!/usr/bin/env python3
"""Score MiSTer-spin vs frame-loss contention hypotheses from schedstat JSON.

Does NOT touch the device. Parent runs tools/schedstat_sample.py on-device,
pulls JSON here, optionally supplies HDMI loss rates for C2-AB.

PRE_REG bands (must match PARENT_C1_C4_MISTER_CONTENTION_CARD.md):
  C2-W misterplexd agg_wait_frac:
      >= 10%  → WAIT_HIGH (contention-consistent support)
      <=  3%  → WAIT_LOW  (refute support if loss still high)
  C2-F ffmpeg agg_wait_frac:
      >= 15%  → FF_STARVE_CONSISTENT
      <=  8%  → FF_STARVE_REFUTED_SUPPORT
  C2-AB loss_b/loss_a:
      <= 0.30 → CONTENTION_IMPLICATED
      in [0.7, 1.3] → CONTENTION_ELIMINATED
  MiSTer wait_frac high → NOT a spin (blocked); low wait + high run → scavenger spin

Exit:
  0  scored (always prints VERDICT=...)
  2  bad args / unreadable
  77 NO-DATA (no misterplexd/ffmpeg/MiSTer rows)
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Dict, Optional


def agg_get(data: Dict[str, Any], key: str) -> Dict[str, Any]:
    a = data.get(key) or {}
    return a if isinstance(a, dict) else {}


def wf(agg: Dict[str, Any]) -> Optional[float]:
    if agg.get("NO_DATA"):
        return None
    v = agg.get("agg_wait_frac_pct")
    return float(v) if v is not None else None


def run_pct(agg: Dict[str, Any]) -> Optional[float]:
    if agg.get("NO_DATA"):
        return None
    v = agg.get("sum_run_pct_wall")
    return float(v) if v is not None else None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("schedstat_json", help="from tools/schedstat_sample.py")
    ap.add_argument("--loss-a-pct", type=float, default=None, help="HDMI loss %% Main running")
    ap.add_argument("--loss-b-pct", type=float, default=None, help="HDMI loss %% Main stopped")
    ap.add_argument(
        "--hdmi-loss-still-pct",
        type=float,
        default=None,
        help="If set with WAIT_LOW, used to support REFUTE (loss continues)",
    )
    args = ap.parse_args()

    path = Path(args.schedstat_json)
    if not path.is_file():
        print(f"NO_FILE {path}")
        return 2

    data = json.loads(path.read_text(encoding="utf-8"))
    mp = agg_get(data, "misterplexd_agg")
    ff = agg_get(data, "ffmpeg_agg")
    mi = agg_get(data, "mister_agg")

    print(f"label={data.get('label')} dwall_s={data.get('dwall_s')} tag=measured")

    def show(name: str, a: Dict[str, Any]) -> None:
        if a.get("NO_DATA") or wf(a) is None:
            print(f"{name}: NO-DATA")
            return
        print(
            f"{name}: agg_wait_frac_pct={wf(a)} max_busy_wf={a.get('max_busy_thread_wait_frac_pct')} "
            f"sum_run_pct_wall={run_pct(a)} n_busy={a.get('n_busy_threads')} tag=measured"
        )

    show("misterplexd", mp)
    show("ffmpeg", ff)
    show("MiSTer", mi)

    notes = []
    # C1-style: MiSTer spin vs blocked
    mi_wf, mi_run = wf(mi), run_pct(mi)
    if mi_wf is None and mi_run is None:
        notes.append("MiSTer=NO-DATA")
    elif mi_wf is not None and mi_run is not None:
        if mi_wf <= 5.0 and mi_run >= 30.0:
            notes.append("C1_R: MiSTer low_wait+high_run → scavenger/spin signature PASS band")
        elif mi_wf >= 15.0:
            notes.append("C1_R: MiSTer HIGH wait_frac → blocked not spinning (unexpected for poll0)")
        else:
            notes.append(f"C1_R: MiSTer grey wait={mi_wf} run={mi_run}")

    mp_wf = wf(mp)
    ff_wf = wf(ff)
    if mp_wf is None and ff_wf is None and mi_wf is None:
        print("VERDICT=NO-DATA detail=no_process_aggs")
        return 77

    # C2-W / C2-F
    c2w = "NO-DATA"
    if mp_wf is not None:
        if mp_wf >= 10.0:
            c2w = "WAIT_HIGH"
        elif mp_wf <= 3.0:
            c2w = "WAIT_LOW"
        else:
            c2w = "WAIT_GREY"
        notes.append(f"C2-W misterplexd={c2w} wf={mp_wf}")

    c2f = "NO-DATA"
    if ff_wf is not None:
        if ff_wf >= 15.0:
            c2f = "FF_STARVE_CONSISTENT"
        elif ff_wf <= 8.0:
            c2f = "FF_STARVE_REFUTED_SUPPORT"
        else:
            c2f = "FF_GREY"
        notes.append(f"C2-F ffmpeg={c2f} wf={ff_wf}")

    # C2-AB
    c2ab = "NOT_RUN"
    if args.loss_a_pct is not None and args.loss_b_pct is not None:
        if args.loss_a_pct <= 0:
            c2ab = "INVALID_LOSS_A"
        else:
            ratio = args.loss_b_pct / args.loss_a_pct
            notes.append(
                f"C2-AB loss_a={args.loss_a_pct}% loss_b={args.loss_b_pct}% ratio={ratio:.3f} tag=caller_supplied"
            )
            if ratio <= 0.30:
                c2ab = "CONTENTION_IMPLICATED"
            elif 0.7 <= ratio <= 1.3:
                c2ab = "CONTENTION_ELIMINATED"
            else:
                c2ab = "CONTENTION_GREY"

    # Overall
    if c2ab == "CONTENTION_IMPLICATED":
        verdict = "CONTENTION_IMPLICATED"
        detail = "C2-AB primary: HDMI loss fell sharply with Main stopped"
    elif c2ab == "CONTENTION_ELIMINATED":
        verdict = "CONTENTION_ELIMINATED"
        detail = "C2-AB primary: HDMI loss unchanged with Main stopped"
    elif c2w == "WAIT_HIGH" and c2f == "FF_STARVE_CONSISTENT":
        verdict = "CONTENTION_CONSISTENT_SUPPORT"
        detail = "high misterplexd+ffmpeg wait_frac; run C2-AB to prove causality"
    elif c2w == "WAIT_HIGH":
        verdict = "CONTENTION_CONSISTENT_SUPPORT"
        detail = "misterplexd runqueue wait high; run C2-AB"
    elif c2w == "WAIT_LOW":
        loss = args.hdmi_loss_still_pct
        if loss is not None and loss >= 0.5:
            verdict = "CONTENTION_REFUTED_SUPPORT"
            detail = (
                f"misterplexd wait_frac low while HDMI loss still {loss}% — "
                "CPU runqueue delay unlikely; C2-AB still gold standard"
            )
        else:
            verdict = "WAIT_LOW_NO_LOSS_CTX"
            detail = "low misterplexd wait; supply --hdmi-loss-still-pct or C2-AB"
    elif c2ab == "CONTENTION_GREY":
        verdict = "INCONCLUSIVE"
        detail = "C2-AB grey ratio — more reps"
    else:
        verdict = "INCONCLUSIVE"
        detail = "need C2-AB and/or clearer wait_frac; do not claim contention"

    print(f"VERDICT={verdict}")
    print(f"detail={detail}")
    for n in notes:
        print(f"note: {n}")
    print(
        "bands: C2-W high>=10 low<=3; C2-F high>=15 low<=8; "
        "C2-AB implicate ratio<=0.30 eliminate [0.7,1.3]; tag=PRE_REG"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
