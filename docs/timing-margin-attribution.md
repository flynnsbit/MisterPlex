# clk_ddr margin attribution (integ tip `ef3a122` / STA 2026-07-29)

## Context

Post-fit of `feat/disp-fmt` tip closed timing with **TNS=0**. Compared to the
**wtime4** numbers recorded in `docs/PHASE_BACKLOG.md` (Hour-21: Setup
`clk_ddr` **+0.284**, Hold `clk_sys` **+0.244**, every TNS 0.000) and re-measured
on the integ-tip STA artifact:

| metric | wtime4 (backlog quote) | integ tip STA (measured) | Δ |
|--------|------------------------|--------------------------|---|
| clk_ddr setup (general[2]) | **+0.284 ns** | **+0.258 ns** | **−0.026 ns** |
| clk_sys hold (general[0]) | **+0.244 ns** | **+0.240 ns** | **−0.004 ns** |
| TNS (all sections) | 0 | 0 | 0 |

Raw integ-tip STA (`Plex.sta.rpt` Setup/Hold Summary):

```
; Setup Summary
; emu|pll|...|general[2]...divclk  ; 0.258  ; 0.000
; emu|pll|...|general[0]...divclk  ; 0.712  ; 0.000

; Hold Summary
; emu|pll|...|general[0]...divclk  ; 0.240  ; 0.000
; emu|pll|...|general[2]...divclk  ; 0.311  ; 0.000
```

Fmax (same report): clk_sys **23.27 MHz**, clk_ddr **92.14 MHz**.
Required clk_ddr period is 90 MHz per project docs/CDC inventory; this file does
not re-derive that from SDC in-line.

## Can we name endpoints?

**No.** The exported STA is **summary-only** (1011 lines). Searches for
`From Node`, `To Node`, `Path #1`, and `Data Arrival Path` return **zero** hits
in `Plex.sta.rpt`, `Plex.fit.rpt`, and `compile.log`.

Honest finding (evidence = absence of path rows in those files):

> **Erosion is unattributable to named RTL endpoints from the artifacts we have.**

What that does **not** prove: that the erosion is “spread thinly across many
paths.” Absence of path detail ≠ diffuse physical reality. Settling check:
re-fit with detailed `report_timing -npaths N` (or equivalent) on clk_ddr and
quote From/To nodes.

## Binding constraint (measured comparison only)

| domain | worst setup (this STA) | Fmax (this STA) |
|--------|------------------------|-----------------|
| clk_ddr general[2] | **0.258 ns** (lowest setup slack in report) | 92.14 MHz |
| clk_sys general[0] | 0.712 ns | 23.27 MHz |

“Binding for setup closure risk” here means only: **lowest setup slack number
in this STA is clk_ddr**. It does not identify a module.

Hierarchy sizes (post-fit, not path delays) were quoted earlier from the fit
hierarchy gate table; ALM size is **not** path proof.

## Gate

`scripts/check_timing_margin.py` + `assets/timing_margin_baseline.json` (wtime4)
fail when tracked margin regresses more than **50 ps** from reference, or when
TNS/slack go negative. Missing/malformed STA → **rc=77 SKIP-NOT-PASS**.

Wired into `make post-fit-timing-margin`, `scripts/build_rbf_remote.sh` after
negative-slack check, and `make unit` via mutation test
`tests/unit/test_timing_margin_gate.sh`.

Mutation recheck (captured): `tests/unit/test_timing_margin_gate.sh` → true rc=0.

## Trend / mitigation — measured vs UNKNOWN (rule 0)

**Measured arithmetic only** (no rate model):

- Gate floor = ref 0.284 − max_regression 0.05 = **0.234 ns**.
- Current clk_ddr setup **0.258** − floor **0.234** = **0.024 ns** headroom
  before this baseline fails the margin gate.
- Slack to hard zero on this STA = **0.258 ns**.

**RETRACTED / UNKNOWN (previously over-claimed in this doc and session reports):**

- “−0.026 ns per ~fifteen decode merges” / ps-per-merge rate — **not measured**.
  Cause of the delta between wtime4 backlog numbers and this STA is **unknown**.
  Settling check: fit the wtime4 freeze SHA and tip with identical Quartus knobs;
  compare summary and path STA.
- “Roughly one more similar batch before the gate trips” — linear forecast,
  **not a finding**.
- “Routing cliffs” — **no evidence** in summary STA.
- Named first RTL fix target (`ddr_frame_store` retiming, etc.) — **unknown**
  until detailed path report names endpoints.

**Mitigations with evidence vs not:**

1. Keep margin gate red-blocking — backed by mutation rc=0/1/77 and repo hooks.
2. Enable detailed `report_timing` on next intentional fit — this is the check
   that settles endpoint attribution; not yet run.
3. Module-level RTL timing edits — do not start from hierarchy size alone.
