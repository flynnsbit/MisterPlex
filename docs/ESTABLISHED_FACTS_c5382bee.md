# Established facts — RBF c5382bee (parent hardware, 2026-08-01)

**Source of truth:** parent-run on device, pre-registered predictions, HDMI pixels.
Agents do **not** re-run hardware. Do not weaken or “re-prove” these as inference.

## Vertical unique-row ceiling — PROVEN

Product DDR publish path (`FpgaSpi::publishDdrFrame`), **H.264 out of loop**,
`push_frame --ddr --pattern` on md5-verified `c5382bee`:

| Pattern | mean | std | glass |
|---------|------|-----|-------|
| mid_grey CONTROL | 137.0 | 0.00 | path sound |
| even_black | 7.0 | 0.00 | solid BLACK |
| even_white | 255.0 | 0.00 | solid WHITE |
| odd_black | 255.0 | 0.00 | solid WHITE (**INVERTED**) |
| odd_white | 7.0 | 0.00 | solid BLACK (**INVERTED**) |

`std = 0.00` ⇒ no stripes: odd store rows are **entirely absent**. One-row phase
shift inverts a flat field. **~50% of rows never reach display.**

**Scope:** **vertical only.** Horizontal “529-of-640” is **arithmetic / timing
class only** (`clk_sys = 20 MHz` → 20e6/60/524 = 636 < 640) — **not** pixel-proven.

**Before-bank for fix:** w-geom T7 unique rows 240→480. Re-run this card after
that RBF must **break** solid-field collapse.

## Retracted / void until new RBF

| Claim | Status |
|-------|--------|
| `p_ge50 = 14.5%` as scored hit/miss | **UNSCORED** (σ ≫ mean; raw log gone — remeasure trimmed) |
| “Two independent instruments agree” (p_ge50 + acf lag1) | **WITHDRAWN** — two stats of one series |
| `drops=0` / closed FRAME_LEDGER as display health | **ARM supply only** — no FPGA observe |
| `unaccounted` as independent of residual | **alias** — same formula (tag derivation) |
| Anything from PLXD[63:48] `frames_done` as swap count | **void** on c5382bee (vsync pack) |

## Safety (user today)

Mailbox liveness via `frames_done` advance is **defeated** on c5382bee (vsync
pack). ARM interim: `plxd_liveness.hpp` — counter = timebase; `[SWAP_STUCK]` on
stuck `swap_pending` / display-ack. Full cure = fitted RBF with real swap pack.

## Standing rules

1. **Label + derivation in the same breath.**
2. **Pre-retraction three-line check** — `docs/PRE_RETRACTION_CHECK.md`.
3. **`rc=77` / UNSCORED ≠ pass.**

## Gates on this branch

- `tests/unit/test_c5382bee_established_facts.py` — locks vertical ceiling + voids
- `publish_*_ledger` — p_ge50 **UNSCORED** when σ > 2× mean
- `plxd_liveness` / label-derivation / FRAME_LEDGER `scope=ARM_PUBLISH_NOT_DISPLAY`
