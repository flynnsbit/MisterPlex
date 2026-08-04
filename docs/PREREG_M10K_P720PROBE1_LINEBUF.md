# PREREG — linebuf M10K attack vs p720probe1 map (w-nostub)

**Control (parent A&S, Quartus 17.0.2, p720probe1):**  
`/home/flynnsbit/mplex-builds/p720probe1/Plex_MiSTer/output_files/Plex.map.rpt`

## Measured from that map.rpt (this lane re-read the file)

| Metric | Value | Control |
|--------|------:|---------|
| ALMs needed | **20,750** / 41,910 (49.5%) | Resource Usage Summary |
| Dedicated logic registers | **22,864** | same |
| Total block memory bits | **1,369,283** | same |
| DSP blocks | **42** | same |
| `line_buf_ram:gen_line[*]` indices | **0..31** (n=**32**) | path strings in M10K table |
| yram geometry | **32 × (160 × 64)** SDP M10K | M10K block table |
| uram geometry | **32 × (80 × 64)** SDP M10K | same |
| vram geometry | **32 × (80 × 64)** SDP M10K | same |

**M10K table rows in this report:** 98 total (96 line_buf + audio 2048×32 + bitstream_fifo 32768×8).  
ascal does **not** appear as `M10K block` rows here — parent’s “124 instances / 294 M10K / ascal 42” may include another section or post-fit split. **This lane’s entity-table parse: linebuf dominates at 96 logical RAMs → 192 blocks under 2 blk/inst packing.**

### Linebuf block math (depth × width → blocks)

| Instance | depth × width | bits/inst | Legal pack | blk/inst | ×32 | Waste |
|----------|---------------|----------:|------------|---------:|----:|------|
| yram | **160 × 64** | 10,240 | 2 × (256 × 32) | **2** | **64** | 50% (width>40) |
| uram | **80 × 64** | 5,120 | 2 × (256 × 32) | **2** | **64** | 75% |
| vram | **80 × 64** | 5,120 | 2 × (256 × 32) | **2** | **64** | 75% |
| **linebuf total** | | 655,360 | | | **192** | |

p720probe1 RTL still uses `line_buf_ram` DATA_W=64 — **PACK_PX5 not in that build** (`line_buf_ram_px5` absent from map).

## Why n=32, not 16 — DO NOT “fix” without design change

Quoted product RTL (`ddr_frame_store.sv`):

```systemverilog
localparam int LINE_SLOTS = LINE_COUNT * 2;
localparam [SLOT_W-1:0] SECOND_SET_BASE = SLOT_W'(LINE_COUNT);
// ...
video_slot = (disp_buf ? SECOND_SET_BASE : '0) + vi[...];
cur_base_idx  = disp_buf_d2 ? SECOND_SET_BASE : '0;
prep_base_idx = disp_buf_d2 ? '0 : SECOND_SET_BASE;
// vsync swap:
disp_buf <= ~disp_buf;
```

`FRAME_LINES_16=1` → `LINE_COUNT=16` **lines per set**.  
`LINE_SLOTS=32` = **display set + prep set** (ping-pong while fill tracks the other bank/window).  
This is **deliberate double-buffering**, not a QSF bug. Halving to 16 slots would remove the prep window and is a **behavioral** change — out of scope until parent authorizes.

## Options costed (layout stated) — before changing further

### A. PACK_PX5 256×40 (implemented on `w-nostub-m10k-pack`)
| Plane | New depth × width | blk/inst | ×32 |
|-------|-------------------|---------:|----:|
| Y | **256 × 40** (1280 px / 5) | **1** | 32 |
| U | **128 × 40** in 256×40 shell | **1** | 32 |
| V | same | **1** | 32 |
| Packer FIFOs (shared) | Y 256×40 + U/V ≤128×40 | **+1..3 EST** | — |
| **line-related** | | | **96 + 1..3** |

**Save vs measured 192:** **~93–96 M10K** on linebufs.  
Cost: 5-px granularity, packer SKID, stream L→R only (see `docs/PREREG_M10K_PX5_PACK.md`).

### B. Narrow port, keep byte/qword addressing (no 5-px pack)
e.g. Y as 320 × 32 (still 2 blk if width 32 depth 320 → 2×256×32) — **no win** while width stays ≥32 and depth>256 needs 2 depth tiles.  
Y as 640 × 16 → 2×512×16 = 2 blk — **no win**.  
Y as 1280 × 8 → 2×1K×8 = 2 blk — **no win**.  
**Root cause is width 64 forcing ≥2 width-tiles; only width ≤40 at depth ≤256 hits 1 blk for a full luma line.**

### C. Merge uram+vram
U+V read **same cycle** (two stream readers / two qwords).  
- Wide 80 × 128: ceil(128/32)=4 → **4 blk/slot chroma** = same as 2+2.  
- Interleave 160 × 64 single port: cannot supply U and V same cycle without 2nd port or 2-cycle serialize (present path wants both).  
**Rejected for product scanout without dual-port or serialize redesign.**

## PREREG post-PACK_PX5 (publish before parent re-map)

Assuming p720probe1 non-linebuf M10K stays constant:

| Quantity | Pre (measured line 192) | Post PACK_PX5 PREREG |
|----------|------------------------:|---------------------:|
| linebuf blocks | **192** (160×64 / 80×64 @ 2 each) | **96** (256×40 @ 1 each) |
| packer FIFO blocks | 0 | **+1..3 EST** |
| line-related | 192 | **97..99** |
| Δ line | — | **save 93..95** |
| Chip M10K if parent total 294 | 294 | **PREREG 201..204** (294 − 93..95) |
| Chip M10K if map-table-only 231 | 231 | **PREREG 138..141** (231 − 93..95) |

**ALM:** +200..400 EST pack/stream (unfitted).  
**Miss if:** Y still maps to 2 M10K/inst, or STA unpack path fails (post-strip slack was only +0.311 ns).

## Unit control
`tests/unit/test_line_buf_px5_rtl_sim.sh`  
`tests/unit/test_line_buf_slot_double_buffer_static.py` — asserts LINE_SLOTS==2*LINE_COUNT and PACK_PX5 generate.
