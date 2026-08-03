# Multi-pixel integration — sync ownership + black fill (rd-duck)

**Commit scope:** `present_core.sv` under `PRESENT_MULTI_PIXEL`+`DDR_FRAME_STORE` (+ PLL).  
**Default:** macros still OFF. No fit. No device.

## Findings (CONFIRMED by quote)

1. **CLK_VIDEO=clk_pix but H/V from legacy when `!has_frame`**  
   Old: `HBlank = use_ext ? mp_hb_d : hb_d` with `use_ext=has_frame&&...`.  
   Startup presented **20 MHz colorbars timing** sampled as 29.7 MHz pixels.

2. **No active slots without frame**  
   Old: DE push only on `fs_n_valid`; blank only on `!lane_de`.  
   Before frame / on miss → **no DE groups** → 720 raster cannot run black continuously.

3. **Sync sampled at response, not request**  
   Old: `mp_hb_sam` overwritten every `beam_ce`; applied when `fs_n_valid` returns later → line-edge RGB gets **current** beam sync.

4. **`vsync_pulse(fstart)`**  
   Legacy colorbars frame pulse → bank swap can land **mid-720 frame**.  
   Fix: `vsync_pulse(mp_fstart)` under `PRESENT_MULTI_PIXEL`.

## Fixes

| Item | Change |
|------|--------|
| Timing ownership | Mode-on: always `H/V = mp_*` (PLL: from FIFO sideband) |
| RGB no-frame | PLL: black on DE if `!has_frame`; never bars on clk_pix |
| Tag pipe | `MP_STORE_LAT=4` shift of {hb,hs,vb,vs,lane_de} from `beam_ce` |
| Push rule | Every tagged beam group → npx; DE+`fs_n_valid`→store RGB; else black |
| Bank swap | `mp_fstart` |

## Tests

```bash
./tests/unit/test_present_mp_integrated.sh   # NO_FRAME black continuous + FRAME mock store
./tests/unit/test_present_npx_cea_raster.sh
./tests/unit/test_present_npx_full_raster.sh
```

Integrated TB is beam→mock-store(LAT)→tag→npx — catches class bridge-only tests missed.

## Open

- Exact `MP_STORE_LAT` vs real `ddr_frame_store` under DDR backlog still needs parent/integration hit once store model is full.
- Glass 29.7 still not claimed.
