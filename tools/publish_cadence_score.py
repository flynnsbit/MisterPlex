#!/usr/bin/env python3
"""Score publish cadence from daemon log — PRIMARY = one-refresh hold fraction.

DEFECT 1 (parent): p_ge50 is NOT a defect metric (conflates legal ~50ms gaps
with lateness if 41.667 is treated as a quantum). Primary:

  p_one_refresh_hold = fraction of publish intervals with
      round(iv_ms / T_vsync) == 1
  der printed beside name. At 24fps@60Hz this is unambiguously wrong.

p_d1 / p_delta1 = frac(Δframes_done==1) — DIFFERENT metric; never alias silently.

DEFECT 2: vsync_tag must be measured or every hold_d is CONDITIONAL.
DEFECT 3 / ERROR 17: never print fps without src=measured|caller_supplied|DEFAULT_ASSUMED.

Guards: empty log = NO_DATA not zero; do not pool termination classes;
sigma>=mean => p_ge50 forensic unscored.

Exit: 0 OK, 2 HITCHY/FAIL, 77 UNSCORED, 1 usage.
true rc: cmd; echo "true rc=$?"  — never through a pipe.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

_TOOLS = Path(__file__).resolve().parent
if str(_TOOLS) not in sys.path:
    sys.path.insert(0, str(_TOOLS))

from artifact_stamp import (  # noqa: E402
    add_stamp_args,
    parse_decode_src_from_log_line,
    refuse_pool_decode_src,
    require_stamp,
    stamp_from_namespace,
)

RC_OK = 0
RC_USAGE = 1
RC_FAIL = 2
RC_UNSCORED = 77

TERM_CLASSES = ("session_end", "mid", "stop_or_seek", "unknown")


def parse_kv(line: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for m in re.finditer(r"([A-Za-z0-9_]+)=([^\s]+)", line):
        out[m.group(1)] = m.group(2)
    return out


def term_class(line: str) -> str:
    if "phase=session_end" in line or "phase=session-end" in line:
        return "session_end"
    if "phase=mid" in line:
        return "mid"
    if "stop" in line or "seek" in line:
        return "stop_or_seek"
    return "unknown"


def score_kv(kv: dict[str, str], *, require_measured_vsync: bool) -> dict:
    def f(name: str):
        if name not in kv:
            return None
        try:
            return float(kv[name])
        except ValueError:
            return None

    # Primary defect name (prefer new field)
    p1 = f("p_one_refresh_hold")
    if p1 is None:
        p1 = f("p_hold_d1")
    p1_der = kv.get(
        "p_one_refresh_hold_der",
        "round(publish_iv_ms/T_vsync)==1",
    )
    cad = kv.get("cadence_verdict", "ABSENT")
    mean_ms = f("mean_ms")
    sigma_ms = f("sigma_ms")
    p_ge50 = f("p_ge50")
    p_ge50_tag = kv.get("p_ge50_tag", "ABSENT")
    vsync_tag = kv.get("vsync_tag", kv.get("phase_tag", "ABSENT"))
    if "ESTIMATE" in str(vsync_tag) or vsync_tag == "DEFAULT_ASSUMED":
        vsync_status = "DEFAULT_OR_ESTIMATE"
    elif vsync_tag == "measured" or "MEASURED" in str(vsync_tag):
        vsync_status = "measured"
    else:
        vsync_status = str(vsync_tag)

    # Sigma gate: p_ge50 forensic AND primary cadence both unscored when sigma>=mean
    sigma_bad = (
        mean_ms is not None
        and sigma_ms is not None
        and mean_ms > 0
        and sigma_ms >= mean_ms
    )
    if sigma_bad:
        p_ge50_tag = "UNSCORED_SIGMA_GE_MEAN"

    rep = {
        "PRIMARY_p_one_refresh_hold": p1,
        "PRIMARY_der": p1_der,
        "PRIMARY_tag": "derived",
        "cadence_verdict": cad,
        "p_hold_d2": f("p_hold_d2"),
        "p_hold_d3": f("p_hold_d3"),
        "p_hold_d_ge4": f("p_hold_d_ge4"),
        "cad_alt_frac": f("cad_alt_frac"),
        "mean_ms": mean_ms,
        "mean_ms_der": "mean(publish_iv_ms)",
        "sigma_ms": sigma_ms,
        "sigma_ms_der": "stdev(publish_iv_ms)",
        "p_ge50": p_ge50,
        "p_ge50_der": "frac(publish_iv_ms>50)_FORENSIC_NOT_DEFECT",
        "p_ge50_tag": p_ge50_tag,
        "p_delta1": f("p_delta1") if "p_delta1" in kv else f("p_d1"),
        "p_delta1_der": "frac(delta_frames_done==1)_NOT_one_refresh_hold",
        "vsync_tag": vsync_tag,
        "vsync_status": vsync_status,
        "hold_d_conditional": vsync_status != "measured",
    }

    if require_measured_vsync and vsync_status != "measured":
        rep["verdict"] = "UNSCORED_VSYNC_NOT_MEASURED"
        rep["rc"] = RC_UNSCORED
        rep["reason"] = (
            "hold_d/p_one_refresh_hold conditional on T_vsync; "
            "run tools/measure_refresh_hz.py and pass --vsync-hz measured"
        )
        return rep

    # Binding: refuse to score hitch/cadence when sigma >= mean (parent T2).
    # Raw p_one_refresh_hold may still be printed for forensics.
    if sigma_bad:
        rep["verdict"] = "UNSCORED_SIGMA_GE_MEAN"
        rep["rc"] = RC_UNSCORED
        rep["reason"] = (
            "sigma_ms>=mean_ms — refuse p_one_refresh_hold/p_ge50 as scores; "
            "do not pool with clean natural-EOF session"
        )
        return rep

    if p1 is None and cad in ("ABSENT", "UNSCORED"):
        rep["verdict"] = "UNSCORED"
        rep["rc"] = RC_UNSCORED
        rep["reason"] = "no p_one_refresh_hold — redeploy cadence daemon"
        return rep

    if p1 is not None and p1 >= 0.02:
        rep["verdict"] = "HITCHY_ONE_REFRESH_HOLD"
        rep["rc"] = RC_FAIL
        return rep
    if cad == "HITCHY_D1":
        rep["verdict"] = "HITCHY_ONE_REFRESH_HOLD"
        rep["rc"] = RC_FAIL
        return rep
    if cad in ("CADENCE_32_CLEAN", "CADENCE_METRONOME_OK", "CADENCE_OK_MILD"):
        rep["verdict"] = cad
        rep["rc"] = RC_OK
        return rep
    if cad == "CADENCE_IRREGULAR":
        rep["verdict"] = cad
        rep["rc"] = RC_FAIL
        return rep
    if p1 is not None and p1 < 0.02:
        rep["verdict"] = "ONE_REFRESH_HOLD_OK"
        rep["rc"] = RC_OK
        return rep
    rep["verdict"] = cad or "UNSCORED"
    rep["rc"] = RC_UNSCORED
    return rep


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("log", type=Path, nargs="?", help="daemon log")
    ap.add_argument(
        "--phase",
        choices=TERM_CLASSES,
        default="session_end",
        help="termination class to score; refuse merge across classes",
    )
    ap.add_argument(
        "--require-measured-vsync",
        action="store_true",
        help="rc=77 unless vsync_tag=measured (DEFECT 2 loud)",
    )
    ap.add_argument("--vsync-hz", type=float, default=None, help="caller_supplied measured Hz")
    ap.add_argument(
        "--require-decode-src",
        default=None,
        help="if set, refuse score when log decode_src differs (no pool)",
    )
    ap.add_argument("--self-test", action="store_true")
    add_stamp_args(ap)
    args = ap.parse_args()

    if args.self_test:
        print("PRE-REGISTER cadence score:")
        print("  PRIMARY=p_one_refresh_hold der=round(iv/T)==1")
        print("  p_ge50=forensic_only; sigma>=mean => not score")
        print("  no pool across phase= / decode_src=")
        print("  fleet: artifact pair required")
        ok = True
        r = score_kv(
            {
                "p_one_refresh_hold": "0.0335",
                "p_one_refresh_hold_der": "round(publish_iv_ms/T_vsync)==1",
                "cadence_verdict": "HITCHY_D1",
                "mean_ms": "41.659",
                "sigma_ms": "10.506",
                "p_ge50": "0.1403",
                "p_ge50_tag": "measured",
                "vsync_tag": "DEFAULT_ASSUMED",
            },
            require_measured_vsync=False,
        )
        print("LIVE_CLASS", r)
        if r["rc"] != RC_FAIL or r["PRIMARY_p_one_refresh_hold"] != 0.0335:
            print("FAIL hitch primary"); ok = False
        else:
            print("PASS hitch primary p_one_refresh_hold=0.0335")
        r2 = score_kv(
            {"p_ge50": "0.15", "mean_ms": "42", "sigma_ms": "65", "vsync_tag": "measured"},
            require_measured_vsync=True,
        )
        print("SIGMA", r2)
        if r2["rc"] != RC_UNSCORED:
            print("FAIL sigma"); ok = False
        else:
            print("PASS sigma UNSCORED")
        r3 = score_kv(
            {
                "p_one_refresh_hold": "0.0335",
                "cadence_verdict": "HITCHY_D1",
                "vsync_tag": "DEFAULT_ASSUMED",
            },
            require_measured_vsync=True,
        )
        if r3["rc"] != RC_UNSCORED:
            print("FAIL vsync require"); ok = False
        else:
            print("PASS vsync require UNSCORED")
        if refuse_pool_decode_src("caller_supplied", "conf:/media/fat/misterplex.conf"):
            print("PASS decode_src pool refuse")
        else:
            print("FAIL decode_src pool"); ok = False
        # unstamped score path must 77
        args.rbf_md5 = None
        args.daemon_md5 = None
        st = stamp_from_namespace(args)
        o, _, rc = require_stamp(st)
        if o or rc != RC_UNSCORED:
            print("FAIL unstamped"); ok = False
        else:
            print("PASS unstamped UNSCORED")
        print("SELF_TEST_OK" if ok else "SELF_TEST_FAIL")
        return RC_OK if ok else RC_FAIL

    st = stamp_from_namespace(args)
    print("STAMP", st.header_kv())
    ok_pair, reason, rc_pair = require_stamp(st)
    if not ok_pair and not args.allow_unstamped:
        print(f"VERDICT=UNSCORED rc={RC_UNSCORED} reason={reason}")
        return RC_UNSCORED

    if not args.log or not args.log.is_file():
        print("NO_DATA log missing — empty means no-data not zero")
        return RC_UNSCORED

    lines = args.log.read_text(errors="replace").splitlines()
    cands = [
        ln
        for ln in lines
        if "publish_swap_delta" in ln and "phase_est" not in ln and "_alias" not in ln
    ]
    if not cands:
        print("NO_DATA no publish_swap_delta lines — not zero defect")
        return RC_UNSCORED

    # Filter by termination class — NEVER pool
    matched = [ln for ln in cands if term_class(ln) == args.phase]
    if not matched:
        classes = sorted({term_class(ln) for ln in cands})
        print(
            f"NO_DATA phase={args.phase} lines=0 present_classes={classes} "
            f"— refuse pool; pick --phase"
        )
        return RC_UNSCORED

    # decode_src partition: scan nearby media lines for decode_src
    decode_srcs = set()
    decodes = set()
    for ln in lines:
        if "decode_src=" in ln:
            d, s = parse_decode_src_from_log_line(ln)
            if s != "NO-DATA":
                decode_srcs.add(s)
            if d != "NO-DATA":
                decodes.add(d)
    if len(decode_srcs) > 1:
        print(
            f"VERDICT=UNSCORED rc={RC_UNSCORED} reason=mixed_decode_src={sorted(decode_srcs)} "
            f"— refuse pool across decode_src"
        )
        return RC_UNSCORED
    log_decode_src = next(iter(decode_srcs), "NO-DATA")
    log_decode = next(iter(decodes), "NO-DATA")
    if st.decode_src == "NO-DATA" and log_decode_src != "NO-DATA":
        st.decode_src = log_decode_src
        st.decode_src_src = "measured_log"
    if st.decode == "NO-DATA" and log_decode != "NO-DATA":
        st.decode = log_decode
    if args.require_decode_src and refuse_pool_decode_src(args.require_decode_src, log_decode_src):
        print(
            f"VERDICT=UNSCORED rc={RC_UNSCORED} "
            f"reason=decode_src_mismatch want={args.require_decode_src} got={log_decode_src}"
        )
        return RC_UNSCORED
    print(
        f"decode={st.decode} decode_src={st.decode_src} decode_src_src={st.decode_src_src} "
        f"decode_src_partition=no_pool_across_values"
    )

    pick = None
    for ln in reversed(matched):
        if "p_one_refresh_hold=" in ln or "p_hold_d1=" in ln or "cadence_verdict=" in ln:
            pick = ln
            break
    if pick is None:
        pick = matched[-1]

    print(f"phase={args.phase} n_lines={len(matched)} (not pooled with other phases)")
    print("LINE", pick[:280])
    kv = parse_kv(pick)
    if args.vsync_hz is not None:
        kv["vsync_tag"] = "measured"
        kv["vsync_hz"] = str(args.vsync_hz)
        print(
            f"vsync_hz={args.vsync_hz} vsync_hz_tag=caller_supplied "
            f"vsync_hz_der=parent_measure_refresh_hz"
        )
    rep = score_kv(kv, require_measured_vsync=args.require_measured_vsync)
    print(
        f"VERDICT={rep['verdict']} rc={rep['rc']} "
        f"PRIMARY_p_one_refresh_hold={rep.get('PRIMARY_p_one_refresh_hold')} "
        f"PRIMARY_der={rep.get('PRIMARY_der')} "
        f"cadence={rep.get('cadence_verdict')} "
        f"p_ge50={rep.get('p_ge50')} p_ge50_tag={rep.get('p_ge50_tag')} "
        f"p_ge50_role=forensic_only "
        f"mean_ms={rep.get('mean_ms')} sigma_ms={rep.get('sigma_ms')} "
        f"vsync_status={rep.get('vsync_status')} "
        f"hold_d_conditional={rep.get('hold_d_conditional')} "
        f"p_delta1={rep.get('p_delta1')} p_delta1_der={rep.get('p_delta1_der')} "
        f"artifact_pair={st.artifact_pair} decode_src={st.decode_src}"
    )
    if rep.get("reason"):
        print(f"reason={rep['reason']}")
    if not ok_pair:
        return RC_UNSCORED
    return int(rep["rc"])


if __name__ == "__main__":
    sys.exit(main())
