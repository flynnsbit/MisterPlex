#!/usr/bin/env python3
"""Static gate: PIPELINE_REFILL_SCHEDULER must consume an atomic schedule record.

H-R1d class (w-mem SCHED_RECORD_ATOMIC):
  After 6472789d, need_*/target_*_r are registered from combo that baked
  cur/prep bases on the sample cycle. S_IDLE must not re-issue fill_* from a
  *second* live (swap_pending_d2 && need_*_r) mux when sched_valid is true —
  issue must read the recorded sched_bank / sched_idx / sched_y|sched_cy.

This unit freezes the consume contract of the pipelined schedule record
(fit-free). It does not claim the full product land of sel_prep_r capture;
that is a separate RTL change under FIT_GO.

POSITIVE:
  - S_IDLE has a PIPELINE_REFILL_SCHEDULER && sched_valid consume arm
  - fill_bank / fill_idx / fill_y|fill_cy come from sched_* in that arm
  - consume arm has no live prep/cur mux on fill_bank/fill_idx/fill_y
  - (optional) each sched_valid latch co-assigns bank+idx+line from one select

NEGATIVE:
  - rewriting fill_bank <= sched_bank to a live prep/cur mux must go RED
  - dropping fill_idx <= sched_idx must go RED
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

# Live prep/cur select that must not drive fill_* on the sched_valid consume path.
LIVE_PREP_MUX_RE = re.compile(
    r"\bswap_pending_d2\s*&&\s*need_[yc]_prep_[rc]\b"
)
# fill_* must not re-derive from pending/disp bank or target_* on consume.
FILL_LIVE_BANK_RE = re.compile(
    r"\bfill_bank\s*<=\s*.*\b(?:pending_bank_d2|disp_bank_d2)\b"
)
FILL_LIVE_IDX_RE = re.compile(
    r"\bfill_idx\s*<=\s*.*\btarget_[yc]_idx_(?:prep|cur)_[rc]\b"
)
FILL_LIVE_Y_RE = re.compile(
    r"\bfill_y\s*<=\s*.*\btarget_y_(?:prep|cur)_[rc]\b"
)
FILL_LIVE_CY_RE = re.compile(
    r"\bfill_cy\s*<=\s*.*\btarget_c_(?:prep|cur)_[rc]\b"
)


def fail(msg: str) -> int:
    print(f"FAIL ddr_schedule_atomic_record: {msg}", file=sys.stderr)
    return 1


def strip_sv_comments(line: str) -> str:
    return line.split("//", 1)[0]


def code_only(text: str) -> str:
    return "\n".join(strip_sv_comments(ln) for ln in text.splitlines())


def extract_s_idle_body(src: str) -> str | None:
    m = re.search(
        r"S_IDLE\s*:\s*begin(.*?)(?=\n\s*(?:S_[A-Z0-9_]+|default)\s*:)",
        src,
        flags=re.S,
    )
    return m.group(1) if m else None


def extract_balanced_begin(src: str, begin_pos: int) -> str | None:
    """Given index of 'begin' keyword, return body inside matching begin/end."""
    # begin_pos points at 'b' of begin
    i = begin_pos + len("begin")
    depth = 1
    while i < len(src):
        # Skip line comments
        if src.startswith("//", i):
            nl = src.find("\n", i)
            i = len(src) if nl < 0 else nl + 1
            continue
        # Keyword-ish tokens
        m = re.match(r"\b(begin|end)\b", src[i:])
        if m:
            tok = m.group(1)
            if tok == "begin":
                depth += 1
            else:
                depth -= 1
                if depth == 0:
                    return src[begin_pos + len("begin") : i]
            i += len(tok)
            continue
        i += 1
    return None


def extract_sched_valid_consume(s_idle: str) -> str | None:
    """Body of: else if (PIPELINE_REFILL_SCHEDULER && sched_valid) begin ... end"""
    m = re.search(
        r"(?:else\s+)?if\s*\(\s*PIPELINE_REFILL_SCHEDULER\s*&&\s*sched_valid\s*\)\s*begin",
        s_idle,
    )
    if not m:
        return None
    # Find the 'begin' that ends the match
    begin_kw = s_idle.rfind("begin", m.start(), m.end())
    if begin_kw < 0:
        return None
    return extract_balanced_begin(s_idle, begin_kw)


def extract_pipeline_latch_blocks(s_idle: str) -> list[str]:
    """Bodies of if (PIPELINE_REFILL_SCHEDULER) begin ... end that set sched_valid <= 1."""
    blocks: list[str] = []
    for m in re.finditer(
        r"if\s*\(\s*PIPELINE_REFILL_SCHEDULER\s*\)\s*begin",
        s_idle,
    ):
        begin_kw = s_idle.rfind("begin", m.start(), m.end())
        body = extract_balanced_begin(s_idle, begin_kw)
        if body is None:
            continue
        code = code_only(body)
        # Consume arm clears sched_valid; latch arms set it. Skip consume-shaped.
        if re.search(r"\bsched_valid\s*<=\s*1'b1\b", code):
            blocks.append(body)
    return blocks


def check_consume_from_record(consume: str) -> list[str]:
    errs: list[str] = []
    code = code_only(consume)

    required = (
        (r"\bfill_bank\s*<=\s*sched_bank\b", "fill_bank <= sched_bank"),
        (r"\bfill_idx\s*<=\s*sched_idx\b", "fill_idx <= sched_idx"),
        (r"\bfill_y\s*<=\s*sched_y\b", "fill_y <= sched_y"),
        (r"\bfill_cy\s*<=\s*sched_cy\b", "fill_cy <= sched_cy"),
        (r"\bsched_valid\s*<=\s*1'b0\b", "sched_valid <= 1'b0 (consume)"),
    )
    for pat, label in required:
        if not re.search(pat, code):
            errs.append(f"consume arm missing {label}")

    # Must not re-mux fill_* from live prep/cur when consuming the record.
    if LIVE_PREP_MUX_RE.search(code):
        errs.append(
            "consume arm still has live (swap_pending_d2 && need_*_prep_*) "
            "— fill must come from sched_* record only"
        )
    if FILL_LIVE_BANK_RE.search(code):
        errs.append("consume arm fill_bank re-derives from pending/disp bank")
    if FILL_LIVE_IDX_RE.search(code):
        errs.append("consume arm fill_idx re-derives from target_*_idx")
    if FILL_LIVE_Y_RE.search(code):
        errs.append("consume arm fill_y re-derives from target_y_*")
    if FILL_LIVE_CY_RE.search(code):
        errs.append("consume arm fill_cy re-derives from target_c_*")

    # Bank stamp on slot must also use recorded bank/idx (not live).
    if not re.search(r"\by_bank\s*\[\s*sched_idx\s*\]\s*<=\s*sched_bank\b", code):
        errs.append("consume arm missing y_bank[sched_idx] <= sched_bank")
    if not re.search(r"\bc_bank\s*\[\s*sched_idx\s*\]\s*<=\s*sched_bank\b", code):
        errs.append("consume arm missing c_bank[sched_idx] <= sched_bank")

    return errs


def check_latch_coassigns(latch_blocks: list[str]) -> list[str]:
    """Optional: each sched_valid latch co-assigns bank + idx + line from one select."""
    errs: list[str] = []
    if len(latch_blocks) < 2:
        errs.append(
            f"expected >=2 PIPELINE_REFILL_SCHEDULER latch arms (Y+C), got {len(latch_blocks)}"
        )
        return errs

    for i, body in enumerate(latch_blocks):
        code = code_only(body)
        has_bank = re.search(r"\bsched_bank\s*<=", code) is not None
        has_idx = re.search(r"\bsched_idx\s*<=", code) is not None
        has_y = re.search(r"\bsched_y\s*<=", code) is not None
        has_cy = re.search(r"\bsched_cy\s*<=", code) is not None
        if not (has_bank and has_idx and (has_y or has_cy)):
            errs.append(
                f"latch[{i}]: sched_valid=1 must co-assign bank+idx+(y|cy) "
                f"(bank={has_bank} idx={has_idx} y={has_y} cy={has_cy})"
            )
            continue

        # Extract ternary selects for bank/idx/line and require identical conditions.
        selects: list[str] = []
        for name in ("sched_bank", "sched_idx", "sched_y", "sched_cy"):
            m = re.search(
                rf"\b{name}\s*<=\s*\(([^?]+)\)\s*\?",
                code,
            )
            if m:
                selects.append(re.sub(r"\s+", " ", m.group(1).strip()))
        if len(selects) < 2:
            # Non-ternary atomic form (e.g. sel_prep_r) is also OK if all present.
            continue
        if len(set(selects)) != 1:
            errs.append(
                f"latch[{i}]: bank/idx/line mux selects disagree: {selects}"
            )
    return errs


def negative_live_mux_on_consume_must_fail(consume: str) -> list[str]:
    poisoned = re.sub(
        r"\bfill_bank\s*<=\s*sched_bank\b",
        "fill_bank <= (swap_pending_d2 && need_y_prep_r) ? pending_bank_d2 : disp_bank_d2",
        code_only(consume),
        count=1,
    )
    if "sched_bank" in poisoned and "pending_bank_d2" not in poisoned:
        return ["negative twin: could not poison fill_bank <= sched_bank"]
    errs = check_consume_from_record(poisoned)
    if not any("live" in e or "pending/disp" in e or "fill_bank" in e for e in errs):
        return [
            "negative twin: consume check failed to reject live fill_bank mux "
            f"(errs={errs})"
        ]
    return []


def negative_drop_fill_idx_must_fail(consume: str) -> list[str]:
    poisoned = re.sub(
        r"\bfill_idx\s*<=\s*sched_idx\s*;",
        "// fill_idx dropped",
        code_only(consume),
        count=1,
    )
    if "fill_idx <= sched_idx" in poisoned:
        return ["negative twin: could not drop fill_idx <= sched_idx"]
    errs = check_consume_from_record(poisoned)
    if not any("fill_idx" in e for e in errs):
        return [
            "negative twin: consume check failed to catch missing fill_idx "
            f"(errs={errs})"
        ]
    return []


def main() -> int:
    if not STORE.is_file():
        return fail(f"missing {STORE}")

    src = STORE.read_text(encoding="utf-8", errors="replace")
    s_idle = extract_s_idle_body(src)
    if s_idle is None:
        return fail("could not extract S_IDLE body from ddr_frame_store.sv")

    if "PIPELINE_REFILL_SCHEDULER" not in s_idle:
        return fail("S_IDLE has no PIPELINE_REFILL_SCHEDULER path")

    consume = extract_sched_valid_consume(s_idle)
    if consume is None:
        return fail(
            "could not extract PIPELINE_REFILL_SCHEDULER && sched_valid consume arm"
        )

    errs: list[str] = []
    consume_errs = check_consume_from_record(consume)
    errs.extend(consume_errs)

    latch_blocks = extract_pipeline_latch_blocks(s_idle)
    errs.extend(check_latch_coassigns(latch_blocks))

    # Negative twins only when positive consume is green.
    if not consume_errs:
        errs.extend(negative_live_mux_on_consume_must_fail(consume))
        errs.extend(negative_drop_fill_idx_must_fail(consume))

    # Product default keeps pipeline scheduler on (record path is product).
    if not re.search(
        r"parameter\s+bit\s+PIPELINE_REFILL_SCHEDULER\s*=\s*1'b1", src
    ):
        errs.append("PIPELINE_REFILL_SCHEDULER default must be 1'b1 (product)")

    if errs:
        for e in errs:
            print(f"FAIL ddr_schedule_atomic_record: {e}", file=sys.stderr)
        return 1

    print("PASS ddr_schedule_atomic_record:")
    print(f"  store={STORE}")
    print("  S_IDLE consume (PIPELINE && sched_valid): fill_* from sched_* only")
    print("  no live (swap_pending_d2 && need_*_prep) mux on consume fill path")
    print(
        f"  latch arms={len(latch_blocks)} co-assign bank+idx+(y|cy) from one select"
    )
    print("  negative: live fill_bank mux / missing fill_idx are RED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
