#!/usr/bin/env python3
"""Offline scorer for bounce2 PRESENT_PROFILE=1 thread_cpu capture.

Frozen against PREREGISTER_V9_THREAD.txt falsifiers — do not reinterpret after data.

Inputs (files or stdin log):
  - daemon log containing:
      media: present_profile ...
      media: thread_cpu tid=N(comm) j=J ...
  - optional metrics file or CLI for process jiffies window:
      --process-pct P   OR  --dm DJ --du SEC [--hz 100] [--nproc 2]
      (P = percent-onecpu = 100*dm/(hz*du)  monadic; if nproc formula 200*dm/dc used,
       pass --process-pct already computed by the same method as A/B)

Outputs ranked table, P, S, G, R1–R5 verdicts CONFIRMED/FALSIFIED/INSUFFICIENT.

Usage:
  score_thread_cpu.py CAPTURE.log [--process-pct 95.5]
  score_thread_cpu.py --selftest
"""
from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple

THREAD_RE = re.compile(
    r"tid=(?P<tid>\d+)\((?P<comm>[^)]*)\)\s*j=(?P<j>\d+)"
)
PROFILE_RE = re.compile(r"media:\s*present_profile\b")
THREAD_LINE_RE = re.compile(r"media:\s*thread_cpu\b")


@dataclass
class Sample:
    idx: int
    tids: Dict[int, Tuple[str, int]]  # tid -> (comm, j)


@dataclass
class Score:
    process_pct: Optional[float]
    hz: float
    du: Optional[float]
    per_tid: List[Tuple[int, str, int, float]]  # tid, comm, dj, pct
    S: float
    G: Optional[float]
    P: Optional[float]
    verdicts: Dict[str, str]
    notes: List[str] = field(default_factory=list)


def parse_log(text: str) -> List[Sample]:
    samples: List[Sample] = []
    lines = text.splitlines()
    i = 0
    sidx = 0
    while i < len(lines):
        if PROFILE_RE.search(lines[i]) or THREAD_LINE_RE.search(lines[i]):
            # prefer pair: profile then thread_cpu
            pass
        if THREAD_LINE_RE.search(lines[i]):
            tids = {}
            for m in THREAD_RE.finditer(lines[i]):
                tid = int(m.group("tid"))
                tids[tid] = (m.group("comm"), int(m.group("j")))
            if tids:
                samples.append(Sample(sidx, tids))
                sidx += 1
        i += 1
    return samples


def classify_role(comm: str, j_rank: int, n: int) -> str:
    c = comm.lower()
    # All pthread comms often remain process name on Linux ("misterplexd").
    # Role inference without /proc/comm differentiation is WEAK — use j_rank.
    return "unknown"


