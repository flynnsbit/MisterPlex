# Phase 1a 320×240 I/P — fit path, lessons, successes (2026-08-24)

This note records what actually happened on the Phase 1a 320×240 I/P fit path for Shawn Henderson / MisterPlex on **2026-08-24 (CDT)**. Numbers and SHAs below are the official run facts. Do not invent replacements.

## Product

MisterCast’s end state is FPGA H.265 plus Plex A/V on MiSTer. H.264 Phase 1 is the on-ramp, not a second product.

Stay on the same **Plex_MiSTer** / **stream_path**. Do not start a second core.

Home tree: `~/Projects/MisterPlex/` (dirty local `main`).

Roles:

- **MisterFPGA Developer** — `/sys` and the RTL pipeline
- **FPGA Developer** — Quartus 17.0.2 map/fit/RBF
- **H264 Expert** — spec, CAVLC, vectors
- **CoS** — `FIT_GO`, cut order, `product_recon_ok`

## Fixture (official Phase 1a)

**Stream:** `tests/fixtures/h264_phase1a_p16skip/plex_phase1a_p16skip_320x240_12f.264`

- sha256 `9b49b7366c2be202ea2e26994c4f13d05dd82f3741fc3505a33e029e38e8632b`

**Gold:** `gold_12f_320x240.yuv`

- sha256 `ba3dea60d1b06c13073c9a893d62d27135eadc5c02bb736bc6f840d87f251f98`

**Walk:** I is 300/300 types `{1,3}`; 11 P frames each 300. The walker rejects types 1–4 except I `{1,3}` and `P_16x16+Skip`. There is no `P_16x8` / `P_8x16` RTL.

`plex_inter_p16` is **not** Phase 1a (MB5 is `P_16x8`). Do not treat 11×300 on that file as the bar.

## Gold / RTL rules that stayed

- `apply_itu_fix=false`. Do not change IDCT.
- **sat9:** two’s-complement saturate s16→s9 (−256..255), not wrap, not sat8.
- Phase 1 residual: CAVLC s16 → sat9 → dequant s9. Do not widen dequant in Phase 1.
- `status_in` goldens: `residual_csum` `0x14`, `recon_sig` `0x3b`.
- GOP12 Verilator: F0–F11 `MAE_Y=0` and `MAE_I420=0`, `chroma_zero=0` vs gold. Dump SHA matches gold.
- `nalu_scanner` is 8276 B with Walker `sl_rbsp_*` ports. Do not `git-checkout HEAD` if it drops those ports.
- `product_recon_ok` = `clip_gold_match` (`verilator public_flat_rw`, reset 0). **NEVER** assign `1'b1`. The TB pokes after I420 match. Hardware stays 0 unless the TB pokes.
- Integer `(0,0)` skip uses `pel_copy` (`mc_start` held low). Do not send skip through qpel.
- `clk_sys` 20 MHz, `CLK_VIDEO=clk_sys`. `ddr_bus_arbiter`: m0 present @ 90 MHz first, m1 bitstream @ 20 MHz via `async_fifo`. No m2 DPB until later CoS.
- Address walls: ascal `0x20000000`, rotate `0x24000000`, present `0x30000000`–`0x306FFFFF`. Stream ring `0x30100000` collides 720p bank0 (HEVC later must move stream to `0x30700000` first).
- No 640 DPB. No local 115200 picture arrays in `mb_ctrl`. Picture store is `stream_path` `dpb_pic[0:230399]` (2×115200 I420), sync M10K only.
- No `(* keep *)`. No `.stp` in QSF.
- Quartus-17: latch-then-slice (no nested func bit-select). Error **10170** was `blk_scan()[n]`. Error **10106** was 115200 for-copy (5000-iter cap) → `bank_sel` swap. Error **276003** / Info **276014** async RAM → registered Q.

## DPB wrap (correct shape)

`h264_dpb_one_ref_320` lives in `mb_ctrl`. There is no `cur_pic` / `ref_pic`.

- `bank_sel` toggles on `frame_done_pulse`; `have_ref<=1`; no 115200 copy/wipe; `idr_start` does not clear `have_ref`.
- Write: `mem_waddr = core_waddr + (bank_sel ? 115200 : 0)`
- MC read: `mem_raddr = core_raddr + (bank_sel ? 0 : 115200)` i.e. `~bank_sel`
- `mem_rdata` is `stream_path` 1-cycle registered Q. An extra flop is the N+1 tap bug.
- Stale executors reintroduced `cur`/`ref`; CoS killed that. Do not restore those arrays.

## Quartus map/fit table

FPGA Developer, Cyclone V **5CSEBA6**: **41910 ALM**, **112 DSP**.

| Run | Result | Notes |
| --- | --- | --- |
| plex-fit7 | map OK | sequential `u_luma` 51408 ALUT / 0 DSP; DSP 121/112; ALM est 103236; Hadamard 32 DSP |
| plex-fit8 | map OK | Hadamard 32→2 DSP (1 mul / 16-cycle); DSP 122; chroma grew V64+U8=72; `u_luma` 51398 |
| plex-fit9 | map OK | shared sequential chroma: one `u_chroma` 7 DSP; `u_luma` EXPLODED 206318 ALUT + 44 DSP; 1024:1 pred mux; ALM est 241713; DSP 127 |
| plex-fit10 | map OK | dest-write sequential did **NOT** undo mux; `u_luma` 202779 / 44 DSP; ALM est 239935 |
| plex-fit11 | map OK | sequential 6-tap qpel **HIT** luma target: `u_luma` 2061 ALUT / 0 DSP; DSP 83/112; ALM est 44075 (+2165) |
| plex-fit12 | map OK, fitter FAIL | `top_line` M10K 320×8; 276007 gone; ALM est 42673 (+763); `mb_ctrl` 21860 (was 22510); fitter 170012: 4239 LAB vs 4191 (+48 LAB); ALM used 41904/41910; OOM=NO |
| plex-fit13 | map+fit SUCCESS | `u_i16` 1468 ALUT (was 7232); ALM est 37833; Fit ALMs 36561/41910 (87%); DSP 83; `mb_ctrl` 18789 |
| plex-fit14 | assemble copied fit13 RBF | present-gate RTL on disk; rematch still required |

