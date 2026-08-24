# Path — use both HPS DDR3 and the MiSTer SDRAM stick

**Status:** DEFER (recorded 2026-08-13). Not the live exclusive.  
**Why it exists:** User: the stick feels wasted while 720p unique fps dies on one DRAM.

## What we do today (`17dd3b56` / `DDR_FRAME_STORE`)

| Memory | Role |
|--------|------|
| **HPS DDR3** | FFmpeg decode, 2-slot cached ring, uncached `/dev/mem` publish to `0x30180000`, **and** FPGA present reads. One chip. Isolated FFmpeg **32.3 fps**; play unique **~15** (contention). |
| **SDRAM stick** | **Idle.** `DDR_FRAME_STORE` tri-states pins (`SDRAM_nCS=1` in `Plex.sv`). Not a second frame buffer. |

A deeper FIFO in Linux RAM does not create 24 unique frames if present+decode still share DDR3. 24 Hz beam ≠ 24 unique fps. Soft-skip ≠ PASS.

## The unused path

**Decode and ring stay on HPS DDR3. FPGA scanout / second bank lives on the SDRAM stick.**

- ARM never does 1.38 MB uncached stores into the reserved `0x30xx` hole for glass.
- FPGA HDMI line fetch comes off the **other** DRAM (16-bit stick, `SDRAM_CLK_142` / CL3 already in the 720p24 QSF for bring-up).
- 720p24 I420 dual-bank is ~2.8 MB; 24 unique fps both ways is ~66 MB/s — inside stick bandwidth if the B2-class controller is honest on silicon.
- Audio 48 kHz `/dev/MrAudio` stays on the FPGA; av-lock only works once unique video can follow.

This is **not** “buffer more of the same DDR3 path.” It is a **physical split**.

## Freddo (2026-08-13): triple buffer + DMA into the stick

Same split, named the way a DVD-core author would: **scanout lives in SDRAM VRAM**; ARM/DDR only *produces* frames; an FPGA DMA (not Linux `mmap` of the stick — pins are FPGA-only) copies unique I420 into a back buffer. Triple (display / hold / fill) so the beam never waits on FFmpeg or HPS DDR3.

**Format lock (user 2026-08-13, L56):** every SDRAM bank is **I420 / YUV420p**. RGB only on the way out to the beam (`clk_pix` / `PLEX_STORE_YUV_PIPE` class). Do **not** put RGB565 (or RGB24) in the stick — B2-era 320×240 RGB565 VRAM is retired. 3×720p I420 ≈ 4.15 MB; 3×720p RGB565 ≈ 5.5 MB and ~44 MB/s scan vs ~33 MB/s YUV. Half the bus is why Freddo kept YUV; we already ship that on DDR.

**What it actually buys:** isolated F=32 vs play unique ~15 is DDR3 *contention*. If `clk_pix` line fetch leaves HPS DDR, decode can run near the isolated number. 24 Hz beam still ≠ 24 unique; unique becomes “how fast can the copy engine fill the next bank.”

**What it does not buy:** `ebfe4a12` undriven `fabric_copy_visible` (needs a new RBF either way). P4-DISPLAY HDMI 640×480. MPEG-2.

**Time-mux (Freddo, user 2026-08-13):** do **not** run scan and fill as 66 MB/s at once. Stick is one client at a time:

| Phase | Who owns the stick | Rate |
|-------|--------------------|------|
| Active video | scanout only | **~33 MB/s** I420 1280×720×1.5×24 |
| HSYNC + VSYNC / blanking | FPGA DMA into the fill bank | peak × blanking fraction |

Freddo’s “33 MB should fit” is the **scan** budget. Isolated from decode on DDR3, that is a single 16-bit read stream. 142 MHz × 2 B = 284 MB/s peak; NeoGeo-class ~8 clk/word is ~35 MB/s useful — **just enough for scan, no fill leftover**. A page/burst controller is what makes 33 MB/s comfortable **and** leaves blanking for DMA.

Fill rate ≈ `blanking_fraction × DMA_peak`. One 720p I420 is 1.382 MB. Need ~33 MB/s *average* DMA for 24 unique.

| Totals | Blank fraction | Blank time @24 Hz | DMA peak for 24 unique |
|--------|----------------|-------------------|-------------------------|
| Our 720p24 **1312×762** (32 px HBlank) | **7.8%** | ~3.3 ms | **~425 MB/s** |
| CEA 720p24 **1650×750** | **25.5%** | ~10.6 ms | **~130 MB/s** |

So: **VBlank-only** was the wrong scare. H+V blank together is the window. Our **tight 1312×762** modeline is hostile (32-px HSYNC cannot take a 1920 B line: 1.44 GB/s). Fat porches (CEA-class) + burst DMA during every H/V blank **can** land 1.38 MB/frame if DMA_peak is ~130 MB/s (plausible on 142 MHz if not 8-clk/word). Per-line HBlank DMA on the current totals does **not** work.

**Design implication if this path is the exclusive:** widen blanking when the stick is VRAM; keep I420 in banks; RGB only on `clk_pix`; DMA only in blank; scan only in active. Capacity 3×1.38 MB is easy. NeoGeo word-at-a-time controller is **not** the DMA engine.

**Order:** still after Branch B, or if B unique FAIL / cannot close. New exclusive. Drop `DDR_FRAME_STORE` pin-tie-off. CL3 first (`docs/sdram-bringup.md`). Do not raise product `clk_sys`. `07f54d9f` stays.

## Order vs live exclusive

1. **Now:** `slot720p24f` Branch B — fabric-direct on **same** DDR3 (`clk_ddr` pull, skip CPU memcpy). One Quartus. May be enough for ≥23.9 unique.
2. **If B TIMING_OK but unique still FAIL, or B cannot close STA:** this path — new exclusive. Must **drop** the `DDR_FRAME_STORE` pin-tie-off and actually own `SDRAM_*`. Bring-up: `docs/sdram-bringup.md` (CL3 first). Do not raise product `Plex.qsf` `clk_sys`. 240/480 glass `07f54d9f` stays.
3. Do **not** start a second Quartus while `slot720p24f` is LIVE.

## Non-goals / dead

- Conf switch on `17dd3b56` — stick is not in that netlist.
- PL330 userspace (`CH_RDWR_ERR`).
- Host present-policy (2-slot ring / drop RequireReleased) as the 23.9 fix.
- Same-clock `stream_path` @ 24 MHz (Fmax 13.77).

Evidence: `Plex.sv` `ifdef DDR_FRAME_STORE` pin tie-off; W-meas F=32.31; play unique 15.2–15.47; `docs/sdram-bringup.md`.
