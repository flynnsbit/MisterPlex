# Parent ERROR 20 / 21 response (w-geom)

## ERROR 20 — comment "fix" cancelled

**Verified in git, not assumed:** pre-`100b797d` text said present-tense
`frames_done field is actually bank_vsync_count` (wrong for product RTL today).

My rewrite to a **HISTORICAL FAULT** note matches what parent now quotes as correct.
**Not reverting** to the old present-tense claim (that would reintroduce the bug
parent's ERROR 20 was meant to protect against). No further edits to that block.

Substance unchanged: `frames_done` = swap count; only `vsync_toggle` every vsync.

## ERROR 21 — corrected interval verdict mapping

| p_ge50 | verdict | meaning |
|---|---|---|
| 9–11% | `ARM_LATE_MATCH_HOLD45` | ARM late; CPU/schedule |
| **< 3%** | **`ARM_EXONERATED_FPGA_SIDE`** | **positive redirect** to CDC `pending_ready_s2` / DDR-complete / SWAP_REQ race — **not** a dead end |

Old name `ARM_CLEAN` removed from verdict strings.

## First measurement (free): publish_swap_delta

On every **successful** `publishDdrFrame`:
- mono_us (steady_clock)
- `frames_done` from PLXD bank-select snapshot already taken in `sendDdrFrame` (**no extra SPI**)
- Δfd vs previous publish (uint16 unwrap)
- phase_est_us = mono % 16666 **tag=ESTIMATE_60Hz** (vsync_toggle not ARM-readable without RBF)

Session end logs:
- `media: publish_swap_delta … p_d0=… interval_verdict=… skip_verdict=…`
- `media: publish_swap_delta_phase_est d0_bins=… d1_bins=…`

Δ=0 ⇒ zero-refresh skip (pending overwrite class). Δ=1 ⇒ previous swapped.

## 624 vs 640

**Not a latent FRAME_STRIDE defect.** Contract (quoted):
- CODED 624×480, Y_STRIDE 624, DISPLAY crop 618, PRESENTED 640 with pillar 11+11
- QSF `FRAME_W/H=640/480` is presented/scanout domain
- `ddr_frame_store` planes use `CODED_W`; `FRAME_STRIDE` defaults to 640 but YUV line qwords use CODED_W

## Parent run

```bash
# deploy misterplexd from this tip; >=60s 480p soak; stop stream
grep -E 'publish_swap_delta|publish_interval' /path/to/misterplexd.log | tail -40
scripts/score_publish_interval_log.sh /path/to/misterplexd.log
```
