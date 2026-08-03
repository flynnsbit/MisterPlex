# rd-duck same-clock sync trap (fixed)

## Finding (confirmed in source)

`PRESENT_MULTI_PIXEL` with PLL **off** used:
- `MP_INCLUDE_SYNC = 0`
- `mp_hb_d = mp_hb` (direct beam)
- RGB via store LAT + skid + async FIFO + PREFILL=16

→ H/V **led** RGB by the queue. DE opened on beam time while pixels were still in-flight.

## Fix

1. `MP_INCLUDE_SYNC = 1` always (same-clock and PLL).
2. Always `mp_hb_d = mp_out_hb` (FIFO sideband).
3. Pack `fstart` in sideband (`SYNC_W=5`); `vsync_pulse`/`frame_start` = `mp_out_fs`.
4. Oracle: `test_present_npx_first_last_de.sh` green + RED_DIRECT_SYNC.

## BEAM_960

**Not** this path. 1px CE=1 + `DE_LAG` only. Do not parameterize MULTI_PIXEL for 960.
