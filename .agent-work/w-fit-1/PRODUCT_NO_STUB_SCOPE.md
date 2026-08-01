# PRODUCT_NO_STUB / dark-silicon — corrected argument (no fit requested)

**Shipping RBF:** md5 **`8fdf440f`**  
**Fit report (must cite path):**  
`fpga/Plex_MiSTer/remote_out/fit-t7b-prog480/Plex.fit.rpt`  
(= `/home/flynnsbit/mplex-builds/fit-t7b-prog480/Plex_MiSTer/output_files/Plex.fit.rpt`)  
**Not this design:** ALM~21,021 / DSP **74** fits (e.g. product-wire6 `14eaeff3`) — different RBF.

## Withdrawn (do not repeat)

| Withdrawn claim | Why false |
|-----------------|-----------|
| `host_owns_fs` latches on first ARM DDR swap → `stub_allow=0` for session | Under `DDR_FRAME_STORE=1`, `assign ddr_swap=1'b0`. Product doorbell ≠ `ddr_swap`. Latch only via SPI `f1_swap`. |
| “Latched for the session” | `reset = RESET \| status[0] \| buttons[1]` is runtime-reachable. |
| “No CAVLC entropy decode in fabric” | Inline probe: `slice_hdr_parser` emits `residual_tc`/16 coeffs into `decode_stub`. Standalone `h264_cavlc_*` modules are unfitted; **capability is scope-limited, not absent**. |
| “RAM blocks are the binding constraint” (slogan) | 84% blocks hold 53% bits — shallow packing. Block-bound for many small buffers; bit-headroom ~2.66 Mbit for deep stores via consolidation. DSP 44/112 is not binding. |

## Correct dark-silicon argument (stronger)

Under shipping `DDR_FRAME_STORE=1`:

1. `present_core.sv` compiles `ddr_frame_store` only.
2. The **only** `.wr_en(fs_wr_en)` in that file is on legacy `frame_store` inside `` `else ``.
3. ⇒ **`fs_wr_en` / `fs_swap` have no consumer.** Stub write port is **physically unconnected** in idle, boot, and playback. No pre-first-swap window.
4. `Plex.sv` `host_owns_fs` / `stub_allow` / `_keep_hybrid_product` are **dead/inert for HDMI** (safety gate that gates nothing; anti-prune observer).

**Reclaim:** ~**9,217 ALM + 268 M10K** display-dark on `8fdf440f` entity rows. Soft non-dark: bitstream reader `bus_want` poll, telemetry, fit cost.

## Method rule (hierarchy)

Zero rows alone ≠ absent (flattening). Zero rows + zero instantiator rows = module unreachability. Even that ≠ capability absence (inline reimplementation). Scope claims need source lines.

## PRODUCT_NO_STUB (scaffolding — default OFF)

- `stream_path.sv` `` `ifndef PRODUCT_NO_STUB `` keeps instance; else zeros ports.
- QSF macro **commented**. Research must stay buildable — **do not delete**.
- Pre-register Tier A vs `8fdf440f`: ALM ~14,368 · M10K ~197 · DSP ~43 · free M10K ~356.
- No new SDC false paths. **No fit slot requested.**

## Gates (true rc)

See latest shell after correction commit.
