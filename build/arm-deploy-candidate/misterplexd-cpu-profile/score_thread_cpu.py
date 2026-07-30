#!/usr/bin/env python3
"""Offline scorer for bounce2 PRESENT_PROFILE=1 capture (post-audit method).

Method (parent audit 2026-07-30) — ALL figures from ONE wall clock window:
  P = 100 × Δprocess_ticks / (HZ × Δwall)     # process percent-onecpu
  B = 100 × Σ bucket_cpu_us / (1e6 × Δwall) # instrumented media buckets only
  S = 100 × Σ_tid Δj_tid / (HZ × Δwall)     # all tids seen in window (incl. ephemeral)
  G = P − S   # jiffies not on sampled tids (parse/UNKNOWN trail)
  U = P − B   # UNINSTRUMENTED process CPU — never "hidden burn", never "87-pt hole"

No fps scaling anywhere. Assumed frame rate must not appear in arithmetic.

Bucket totals reconstructed as avg_*_us × frames|presented from present_profile
(that product is total µs; dividing by Δwall needs no fps).

Ephemeral workers: any tid appearing in any thread_cpu sample contributes
  dj = last_seen_j − first_seen_j (captures threads that exit mid-window).

Frozen R1–R5 falsifiers from PREREGISTER_V9_THREAD.txt are scored as filed.
HTTP was never validly ruled out (play-file exits before comp.start) — R2 live.

Usage:
  score_thread_cpu.py CAPTURE.log --du SEC [--dm DJ | --process-pct P] [--hz 100]
  score_thread_cpu.py --selftest
"""
from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple

THREAD_RE = re.compile(r"tid=(?P<tid>\d+)\((?P<comm>[^)]*)\)\s*j=(?P<j>\d+)")
THREAD_LINE_RE = re.compile(r"media:\s*thread_cpu\b")
PROFILE_LINE_RE = re.compile(r"media:\s*present_profile\b")
FIELD_RE = re.compile(r"(\w+)=([0-9]+)")


@dataclass
class TidTrack:
    comm: str
    first_j: int
    last_j: int


@dataclass
class ProfileWindow:
    frames: int = 0
    presented: int = 0
    bucket_cpu_us: float = 0.0
    raw: Dict[str, int] = field(default_factory=dict)


@dataclass
class Score:
    P: Optional[float]
    B: Optional[float]
    S: float
    G: Optional[float]
    U: Optional[float]
    hz: float
    du: Optional[float]
    per_tid: List[Tuple[int, str, int, float]]
    verdicts: Dict[str, str]
    notes: List[str] = field(default_factory=list)


def parse_profile_line(line: str) -> Optional[ProfileWindow]:
    if not PROFILE_LINE_RE.search(line):
        return None
    fields = {m.group(1): int(m.group(2)) for m in FIELD_RE.finditer(line)}
    frames = fields.get("frames", 0)
    presented = fields.get("presented", 0)
    if frames <= 0:
        return None
    total = 0.0
    for key in ("read_cpu_us_f", "pacing_wait_cpu_us_f"):
        if key in fields:
            total += fields[key] * frames
    for key in (
        "overlay_cpu_us_p",
        "fb_cpu_us_p",
        "pixel_cpu_us_p",
        "ddr_cpu_us_p",
    ):
        if key in fields and presented > 0:
            total += fields[key] * presented
    return ProfileWindow(frames=frames, presented=presented, bucket_cpu_us=total, raw=fields)


def parse_log(text: str) -> Tuple[List[Dict[int, Tuple[str, int]]], List[ProfileWindow]]:
    tid_samples: List[Dict[int, Tuple[str, int]]] = []
    profiles: List[ProfileWindow] = []
    for line in text.splitlines():
        pw = parse_profile_line(line)
        if pw is not None:
            profiles.append(pw)
        if THREAD_LINE_RE.search(line):
            tids: Dict[int, Tuple[str, int]] = {}
            for m in THREAD_RE.finditer(line):
                tid = int(m.group("tid"))
                tids[tid] = (m.group("comm"), int(m.group("j")))
            if tids:
                tid_samples.append(tids)
    return tid_samples, profiles


