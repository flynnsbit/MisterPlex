#!/usr/bin/env python3
"""Static gate: clk_ddr schedule pipeline must register need/target/ready.

Land 6472789d: sample need_*_c / target_*_c / pending_ready_c on posedge
clk_ddr into *_r, and drive S_IDLE *refill* decisions from need_*/target_*_r.

fc78adc6: sticky pending_ready_ddr may use combo pending_ready_c (same-cycle
false when prep incomplete) while need_*/target_* stay registered for STA.

POSITIVE:
  - combo always @* still computes need_*_c / target_*_c / pending_ready_c
  - always @(posedge clk_ddr) samples *_r <= *_c for the schedule outputs
  - S_IDLE refill path uses need_*/target_*_r (not combo need_*/target_*_c)
  - pending_ready_c allowed in sticky ready only (not a DDRAM enable cone root)

NEGATIVE:
  - Injecting need_y_cur_c into the S_IDLE decision path must fail the gate
    (would re-open the desired_y_r → DDRAM/mbox STA cone).
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
STORE = ROOT / "fpga" / "Plex_MiSTer" / "rtl" / "ddr_frame_store.sv"

# Combo schedule outputs that must remain for TB probes / sample inputs.
COMBO_NAMES = (
    "need_y_cur_c",
    "need_c_cur_c",
    "need_y_prep_c",
    "need_c_prep_c",
    "pending_ready_c",
    "target_y_cur_c",
    "target_y_prep_c",
    "target_c_cur_c",
    "target_c_prep_c",
    "target_y_idx_cur_c",
    "target_y_idx_prep_c",
    "target_c_idx_cur_c",
    "target_c_idx_prep_c",
)

REG_NAMES = tuple(n[:-2] + "_r" for n in COMBO_NAMES)

# Identifiers that must not appear as *code* (comments ok) inside S_IDLE body.
# pending_ready_c is allowed for sticky prep ready (fc78adc6); need/target combo
# must not re-enter S_IDLE enable/data decisions.
COMBO_DECISION_RE = re.compile(
    r"\b(?:"
    r"need_[yc]_(?:cur|prep)_c|"
    r"target_[yc](?:_idx)?_(?:cur|prep)_c"
    r")\b"
)


def fail(msg: str) -> int:
    print(f"FAIL ddr_schedule_pipeline_static: {msg}", file=sys.stderr)
    return 1


def strip_sv_comments(line: str) -> str:
    # Line comments only (//); sufficient for this gate.
    return line.split("//", 1)[0]


def extract_s_idle_body(src: str) -> str | None:
    m = re.search(
        r"S_IDLE\s*:\s*begin(.*?)(?=\n\s*(?:S_[A-Z0-9_]+|default)\s*:)",
        src,
        flags=re.S,
    )
    return m.group(1) if m else None


def code_refs(body: str, pattern: re.Pattern[str]) -> list[tuple[int, str, str]]:
    hits: list[tuple[int, str, str]] = []
    for i, line in enumerate(body.splitlines(), 1):
        code = strip_sv_comments(line)
        for m in pattern.finditer(code):
            hits.append((i, m.group(0), line.strip()[:100]))
    return hits


def _line_no(src: str, pos: int) -> int:
    return src.count("\n", 0, pos) + 1


def _always_star_windows(src: str) -> list[tuple[int, str]]:
    """Return (start_pos, text) for each always @* up to the next always/endmodule."""
    starts = [m.start() for m in re.finditer(r"always\s+@\*", src)]
    ends = starts[1:] + [len(src)]
    # Also clamp at endmodule if present in window.
    out: list[tuple[int, str]] = []
    for start, end in zip(starts, ends):
        chunk = src[start:end]
        em = re.search(r"\n\s*endmodule\b", chunk)
        if em:
            chunk = chunk[: em.start()]
        # Next always @(posedge...) also ends a pure @* window when ends[] was only @*.
        nxt = re.search(r"\n\s*always\s+@", chunk[1:])
        if nxt:
            chunk = chunk[: nxt.start() + 1]
        out.append((start, chunk))
    return out


def check_combo_block(src: str) -> list[str]:
    """Combo schedule must still be computed with blocking assigns (TB probes).

    Nested for/end inside always @* makes non-greedy ``end`` extraction fragile,
    so require: (1) an always @* window that drives need_y_cur_c + pending_ready_c,
    (2) blocking ``name =`` assigns for every combo schedule output.
    """
    errs: list[str] = []
    windows = _always_star_windows(src)
    if not windows:
        return ["no always @* in ddr_frame_store.sv"]

    combo = next(
        (
            (pos, win)
            for pos, win in windows
            if "need_y_cur_c" in win and "pending_ready_c" in win
        ),
        None,
    )
    if combo is None:
        return ["always @* does not compute need_y_cur_c / pending_ready_c"]

    combo_always_pos, window = combo
    for name in COMBO_NAMES:
        blocking = False
        for line in window.splitlines():
            code = strip_sv_comments(line)
            if re.search(rf"\b{name}\s*<=", code):
                continue
            if re.search(rf"\b{name}\s*=", code):
                blocking = True
                break
        if not blocking:
            errs.append(
                f"combo always @* (line {_line_no(src, combo_always_pos)}) "
                f"missing blocking assignment to {name}"
            )
    return errs


def check_sample_block(src: str) -> list[str]:
    errs: list[str] = []
    # Registered sample: always @(posedge clk_ddr) with need_y_cur_r <= need_y_cur_c
    # Search whole file for non-blocking sample pairs (robust to nested ends).
    for cname, rname in zip(COMBO_NAMES, REG_NAMES):
        if not re.search(rf"\b{rname}\s*<=\s*{cname}\b", src):
            errs.append(f"posedge sample missing {rname} <= {cname}")

    # Must live under always @(posedge clk_ddr), not combo.
    m = re.search(
        r"always\s+@\s*\(\s*posedge\s+clk_ddr\s*\)\s*begin",
        src,
    )
    if not m:
        errs.append("missing always @(posedge clk_ddr)")
    else:
        # Confirm a sample pair sits after some posedge clk_ddr always.
        sample_ok = False
        for m in re.finditer(r"always\s+@\s*\(\s*posedge\s+clk_ddr\s*\)\s*begin", src):
            window = src[m.start() : m.start() + 4000]
            if re.search(r"\bneed_y_cur_r\s*<=\s*need_y_cur_c\b", window):
                sample_ok = True
                break
        if not sample_ok:
            errs.append(
                "need_y_cur_r <= need_y_cur_c not found inside always @(posedge clk_ddr)"
            )
    return errs


def check_s_idle_decisions(body: str) -> list[str]:
    errs: list[str] = []
    bad = code_refs(body, COMBO_DECISION_RE)
    for lineno, name, snippet in bad:
        errs.append(f"S_IDLE code uses combo {name} at body-line {lineno}: {snippet}")

    # Required registered decision sites (at least one of each family).
    # H-R1d: prep arm may use sel_y_prep_r / sel_c_prep_r (frozen with need_*_r)
    # instead of live (swap_pending_d2 && need_*_prep_r).
    required_r = (
        "pending_ready_r",
        "need_y_cur_r",
        "need_c_cur_r",
        "target_y_cur_r",
        "target_y_prep_r",
        "target_c_cur_r",
        "target_c_prep_r",
    )
    for name in required_r:
        if not re.search(rf"\b{name}\b", body):
            errs.append(f"S_IDLE body missing registered decision signal {name}")
    if not (
        re.search(r"\bneed_y_prep_r\b", body) or re.search(r"\bsel_y_prep_r\b", body)
    ):
        errs.append(
            "S_IDLE body missing prep-Y decision (need_y_prep_r or sel_y_prep_r)"
        )
    if not (
        re.search(r"\bneed_c_prep_r\b", body) or re.search(r"\bsel_c_prep_r\b", body)
    ):
        errs.append(
            "S_IDLE body missing prep-C decision (need_c_prep_r or sel_c_prep_r)"
        )
    return errs


def negative_combo_in_s_idle_must_fail(src: str) -> list[str]:
    """Inject combo into S_IDLE decision; check_s_idle must go red."""
    body = extract_s_idle_body(src)
    if body is None:
        return ["negative twin: no S_IDLE body"]
    poisoned = body.replace("need_y_cur_r", "need_y_cur_c", 1)
    if poisoned == body:
        return ["negative twin: could not poison need_y_cur_r"]
    errs = check_s_idle_decisions(poisoned)
    if not any("need_y_cur_c" in e for e in errs):
        return [
            "negative twin: S_IDLE check failed to catch need_y_cur_c decision use "
            f"(errs={errs})"
        ]
    return []


def main() -> int:
    if not STORE.is_file():
        return fail(f"missing {STORE}")
    src = STORE.read_text(encoding="utf-8", errors="replace")

    body = extract_s_idle_body(src)
    if body is None:
        return fail("could not extract S_IDLE case body from ddr_frame_store.sv")

    errs: list[str] = []
    errs.extend(check_combo_block(src))
    errs.extend(check_sample_block(src))
    errs.extend(check_s_idle_decisions(body))
    errs.extend(negative_combo_in_s_idle_must_fail(src))

    if errs:
        for e in errs:
            print(f"FAIL ddr_schedule_pipeline_static: {e}", file=sys.stderr)
        return 1

    print("PASS ddr_schedule_pipeline_static:")
    print("  combo always @* still drives need_*/target_*/pending_ready_c (TB probes)")
    print("  always @(posedge clk_ddr) samples *_r <= *_c")
    print("  S_IDLE decisions use only *_r (no combo *_c in code)")
    print("  negative: need_y_cur_c in S_IDLE is RED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
