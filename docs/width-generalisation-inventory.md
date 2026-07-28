# Width Generalisation Inventory: 39 → 40 MB Columns

**Author:** w-dpb  
**Date:** 2026-07-27  
**Branch:** `feat/dpb-fetch`  
**Status:** Inventory only — no changes proposed until PMS corpus measurement settles.

---

## BOTTOM LINE

**39-versus-40 is a parameter change, not a structural one.** Every width-dependent
path uses parameterised arithmetic. No new buffers, no new arbitration, no structural
redesign. The one M10K cost (intra above-row context) is ≤ 1 M10K block.

---

## Inventory of width-dependent sites

### A. RTL parameters and constants (PARAMETER EDIT only)

| File:Line | Constant | Current | At 640 | Cost |
|-----------|----------|---------|--------|------|
| `h264_dpb.sv:6,30,53` | `FRAME_W` default | 624 | 640 | **Zero** — parameter override at instantiation |
| `ddr_frame_layout_params.svh:5` | `DDR_FRAME_CODED_WIDTH` | 624 | 640 | Zero — shared constant, atomic update with ARM |
| `ddr_frame_layout_params.svh:25` | `DDR_FRAME_Y_STRIDE_BYTES` | 624 | 640 | Zero |
| `ddr_frame_layout_params.svh:26` | `DDR_FRAME_CHROMA_STRIDE_BYTES` | 312 | 320 | Zero |
| `ddr_frame_layout_params.svh:21-22` | Plane offsets U/V | 299520/374400 | 307200/384000 | Zero |
| `ddr_frame_layout_params.svh:20` | `DDR_FRAME_YUV420P_BYTES` | 449280 | 460800 | Zero (still < bank stride 0x80000) |
| `decode_stub.sv:226` | `.width(16'd624)` | 624 literal | 640 or param | Zero — diagnostic constant |
| `h264_deblock.sv:394` | `MB_COUNT` default | 1170 | 1200 | Zero — parameter, `$clog2(1200) = 11` same as `$clog2(1170) = 11` |

### B. Address arithmetic (ZERO cost — all parameterised)

| File:Line | Computation | Width-sensitive? | Cost at 640 |
|-----------|-------------|-----------------|-------------|
| `h264_dpb.sv:22,165-167` | `base + y × FRAME_W + x` | Yes — uses parameter | **None** — 32-bit multiply |
| `h264_dpb.sv:205` | `clamp_coord(sx, FRAME_W[15:0])` | Yes — uses parameter | **None** |
| `decode_stub.sv:318` | `DPB_MB_W = (WIDTH+15)/16` | Yes — uses parameter | **None** — 40 instead of 39 |
| `decode_stub.sv:376-377` | `mb_addr % DPB_MB_W` / `/ DPB_MB_W` | Yes — uses localparam | **None** |
| `ddr_frame_store.sv:76-77` | `Y_LINE_QWORDS = CODED_W/8` | Yes — uses parameter | **None** — 80 instead of 78 |
| `sps_parser.sv:339` | `mb_width <= w_mbs[7:0]` | Dynamic from bitstream | **None** — already handles arbitrary widths |

### C. Line buffers (M10K cost)

| File:Line | Buffer | Current size | At 640 | Δ M10K |
|-----------|--------|-------------|--------|--------|
| `ddr_frame_store.sv:151-159` | Y/U/V line bufs × LINE_SLOTS(16) | Y: 78 qwords × 64b, C: 39 qwords × 64b | Y: 80 qw × 64b, C: 40 qw × 64b | **Zero** — M10K blocks are 10,240 bits; 80×64=5120 < 10,240, both fit in 1 M10K per RAM |
| (future) intra pred above-row context | Not yet designed | N/A | 40×16 = 640 luma + 40×8×2 = 640 chroma = 1280 bytes | **≤ 1 M10K** (10,240 bits = 1,280 bytes) |
| (future) CAVLC nC row context | Not yet designed | N/A | 40×4 = 160 entries × 5 bits = 800 bits | **0 M10K** — fits in registers or 1 MLAB |

**Total M10K delta: 0 for existing RTL, ≤ 1 for the future datapath.**

(For context: w-ctl measured 146 M10K free of 356 total. 1 block is 0.3% of available.)

### D. Counter/address bit widths (ALL SAFE)