Framework DSP not muxed: ascal 23 + audio IIR 8 + present 1.

## Named cuts that worked (and why)

1. Sequential luma dest write was **not** enough. Combo `qpel_at(ox,oy)` indexing a 2D window unrolled 1024:1 muxes inside one interpolator.
2. **Fix:** one tap address per cycle, 6-tap sequential `(1,-5,20,20,-5,1)`. Registered `rdata <= ref_win[raddr_w]`. H/V reuse one FIR. Integer skip stays `pel_copy`.
3. Shared sequential chroma (U then V, one 8×8) saved DSP after Hadamard time-mux. Do not unroll luma while sharing chroma.
4. `top_line`: async combo neighbor read (276014) → sync M10K + `ST_NLOAD` +1 cycle. Saved ~650 ALUT; not enough for LAB packing.
5. Serialize I16: one selected mode, one row/cycle. All 4 modes kept (V/H/DC/Plane). 7232→1468 ALUT. Closed the fitter (48 LAB short → 87% ALM).
6. CBP Ram0/Ram1 stayed combo (CoS: do not convert). `async_fifo` 276014 left alone.

## Successes

- `FIT_GO=YES` for 320×240 I/P fit only (CoS after I420).
- fit13 RBF produced and verified:
  - path `~/Projects/MisterPlex/fpga/Plex_MiSTer/output_files/Plex.rbf` (gitignored `*.rbf`)
  - 4291028 bytes
  - sha256 `6faba2acec31f1f6bf26f5bb14c4f335b6bf473fb447bd094e83eb3d224083ce`
  - `CORENAME=Plex` live on MiSTer, sha256 match, no Enbrighten.
- GOP12 SPI parse on hardware: `has_stream=1` `has_idr=1` `sps=320x240` `nalu=15` last P.

## Glass / present (2026-08-24 evening, CDT)

HDMI/ascal does **not** read `dpb_pic`. `dpb_pic` is on-chip M10K. Glass is `present_core` `frame_store`.

`present_core`: Pattern=None + no frame → black.

Old gate: `fpga_allow = status[16] & product_recon_ok & ~ingest_dl & ~ddr_busy`.

`product_recon_ok=0` on silicon → black even with a good decode. `host_owns_fs` (F1/DDR swap) still blocks until Reset. O[16] FPGA present defaults Off.

`frames_out` is a decode counter; it was not a display gate.

Named split (`Plex.sv` **08:06:39 CDT**): `decode_frame_valid = recon_valid | (frames_out != 0)`; `fpga_allow` uses that instead of `product_recon_ok`. `product_recon_ok` stays the `clip_gold_match` TB bit. Never `1'b1`.

`stream_path` exports `frames_out = use_mb ? mb_frames : stub_frames_w`.

CoS 08:48 CDT: the first fit14 RBF was a copy of fit13 (same sha256 6faba2ac). Studio Plex.sv still has decode_frame_valid at L625-626 (mtime 08:06:39). Do not revert. A rematch of that tree is required for a new RBF.

## Do-not-repeat

- Do not generate-all-then-mux (`pred[256]` or `qpel_at` combo 2D window).
- Do not combo-index large arrays with variable `ox`,`oy`.
- Do not reintroduce `cur_pic`/`ref_pic` or grow `stream_path` RAM / `FRAME_W=640`.
- Do not put `(* keep *)` back.
- Do not freelance ALM/DSP cuts; CoS names them.
- Do not start Quartus from the RTL agent; one rematch from FPGA Dev after CoS GO.
- Do not drop Walker `sl_rbsp` ports.
- HEVC parked: no instantiate now; m2 DPB `0x30800000` later; CABAC on `clk_ddr` 90 MHz not `clk_sys`.

## Key files

- `rtl/h264_mb_ctrl.sv` — walker, residual seq, DPB wrap, I16/P16/Skip, `top_line` M10K, `product_recon_ok`
- `rtl/h264_dpb.sv` — sequential 6-tap `u_luma`, shared `u_chroma`
- `rtl/h264_intra_pred.sv` — sequential `u_i16`
- `rtl/h264_i16_dc_hadamard.sv` — 1-mul 16-cycle
- `rtl/stream_path.sv` — `dpb_pic` 230400 M10K, `frames_out` export
- `Plex.sv` — present gate split, O[16], `host_owns_fs`
- `rtl/h264_inter_pred.sv` — Q17 flatten (`decode_stub` diag path)

## Where we are

fit13 RBF is live on MiSTer (`Plex.rbf`, sha256 match, GOP12 SPI parse). The first fit14 assemble reused the fit13 database (same sha256). Present-gate RTL is on disk and needs a real rematch for glass. `product_recon_ok` is still 0 on hardware.
