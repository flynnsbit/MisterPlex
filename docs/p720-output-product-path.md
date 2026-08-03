# 720p OUTPUT product path (parent 2026-08-03)

## What ships

```
960x540 Constrained Baseline source
  -> ARM decode 22.75 ms + native I420 copy 8.42 ms = 31.17 ms
  -> margin +10.49 ms vs 41.667 @24fps
  -> PLXG native_push into Option-C bank (0x30180000)
  -> fabric upscale to 1280x720 raster on glass
```

This is **720p output**. It is **not** 720p source. Parent proxy instrument
validated (1280x720 control within 0.4% of PMS). 5/5 predictions HIT.

## What does not ship on this path

| Path | Verdict |
|------|---------|
| 1280x720 source + CPU copy | FAIL (-6.95 to -8.77 ms) |
| 1024x576 intermediate | PASS math but margin 6.05 < ~10 ms peer tax — rejected |
| 854x480 | conservative fallback (+14.31) |
| FPGA-written banks / zero ARM pixels | separate ship gate (`publish_bytes=0`) |
| Full fabric H.264 decode | multi-month endgame |
| DMA true 720p source | w-path upgrade (kills 14.97 ms copy) |

## ABI

- `makePlex720pOutputFrom540pSourcePlan()` — publish_bytes=777600, fabric_owned
- `ddr720pOutputProductPathAccepts` — margin floor 10 ms, fabric scale required
- `ddr720p24ShipAcceptsZeroArmPerPixel` — unchanged; true 720p source / fabric writer
- DPB sizing: delivered level 31 (`h264_level_limits.hpp`)
- Caveat: `-f null` decode-only; E2E cast is parent-only on glass

## Clocks

w-clock: `clk_pix` ~29.7 MHz for 720p24 CEA (separate PLL). Multi-pixel alone
does not raise output Hz while `clk_pix = clk_sys = 20 MHz`.
