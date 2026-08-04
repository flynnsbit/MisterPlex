#!/usr/bin/env python3
"""fc78adc6 intent: sticky pending_ready must not false-ready on first swap cycle.

Bug class (post 6472789d schedule register, pre fc78adc6):
  - always @* defaults pending_ready_c = 1 when !swap_pending_d2 (prep not gated).
  - posedge samples pending_ready_r <= pending_ready_c, so ready_r stays 1 for one
    clk_ddr after swap_pending rises while prep lines are incomplete.
  - Sticky equation that ORs lagged pending_ready_r then asserts pending_ready_ddr
    for that one cycle → CDC can arm vsync swap with empty prep linebufs
    (silicon cceb58e7 underrun FFFF / black glass class).

Fix (fc78adc6):
  - Sticky pending_ready_ddr uses combo pending_ready_c (drops same cycle as prep miss).
  - need_*/target_* may remain registered for STA; sticky ready alone is combo-safe.

This unit is fit-free:
  A) Pure cycle model of the lag hazard (behavioral positive/negative).
  B) Static source gate on ddr_frame_store.sv sticky assign shape.

POSITIVE:
  - model: first swap_pending cycle + prep incomplete → sticky_c == 0
  - model: same cycle sticky_r (lagged) == 1 (documents the hazard)
  - RTL sticky block under PENDING_READY_STICKY_PREP uses pending_ready_c
  - RTL sticky block does not use pending_ready_r in code (comments ok)
  - combo still only clears pending_ready_c under swap_pending_d2

NEGATIVE:
  - sticky assign rewritten to pending_ready_r must fail the static check
  - model: claiming sticky_r is safe on first incomplete cycle must fail
"""
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
STORE = Path(
    os.environ.get(
        "DDR_FRAME_STORE",
        ROOT / "fpga" / "Plex_MiSTer" / "rtl" / "ddr_frame_store.sv",
    )
)


def fail(msg: str) -> int:
    print(f"FAIL sticky_pending_ready_same_cycle: {msg}", file=sys.stderr)
    return 1


def strip_sv_comments(line: str) -> str:
    return line.split("//", 1)[0]


def extract_s_idle_body(src: str) -> str | None:
    m = re.search(
        r"S_IDLE\s*:\s*begin(.*?)(?=\n\s*(?:S_[A-Z0-9_]+|default)\s*:)",
        src,
        flags=re.S,
    )
    return m.group(1) if m else None


def extract_sticky_assign(s_idle: str) -> str | None:
    """Code-only body of if (PENDING_READY_STICKY_PREP) begin ... end (before else)."""
    m = re.search(
        r"if\s*\(\s*PENDING_READY_STICKY_PREP\s*\)\s*begin(.*?)end\s*else",
        s_idle,
        flags=re.S,
    )
    if not m:
        return None
    code_lines = [strip_sv_comments(ln) for ln in m.group(1).splitlines()]
    return "\n".join(code_lines)


# ---------------------------------------------------------------------------
# A) Behavioral model — no Verilator / no fit
# ---------------------------------------------------------------------------

def model_combo_ready(swap_pending: bool, prep_complete: bool) -> bool:
    """Mirror ddr_frame_store always @* prep ready (simplified).

    RTL: pending_ready_c defaults 1; only when swap_pending_d2 && missing prep
    line does it drop. When !swap_pending, ready_c stays 1 even if prep empty.
    """
    if not swap_pending:
        return True
    return prep_complete


def run_lag_hazard_model() -> list[str]:
    """Simulate one-cycle lag of pending_ready_r vs combo pending_ready_c."""
    errs: list[str] = []

    # Cycle history: (swap_pending, prep_complete)
    # Before publish: swap=0 → combo ready always 1 even with empty prep.
    # First cycle after swap rises: prep still incomplete.
    sequence = [
        # (swap, prep_complete)
        (False, False),  # idle, empty prep set
        (False, False),
        (True, False),  # first swap_pending cycle — hazard window
        (True, False),
        (True, True),  # prep finished
    ]

    ready_r = True  # matches RTL reset/default tendency of pending_ready_r <= 1
    saw_first_swap = False

    for cycle, (swap, prep_ok) in enumerate(sequence):
        ready_c = model_combo_ready(swap, prep_ok)
        # Sticky equations evaluated with *current* ready_r (pre-update sample)
        sticky_c = swap and ready_c
        sticky_r = swap and ready_r  # pre-fc78adc6 lag form

        if swap and not prep_ok and not saw_first_swap:
            saw_first_swap = True
            # fc78adc6 positive: combo sticky must not pulse true.
            if sticky_c:
                errs.append(
                    f"model cycle {cycle}: sticky_c pulsed true on first "
                    f"swap_pending while prep incomplete (ready_c={ready_c})"
                )
            # Document the hazard: lagged sticky WOULD pulse true.
            if not sticky_r:
                errs.append(
                    f"model cycle {cycle}: expected sticky_r lag hazard "
                    f"(ready_r still 1) but sticky_r={sticky_r}"
                )
            if sticky_r and not sticky_c:
                # Expected hazard shape — good.
                pass

        if swap and prep_ok:
            if not sticky_c:
                errs.append(
                    f"model cycle {cycle}: sticky_c should be true when prep complete"
                )

        # Register sample for next cycle (posedge).
        ready_r = ready_c

    if not saw_first_swap:
        errs.append("model never entered first swap_pending incomplete cycle")

    # Negative twin: claiming lagged sticky is safe must fail a checker.
    # At first incomplete swap, sticky_r is the false-ready pulse.
    ready_r = True
    swap, prep_ok = True, False
    ready_c = model_combo_ready(swap, prep_ok)
    sticky_r = swap and ready_r
    if not sticky_r:
        errs.append("negative twin setup broken: sticky_r should be the false-ready")
    # A "safe?" predicate that accepts sticky_r would be wrong:
    false_claim_safe = not sticky_r  # correct safety is NOT sticky on incomplete
    if false_claim_safe:
        errs.append("negative twin: lagged ready incorrectly scored safe")

    return errs


