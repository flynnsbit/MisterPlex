# M10K layout correction (w-clock) — parent 2026-08-04

**Status:** Responds to parent correction that “1280 bytes = 1 M10K” is **false** for
legal Cyclone V M10K depth×width modes. Budget total **356 M10K free** (post-strip
197/553) is **unchanged** — only how far 356 goes for line buffers changes.

## Control for legal configurations

Parent listed handbook modes. **Independent control from our own fit** (not parent
authority): `remote_out/nostub-poststrip1/Plex.fit.rpt` **Fitter RAM Summary** contains
real instances at:

| Port A Depth × Width | Size (bits) | M10K blocks | Where |
|---------------------:|------------:|------------:|-------|
| **256 × 40** | 10240 | **1** | `ascal` `o_a_poly_mem` / `o_h_poly_mem` / `o_v_poly_mem` |
| 2048 × 32 | 65536 | 7 (entity audio_fifo) | `audio_fifo` |
| 2048 × 24 | 49152 | 5 | `ascal` line mem |
| **78 × 64** | 4992 | **2** each | `line_buf_ram` Y |
| **39 × 64** | 2496 | **2** each | `line_buf_ram` U/V |

So **256×40 is real silicon packing in this project** (ascal). Parent’s packed path exists.
**1K×8 is not observed** in this post-strip netlist’s line path; our present linebufs are
**64-bit**, not 8-bit.

Device bit capacity still **10,240 bits/block** (553 × 10240 = 5,662,720) — measured
summary bits vs implementation bits:

```
M10K blocks                         197 / 553 (36 %)
Total block memory bits             872,909 / 5,662,720 (15 %)
Total block memory implementation bits  2,017,280 / 5,662,720 (36 %)
```

Control: same `Plex.fit.rpt` Resource Usage Summary. Physical blocks bind; bit-% does not.

## Parent arithmetic — accepted with layout labels

| Layout | Bytes usable / M10K | Cost of one 1280×8 luma line |
|--------|--------------------:|-----------------------------:|
| Naive **1K × 8** | **1024** | **2 M10K** (1024+256; 2nd block 25% used) |
| Packed **256 × 40** (5 px/word) | **1280** | **1 M10K** fully used |
| Illegal “1280 × 8” single block | — | **not a legal config** |

**Architectural tax of 256×40:** 5-pixel granularity on ports, scaler phase, addressing.

## w-clock figures rechecked

| Claim (this lane) | Old | Layout assumed | Corrected | Class |
|-------------------|-----|----------------|-----------|-------|
| `plex_clk_status` measure path | **0 M10K** | flops/counters only | **0 M10K** | ESTIMATE → still 0 (no RAM arrays in RTL). ALM &lt;200 **UNVERIFIED** until fit |
| `present_content_window` V1 NN | 0 M10K | logic only | **0 M10K** | ESTIMATE (no mem) |
| Comment “1280 = one M10K luma line” | 1 M10K | **implicit 1280×8 illegal / packed without saying so** | **RETRACTED** | was wrong |
| Comment bilinear dual Y “≈2 M10K @1280” | 2 | ambiguous | **2–4 naive 8-bit; 2 packed 40-bit** | ESTIMATE only |
| T_copy +8.962 ms margin | n/a | n/a | **unchanged** — time budget, not M10K; still **PRE-REG arithmetic**, e2e OPEN | — |
| STA PRE-REG P1–P4 | n/a | n/a | **unchanged** (timing) | PRE-REG |

w-clock did **not** publish a “356 lines of 720p in BRAM” claim. No republish needed for that
error class beyond retracting the content_window comment.

## Measured present path M10K (post-strip fit — not estimate)

Source: `nostub-poststrip1` Fitter Resource Utilization by Entity:

| Node | Block bits | **M10K** | Notes |
|------|----------:|---------:|-------|
| `sys_top` | 872909 | **197** | device row |
| `emu` | 488384 | **138** | |
| `present_core` | 225280 | **103** | includes fstore+audio |
| `ddr_frame_store` | **159744** | **96** | **all line_buf_ram** |
| `audio_fifo` | 65536 | **7** | 2048×32 |
| `ascal` | 315488 | **43** | framework scaler |

### line_buf layout (measured, not handbook guess)

```
Y: 78 × 64 SDP dual-clock  → 4992 bits → 2 M10K each
U/V: 39 × 64                → 2496 bits → 2 M10K each
LINE_COUNT=8 → LINE_SLOTS=16 → 16×3=48 instances → 96 M10K
efficiency = 159744/(96×10240) = 16.3%
```

This is **qword (64-bit) DDR beat buffering**, not “one 8-bit pixel line per M10K”.
78 qwords × 8 = **624 bytes/line** (coded width on this fit — verify-scaler territory).

## 720p LINE_COUNT=16 scale — PREDICTION only

Product candidate enables `FRAME_W=1280`, `FRAME_LINES_16`.

| | Value | Class |
|--|------:|-------|
| Instances | 32 slots × 3 = **96** | derived from RTL |
| Y depth×width | **160 × 64** (1280/8) | derived |
| U/V | **80 × 64** | derived (4:2:0 half) |
| Logical bits | 655360 | arith |
| ceil(bits/10240) | **64** | **lower bound only** |
| Pred @ measured pack (2 M10K/inst) | **192 M10K** | **PREDICTION** |
| Δ vs post-strip 96 | **+96** | PREDICTION |
| Residual of 356 after Δ | **260** | if pred holds |

**Why 2 M10K/inst may still hold:** width 64 > max single-block 40 → ≥2 blocks for the
port; depth 160 ≤ 256 so depth may not buy a third block. **Unknown until fit** — could
be 2 or 4 per Y buffer if tool splits differently.

**Settle check:** next 720p fit entity row `ddr_frame_store` M10K + RAM Summary
depth×width×M10K for `gen_line[0].yram`.

## Implications for 720p presentation budget

- Free **356 M10K** still solid (parent fit control).
- **line_buf alone** may consume **~192 M10K** at LINE_COUNT=16 under current 64-bit
  shallow packing (**pred**), leaving ~164 before ascal growth / fabric DMA / OSD.
- Bit lower bound 64 is **not** a planning number — wire6 already proved 6× waste on this
  exact module class.
- Improving density means **wider legal modes with full depth use** or fewer slots — not
  assuming 1280 B/block at 8-bit.
- Packed 5 px/word is a real option only if present/scaler accept the granularity.

## What w-clock will not claim

- Fitted M10K for clk_pix-live candidate (no fit run).
- That 356 M10K “holds half a 720p frame as 8-bit lines” (false under naive layout).
- T_copy arithmetic as measured e2e.

