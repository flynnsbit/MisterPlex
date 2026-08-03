# present_npx_path — wide group FIFO + prefill/skid (rd-duck rounds)

**Status:** RTL + unit evidence on `w-clock-bump`. Macros default OFF. **No fit. No device.**  
**Do not claim glass 29.7 Hz sustained** until parent fit + capture.

---

## 1) Serialize wall (CONFIRMED)

Old: sys-domain lane serialize before FIFO → `F_sys*PPC/(1+PPC)` = **13.33 Mpix/s @20/PPC2** ≪ 29.7.  
`rd_underrun` hard-0. rd-duck correct.

## 2) Wide group FIFO (landed)

Peak `F_sys*PPC` = **40 Mpix/s @20/PPC2**. Unpack on `clk_pix`. Real `rd_underrun`.

## 3) rd-duck audit round 2 (CONFIRMED gaps → fixed)

| Finding | Verdict | Action |
|---------|---------|--------|
| RED hole re-arm at g==64 | Was real; fixed earlier with `hole_done` | Keep one-shot |
| Active-only TB ≠ CEA slots | **CONFIRMED** | `present_npx_cea_raster_tb` sends H_TOTAL×V_TOTAL + HS/VS |
| No prefill / phase risk | **CONFIRMED** | `PREFILL_GROUPS=8` + 2FF; phase/seed sweep GREEN |
| Bresenham 100 ns gap vs 67 ns unpack | Real jitter class | Prefill cushion |
| Upstream `in_ready` / in-flight store | **Gap real** | Sys **skid depth 16**, soft ready at depth-4; see `IN_READY_UPSTREAM.md` |
| Fractional `#16.835` clock | Verilator truncates | Integer **ps** half-periods |

### Prefill / skid (product defaults)

- `PREFILL_GROUPS=8` — no pop until 8 async writes (2FF to pix)
- `SKID_AW=4` (16 deep); `in_ready=!skid_af` (AF at depth-4)
- Hard accept `in_valid && !skid_full` for late store pulses after soft backpressure
- Integrated `present_core`+`ddr_frame_store` cosim of in-flight under AF: **still open**

### Tests (true rc)

| Test | Result |
|------|--------|
| `test_present_npx_full_raster.sh` | PASS (1280×720 active, prefill, RED starve) |
| `test_present_npx_cea_raster.sh` | PASS short CEA 1650×12 + HS/VS + phase{0,10,16,18,34}×seed{0,200} + RED |
| path / sync / cdc soak | PASS |

```bash
./tests/unit/test_present_npx_full_raster.sh; echo "true rc=$?"
./tests/unit/test_present_npx_cea_raster.sh; echo "true rc=$?"
FULL=1 ./tests/unit/test_present_npx_cea_raster.sh   # optional 750-line; slow
```

CEA green scores **mid-frame** underrun only (post-frame empty after producer stop is not a product fail).

## 4) STA prereg addendum

- Wider FIFO word + skid regs on `clk_sys` (same gray CDC + 2FF prefill)
- Neg slack = hard fail; no whole-domain false_path
- Exact Fmax **unknown until fit**

## 5) Honesty

- Sim proves: wide FIFO throughput class, CEA short-frame sync sideband, phase grid with prefill, real underrun flag.
- **Not proved:** post-fit Fmax @29.7, full 750-line in default CI, integrated store backpressure cosim, glass 24 Hz.
