# present_npx_path — wide group FIFO (rd-duck finding, w-clock confirm + fix)

**Status:** CONFIRMED + FIXED (default still OFF via `PRESENT_MULTI_PIXEL`).  
**Commit scope:** `present_npx_path.sv` rewrite, full-raster TB, STA prereg note.  
**Fit:** not re-scoped; still HELD by parent.

---

## 1) Confirm 13.33 Mpix/s (quoted structure + arithmetic)

### Old producer (pre-fix, serialize on `clk_sys` before FIFO)

Structure (historical): accept one PPC group → hold → emit **one lane per sys cycle** into a narrow pixel FIFO.

Cycles per group = **1 (accept) + PPC (serialize)** = `1 + PPC`.

```
peak_Mpix/s = F_sys * PPC / (1 + PPC)
@ F_sys=20 MHz, PPC=2:  20 * 2 / 3 = 13.333… Mpix/s
@ F_sys=20 MHz, PPC=4:  20 * 4 / 5 = 16.0     Mpix/s
```

Required for CEA 720p24 content rate: **29.7 Mpix/s** (`1650×750×24`).

```
13.33 << 29.7   →  FIFO underruns mid-line even with clk_pix=29.7
```

**Verdict: rd-duck is correct.** Adding `clk_pix` alone moved the bottleneck to the producer; it did not vanish.

### Old `rd_underrun` (quoted class of bug)

Pre-fix product path forced the indicator inactive (`rd_underrun` hard 0 / never armed).  
A starved raster could tear on glass with **no fabric flag**. That is worse than the underrun itself.

---

## 2) Fix (landed, macro-gated by parent instantiation)

### Architecture

| Side | Clock | Behaviour |
|------|-------|-----------|
| Write | `clk_sys` | **1 whole group / accepted cycle** into `async_fifo` width `W` |
| Read | `clk_pix` | Pop group when `!hold_busy && !empty`; unpack lanes 1 px/clk |
| CDC | gray ptr only | Same `async_fifo` as before — **wider word**, not a new crossing class |

Pack (`INCLUDE_SYNC=1`):

```
{ vs, hs, vb, hb, lane_valid[PPC-1:0], r[PPC*8], g[PPC*8], b[PPC*8] }
```

Peak after fix:

```
peak_Mpix/s = F_sys * PPC
@ 20 MHz × PPC=2:  40.0  ≥ 29.7   (margin 1.35×)   // PIX24
@ 20 MHz × PPC=4:  80.0  ≥ 74.25  (margin 1.08×)  // PIX60 path
```

### Real `rd_underrun`

```systemverilog
// clk_pix domain — never hard-tied 0
if (hold_busy) ...
else if (!fifo_empty) ... // pop + maybe emit lane0
else begin
  // black
  if (stream_seen)
    rd_underrun <= 1'b1;  // mid-stream empty
end
```

- Arms only after at least one pixel has streamed (`stream_seen`).
- Pulses every `clk_pix` cycle while empty mid-stream.
- **Failure mode if ignored:** mid-line black / tear; rate-match + gray FIFO remain the risky pair.

### What breaks on mid-line underrun

1. `out_ce` drops (no pixel).
2. RGB forced 0 that cycle.
3. `rd_underrun` high — parent/OSD must surface this; silent shear is forbidden.
4. H/V blanking sideband freezes at last hold values until next group (sync may glitch if hole is long) — blanking recovery is not claimed perfect; **detectability** is.

---

## 3) Tests (true rc, soft-skip ≠ PASS)

| Test | Result |
|------|--------|
| `tests/unit/test_present_npx_full_raster.sh` | **PASS** green full 1280×720 no-gap + RED starve underrun |
| `test_present_npx_path_verilator.sh` | PASS |
| `test_present_npx_sync_sideband.sh` | PASS |
| `test_present_npx_cdc_soak.sh` | PASS |
| `test_present_pix_rate_match.sh` | PASS |

GREEN proves beat conservation: `wr_px == rd_px == 921600`, `ur_count==0` under Bresenham 29.7/20 balance.  
RED: 64 groups then 8000 sys idle → `rd_underrun > 0`.

```bash
cd /home/flynnsbit/Projects/MisterPlex-wt-clock
./tests/unit/test_present_npx_full_raster.sh; echo "true rc=$?"
```

---

## 4) STA pre-registration (updated for wider FIFO word)

Unchanged domain story: `clk_sys` write / `clk_pix` read / gray dual-clock only.

**New / restated vs prior prereg:**

| Item | Expectation |
|------|-------------|
| FIFO word | Wider (`W ≈ 4 + PPC + 3*PPC*8` with sync) — more MLAB bits, **same** gray CDC |
| `async_fifo` mem false-path | Still legitimate (data RAM, not pointers) |
| Whole-domain `false_path` sys↔pix | **FORBIDDEN** (gate self-weaken) |
| Fmax `clk_sys` | ≥ 20.0 MHz (shipping PLL) |
| Fmax `clk_pix` (stage1) | ≥ 29.7 MHz |
| Setup slack | all constrained ≥ 0 — **neg = HARD FAIL** |
| Hierarchy | `u_mp_npx_path` nonzero (elision = fail) |
| Exact Fmax decimals | **unknown until fit** — do not invent |

Parent score commands (unchanged):

```bash
make post-fit-timing STA_RPT=.../Plex.sta.rpt
make post-fit-timing-margin STA_RPT=.../Plex.sta.rpt
make post-fit-hierarchy FIT_RPT=.../Plex.fit.rpt
```

---

## 5) Applied vs proposed

| Item | State |
|------|-------|
| Wide group FIFO + real underrun RTL | **APPLIED** on `w-clock-bump` |
| Full-raster + RED unit tests | **APPLIED** |
| `PRESENT_MULTI_PIXEL` default | **OFF** (product bit-identical) |
| Quartus fit | **NOT run** (parent exclusive) |
| Device / deploy | **NOT done** |

---

## 6) Honesty wall

Even with this fix, product glass at 24 Hz still needs:

1. `PRESENT_CLK_PIX_PLL` + multi-pixel **ON** in the integration fit,
2. w-mem Option-C capacity predicate (960-wide → not legacy 512 KiB),
3. STA green on prereg cuts,
4. Parent glass capture — agents do not assert hardware.

Producer peak 40 ≥ 29.7 is **RTL arithmetic + sim**, not post-fit STA.