| Wire/Reg | Width | Max at 39 cols | Max at 40 cols | Overflow? |
|----------|-------|---------------|----------------|-----------|
| `mb_x` / `mb_y` (`[7:0]`) | 8 bits | 38/29 | 39/29 | **No** — 0–255 |
| `mb_width` (sps_parser output) | 8 bits | 39 | 40 | **No** — 0–255 |
| `DPB_MB_AW = $clog2(MB_COUNT)` | 11 bits | $clog2(1170)=11 | $clog2(1200)=11 | **No** |
| `filtered_mb_addr [10:0]` | 11 bits | 1169 | 1199 | **No** — max 2047 |
| `mem_waddr / mem_raddr [31:0]` | 32 bits | 449,279 | 460,799 | **No** |
| `ddr_frame_store X_W` | `$clog2(FRAME_W)` | $clog2(640)=10 | Same 10 | **No** |

### E. Timing-sensitive paths

| Path | Current | Impact at 640 | Risk |
|------|---------|---------------|------|
| `y × FRAME_W` (DPB address calc) | 16×16 multiply | Operand changes from 624 to 640 | **None** — same bit widths, same DSP/LUT structure |
| `mb_addr % DPB_MB_W` (decode_stub) | Division by 39 | Division by 40 | **Easier** — 40 = 8×5, more synthesis-friendly than 39 |
| `ddr_frame_store` line read state | 78 qword burst | 80 qword burst | **Negligible** — 2 extra DDR clock cycles per line |

### F. ARM-side constants (coordinated update)

| File:Line | Constant | Current | At 640 |
|-----------|----------|---------|--------|
| `host/libmisterplex/ddr_frame_layout.hpp:8` | `kPlex480pCodedWidth` | 624 | 640 |
| `host/libmisterplex/ddr_frame_layout.hpp:11` | `kPlex480pDisplayWidth` | 618 | 634 (if still crop-right 6) or 640 (no crop) |
| `host/libmisterplex/ddr_frame_layout.hpp:23-31` | Line qwords, plane offsets, strides | 624-derived | 640-derived |
| `media_player.cpp:1308` | `rec.width == g.coded_width` | Gates at 624 | Would pass at 640 |
| `assets/plex-profiles/MiSTerPlex.xml` | (not a width gate) | Requests 640 | No change needed |

### G. Silent-mismatch audit (parent's specific caution)

Sites that **silently skip, clamp or truncate** rather than failing loudly if width
doesn't match:

| Site | Behaviour | Risk |
|------|-----------|------|
| `media_player.cpp:1308-1322` | `rec.width != 624` → logs once, drops all subsequent frames | **Already made loud by w-osd (`cf2629f`)** — now visible in status mailbox |
| `h264_dpb.sv:205 clamp_coord` | Clamps coordinates to `[0, FRAME_W-1]` | **Correct behaviour** — this IS the normative H.264 edge clamp. Silent is correct here. |
| `ddr_frame_store.sv:83 LAST_X` | Wraps scanout at `FRAME_W-1` | **Correct** — presentation boundary, not a data truncation |
| `decode_stub.sv:401` | `mb_w == 0 ? 20 : mb_w` | **Silent fallback to 20** if SPS not yet parsed — diagnostic only, not a data path |

**No new silent mismatches found.** The `media_player.cpp` one was the only dangerous
case and w-osd has already addressed it.

---

## ANSWER: Parameter change or structural?

**Parameter change.** Specifically:
- 8 constants in `ddr_frame_layout_params.svh` + mirror in `ddr_frame_layout.hpp`
- 3 default parameter values in `h264_dpb.sv` (overridden at instantiation)
- 1 literal in `decode_stub.sv:226` (diagnostic)
- 1 default in `h264_deblock.sv:394` (overridden at instantiation)

No new buffers. No new M10K. No wider address buses. No structural change.
The argument for just doing it — when/if the PMS measurement confirms 640 can arrive —
is strong. The cost of the change itself is near zero. The cost of *validating* it
(which is what matters) is my width-edge test, already written and passing.

---

## What I am NOT claiming

- I am not claiming 640-wide content will arrive (w-feed is measuring that)
- I am not claiming the decode datapath works at either width (per #19, it doesn't exist)
- The "zero cost" labels above are for the parameter edit itself — they do not include
  the cost of the coordinated ARM+RTL update, testing, and re-fit
