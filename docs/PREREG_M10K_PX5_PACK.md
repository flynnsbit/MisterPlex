# PREREG — packed 256×40 line buffers (w-nostub) BEFORE parent fit

Published before fit measurement. Control: parent fit leaf rows on `fit/720p-compose` with PACK_PX5.

## Handbook layouts (parent-corrected)
- Illegal: 1280×8
- Naive byte: 1K×8 = 1024 B → 1280-px line = **2 M10K**
- Packed: **256×40** = 10240 b = 1280 B → 1280-px line = **1 M10K**, 5 px/word
- Product prior path was DATA_W=64 qword linebufs (not 1K×8)

## Product baseline (measured 480p fit leaf rows)
- DATA_W=64, Y WIDTH=78 / C=39, **2+2+2 M10K/slot**, LINE_SLOTS=16 → **96 M10K**
- Layout class: 64b dual-clock M10K

## 720p EST @ LINE_COUNT=16 (LINE_SLOTS=32), CODED 1280 — PREREG

| Plane | Naive 64b layout | Naive M10K/slot | Packed layout | Packed M10K/slot |
|-------|------------------|----------------:|---------------|-----------------:|
| Y 1280×8 | depth 160×64 | **2** | **256×40** (256 words exact) | **1** |
| U 640×8 | depth 80×64 | **2** | 128×40 in **256×40** (50% util) | **1** |
| V 640×8 | same | **2** | same | **1** |
| **slot** | | **6** | | **3** |
| **×32 slots** | | **192** | | **96** |

**Shared packer word FIFOs (not ×slot):** Y FIFO 256×40 + U/V 128×40 ≈ **+1–3 M10K** (entity EST).
**Net PREREG line-related:** ~97–99 M10K vs naive 192 → **save ~93–95 M10K**.
Headline linebuf pool: **96 M10K packed** (same as 480p 64b pool size).

ALM packer+unpacker+stream: **EST +200..400 ALM** — UNKNOWN until fit.
Unpack/stream latency: registered (issue→capture waitcnt=2 on read; packer 1 word/clk out). No long comb on clk_sys (post-strip slack only **+0.311 ns**).

## 5-px granularity handling
- **Write:** `line_buf_px5_pack` folds 64b DDR beats → 40b words (LCM 40 B).
- **Read:** `line_buf_px5_stream_rd` L→R byte queue (beam only). Random src_x mid-line NOT supported; CROP_LEFT must be 0 (generate guard).
- **Phase extract:** `line_buf_px5_unpack` for dual-word window (phase=4,PPC=2 spans words); +1 reg stage.

## Miss criteria
- Fit Y leaf still ≥2 M10K under ramstyle M10K → packing miss
- STA setup slack on unpack/stream path < 0 → timing miss
- Skid overflow under continuous DOUT → need deeper SKID / FSM gap

## Unit control
`tests/unit/test_line_buf_px5_rtl_sim.sh` — pack 1280 continuous beats, stream readback, NEGATIVE naive first-5-of-8, unpack phase4 span.