def score_samples(
    samples: List[Sample],
    process_pct: Optional[float],
    hz: float = 100.0,
    du: Optional[float] = None,
    observer_anchor: float = 95.5,
    observer_band: float = 10.0,
) -> Score:
    notes: List[str] = []
    if len(samples) < 2:
        notes.append("INSUFFICIENT: need ≥2 thread_cpu samples for Δj")
        return Score(process_pct, hz, du, [], 0.0, None, process_pct,
                     {f"R{i}": "INSUFFICIENT" for i in range(1, 6)}, notes)

    a, b = samples[0], samples[-1]
    # long-lived: present in both samples
    live = set(a.tids) & set(b.tids)
    per = []
    for tid in live:
        comm0, j0 = a.tids[tid]
        comm1, j1 = b.tids[tid]
        comm = comm1 or comm0
        dj = j1 - j0
        if dj < 0:
            notes.append(f"tid={tid} negative dj={dj} (wrap/reuse?)")
            dj = 0
        if du and du > 0:
            pct = 100.0 * dj / (hz * du)
        else:
            pct = float("nan")
        per.append((tid, comm, dj, pct))
    per.sort(key=lambda x: x[2], reverse=True)

    if du and du > 0 and not any(x[3] != x[3] for x in per):  # not nan
        S = sum(p for *_, p in per)
    else:
        # Without du, S only if process_pct and we can ratio by dj
        total_dj = sum(x[2] for x in per)
        if process_pct is not None and total_dj > 0:
            # Attribute process_pct proportional to dj among long-lived
            S = process_pct  # if we assume long-lived explain all — NO that's wrong
            # Better: leave S as sum of pct only when du known
            S = float("nan")
            notes.append("du unknown: cannot compute absolute percent-onecpu per tid; using dj ranks only")
        else:
            S = float("nan")

    P = process_pct
    G = (P - S) if (P is not None and S == S) else None  # S==S rejects nan

    # Rank by dj
    if not per:
        notes.append("no long-lived tids")
        verd = {f"R{i}": "INSUFFICIENT" for i in range(1, 6)}
        return Score(P, hz, du, per, S if S == S else 0.0, G, P, verd, notes)

    top_tid, top_comm, top_dj, top_pct = per[0]
    total_dj = sum(x[2] for x in per)
    # Heuristic roles when all comms are misterplexd: rank positions
    # media often highest after audio on device — we cannot know. Use:
    # R1 audio: top long-lived with pct>=40 OR (top_dj/total_dj>=0.5 and top_pct>=40)
    # Without unique comms, R1 CONFIRMED only if top_pct >= 40 and P still high.

    def pct_or_share(p: float, dj: int) -> float:
        if p == p:  # not nan
            return p
        if total_dj > 0 and P is not None:
            return P * (dj / total_dj)  # ONLY if G~0 assumption — mark
        return float("nan")

    # Prefer absolute pct when du known
    use_abs = du is not None and du > 0 and all(x[3] == x[3] for x in per)

    def tpct(entry) -> float:
        return entry[3] if use_abs else pct_or_share(entry[3], entry[2])

    if not use_abs and P is not None and total_dj > 0:
        notes.append(
            "WARN: absolute percent-onecpu inferred by dj share * P only if G small; "
            "verdicts using share are weaker"
        )
        # Recompute display pct as share*P for table
        per = [(t, c, dj, (P * dj / total_dj if total_dj else 0.0)) for t, c, dj, _ in per]
        S = sum(x[3] for x in per)  # equals P by construction — G=0 artifact!
        notes.append(
            "CRITICAL: without --du, S is forced to P via share (G=0 by construction). "
            "Pass --du/--process-pct with measured window for real G."
        )
        G = 0.0 if P is not None else None

    top_pct = per[0][3]
    # Second etc.
    sum_long = sum(x[3] for x in per)

    # Observer effect
    if P is not None and abs(P - observer_anchor) > observer_band:
        notes.append(
            f"OBSERVER?: P={P:.1f} outside anchor {observer_anchor}±{observer_band}"
        )

    # Dead-thread gap needs process dm vs sum live dj — if P and use_abs:
    if use_abs and P is not None:
        G = P - sum_long
        S = sum_long

    verdicts = {}

    # R1 AUDIO — plurality of residual; falsify if top <15 while P>=90
    # Without comm labels we cannot know audio for sure — CONFIRMED only if
    # top_pct >= 40 and (P is None or P >= 50). Label INSUFFICIENT_ROLE if no
    # audio-specific tag; still apply numeric falsifiers on TOP tid as proxy
    # for "plurality holder".
    residual = (P - 8.0) if P is not None else None  # ~8 is media PROFILE
    if P is not None and P >= 90 and top_pct < 15:
        verdicts["R1"] = "FALSIFIED"  # audio-as-plurality dead: nothing big on live tids
        notes.append("R1 FALSIFIED: P>=90 but top live tid <15% (not audio-sized)")
    elif top_pct >= 40:
        verdicts["R1"] = "CONFIRMED"  # plurality holder is large; role=audio is hypothesis
        notes.append(
            "R1 CONFIRMED numerically (top live tid >=40percent-onecpu). "
            "Role=audio still needs tid identity (comm or capture map)."
        )
    elif top_pct != top_pct:
        verdicts["R1"] = "INSUFFICIENT"
    else:
        verdicts["R1"] = "INSUFFICIENT"
        notes.append(f"R1 INSUFFICIENT: top_pct={top_pct:.1f} not >=40 and not falsified")

    # R2 EPHEM HTTP — large G with room for dead threads
    if G is not None and use_abs:
        if G >= 40:
            verdicts["R2"] = "CONFIRMED"
            notes.append(f"R2 CONFIRMED: G={G:.1f} >=40 (dead/unseen tids hold residual)")
        elif sum_long >= 0.80 * (P or 0) and P and P >= 50:
            verdicts["R2"] = "FALSIFIED"
            notes.append("R2 FALSIFIED: long-lived explain >=80% of P")
        else:
            verdicts["R2"] = "INSUFFICIENT"
    else:
        verdicts["R2"] = "INSUFFICIENT"
        notes.append("R2 INSUFFICIENT: need absolute P and du for G")

    # R3 MEDIA unbucketed — thr_ >> 8+15. Without id, if top is only ~8-12 FALSIFIED for "secret media"
    if use_abs:
        # any tid in 8-12 band matching profile = media accounted
        media_like = [x for x in per if 5.0 <= x[3] <= 15.0]
        huge = [x for x in per if x[3] >= 25.0]
        if media_like and not any(x[3] >= 23 for x in per):
            # media-sized tid exists and nothing is "unbucketed huge" on same scale
            if top_pct <= 15:
                verdicts["R3"] = "FALSIFIED"
                notes.append("R3 FALSIFIED: no live tid >> PROFILE media band")
            else:
                verdicts["R3"] = "INSUFFICIENT"
        elif any(x[3] >= 23 for x in per) and top_pct >= 23:
            # could be media unbucketed OR audio — cannot separate without role
            verdicts["R3"] = "INSUFFICIENT"
            notes.append("R3 INSUFFICIENT: large tid could be media or audio without role map")
        else:
            verdicts["R3"] = "INSUFFICIENT"
    else:
        verdicts["R3"] = "INSUFFICIENT"

    # R4 SPI/OSD/input — small expected; FALSIFIED if those are small — we lack tags
    # CONFIRMED only if a non-top small set is still >15? Skip: if all non-top <5 and top is big, R4 FALSIFIED as residual owner
    if use_abs and len(per) >= 1:
        rest = sum(x[3] for x in per[1:])
        if rest < 5 and top_pct >= 40:
            verdicts["R4"] = "FALSIFIED"
            notes.append("R4 FALSIFIED as residual owner: non-top live sum <5")
        elif rest >= 15:
            verdicts["R4"] = "INSUFFICIENT"
            notes.append("R4 INSUFFICIENT: non-top live sum >=15 needs role map")
        else:
            verdicts["R4"] = "INSUFFICIENT"
    else:
        verdicts["R4"] = "INSUFFICIENT"

    # R5 main/gdm/tl negligible — FALSIFIED surprise if any single >15 that's not top audio/media
    if use_abs:
        surprise = [x for x in per if x[3] > 15]
        if len(surprise) == 0:
            verdicts["R5"] = "FALSIFIED"  # as "unexpected large" — actually expected small = the claim "they are small" is confirmed
            # Clarify: R5 claim was they are <5. Falsifier was any >15.
            # If none >15 among what we'd call main/gdm — without tags, if only one large tid, R5 claim OK
            verdicts["R5"] = "CONFIRMED"  # claim: negligible — no multi large surprise
            notes.append("R5 CONFIRMED as negligible class: not multiple >15% tids (or only plurality holder large)")
        elif len(surprise) >= 2:
            verdicts["R5"] = "FALSIFIED"
            notes.append("R5 FALSIFIED: multiple tids >15% (unexpected control-plane load)")
        else:
            verdicts["R5"] = "CONFIRMED"
    else:
        verdicts["R5"] = "INSUFFICIENT"

    # Large G no trail marker
    if G is not None and G >= 40 and use_abs:
        notes.append(
            "ARTIFACT_CHECK: G large — if capture has no short-lived tid trail across "
            "mid snapshots, score UNKNOWN parse vs dead workers (see prereg B5-A/B)"
        )

    return Score(P, hz, du, per, S if S == S else 0.0, G, P, verdicts, notes)