def accumulate_tids(samples: List[Dict[int, Tuple[str, int]]]) -> Dict[int, TidTrack]:
    tracks: Dict[int, TidTrack] = {}
    for sample in samples:
        for tid, (comm, j) in sample.items():
            if tid not in tracks:
                tracks[tid] = TidTrack(comm=comm, first_j=j, last_j=j)
            else:
                t = tracks[tid]
                t.last_j = j
                if comm:
                    t.comm = comm
    return tracks


def score(
    tid_samples: List[Dict[int, Tuple[str, int]]],
    profiles: List[ProfileWindow],
    *,
    process_pct: Optional[float],
    dm: Optional[float],
    du: Optional[float],
    hz: float = 100.0,
    bucket_cpu_us_override: Optional[float] = None,
    observer_anchor: float = 95.5,
    observer_band: float = 10.0,
) -> Score:
    notes: List[str] = []
    notes.append(
        "LABELS: P=process%onecpu B=bucket%onecpu S=sum_tid%onecpu "
        "G=P-S U=P-B(uninstrumented process CPU — NOT hidden-burn/87-hole)"
    )
    notes.append("METHOD: single wall clock du; no fps scaling")

    P: Optional[float] = process_pct
    if P is None and dm is not None and du is not None and du > 0:
        P = 100.0 * dm / (hz * du)
        notes.append(f"P from dm/du: dm={dm} du={du} hz={hz} -> P={P:.3f}")
    elif P is not None:
        notes.append(f"P from --process-pct={P}")

    B: Optional[float] = None
    bucket_us = bucket_cpu_us_override
    if bucket_us is None and profiles:
        bucket_us = profiles[-1].bucket_cpu_us
        notes.append(
            f"B buckets from present_profile totals_us={bucket_us:.0f} "
            f"(frames={profiles[-1].frames} presented={profiles[-1].presented})"
        )
    if bucket_us is not None and du is not None and du > 0:
        B = 100.0 * bucket_us / (1e6 * du)
        notes.append(f"B={B:.3f} percent-onecpu (no fps)")
    elif bucket_us is not None:
        notes.append("B unavailable: need --du to convert bucket_us -> percent-onecpu")
    else:
        notes.append("B unavailable: no present_profile CPU fields and no --bucket-cpu-us")

    if len(tid_samples) < 1:
        notes.append("INSUFFICIENT: no thread_cpu samples")
        return Score(
            P, B, 0.0, None, (P - B) if (P is not None and B is not None) else None,
            hz, du, [], {f"R{i}": "INSUFFICIENT" for i in range(1, 6)}, notes,
        )

    tracks = accumulate_tids(tid_samples)
    if len(tid_samples) < 2:
        notes.append("INSUFFICIENT: need >=2 thread_cpu samples for dj")
        verd = {f"R{i}": "INSUFFICIENT" for i in range(1, 6)}
        return Score(
            P, B, 0.0, None, (P - B) if (P is not None and B is not None) else None,
            hz, du, [], verd, notes,
        )

    per: List[Tuple[int, str, int, float]] = []
    for tid, tr in tracks.items():
        dj = tr.last_j - tr.first_j
        if dj < 0:
            notes.append(f"tid={tid} negative dj={dj} (tid reuse?) — clamp 0")
            dj = 0
        if du is not None and du > 0:
            pct = 100.0 * dj / (hz * du)
        else:
            pct = float("nan")
        per.append((tid, tr.comm, dj, pct))
    per.sort(key=lambda x: x[2], reverse=True)

    if du is not None and du > 0:
        S = sum(p for *_, p in per)
    else:
        S = float("nan")
        notes.append("S unavailable without --du")

    G = (P - S) if (P is not None and S == S) else None
    U = (P - B) if (P is not None and B is not None) else None
    if U is not None:
        notes.append(
            f"U=uninstrumented_process_CPU={U:.3f}  "
            f"(do NOT call this hidden-burn or 87-point hole)"
        )
    if G is not None:
        notes.append(f"G=P-S={G:.3f} (same-window jiffies gap)")

    if P is not None and abs(P - observer_anchor) > observer_band:
        notes.append(
            f"OBSERVER?: P={P:.1f} outside PROFILE=0 anchor {observer_anchor}+/-{observer_band}"
        )

    verdicts: Dict[str, str] = {}
    if not per or S != S or du is None:
        for i in range(1, 6):
            verdicts[f"R{i}"] = "INSUFFICIENT"
        notes.append("verdicts INSUFFICIENT without absolute tid percent-onecpu")
        return Score(P, B, S if S == S else 0.0, G, U, hz, du, per, verdicts, notes)

    top_tid, top_comm, top_dj, top_pct = per[0]

    if P is not None and P >= 90 and top_pct < 15:
        verdicts["R1"] = "FALSIFIED"
        notes.append("R1 FALSIFIED: P>=90 but top tid <15%onecpu")
    elif top_pct >= 40:
        verdicts["R1"] = "CONFIRMED"
        notes.append(
            "R1 CONFIRMED numerically (top tid >=40). "
            "Role=audio still needs tid identity — do not treat vacuous HTTP miss as support."
        )
    else:
        verdicts["R1"] = "INSUFFICIENT"
        notes.append(f"R1 INSUFFICIENT: top_pct={top_pct:.1f}")

    short_span = []
    if len(tid_samples) >= 2:
        first_set = set(tid_samples[0])
        last_set = set(tid_samples[-1])
        for tid, tr in tracks.items():
            if tid not in first_set or tid not in last_set:
                dj = tr.last_j - tr.first_j
                if dj > 0:
                    short_span.append((tid, dj))
    ephemeral_pct = 0.0
    if du and du > 0:
        ephemeral_pct = sum(100.0 * dj / (hz * du) for _, dj in short_span)

    if G is not None and G >= 40:
        verdicts["R2"] = "CONFIRMED"
        notes.append(f"R2 CONFIRMED: G={G:.1f}>=40 (CPU not on any sampled tid trail)")
    elif ephemeral_pct >= 40:
        verdicts["R2"] = "CONFIRMED"
        notes.append(f"R2 CONFIRMED: ephemeral-span tids sum {ephemeral_pct:.1f}%onecpu")
    elif P is not None and S >= 0.80 * P and ephemeral_pct < 10 and (G is None or G < 15):
        verdicts["R2"] = "FALSIFIED"
        notes.append("R2 FALSIFIED: long-lived+seen explain >=80% P; ephemeral small")
    else:
        verdicts["R2"] = "INSUFFICIENT"
        notes.append(
            f"R2 INSUFFICIENT: G={G} ephemeral_pct={ephemeral_pct:.1f} "
            "(HTTP never ruled out pre-capture)"
        )

    if B is not None:
        huge = [x for x in per if x[3] >= max(25.0, (B + 15))]
        media_like = [x for x in per if x[3] <= 20]
        if media_like and not huge and top_pct <= 20:
            verdicts["R3"] = "FALSIFIED"
            notes.append("R3 FALSIFIED: no live tid >> bucket band B")
        elif huge:
            verdicts["R3"] = "INSUFFICIENT"
            notes.append("R3 INSUFFICIENT: large tid may be media or audio without role map")
        else:
            verdicts["R3"] = "INSUFFICIENT"
    else:
        verdicts["R3"] = "INSUFFICIENT"
        notes.append("R3 INSUFFICIENT: B unknown")

    rest = sum(x[3] for x in per[1:]) if len(per) > 1 else 0.0
    if rest < 5 and top_pct >= 40:
        verdicts["R4"] = "FALSIFIED"
        notes.append("R4 FALSIFIED as residual owner: non-top sum <5")
    elif rest >= 15:
        verdicts["R4"] = "INSUFFICIENT"
        notes.append("R4 INSUFFICIENT: non-top sum >=15 needs role map")
    else:
        verdicts["R4"] = "INSUFFICIENT"

    surprise = [x for x in per if x[3] > 15]
    if len(surprise) >= 2:
        verdicts["R5"] = "FALSIFIED"
        notes.append("R5 FALSIFIED: multiple tids >15%")
    else:
        verdicts["R5"] = "CONFIRMED"
        notes.append("R5 CONFIRMED: at most one tid >15% (plurality holder)")

    if G is not None and G >= 40:
        notes.append(
            "ARTIFACT_CHECK: large G — if no short-lived tid trail mid-window, "
            "score UNKNOWN parse vs true unsampled CPU"
        )

    return Score(P, B, S, G, U, hz, du, per, verdicts, notes)


