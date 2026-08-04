# PPC=2 downstream audit (w-clock) — source only

Product recipe: **MULTI + PPC=2 + clk_pix@29.7**, clk_sys@20.  
Question: does everything downstream of `present_pix_rate_match` / store N-wide ports handle PPC=2, and does DDR feed it?

## Chain (clk_sys → glass)

| Stage | Handles PPC=2? | Evidence |
|-------|----------------|----------|
| `ddr_frame_store` N-wide RGB | YES | `PX_PER_CLK` param default 1; ports `rd_r_n` width `PX_PER_CLK*8` (`ddr_frame_store.sv:35,48-51`). Hit path `pack_npx` loops `pxi < PX_PER_CLK` (`:506-508`). |
| Line fill / DDR | YES, not ×PPC | `Y_LINE_QWORDS = CODED_W/8` (`:86`). `DDRAM_RD` only on fill/poll path (`:1070,1109`). Present hit: `rd_miss_now` (`:340`) — no DDR on linebuf hit. |
| `present_core` MULTI | YES | `PRESENT_PPC = PRESENT_PX_PER_CLK` (`present_core.sv:193`); store `.PX_PER_CLK(FS_PX_PER_CLK)` (`:595-619`); `$error` if PPC∉{1,2,4} and if FRAME≠1280×720 (`:761-764`). |
| `present_npx_path` | YES | Group write to async_fifo; peak Mpix/s = F_sys×PPC (`present_npx_path.sv` header `:4-10`, param `:29`). Unpack 1 px/clk on `clk_pix`. |
| `present_pix_rate_match` | YES (SoT throttle) | Verilator: fires=148500 / 200k cy → 29.7 Mpix/s @20 MHz keep-pack (TB gate). Live beam uses FIFO backpressure; rate_match remains SoT. |
| ascal / CLK_VIDEO | under flag | `PRESENT_CLK_PIX_PLL` → CLK_VIDEO=clk_pix (Plex.sv). Async SDC group when enabled. **Post-fit STA for clk_pix@29.7 still UNKNOWN until parent fit.** |

## DDR feed vs PPC=2

- Average DDR read for one present of full I420: **B_frame = 1_382_400 B** → **33.1776 MB/s @24** regardless of PPC.
- PPC=2 doubles **linebuf extract rate** (2 unique RGB/sysclk during DE), not average DDR beats.
- Blackout cover @ PPC2/20M/1280: 8 lines = 256 µs FAIL vs 500 µs model; **16 lines = 512 µs PASS** — ABI floor enforces 16 on FRAME 1280×720 (`ddr_frame_abi_select.svh`).

## Residual risks (not closed without fit/sim)

1. **clk_pix domain STA** — first measurement is fit PRE-REG P3; no report yet → unknown.
2. **CDC FIFO depth under backpressure** — design intent OK; full-frame MULTI+PPC2+clk_pix e2e is w-osd gate.
3. **Concurrent HPS write + fabric fill** — average 66.36 MB/s R+W; peak port contention is w-mem bus-stall TB territory, not disproven by average arith.

## Non-claims

- Does **not** claim “720p works on device.”
- Does **not** ACK 3.0 B/clk_sys as DDR load (see AGREED_BW_720P.md / plex_bw_status).
