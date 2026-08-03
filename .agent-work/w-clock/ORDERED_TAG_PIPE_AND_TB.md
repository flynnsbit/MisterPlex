# Ordered tag pipe + TB hardening (rd-duck audit)

## Product RTL (already fixed; re-confirmed)

`present_core.sv`:
- `mp_npx_valid = mp_push` only (single `MP_STORE_LAT` pipe for **all** groups)
- RGB: `mp_use_fs = mp_push && mp_push_de && fs_n_valid` (miss → black, still one group)
- **Forbidden:** `fs_n_valid | blank_push` dual-latency OR

## Dual-OR defect class (executable RED)

`RED_DUAL_OR=1` in `present_mp_integrated_tb.sv`:
- blank path LAT=1, DE path LAT=4, `npx_valid = act|blank`
- collision drops a group; RED requires coll>0 or observable shortfall
- GREEN uses ordered pipe only

## CEA / integrated TB fixes

| Issue | Fix |
|-------|-----|
| no timescale | `` `timescale 1ps/1ps `` |
| PHASE units | PHASE_PS/NS = **nanoseconds** → `#(N*1000)` ps |
| fake Bresenham | real `present_pix_rate_match` |
| short frame only | still default VA=8 VT=12; FULL=1 for 750; **NUM_FRAMES=2** continuous |
| no H_TOTAL/HS width | assert slots/line + HS_W |
| post-drain ur false fail | score ur only while `exp_slots_rem > 0` |

## Commands

```bash
./tests/unit/test_present_mp_integrated.sh   # NO_FRAME + FRAME + RED_DUAL_OR
./tests/unit/test_present_npx_cea_raster.sh  # green/red/phase
```