def format_report(sc: Score) -> str:
    lines = [
        "THREAD_CPU SCORE (post-audit method; R1-R5 falsifiers frozen from PREREGISTER)",
        f"P(process_percent-onecpu)={sc.P}",
        f"B(bucket_percent-onecpu)={sc.B}",
        f"S(sum_tid_percent-onecpu)={sc.S:.3f}" if sc.S == sc.S else f"S={sc.S}",
        f"G=P-S={sc.G}",
        f"U=P-B(uninstrumented_process_CPU)={sc.U}",
        f"du={sc.du} hz={sc.hz}",
        "per-tid (first->last j across window, includes ephemeral):",
    ]
    for tid, comm, dj, pct in sc.per_tid:
        lines.append(f"  tid={tid} comm={comm!r} dj={dj} percent-onecpu={pct:.2f}")
    lines.append("verdicts:")
    for k in sorted(sc.verdicts):
        lines.append(f"  {k}: {sc.verdicts[k]}")
    if sc.notes:
        lines.append("notes:")
        for n in sc.notes:
            lines.append(f"  - {n}")
    lines.append(
        f"SUMMARY: R1={sc.verdicts.get('R1')} R2={sc.verdicts.get('R2')} "
        f"P={sc.P} B={sc.B} S={sc.S if sc.S == sc.S else None} "
        f"G={sc.G} U={sc.U}"
    )
    return "\n".join(lines) + "\n"