# ---------------------------------------------------------------------------
# B) Static RTL gate
# ---------------------------------------------------------------------------

def check_sticky_uses_combo(sticky_code: str) -> list[str]:
    errs: list[str] = []
    # Collapse whitespace for equation shape checks.
    flat = re.sub(r"\s+", " ", sticky_code)

    if "pending_ready_ddr" not in flat:
        errs.append("sticky block missing pending_ready_ddr assign")
        return errs

    if not re.search(r"\bpending_ready_c\b", sticky_code):
        errs.append(
            "sticky pending_ready_ddr must use combo pending_ready_c "
            "(fc78adc6 same-cycle drop when prep incomplete)"
        )

    # Lagged register must not drive sticky ready (the cceb58e7 false-ready).
    if re.search(r"\bpending_ready_r\b", sticky_code):
        errs.append(
            "sticky pending_ready_ddr still references pending_ready_r "
            "(one-cycle lag false-ready; use pending_ready_c)"
        )

    if not re.search(r"\bswap_pending_d2\b", sticky_code):
        errs.append("sticky assign must gate on swap_pending_d2")

    # Product sticky form: ready stays high via sched_pending_ready OR combo ready.
    if "sched_pending_ready" not in sticky_code:
        errs.append(
            "sticky assign missing sched_pending_ready term "
            "(product sticky holds ready across current-window refill)"
        )

    return errs


def check_combo_clears_only_under_swap(src: str) -> list[str]:
    """pending_ready_c = 0 must sit under swap_pending_d2 (lag model premise)."""
    errs: list[str] = []
    # Find blocking clear sites.
    clears = list(
        re.finditer(r"pending_ready_c\s*=\s*1'b0", src)
    )
    if not clears:
        errs.append("no pending_ready_c = 1'b0 clear sites in store")
        return errs

    for m in clears:
        # Look back a short window for swap_pending_d2 guard.
        window = src[max(0, m.start() - 200) : m.start()]
        window_code = "\n".join(strip_sv_comments(ln) for ln in window.splitlines())
        if "swap_pending_d2" not in window_code:
            errs.append(
                "pending_ready_c clear not near swap_pending_d2 "
                f"(near offset {m.start()})"
            )
    # Default must be 1 (so idle samples ready_r=1).
    if not re.search(r"pending_ready_c\s*=\s*1'b1", src):
        errs.append("pending_ready_c default 1'b1 missing (idle lag seed)")
    return errs


def negative_sticky_r_must_fail(sticky_code: str) -> list[str]:
    poisoned = sticky_code.replace("pending_ready_c", "pending_ready_r")
    if poisoned == sticky_code:
        return ["negative twin: could not rewrite pending_ready_c → pending_ready_r"]
    errs = check_sticky_uses_combo(poisoned)
    if not any("pending_ready_r" in e for e in errs):
        return [
            "negative twin: sticky check failed to reject pending_ready_r "
            f"(errs={errs})"
        ]
    return []


def main() -> int:
    if not STORE.is_file():
        return fail(f"missing {STORE}")

    errs: list[str] = []
    errs.extend(run_lag_hazard_model())

    src = STORE.read_text(encoding="utf-8", errors="replace")
    s_idle = extract_s_idle_body(src)
    if s_idle is None:
        return fail("could not extract S_IDLE body from ddr_frame_store.sv")

    sticky = extract_sticky_assign(s_idle)
    if sticky is None:
        return fail("could not extract PENDING_READY_STICKY_PREP assign in S_IDLE")

    sticky_errs = check_sticky_uses_combo(sticky)
    errs.extend(sticky_errs)
    errs.extend(check_combo_clears_only_under_swap(src))
    # Negative twin only when sticky path is green; pre-fc78 already RED above.
    if not sticky_errs:
        errs.extend(negative_sticky_r_must_fail(sticky))

    # Product default must keep sticky on.
    if not re.search(
        r"parameter\s+bit\s+PENDING_READY_STICKY_PREP\s*=\s*1'b1", src
    ):
        errs.append("PENDING_READY_STICKY_PREP default must be 1'b1 (product)")

    if errs:
        for e in errs:
            print(f"FAIL sticky_pending_ready_same_cycle: {e}", file=sys.stderr)
        return 1

    print("PASS sticky_pending_ready_same_cycle:")
    print("  model: first swap_pending + prep incomplete → sticky_c=0 (fc78adc6)")
    print("  model: same cycle sticky_r=1 documents one-clk lag hazard")
    print("  RTL sticky uses pending_ready_c, not pending_ready_r")
    print("  combo clears pending_ready_c only under swap_pending_d2")
    print("  negative: sticky pending_ready_r is RED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
