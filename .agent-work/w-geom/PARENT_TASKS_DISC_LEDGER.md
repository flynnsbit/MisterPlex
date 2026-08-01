# Parent tasks — disc + ledger + cost (w-geom)

## 1. Late-arrival vs late-observation discriminator

**Implemented** in `publish_interval_ledger.hpp` + `media_player::publishDdrFrame`:

- `tPre` immediately before `fpga_.publishDdrFrame`
- `tPost` immediately after
- `note(pre, post)`: arrival interval = pre[i]-pre[i-1]; write_us = post-pre
- Cause attribution: late arrival_iv attributes **previous** sample's write_us (blocked write delays next pre)
- Logs: `formatSummaryLine` includes `mean_write_us*`, `write_late_ratio`, `disc_verdict`
- `formatDiscLine` + mid-session when `MISTERPLEX_PUBLISH_INTERVAL_LOG=1`
- Dump CSV: `pre_us,write_us` via `MISTERPLEX_PUBLISH_INTERVAL_DUMP`

| disc_verdict | Rule |
|--------------|------|
| LATE_ARRIVAL | write flat on long arrival ivs (ratio ~1 or free write path) |
| LATE_OBSERVATION | mean_write_us_late ≫ ok and ratio ≥ 2 |
| MIXED_OR_LATE_OBSERVATION | ratio ≥ 1.5 |
| UNSCORED | &lt;10 late samples or &lt;50 writes |

**Prior soak p_ge50=0.145 is UNSCORED** (parent). Re-soak scores `p_ge50_steady` + `disc_verdict`.

## 2. Honest ledger

- FRAME_LEDGER: single `residual=`; `residual_eq=frames-presents-drops`; `residual_scope=supply_arm_only`; `fpga_obs=none`; `presents_src=arm_publish_ok`; **no** `unaccounted=`
- supply_bucket: `d_residual` / `residual=` same derivation labels
- lifetime: `lifetime_residual` not `lifetime_unaccounted`

## 3. Horizontal cost

See `HORIZONTAL_640_COST.md` — needs ~25–27 MHz or new timing class; **defer fit**.

## 4. Underrun baseline

See `UNDERRUN_BASELINE.md` — PLXF `0x300FF118` [63:48].

## 5. w-fit-1

T7 vertical signed off earlier (`w-fit-ceiling-fd-min`). w-geom available for STA/hierarchy; no second fit.