def selftest() -> int:
    failures = 0

    def check(name: str, cond: bool, detail: str = "") -> None:
        nonlocal failures
        if cond:
            print(f"SELFTEST PASS {name}")
        else:
            failures += 1
            print(f"SELFTEST FAIL {name} {detail}")

    log_a = (
        "media: present_profile frames=300 presented=300 "
        "read_cpu_us_f=574 pacing_wait_cpu_us_f=497 overlay_cpu_us_p=1 "
        "fb_cpu_us_p=0 pixel_cpu_us_p=7 ddr_cpu_us_p=1595\n"
        "media: thread_cpu tid=1(misterplexd) j=100 tid=2(misterplexd) j=50 tid=3(misterplexd) j=20\n"
        "media: thread_cpu tid=1(misterplexd) j=6100 tid=2(misterplexd) j=850 tid=3(misterplexd) j=120\n"
    )
    sa, pa = parse_log(log_a)
    sc = score(sa, pa, process_pct=None, dm=5730, du=60.0, hz=100.0)
    print(format_report(sc))
    check("A_P_95.5", sc.P is not None and abs(sc.P - 95.5) < 0.01, str(sc.P))
    check("A_B_no_fps", sc.B is not None and sc.B < 5.0, str(sc.B))
    check("A_U_defined", sc.U is not None and sc.U > 80, str(sc.U))
    check("A_label_uninstrumented", any("uninstrumented" in n for n in sc.notes))
    check("A_no_87_hole_label", any("uninstrumented_process_CPU" in n for n in sc.notes) and any("NOT" in n and "87" in n for n in sc.notes))
    check("A_R1_confirmed", sc.verdicts["R1"] == "CONFIRMED", str(sc.verdicts))
    check("A_R2_falsified", sc.verdicts["R2"] == "FALSIFIED", str(sc.verdicts))

    log_b = (
        "media: present_profile frames=100 presented=100 "
        "read_cpu_us_f=100 pacing_wait_cpu_us_f=100 overlay_cpu_us_p=0 "
        "fb_cpu_us_p=0 pixel_cpu_us_p=0 ddr_cpu_us_p=0\n"
        "media: thread_cpu tid=1(misterplexd) j=10 tid=2(misterplexd) j=10\n"
        "media: thread_cpu tid=1(misterplexd) j=110 tid=2(misterplexd) j=110\n"
    )
    sb, pb = parse_log(log_b)
    scb = score(sb, pb, process_pct=95.5, dm=None, du=60.0)
    print(format_report(scb))
    check("B_R1_falsified", scb.verdicts["R1"] == "FALSIFIED", str(scb.verdicts))
    check("B_R2_confirmed_G", scb.verdicts["R2"] == "CONFIRMED", str(scb.verdicts))
    check("B_G_large", scb.G is not None and scb.G >= 40, str(scb.G))

    log_c = (
        "media: present_profile frames=50 presented=50 "
        "read_cpu_us_f=50 pacing_wait_cpu_us_f=50 overlay_cpu_us_p=0 "
        "fb_cpu_us_p=0 pixel_cpu_us_p=0 ddr_cpu_us_p=0\n"
        "media: thread_cpu tid=1(misterplexd) j=100 tid=9(httpw) j=1000\n"
        "media: thread_cpu tid=1(misterplexd) j=200 tid=9(httpw) j=5000\n"
        "media: thread_cpu tid=1(misterplexd) j=300\n"
    )
    scc = score(parse_log(log_c)[0], parse_log(log_c)[1], process_pct=95.5, dm=None, du=60.0)
    print(format_report(scc))
    check("C_ephemeral_counted", any(t == 9 for t, *_ in scc.per_tid), str(scc.per_tid))
    e9 = next(x[3] for x in scc.per_tid if x[0] == 9)
    check("C_ephemeral_pct", e9 > 40, str(e9))
    check("C_R2_ephemeral", scc.verdicts["R2"] == "CONFIRMED", str(scc.verdicts))

    scd = score(parse_log(log_a)[0], parse_log(log_a)[1], process_pct=120.0, dm=None, du=60.0)
    check("D_observer", any("OBSERVER" in n for n in scd.notes), str(scd.notes))

    sce = score(
        parse_log("media: thread_cpu tid=1(x) j=5\n")[0],
        [],
        process_pct=95.5,
        dm=None,
        du=60.0,
    )
    check("E_single_insufficient", sce.verdicts["R1"] == "INSUFFICIENT")

    check("F_B_not_old_eight", sc.B is not None and abs(sc.B - 8.0) > 1.0, str(sc.B))

    print(f"SELFTEST failures={failures}")
    return 1 if failures else 0


def main(argv: List[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("log", nargs="?", help="capture log path")
    ap.add_argument("--process-pct", type=float, default=None)
    ap.add_argument("--dm", type=float, default=None, help="process utime+stime jiffies delta")
    ap.add_argument("--du", type=float, default=None, help="wall seconds (same window as dm)")
    ap.add_argument("--hz", type=float, default=100.0)
    ap.add_argument(
        "--bucket-cpu-us",
        type=float,
        default=None,
        help="override sum media bucket CPU microseconds for window",
    )
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args(argv)

    if args.selftest:
        return selftest()
    if not args.log:
        ap.error("log path required unless --selftest")
    if args.du is None:
        ap.error("--du SEC required (same-window wall clock; no fps fallback)")

    text = open(args.log, encoding="utf-8", errors="replace").read()
    tid_samples, profiles = parse_log(text)
    sc = score(
        tid_samples,
        profiles,
        process_pct=args.process_pct,
        dm=args.dm,
        du=args.du,
        hz=args.hz,
        bucket_cpu_us_override=args.bucket_cpu_us,
    )
    sys.stdout.write(format_report(sc))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