def format_report(sc: Score) -> str:
    lines = []
    lines.append("THREAD_CPU SCORE (frozen falsifiers from PREREGISTER_V9_THREAD.txt)")
    lines.append(f"P(process_percent-onecpu)={sc.P}")
    lines.append(f"S(sum_long_lived_percent-onecpu)={sc.S:.3f}" if sc.S == sc.S else f"S={sc.S}")
    lines.append(f"G=P-S={sc.G}")
    lines.append(f"du={sc.du} hz={sc.hz}")
    lines.append("per-tid (long-lived Δj):")
    for tid, comm, dj, pct in sc.per_tid:
        lines.append(f"  tid={tid} comm={comm!r} dj={dj} percent-onecpu={pct:.2f}")
    lines.append("verdicts:")
    for k in sorted(sc.verdicts):
        lines.append(f"  {k}: {sc.verdicts[k]}")
    if sc.notes:
        lines.append("notes:")
        for n in sc.notes:
            lines.append(f"  - {n}")
    # one-line summary
    r1 = sc.verdicts.get("R1", "?")
    r2 = sc.verdicts.get("R2", "?")
    lines.append(f"SUMMARY: R1={r1} R2={r2} G={sc.G} P={sc.P}")
    return "\n".join(lines) + "\n"


def selftest() -> int:
    failures = 0

    def check(name: str, cond: bool, detail: str = ""):
        nonlocal failures
        if cond:
            print(f"SELFTEST PASS {name}")
        else:
            failures += 1
            print(f"SELFTEST FAIL {name} {detail}")

    # Case A: audio-sized top tid, G small
    log_a = """
media: present_profile frames=300
media: thread_cpu tid=1(misterplexd) j=100 tid=2(misterplexd) j=10 tid=3(misterplexd) j=5
media: present_profile frames=300
media: thread_cpu tid=1(misterplexd) j=100+6000 wait
"""
    # fix log_a properly
    log_a = (
        "media: present_profile frames=300\n"
        "media: thread_cpu tid=1(misterplexd) j=100 tid=2(misterplexd) j=50 tid=3(misterplexd) j=20\n"
        "media: present_profile frames=300\n"
        "media: thread_cpu tid=1(misterplexd) j=6100 tid=2(misterplexd) j=850 tid=3(misterplexd) j=120\n"
    )
    # du=60s hz=100 → dj 6000 = 100percent-onecpu on tid1; dj800=13.3%; dj100=1.67%; S≈115? 
    # 6000/(100*60)=1.0 → 100%; 800/6000 wait 850-50=800 → 13.33%; 100→1.67%; S=115
    sa = parse_log(log_a)
    sc = score_samples(sa, process_pct=95.5, hz=100.0, du=60.0)
    print(format_report(sc))
    check("A_R1_confirmed_large_top", sc.verdicts["R1"] == "CONFIRMED", str(sc.verdicts))
    check("A_R2_falsified_longlived", sc.verdicts["R2"] == "FALSIFIED", str(sc.verdicts))

    # Case B: large G — long-lived small, process high
    log_b = (
        "media: thread_cpu tid=1(misterplexd) j=10 tid=2(misterplexd) j=10\n"
        "media: thread_cpu tid=1(misterplexd) j=110 tid=2(misterplexd) j=110\n"
    )
    # dj=100 each over 60s → 1.67% each S=3.3 G=92
    scb = score_samples(parse_log(log_b), process_pct=95.5, hz=100.0, du=60.0)
    print(format_report(scb))
    check("B_R1_falsified", scb.verdicts["R1"] == "FALSIFIED", str(scb.verdicts))
    check("B_R2_confirmed_G", scb.verdicts["R2"] == "CONFIRMED", str(scb.verdicts))
    check("B_G_large", scb.G is not None and scb.G >= 40, str(scb.G))

    # Case C: observer effect note
    scc = score_samples(parse_log(log_a), process_pct=120.0, hz=100.0, du=60.0)
    check("C_observer_note", any("OBSERVER" in n for n in scc.notes), str(scc.notes))

    # Case D: single sample insufficient
    scd = score_samples(parse_log("media: thread_cpu tid=1(x) j=5\n"), process_pct=95.5, du=60.0)
    check("D_insufficient", scd.verdicts["R1"] == "INSUFFICIENT")

    # Case E: G large note about trail
    check("E_artifact_note", any("ARTIFACT_CHECK" in n for n in scb.notes), str(scb.notes))

    print(f"SELFTEST failures={failures}")
    return 1 if failures else 0


def main(argv: List[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("log", nargs="?", help="capture log path")
    ap.add_argument("--process-pct", type=float, default=None, help="P percent onecpu same method as A/B")
    ap.add_argument("--dm", type=float, default=None, help="process jiffies delta")
    ap.add_argument("--du", type=float, default=None, help="wall seconds of window")
    ap.add_argument("--hz", type=float, default=100.0)
    ap.add_argument("--nproc", type=float, default=2.0, help="unused unless --dc given")
    ap.add_argument("--dc", type=float, default=None, help="cpu_all delta; P=100*nproc*dm/dc")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args(argv)

    if args.selftest:
        return selftest()

    if not args.log:
        ap.error("log path required unless --selftest")

    text = open(args.log, encoding="utf-8", errors="replace").read()
    samples = parse_log(text)

    P = args.process_pct
    if P is None and args.dm is not None and args.dc is not None:
        P = 100.0 * args.nproc * args.dm / args.dc
    elif P is None and args.dm is not None and args.du is not None:
        P = 100.0 * args.dm / (args.hz * args.du)

    sc = score_samples(samples, process_pct=P, hz=args.hz, du=args.du)
    sys.stdout.write(format_report(sc))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
