# Phase 3 — FPGA decode path (research + plan)

## Goal

**Product today (shipping RBF `8fdf440f`):** ARM (FFmpeg) decodes H.264; the FPGA owns **DDR frame store + vsync present + audio FIFO**. That is **not** a full H.264 implementation in fabric.

**Honest long-term case for fabric decode is direct-play** (eliminate the PMS transcode rung; handle high-bitrate sources the dual-A9 cannot sustain). It is **NOT CPU relief**: measured H.264 decode threads are only ~6 %onecpu while the *scaler* is ~50 %onecpu — moving entropy/IQ/IDCT into fabric would not fix the ARM budget the way the old premise claimed. Do not resurrect “fabric decode for ARM idle” as motivation.

Phase 2 remains valid bootstrap: FFmpeg → `/dev/fb0` + `/dev/MrAudio`.

---

## Shipping fabric H.264 inventory (authoritative)

**One-line answer for “do we have full H.264 in the FPGA?”:** **No.** Fabric has partial reconstruct/MC/DPB/deblock **blocks** under `decode_stub`, plus NAL/SPS/PPS/slice-header **parsers**, but **no CAVLC entropy decode in fabric**, so the FPGA **cannot extract coefficients from a real bitstream on its own**. Product pixels are ARM-decoded YUV written over DDR.

### Product ownership — why fabric recon cannot present (DDR_FRAME_STORE)

Shipping product builds with **`DDR_FRAME_STORE=1`**. Under that macro the dark-silicon claim is **stronger** than the SPI-era `host_owns_fs` story alone:

1. **Product pixels never use the stub `fs_wr_*` path.** `present_core.sv` under `DDR_FRAME_STORE` instantiates `ddr_frame_store` (doorbell + HPS DDR banks) and **ties `fs_wr_ready=1` without connecting `fs_wr_en` / `fs_wr_pixel` / `fs_swap` to the store**. Those ports only feed the legacy `frame_store` in the `#else` branch. Quoted:

```systemverilog
// present_core.sv — DDR_FRAME_STORE branch
assign fs_wr_ready = 1'b1;
// ...
ddr_frame_store #(...) fstore ( /* rd_*, start_req, bank_sel, DDRAM_*, vsync — no wr_en */ );
// #else legacy frame_store takes .wr_en(fs_wr_en), .swap_banks(fs_swap), ...
```

2. **`ddr_swap` / `ddr_wr_*` are compile-tied to 0** in `Plex.sv` when `DDR_FRAME_STORE` is set. So `host_owns_fs` **cannot** latch on a product DDR doorbell — only on SPI `f1_swap` (ioctl frame download). The earlier shorthand “first ARM DDR swap latches host_owns_fs” is **false under the shipping macro**; product ARM frames enter via `ddr_frame_store` doorbell inside `present_core`, not `ddr_swap`.

```systemverilog
// Plex.sv — DDR_FRAME_STORE
assign ddr_wr_en = 1'b0;
assign ddr_swap = 1'b0;
// ...
else if (f1_swap | ddr_swap) host_owns_fs <= 1'b1;  // ddr_swap constant 0
wire stub_allow = ~host_owns_fs & ~ingest_dl & ~ddr_busy & product_recon_ok_w;
```

3. **`product_recon_ok` resets 0** and only sets on the stub’s pure I-slice hybrid path (`decode_stub.sv`). Product STREAM=0 playback does not open that path. Even if `stub_allow` were 1, (1) still blocks product pixels.

4. **Idle/boot screen** is ARM `paintIdle` → HPS publish → `ddr_frame_store`, not stub paint.

**Verdict:** `decode_stub` **cannot affect product HDMI pixels** in the shipping DDR configuration. It is still **not free silicon**: it consumes fit resources, and `stream_ddr_enable=1` lets `ddr_bitstream_reader` **poll-assert `bus_want`** (arbiter m1) even with an empty ring — a soft DDR tax. Status/LED/telemetry still observe stream counters.

`(* keep = 1 *) wire _keep_hybrid_product = product_recon_ok_w | …` is a **synth keep only** so hybrid handoff nets are not pruned; it is not a pixel path. Removing the stub under `PRODUCT_NO_STUB` drives those nets to 0; the keep OR folds away. It does **not** require keeping the stub for product correctness.

**`decode_stub` ~9.2k ALMs / 268 M10K (~39% ALMs of the device under this fit’s stub row) is diagnostic/experimental fabric, not product video.** See `PRODUCT_NO_STUB` below for reclaim.

### What survived the shipping fit vs what did not

| Class | Meaning |
|-------|---------|
| **PRESENT** | Entity has a hierarchy row in `Plex.fit.rpt` (fitted into `sys_top`) |
| **ABSENT / stripped** | Zero hierarchy rows — unreachable from `sys_top` (see mechanism below) |
| **FLATTENED into parent** | Instantiated in source but no separate hierarchy row; logic absorbed into parent ALMs |

**`h264_hybrid_mb_own` is flattened into `decode_stub`**, not stripped. Source instantiates it (`decode_stub.sv` `u_hybrid_mb`); it is a small comb leaf (`always @*`). Measured `decode_stub` residual own ALMs (stub total minus direct child rows, including `lpm_divide` / `altsyncram`) = **1922.1**. Do **not** report hybrid as absent.

**Mechanism for stripped entropy/intra (verified on `files.qip` + instantiators):**

- In `files.qip` but **not fitted:** `h264_cavlc_residual.sv`, `h264_intra_pred.sv`, `h264_inter_pred.sv`, `h264_decode_core.sv`, … — compile units exist, but nothing on the live `sys_top → stream_path → decode_stub` path **instantiates** them. Quartus drops unreachable design units.
- **Not in `files.qip` at all:** `h264_decode_top.sv`, `h264_decode_skeleton.sv`, `h264_intra_nb_ctx.sv` (never enter the project).
- CAVLC (`h264_cavlc_residual_block`) is only instantiated under `h264_decode_core` / `h264_decode_skeleton`. Core is in the QIP but **uninstantiated** from the product top; skeleton is not in the QIP. **⇒ no CAVLC entropy decode in fabric.**
- Intra predictors live under `h264_decode_top` / skeleton only — same unreachability.
- Note: `h264_iq_idct_4x4.sv` **is** product-reachable; its entities are named `h264_dequant4x4` / `h264_idct4x4` / `h264_recon4x4` (not an entity called `h264_iq_idct_4x4`).

### Machine-checked table (do not hand-edit ALMs)

Regenerate after a new BUILD_OK fit:

```bash
python3 scripts/check_fabric_decode_inventory.py \
  --fit-rpt path/to/Plex.fit.rpt \
  --fixture tests/fixtures/fabric_decode_inventory.json \
  --emit-table
# paste between markers; then:
make fabric-decode-inventory FIT_RPT=path/to/Plex.fit.rpt
```

Baseline below is shipping RBF **`8fdf440f`** (`fit-t7b-prog480`). Gate fails if the doc PRESENT rows disagree with the fit.

<!-- FABRIC_DECODE_INVENTORY_BEGIN -->
| fit totals | ALM **23,585** / 41,910 · regs **22,479** · RAM blocks **465** / 553 · DSP **44** / 112 · block bits **2,997,709** / 5,662,720 |

| entity | ALMs needed | status |
|---|---:|---|
| `stream_path` | 12268 | PRESENT |
| `decode_stub` | 9216.9 | PRESENT |
| `ddr_bitstream_reader` | 541 | PRESENT |
| `bitstream_fifo` | 33.7 | PRESENT |
| `present_core` | 3604.4 | PRESENT |
| `ddr_frame_store` | 3501.3 | PRESENT |
| `h264_dequant4x4` | 2876.3 | PRESENT |
| `h264_dpb_ref_commit` | 1290.7 | PRESENT |
| `h264_deblock_mb` | 962.7 | PRESENT |
| `h264_idct4x4` | 895.8 | PRESENT |
| `h264_mc_block` | 518.3 | PRESENT |
| `h264_mv_pred_part` | 445.3 | PRESENT |
| `h264_mv_pred_16x16` | 369.5 | PRESENT |
| `h264_mc_luma_qpel` | 348.6 | PRESENT |
| `h264_recon4x4` | 306.1 | PRESENT |
| `h264_dpb_one_ref` | 299.2 | PRESENT |
| `h264_mc_chroma_epel` | 168.2 | PRESENT |
| `h264_dpb_mb_write_addr` | 40.7 | PRESENT |
| `h264_dpb_i420_addr` | 39.3 | PRESENT |
| `h264_deblock_writeback_ctrl` | 11.2 | PRESENT |
| `decode_stub` residual (own + flattened leaves e.g. `h264_hybrid_mb_own`) | 1922.1 | FLATTENED_INTO_PARENT |
| `h264_cavlc_residual` | 0 | ABSENT_OK |
| `h264_cavlc_residual_block` | 0 | ABSENT_OK |
| `h264_intra_pred` | 0 | ABSENT_OK |
| `h264_intra4x4_pred` | 0 | ABSENT_OK |
| `h264_intra16x16_pred` | 0 | ABSENT_OK |
| `h264_inter_pred` | 0 | ABSENT_OK |
| `h264_decode_core` | 0 | ABSENT_OK |
| `h264_decode_top` | 0 | ABSENT_OK |
| `h264_decode_skeleton` | 0 | ABSENT_OK |
| `h264_intra_nb_ctx` | 0 | ABSENT_OK |
<!-- FABRIC_DECODE_INVENTORY_END -->

Remaining budget on this fit (device − used): **ALM 18,325** · **DSP 68** · **88 RAM blocks** free (RAM at 84% is the binding constraint — always quote **block** counts, never bit-% “free”).

### What it would take for fabric decode to produce product pixels

Minimum product path (estimates labeled **estimates** — not a fit):

1. **CAVLC entropy** reachable and instantiated on the live top (`h264_cavlc_residual_block` under a wired `h264_decode_core` or equivalent) — without this, no coeffs from real bitstreams.
2. **Intra prediction** reachable (`h264_intra4x4` / `h264_intra16x16` + nb ctx) for I/IDR.
3. **Wire existing** dequant/IDCT/recon/MC/DPB/deblock (already PRESENT) to that entropy/intra front-end instead of stub stimulus.
4. **Product pixel path for fabric recon** under `DDR_FRAME_STORE`: either wire a fabric→DDR present path into `ddr_frame_store` (new), or run a non-DDR `frame_store` product build. Today’s `stub_allow`/`fs_wr_*` mux **does not reach** the product store — fixing `host_owns_fs` alone is **not** enough on the shipping macro set.
5. Inter/P-slice completeness, CABAC policy, and bitrate/direct-play product rules — larger than (1–4).

| Resource | Headroom now | Rough add for (1–2) Baseline CAVLC+intra (**estimate**) | Risk |
|----------|-------------:|--------------------------------------------------------:|------|
| ALM | 18,325 | +2k–8k (entropy+intra+glue; wide band until map) | ALM OK on paper |
| DSP | 68 | ~0 if shift-add dequant stays | OK |
| **RAM blocks** | **88** | **+10–40** for coeff/nb/line state (**estimate**) | **Binding** — 84% already |

A skeleton-only map (`h264_decode_skeleton`) is **not** product evidence; it is off the shipping QIP on purpose.

Gate: `tests/unit/test_fabric_decode_inventory.sh` · `make fabric-decode-inventory FIT_RPT=...`.

---

## PRODUCT_NO_STUB — reclaim dark decode budget (scoped, unfitted)

**Motivation (measured, not the old premise):** ARM cost in 240p/480p playback is dominated by the **scaler** (~50 %onecpu inside ffmpeg), not H.264 decode (~6). Highest-value offload is **fabric scale/geometry in `present_core`**, which needs M10K headroom. `ascal` proves a fabric scaler class is ~1,936 ALM / 43 M10K / 23 DSP. Free M10K today is **88** — binding. Reclaiming `decode_stub` is the enabler.

**Do not delete decode RTL.** Research/STREAM builds leave `PRODUCT_NO_STUB` undefined so `decode_stub` stays in `files.qip` and fully gated.

| Tier | Macro | What drops from product top | Predicted post-fit (**estimate**, baseline `8fdf440f`) | Free after |
|------|--------|-----------------------------|--------------------------------------------------------|------------|
| **A** (default product candidate) | `PRODUCT_NO_STUB=1` | `decode_stub` instance + children (DPB 256 M10K, dequant/IDCT/MC/…) | ALM **~14,368** used (−9,217) · M10K **~197** (−268) · DSP **~43** (−1) | ALM **~27.5k** · M10K **~356** · DSP **~69** |
| **B** (optional) | `PRODUCT_NO_STREAM_PATH=1` | whole `stream_path` (stub + parsers + `bitstream_fifo` 32 M10K + reader) | ALM **~11,317** (−12,268) · M10K **~162** (−303) · DSP **~42** (−2) | ALM **~30.6k** · M10K **~391** · DSP **~70** |

Arithmetic check on baseline DPB: 2,097,152 bits / 256 M10K = **8,192 bits/block** (M10K). Free now: 553−465=**88**.

**Source hook (Tier A):** `stream_path.sv` wraps `decode_stub` in `` `ifndef PRODUCT_NO_STUB `` / `` `else `` constant-0 assigns on stub outputs. QSF ships with the macro **commented** until parent grants a fit that pairs reclaim with w-geom scaler cargo:

```tcl
# set_global_assignment -name VERILOG_MACRO "PRODUCT_NO_STUB=1"
```

**SDC:** no new `set_false_path`. Existing narrow async_fifo exception unchanged.

**Pre-register (publish misses after first PRODUCT_NO_STUB fit):**

| Metric | Baseline `8fdf440f` | Tier A prediction | Tier B prediction |
|--------|--------------------:|------------------:|------------------:|
| ALM used | 23,585 | ~14,368 | ~11,317 |
| M10K used | 465 | ~197 | ~162 |
| DSP used | 44 | ~43 | ~42 |
| setup min | +0.333 | ≥0 (unknown until STA) | ≥0 |
| hold min | +0.245 | ≥0 (unknown until STA) | ≥0 |

If Tier A M10K drop is **≠ ~268**, that is a finding (something else held the DPB or packing differed) — not rounding.

**Static gate:** `tests/unit/test_product_no_stub_dark_silicon.sh` (red-before-green on scaffolding + DDR `fs_wr` disconnect).

**No exclusive fit requested** from this write-up. Scaler (w-geom) should ride the same fit as Tier A.

---

## Profile MiSTerPlex-1 (initial)

| Field | Target |
|-------|--------|
| Video | H.264 Baseline/Main, progressive |
| Resolution | ≤ 720p30 or 480p60 (raise after timing) |
| Audio | AAC-LC stereo or PCM s16le @ 48 kHz |
| Container | MP4/fMP4; ARM demux → elementary NAL + audio |
| Bitrate | Soft cap; PMS weak ladder on direct-play fail |

## Attack order

1. **ARM demux + elementary feed** into FPGA FIFO (clean boundaries; reuse Phase 2 resolve).
2. **Frame store in SDRAM** (triple buffer unique frames) + present engine already proven (Phase 1 cadence).
3. **H.264 decode soft-core / open IP** sized for Cyclone V:
   - Evaluate open cores (e.g. hardh264-class / simplified Baseline pipelines) for ALM/BRAM cost.
   - Fallback: hybrid ARM NEON decode of intra-only profiles is temporary only.
4. **Audio FIFO in present domain** (replace dual-process MrAudio pump for lip-sync ≤±40 ms).

## Memory map (Phase 3)

| Resource | Role |
|----------|------|
| BRAM | NAL/entropy FIFOs, linebufs, audio ring |
| SDRAM | Decoded unique frame store (console VRAM pattern) |
| DDR3 | Stream buffers, ARM↔FPGA bulk, large modes |
| FPGA | **Today:** DDR frame store + cadence present + AUDIO_L/R; partial H.264 blocks under `decode_stub` (not product pixels). **Future direct-play:** entropy+intra+… when wired |
| ARM | **Today:** GDM/companion/resolve + **FFmpeg H.264 decode** + DDR publish. Future demux-only only after fabric product path exists |

## Intermediate milestone (before full H.264 IP)

**RGB frame store on FPGA** (still FFmpeg decode on ARM; present is FPGA vsync):

```text
Phase 3.0 (in tree now):
  F1 / ioctl raw RGB565 320×240 → frame_ingest → dual-bank BRAM frame_store
  present_core mux: Bars | Frame store (OSD O[9])
  cadence + tone unchanged

Phase 3.1 (done this fire):
  `fpga_spi` + `push_frame` — HPS SPI FIO_FILE_TX → frame_ingest
  PRESENT=fb0|fpga|both conf; dual present throttles SPI to every 4th frame
  HW: push_frame 153600B in ~99–127ms; continuous frame_tx during testsrc play
  Auto-present: frame_store shows as soon as has_frame (O[9]=Force bars for debug)

Phase 3.2 (done):
  `audio_fifo` + `audio_ingest` — F2 s16le stereo @48k → present-domain ring
  Prefers FIFO over OSD tone; underrun sticky; HW push index=2
  Continuous misterplexd: MrAudio + F2 SPI chunks (8 KiB = DEPTH 2048 samples)
  audio_ingest **append-mode** (no per-chunk flush); status[10] flush on play start
  M10K fit: ALMs ~19%, block memory ~51%, RAM blocks ~67% (DEPTH 2048)
  HW: multi-chunk F2 OK (~17 ms/16 KiB); live play f2==audio bytes
  `tests/hw/test_f2_append.sh`

Phase 3.3 scaffold (HW-green):
  F3 ioctl → stream_ingest (append) → bitstream_fifo 32 KiB M10K → nalu_scanner
  Scanner counts annex-B start codes (00 00 01 / 00 00 00 01); LED on has_stream
  ARM: `sendBitstreamChunk` / push_frame --index 3; `scripts/gen_test_annexb.py`
  HW: `tests/hw/test_f3_bitstream.sh`; unit `test_annexb_count`
  Fit: block mem ~56%, RAM blocks ~73% (bitstream 262144 bits / 32 M10K)
  Core status readback (UIO_GET_STATUS 0x29 / status_in) — see 3.3b layout below
  `push_frame --status` dumps fields; HW test asserts nalu≥4 after F3 push

Phase 3.3b (done this fire — decode_stub + typed NAL + STREAM path):
  nalu_scanner classifies SPS/PPS/IDR/slice; vcl_pulse on types 1/5
  decode_stub: on VCL → paint 320×240 RGB565 diagnostic → frame_store swap
    (green border=IDR, cyan=P; top strip encodes type/idr_count)
  Same write interface as future Baseline IP (wr_en/pixel/reset/swap)
  Status layout:
    [0] has_frame [1] has_audio [2] has_stream [3] underrun
    [4] has_idr [5] stub_busy
    [15:8] last_nal_type  [31:16] nalu_count  [47:32] fifo_level
    [55:48] idr_count  [63:56] stub_frames[7:0]
    [95:64] bytes_seen  [127:96] bytes_in (historical name; later status overlays
    reuse this field, so in current ARM parsing `bytes_in=4` means `nalu_count=4`,
    not four delivered bytes)
  ARM: STREAM=1 conf → second ffmpeg copy-demux annex-B → F3 chunks
  HW: `tests/hw/test_f3_decode_stub.sh` (has_idr + stub_frames + has_frame)

Phase 3.3c (done this fire — SPS RBSP parse + real Baseline vector):
  Host: `host/libmisterplex/h264_sps.hpp` + `test_sps_parse` (320×240 profile=66)
  FPGA: `sps_parser` multi-cycle bit-walker (ue/u); nalu_scanner captures SPS + EPB strip
  Status: [6] sps_valid; [95:80] sps_width; [79:64] sps_height (bytes_seen dropped)
  Scripts: `gen_test_annexb_real.py` (ffmpeg Baseline annex-B)
  HW: `tests/hw/test_f3_sps.sh` — real F3 push → sps_valid + sps=320x240 + has_frame
  Still not a decoder — dimensions only; decode_stub still paints diagnostics on VCL

Phase 3.3d (done this fire — PPS + I-slice header + MB-grid stub):
  Host: `h264_nal.hpp` PPS + slice_header; `test_slice_hdr` (type=7 I/IDR, CAVLC)
  FPGA: `pps_parser` (CAVLC-only), `slice_hdr_parser` (first_mb/type/pps/frame_num/idr_pic)
  SPS exports log2_max_frame_num, poc_type, mb_width/height
  nalu_scanner captures SPS/PPS/slice-hdr RBSP (slice cap 32B + EPB)
  decode_stub: MB grid overlay from SPS; I-slice green grid
  Status: [7] pps_valid; [63:56] slice_type (was stub_frames)
  HW: `tests/hw/test_f3_slice_hdr.sh` — sps+pps+slice_type=7 + has_frame
  Still not residual decode — headers only; CAVLC/IDCT next

Phase 3.3e (done — slice QP/deblock + first mb_type probe):
  Host/FPGA: full slice header; **IDR `dec_ref_pic_marking` (2 flags) required before qp_delta**
  Real baseline golden (corrected): mb0=0 (I_NxN), slice_qp=25 (init 23 + delta 2)
  Status: first_mb_type [55:48], slice_type [63:56], slice_qp in [47:40]
  HW: `tests/hw/test_f3_mb0.sh` — mb0 + qp + sps+pps+has_frame

Phase 3.3f (done — first-MB CAVLC residual token probe):
  Host: `h264_cavlc.hpp` residual_block + first residual probe (I_NxN or I16)
  FPGA: after I_16x16 mb_type + mb_qp_delta, CAVLC nC=0 coeff_token + T1 signs
  Status: res_ok / res_tc / res_t1 (I16 path; I_NxN first MB may leave res_ok=0 until extended)
  Full slice residual + inv quant/IDCT/recon still next

Phase 3.3g (done — first-MB inv-quant recon stub):
  Host: FFmpeg-table CAVLC residual_block; invQuantHadamardDc4x4; reconFirstI16DcMeanY
  FPGA: residual_ok paints top-left 16×16 recon-gray (128+tc) in decode_stub

Phase 3.3h (host I-slice recon — **MB0/root-cause evidence backed; frame-wide green retired**):
  **Root causes fixed this arc:**
    1. I_16x16 missing `intra_chroma_pred_mode` → walk desync
    2. I4 MPM: unavailable neighbour → pred=DC(2)
    3. I4 top-right sample availability (scan order / `lumaReady`)
    4. I16 DC Hadamard butterfly = FFmpeg `ff_h264_luma_dc_dequant_idct`
    5. **I16 DC scan layout:** CAVLC zigzag must be loaded with FFmpeg `TRANSPOSE(zz[i])`
       into the Hadamard (column-major). ITU raster alone mapped scan-pos 2 → vertical
       frequency; FFmpeg places it at input[1] → gold top/bot pattern. Fixed
       `invQuantHadamardDc4x4` → retired scoreboard once claimed
       **maeY=0 exact 300/300**. That frame-wide green is no longer accepted
       as product evidence because it was measured through RGB565/presentation
       diagnostics with border masking.
    6. **Chroma DC pred rounding:** TL/BR 4x4 must use single-sum `(sA+sL+4)>>3`, not
       nested avgs. Fixed `predChroma8` mode 0 → **maeU=maeV=0** (full YUV exact).
  Host: FULL residual walk exists, but the former full-frame **maeY=U=V=0**
        status is **UNSUBSTANTIATED** as product decode evidence. Native-I420
        scoreboard evidence replaces it: the old MB0 phantom (`got=142 ref=65`
        through RGB565) is clean (`got=73 ref=73 abs=0`). The first native-I420
        full-frame ratchet numbers (624×480 `510/1170`, 320×240 `155/300`,
        wcap `207/300`) are also retired because the reference silently kept
        in-loop deblocking enabled while RTL output was no-deblock. Full-frame
        green must cite native-I420 plane evidence with loop-filter state
        declared/refused in provenance, not RGB565 presentation output or a
        silent FFmpeg default.
  FPGA: ST_CHRPRED (I16) + ST_I4MODE/ST_CBP (I_NxN); gray I16 HW green earlier
  **Next was 3.3i (now done):** host SPI present + STREAM wire — see below.
    - Optional deblock filter (not needed for no-LF gold)
    - FPGA full MB residual + inv quant/IDCT path (extend beyond first-residual probe)

Phase 3.3i (done — host I-slice recon → F1 in misterplexd STREAM path):
  STREAM=1: annex-B demux → retain SPS/PPS → IDR/I VCL → `recon::reconISlice`
    → I420/YUV420p → **F1** `sendYuv420pFrameDdr` (frame_store)
  Still feeds **F3** for FPGA decode_stub / residual probes (diagnostic)
  FFmpeg RGB: fb0 fallback only; F1 frame-store sends remain YUV420p DDR-only
  PRESENT=both: FFmpeg continuous fb0 + recon F1; companion :3005 unchanged
  Logs: `recon frame ok #N WxH mb=…`; session `recon=N`
  Unit: `test_cavlc_dc` FULL walk + recon host check; ARM `-I host`.
  Treat any historical `maeY=U=V=0` wording from this path as retired unless
  paired with native-I420 plane provenance.
  **HW lab 192.168.1.183 (this fire):**
    - Baseline smoke: `recon_ok=3 recon_fail=0 present=3` f1ms≈170
    - High/CABAC `test.mp4`: fail_reason=`cabac` → fb0 fallback continues when enabled
    - Legacy manual RGB565 F1 push is retired; use DDR YUV420p frame pushes
    - F3 residual: `res_ok=1 res_tc=8 res_t1=3` (test_f3_residual.sh green)

Phase 3.3j (done this fire — hybrid present + residual-ready stub paint):
  **Product path (hybrid):** host I-slice recon owns F1 present (3.3i). FPGA keeps
  NAL/SPS/PPS/slice/residual **status** + F3-only diagnostic paint. Do not replace
  host recon until FPGA mae is competitive.

  **Fit (Cyclone V 5CSEBA6, 3.3j RBF 2026-07-24):**
    ALMs ~21% (8.8k/41.9k) — logic headroom for more CAVLC
    Block mem bits ~56%, **M10K 73% (405/553)** — BRAM is the hard limit
      (frame_store dual-bank + bitstream 32 KiB + audio + sys/ascal)
    DSP ~33%. Full I-slice residual walk + inv quant/IDCT/pred + pixel write
    would need substantial extra BRAM (coeff buffers, neighbour rows) and is
    deferred; first-MB probe stays in the 48B slice RBSP capture.

  **FPGA changes this fire:**
    1. `host_owns_fs` sticky after any F1 swap — decode_stub cannot wipe STREAM recon
    2. `decode_stub` waits for residual_ok/slice_valid **rising** (or timeout) so MB0
       gray (128+tc) latches this NAL's probe, not a stale sticky residual
    3. `slice_hdr_parser` clears residual/valid on `cap_clear` (new VCL capture)
    4. Residual token path unchanged (I_NxN tc=8 t1=3 / I16 tokens) — HW-green

  **RBF rebuild (this fire):** Quartus fit OK (ALMs 21%, M10K 73%); flow race killed
    asm once — assembler re-run produced `Plex.rbf` (3.42 MiB). Deployed lab;
    `test_f3_residual.sh` green on new core. Hybrid F1+F3 status smoke OK.
  **Was open → 3.3k residual:** CAVLC levels/runs for first residual; inv quant/IDCT/pred still deferred (M10K).

Phase 3.3k (product path polish — done earlier this arc):
  **STREAM=1 host recon → F1 robust:**
    - multi-IDR: retain/update SPS+PPS; recon every I/IDR; overflow keeps last headers
    - seek/stop: kill both RGB/audio + STREAM demux process groups; pause SIGSTOP both
    - CABAC sticky: PPS `entropy_coding_mode=1` sets skip immediately (no residual walk);
      in-band SPS alone does **not** clear sticky (IDR often repeats SPS/PPS);
      CAVLC PPS clears for re-probe; backup path still sets sticky on `fail_reason=cabac`
  **Prefer direct elementary H.264 for STREAM:**
    - resolve `preferDirectH264` when STREAM=1 → direct Part if Media/Stream is h264/avc
    - avoids Chrome universal High/CABAC that host CAVLC cannot recon
    - local `.264` demux skips `h264_mp4toannexb` BSF
  **Optional skip heavy FFmpeg RGB** (`STREAM_SKIP_RGB=auto|on|off`):
    - auto/on + PRESENT=fpga: skip RGB **from session start** (audio + demux; recon owns F1)
    - PRESENT=both/fb0: always keep RGB (continuous fb0 / STREAM=0 path intact)
    - Logs: `STREAM skip RGB…` vs `STREAM keep FFmpeg RGB (PRESENT=… STREAM_SKIP_RGB=…)`
    - CABAC + skip → no F1: log warns to set `STREAM_SKIP_RGB=0` or `PRESENT=both`
  Unit: `mediaVideoIsH264` + resolve helpers; HW: STREAM=1 PRESENT=both smoke.

Phase 3.3k (FPGA residual advance — this fire):
  **Goal:** extend first-MB residual beyond coeff_token+T1 if BRAM allows; else status/docs.
  **Approach (logic-only, no new M10K):** `slice_hdr_parser` continues after T1 signs into
    non-T1 level prefix/suffix, total_zeros (nC=0), run_before, reverse-scan place →
    `residual_dc` = scan-order coeff[0] (golden Baseline: tc=8 t1=3 **dc=-24**).
  First residual ends ~bit 130 (~17 B) inside existing MAXB=48 RBSP capture — no capture growth.
  **Status:** `[127:96] = {residual_dc[7:0], stream_bytes_in[23:0]}`; host `res_dc=` in
    `push_frame --status`. Existing res_ok/tc/t1 + qp/mb0/ddr_busy unchanged.
  **Paint (F3-only):** MB0 gray = clamp(128 + residual_dc, 0, 255) when residual_ok
    (≈104 on golden; not full inv-quant/IDCT recon — hybrid host F1 still product path).
  **Hybrid confirmed:** `host_owns_fs` still blocks stub wipe of STREAM F1 recon.
  **Fit / HW (lab 2026-07-24 — GREEN):**
    - Analysis & Synthesis **Successful** (regs ~13.9k; block mem bits ~3.17M — **no new M10K**).
    - Sole Quartus fit→RBF OK (NUM_PARALLEL=2, ALMs 22%, M10K 74%) after earlier concurrent-build OOM
      (exit 137) on the 16 GB host — not a device BRAM over-util failure.
    - Deployed `releases/Plex.rbf` → `/media/fat/_Utility/Plex.rbf` (Template HSync + residual_dc + runv-clear).
    - HW: `test_f3_residual.sh` **hard-gates** `res_ok=1 res_tc=8 res_t1=3 res_dc=-24` (golden coeff0).
  **Hybrid confirmed:** host recon owns F1 present (`host_owns_fs`); FPGA residual status/paint
    is F3 diagnostic only until inv-quant/IDCT mae is competitive.
  **Still open (3.3l+):** inv quant + 4x4 IDCT + Intra pred into frame_store for all MBs;
    optional deblock; full-slice residual walk on FPGA (BRAM neighbour/coeff buffers).

Phase 3.3l (plan — inv quant + 4×4 IDCT + Intra pred):
  **Full implementation plan:** `docs/phase3-3l-idct.md`
  **Scope:** first residual → inv quant + IDCT + pred; then first full MB; then all MBs.
  **BRAM (5CSEBA6, post-3.3k fit):** M10K 74% (407/553) free ~146; first-MB path is
    **logic-only** (coeff/IDCT/pred regs). All-MB adds ~2–4 M10K (top Y/UV rows + TC cache).
    Do **not** grow slice MAXB to full IDR or dual YUV framebuffers — stream residual,
    write RGB565 into existing `frame_store`.
  **3.3l-0 done:** `tests/unit/test_idct_quant.cpp` locks synth DC y=62 + real first 4×4
    (tc=8 t1=3 coeff0=-24 → y00=73 mean=62; full y[][] golden) via dequant4x4/idct4x4_add.
  **3.3l-1 host+status wire done; silicon HARD FAIL on dabdaeb0 (still FAIL reference):**
    `h264_residual_gold.hpp` locks full scan + `res_csum8=0x14` (XOR sat8); unit `FPGA_GOLD`;
    host `res_csum=`; **R-csum1 APPLIED** (running XOR+lev, commit `7bee0a6`, RBF **`dabdaeb0`**
    sole-deployed); FBAR PASS + res_dc=-24 OK; **res_csum HARD FAIL** — H-gate
    **0x53/0xa6/0xf9** (+0x53/push) and/or unstable **0x8b/de/31** (never 0x14);
    **soft-skip ≠ hard PASS**. Do **not** thrash-redeploy dabdaeb0.
    RCA guard added: `tests/unit/test_status_telemetry.cpp` + `test_rtl_invariants.py`
    lock the status ABI so `raw[12]=residual_dc`, `raw[13]=residual_csum`, and
    (pre-3.3l-2) `raw[14]=stream_bytes[7:0]`; the old pre-3.3l-1 layout preserved dc but put
    stream low at raw[13], explaining the +file_size%256 walk without implicating
    XOR residual math. Scheduled hardware discriminator:
    `MISTER_HOST=... scripts/res_csum_size_probe.sh` (no deploy) pushes baseline
    and padded vectors; product PASS requires raw[13]=0x14 for both.
    Host (**A-csum-probe2**): progressive residual XOR ends **0x14**; **0x53 ≠ residual intermediate**.
    RCA (**R-csum-rtl2**): one-cycle combo XOR over array (`tmpc`/`lev`) unreliable on this
    Quartus path → multi-cycle scalar RMW fold + `st_res_word` pack harden.
    **R-csum-diagrtl** DIAG force-0x14 pack bisect stacked (dirty; pack path only).
    **R-csum2** (multi-cycle + DIAG force 0x14): LIVE from 12:30:36; log **BUILD END 12:37:32
    exit=0** → host RBF **`4deaf6cc`** ≠ dabdaeb0 (log-proven only; no lab hard PASS invent).
    Detail: `docs/phase3-3l-idct.md` **L-csum-note5** (+ concurrent note6 banner).
  **3.3l-2 RTL module + reference-model prep done (W-REL 2026-07-27; no hardware/no Quartus):**
    `fpga/Plex_MiSTer/rtl/h264_iq_idct_4x4.sv` adds combinational inverse-quant, 4×4 IDCT
    residual, and prediction-add modules for the first residual handoff. Unit
    `test_p3_idct_reference_model` is wired into `make unit`; it is explicitly a C++ reference
    model / source-integration check, **not** a Verilog simulator. It drives the checked-in
    6739-byte Annex-B vector, compares all 16 block-0 `dequant`, signed post-IDCT, and
    reconstructed samples against `tests/fixtures/p3_host_recon/mb0_luma_v1.json`, checks all
    16 MB0 block pred+IDCT→recon rows. The historical frame-MAE grading line
    (`frame_mae_rows=300 maeY=0.000000`) is retained only as a host-source
    regression check and is **not** a product full-frame decode PASS; it came
    from the retired RGB565/presentation scoreboard path. Evidence-backed MB0
    output remains `y00=73 mean=62 coeff_csum=0x14`, corroborated by native
    I420 (`got=73 ref=73 abs=0`). This does **not** replace the Verilator
    behavioural RTL testbench or native-I420 full-frame ratchet.
  **3.3l-2 product RTL staged (W-CAP):** `decode_stub.sv` now consumes proven
    `residual_coeff[0:15]` + `slice_qp` and instantiates the shared
    `h264_iq_idct_4x4.sv` modules for first-4×4 inverse quant + H.264 integer IDCT onto
    **pred=128**. It paints the true first 4×4 into F3 diagnostic MB0 and publishes
    `recon_sig=0x3b` (XOR of reconstructed Y samples) at `raw[14]/status[119:112]`.
    P3-3l2 RCA ABI: `raw[12]=res_dc`, `raw[13]=res_csum`, `raw[14]=recon_sig`,
    `raw[15]=recon_dbg` (usable bits avoid AR-masked bits [2:1]: coeff/dequant/IDCT/recon
    non-zero plus residual-wait flags). Unit `test_p3_idct_rtl_model.py`
    locks product integration and promotes the Verilator path to a hard failure with
    `P3_IDCT_REQUIRE_RTL_SIM=1`; `make rtl-sim` elaborates the real product RTL source and
    the integrated `stream_path` handoff (`slice_hdr_parser` → `decode_stub`).
    `decode_stub` consumes sticky `residual_place_*` payload latched at `ST_PLACE` and
    wakes on `residual_place_pulse`; it must not race transient `residual_ok` or slice-valid.
    **Gate design before fit:** push baseline 6739B and padded 6776B vectors; PASS requires
    `res_csum=0x14`, `recon_sig=0x3b`, and `recon_dbg&~0x06=0xf9` invariant for both
    while the existing nalu_count/status witness changes.
    This is the P3-3l2 analogue of the size-invariant csum gate; no DIAG/constant force.

  **3.3l-3 host full-MB golden done (W-REL 2026-07-26):** `h264_recon.hpp` now has an optional
    `ReconTrace` that records MB0 luma prediction, 16 dequantized coefficients per 4×4, signed
    post-IDCT residual samples, and final reconstructed pixels. Stable RTL fixture:
    `tests/fixtures/p3_host_recon/mb0_luma_v1.json` (`format=misterplex.p3.luma_mb.v1`).
    The checked-in source vector is `tests/fixtures/p3_host_recon/plex_real_baseline_320x240_1f.264`
    and remains **6739 bytes**; no existing generated vector is resized.
  **3.3l-4 host frame-MAE green retired as product evidence (W-CTL reconciliation 2026-07-27):**
    `test_p3_host_recon_vectors` / `tests/fixtures/p3_host_recon/frame_mae_v1.csv`
    formerly reported `vector_bytes=6739 mb=300/300 frame=320x240 maeY=0.000000`.
    That is now **UNSUBSTANTIATED** for product full-frame decode because the
    measurement path was RGB565/presentation-contaminated. The evidence-backed
    first native-I420 ratchets (`plex_inter_p16_624x480_12f` `510/1170`,
    `plex_inter_p16_320x240_12f` `155/300`, `wcap_residual14_idr_plus_p`
    `207/300`) are also retired because their reference silently had in-loop
    deblocking enabled while RTL output did not. Current full-frame status waits
    for no-deblock native-I420 ratchets; first real localized mismatch is MB 182
    `(26,4)`, `Y(420,72)`, `got=107 ref=145`, I16x16 vertical, QP 0, pred=106,
    AC all zero, dequant DC=60, IDCT=1.
    The host CSV can remain a source-level regression fixture, but it must not be
    cited as a full-frame product PASS.
  **Milestones:** 3.3l-0 ✅ → 3.3l-1 host/status ✅ / RBF dabdaeb0 hard csum FAIL → 3.3l-2 MB0 host+handoff ✅ / paint **BLOCKED** →
    3.3l-3 host first full MB ✅ → 3.3l-4 frame-wide green **RETIRED / native-I420 partial** → FPGA 3.3l-3/4 remain blocked behind residual checksum gate → 3.3l-5 hybrid gate.
  **Product:** host F1 recon stays until FPGA mae competitive; F3 diagnostic until then.
  **Non-goals:** deblock, P-slice/MC, CABAC, Quartus-only bring-up without unit goldens.

Phase 3.3m (inter-prediction scope/model — W-REL 2026-07-26 host-only):
  **Survey result:** checked-in Plex/test MP4 assets are Constrained Baseline **I/P only** with
  no B-frames, but still use quarter-pel motion (`motion_scale=4`). Natural encodes include mostly
  P16×16 plus small counts of P16×8/P8×16/P8×8; see `docs/phase3-inter-prediction.md`.
  **Profile lever:** `scripts/gen_test_annexb_inter.py` demonstrates the narrow hardware target:
  Baseline/CAVLC, `bframes=0`, `ref=1`, `weightp=0`, `partitions=none` → deterministic
  12-frame Annex-B vector (`27653` bytes, md5 `fe5ba815b4d67b5b24d7de496facb15b`) with
  `I=1 P=11 B=0`, refs=1, only P16×16 motion vectors, max motion 18×9 px.
  **PMS profile update:** `main` now requests 480p PMS universal as
  `videoResolution=640x480&maxVideoBitrate=2500&videoCodec=h264&videoProfile=baseline&videoLevel=30`.
  Baseline makes inter prediction tractable: no B-slices, no CABAC, no weighted prediction, no
  field/interlaced coding. Treat this as a request until delivered-stream probing proves profile_idc=66
  and CAVLC PPS; source XML may still describe the original Main-profile input.
  **Actual PMS probe (W-A4 2026-07-26):** the server did **not** honor Baseline. Delivered stream
  probed on `feat/a4-sps-baseline` @ `b28e863` as H.264 High, `profile_idc=100`, `level_idc=30`,
  `width=618`, `height=480`, PPS `entropy_cabac=1`, video-only bitrate ~1344.3 kbps, and a 12 s
  slice scan found `i=22 p=165 b=115`. The request still carried `videoResolution=640x480`,
  `maxVideoBitrate=2500`, `videoProfile=baseline`, `videoLevel=30`; PMS mpegts universal target
  produced data while final mp4 returned an empty body. Therefore Baseline-only FPGA inter decode
  is architecturally tractable but **not yet product-safe for PMS 480p**; product must fail closed /
  fall back on High/CABAC/B until PMS delivery is constrained or a broader decoder exists.
  **Scope correction (W-FEED 2026-07-28):** this number was taken from HEVC `/metadata/3`
  source via PMS transcode/delivered-stream probing. It is evidence about the PMS transcode path,
  not evidence about original-Part H.264 ≤480p direct play, and the current library census found
  zero real original-Part H.264 ≤480p items.
  **Goldens:** `tests/fixtures/p3_inter_pred/` adds the checked-in vector, `pframe1_mb_v1.json`
  (`format=misterplex.p3.inter_mb.v1`) and `frame_mae_v1.csv`
  (`format=misterplex.p3.inter_frame_mae.v1`, 12×300 MB rows, host-model maeY=0).
  This is evidence for the host inter model/golden generator only, not a product
  stream-path/DPB/MC full-frame PASS. Unit
  `test_p3_inter_pred_vectors` regenerates byte-identically, exports libav motion vectors, and
  verifies Baseline/CAVLC/profile constraints plus the fixtures; red perturbations cover MV, MAE rows,
  and unsupported-profile handling.
  **Architecture:** inter prediction requires DDR3-backed YUV reference storage; BRAM is not viable
  for 480p references. Level 3.0 worst-case DPB is `floor(8100 / 1200) = 6` 640×480 refs:
  2.76 MB YUV420 for references, ~3.23 MB including current reconstruction. One-ref P16×16 480p
  is roughly 1.6 MB/frame with native YUV420 DDR/present (~94 MB/s @60 before inefficiency) or
  ~1.8 MB/frame with RGB565 output (~108 MB/s @60). Sub-MB partitions raise that toward
  ~132–156 MB/s at 60 on the RGB565 path, ~25% less if `w-c2` YUV420 DDR lands. Current ~160 MB/s
  DDR3 is plausible for the narrow Baseline/YUV path; faster DDRAM clock makes it comfortable.
  SDRAM remains unsuitable until its hardware bring-up is green.
  **Detection rule:** unexpected B-slice, CABAC PPS, non-Baseline profile, over-level stream, or
  `max_num_ref_frames` above the implemented DPB must fail closed and report unsupported; unit
  `test_p3_inter_pred_vectors` includes a generated High/CABAC/B probe for this guard.

Phase 3.3n (real PMS High/CABAC/B sizing — W-REL 2026-07-26 host-only):
  `docs/phase3-high-cabac-scope.md` sizes the final W-A4 sweep result: client-only Baseline forcing
  failed, delivered stream is High/CABAC/B with 624×480 coded / 618×480 display, 39×30=1170 macroblocks,
  25 fps, `max_num_ref_frames=4`, PPS CABAC, and `i=22 p=165 b=115` over 12 s. CABAC planning
  number is **8.775 Mbin/s** (300 bins/macroblock); stress is **17.550 Mbin/s** (600 bins/macroblock). At current
  20 MHz `clk_sys`/DDRAM clock, an optimistic 1-bin/cycle CABAC engine barely covers stress
  (1.14×), a 2-cycle engine fails stress, and a 3-cycle engine fails planning. 4 refs + current
  YUV420 is 2.25 MB; +present/reorder is 2.70 MB, so DDR3 is required and SDRAM/BRAM are not viable.
  **Scope correction (W-FEED 2026-07-28):** this sizing uses HEVC `/metadata/3` source via PMS
  transcode/delivered-stream probing. It remains valid High/CABAC/B transcode-path sizing, but it
  is not evidence about the original-Part H.264 ≤480p path the fabric is being built for.
  Existing 4×4 IQ/IDCT/recon survives below the entropy layer, but the CAVLC walker does not; High
  also requires detection/support for 8×8 transform and B-slice DPB/list machinery. Verdict:
  decoding PMS as delivered is a full High-profile decoder project and not a sane near-term path
  without a faster/proven clock+DDR plan; server-side Baseline XML or ARM/FFmpeg fallback is now a
  hard strategic requirement.
Phase 3.3p (P-slice inter prediction RTL — W-REL 2026-07-26 host-only):
  Server-side PMS XML profile is now the required path: W-A4 proved delivered Baseline/L3.0 with
  `profile_idc=66`, `max_num_ref_frames=1`, `entropy_cabac=0`, `i=6 p=294 b=0`, coded
  **624×480** (39×30=1170 macroblocks) and display 618×480. Client-only Baseline forcing remains failed,
  so unsupported-stream guards stay mandatory. Local x264 proxy with the exact `VideoEncodeFlags`
  plus `partitions=none` measured P frames as intra 4.8%, **P16×16 17.6%**, sub-MB partitions 0%,
  **skip 77.7%**; first RTL rung implements only P_Skip + P_L0_16x16.
  **Scope correction (W-FEED 2026-07-28):** the PMS Baseline/L3.0 number used HEVC
  `/metadata/3` source via the server-side PMS transcode/derived path. It proves the constrained
  delivered stream can match the FPGA contract; it does not prove original-Part H.264 ≤480p
  direct-play behaviour for the user's library.
  RTL: `h264_inter_pred.sv` adds MV median predictor/MVD add/P_Skip zero rule, partition-aware
  predictors for P_L0_16x8/P_L0_8x16/P_8x8/sub-MB modes, luma qpel six-tap interpolation, chroma
  eighth-pel bilinear interpolation, and 9×9 reference fetch address clamping. `h264_p_slice_modes.sv`
  classifies P_Skip, P_L0_16x16, P_L0_16x8, P_L0_8x16, P_8x8/P_8x8ref0 and sub-MB
  8x8/8x4/4x8/4x4 shapes; `slice_hdr_parser.sv` now skips non-IDR ref-marking/ref-idx bits before
  QP and exposes P `mb_skip_run` plus the first P MB type. `decode_stub.sv`
  instantiates the inter RTL in the shipped artifact and paints a top-row MB1 diagnostic tile as four
  green/red stage bands (MV+partition, luma qpel, chroma epel, fetch; aggregate signature `0x57`).
  Verilator: `tests/unit/test_p3_inter_rtl_sim.sh` elaborates the real product RTL listed in
  `files.qip` through `tests/rtl/h264_inter_pred_tb_top.sv`, compares against
  `tests/fixtures/p3_inter_pred/inter_mc_v1.json`, and red-checks bad interpolation rounding via a
  testbench-only fault. The integrated gate `tests/unit/test_p3_inter_stream_path_rtl_sim.sh` now
  elaborates product `stream_path.sv` plus parsers/`decode_stub`/inter RTL, feeds paced multi-NAL
  Annex-B vectors, and requires idle return after each VCL: IDR fixture `nals=4 frames=1`, P fixture
  `nals=15 idr=1 p=11 frames=12`, all four MB1 inter diagnostic bands green, and red-checks a
  testbench-only bad visual-diagnostic pixel fault. Primitive RTL evidence is `mv_cases=6`,
  `partition_cases=10`, plus a bad-partition-MV red-check. This is a stream-path/diagnostic gate; parsed P
  MB syntax is not yet driving MC. DDR/YUV update: one
  624×480 YUV420 ref + current = 898,560 B; +present = 1,347,840 B. At 25 fps, narrow P16×16/P_Skip
  YUV traffic is ~40 MB/s before overhead (~50–70 MB/s planning), comfortable for the validated
  80 MHz DDR/YUV path; SDRAM remains out of scope.

Phase 3.3q (derived real-statistic H.264 ARM boundary profile — W-FEED 2026-07-28):
  **Scope:** measured on the tracked-provenance derived asset in
  `docs/derived-validation-assets.md`: HEVC `/metadata/3` source re-encoded to H.264 Constrained
  Baseline/CAVLC/ref=1/no-B, 624×480, 1800 frames. This is the first real-image-statistics
  H.264 workload at the target geometry, but it remains **derived**, not original library content
  and not original-Part direct-play evidence. The W-A4 / 3.3n / 3.3p numbers above remain
  HEVC-source PMS-transcode evidence, not original-Part H.264 evidence.

  **Pre-registered before summarising the retained ARM run:** (P1) real-statistic content should
  be harder than the synthetic P16 fixtures by compressed bytes/frame and bytes/macroblock; (P2)
  the ARM boundary should be near the live ~31 ms decode+pipe decomposition plus present, barely
  fitting 24 fps and missing 25 fps; (P3) any existing correctness score that goes green on this
  asset without a derived golden/reference is insensitive rather than reassuring.

  **Raw ARM profile buckets** (`PROFILE_FRAMES=1800`, sample
  `/media/fat/misterplex/profile/derived_realcontent_624x480_baseline_ref1_nob_1800f.mp4`,
  raw evidence retained in `build/misterplex-agent-W-FEED-arm-profile.txt`):
  **Reproducibility status:** these numbers are **EXPIRED** on any checkout where
  `scripts/check_arm_profile_asset.sh` does not print `ASSET_OK`. The full local
  source asset lives under ignored `artifacts/local/arm-profile-sample/`, not
  `build/`, specifically so routine `make clean` cannot silently destroy the
  input while leaving this headline number standing.
  - ffmpeg decode/null: `wall_s=38.811395`, `child_cpu_s=41.160496` →
    **21.5619 ms/f wall**, **22.8669 ms/f child CPU**.
  - decode+scale/pad+yuv420p/null: `wall_s=44.129199`, `child_cpu_s=54.256972` →
    scale/format delta **2.9543 ms/f wall**, **7.2758 ms/f child CPU**.
  - decode+scale/pad+yuv420p pipe drain/copy: `wall_s=53.603296`,
    `child_cpu_s=60.109691`, `read_wall_s=53.592391`, `copy_wall_s=4.156984` →
    pipe delta **5.2634 ms/f wall**, parent copy **2.3094 ms/f wall**,
    total decode+scale+pipe **29.7796 ms/f wall**.
  - present/DDR: product-present bucket from the timing-closed 624×480 path is
    **10.4106 ms/f wall**, **4.9162 ms/f CPU**. The raw DDR microbench in the same ARM profile
    measured no-sync `/dev/mem` at **7.199 ms/f wall**, **4.707 ms/f CPU** (`sync=1`:
    7.378/4.755; `flush=1`: 13.246/9.147), so the product-present bucket is the conservative
    end-to-end number to budget.
  - bucket sum with product present: **40.1902 ms/f**. That leaves **+1.476 ms/f** against
    24 fps (41.667 ms) and misses 25 fps (40.000 ms) by **0.190 ms/f**. This is a measured
    component sum, not a hardware A/V playback PASS.
  - Unattributed residual inside the ffmpeg sub-buckets is **0 by construction** because the
    scale and pipe numbers are deltas from nested probes
    (`29.7796 − 21.5619 − 2.9543 − 5.2634`). That is not an independent zero measurement;
    product integration overhead beyond these probes remains unmeasured.

  **Synthetic comparison:** the derived Annex-B is 12,713,118 B / 1800 frames /
  1170 MB/frame = **7062.8 B/f**, **6.037 B/MB**. The synthetic 624×480 P16 fixture is
  70,348 B / 12 frames / 1170 MB/frame = **5862.3 B/f**, **5.011 B/MB**; P-frame packet mean
  is **6924.8 B** derived vs **5344.9 B** synthetic. P1 is therefore confirmed: the derived
  sustained workload is ~20.5% larger per MB overall and ~29.6% larger per P frame than the
  624×480 synthetic P16 blip. The 320×240 synthetic fixtures remain useful stress/unit vectors
  (`7.681 B/MB` P16, `15.100 B/MB` two-frame residual14), but their geometry and sample length
  make them poor sustained 624×480 throughput proxies. P2 is confirmed by the 40.1902 ms/f sum.
  P3 is not scored as a green correctness result: no derived golden/reference is wired, so this
  profile is performance/boundary evidence only.

Phase 3.3r (derived real-statistic H.264 correctness reference — W-FEED 2026-07-28):
  `tests/fixtures/derived_validation/` now tracks a per-frame, per-plane SHA-256 manifest for
  the same 1800-frame derived asset profiled in 3.3q:
  `derived_realcontent_624x480_baseline_ref1_nob_1800f_i420_hashes_disabled_v1.json`.
  The reference is regenerated by `tools/derived_h264_plane_hashes.py` from the untracked
  Annex-B asset in `artifacts/local/arm-profile-sample/`, records the asset SHA-256
  `41f2769189bdceb3c30315bf557e44e01d016d48c3eca8507ceb6eed51919e04`, FFmpeg version
  `n8.1.2`, the exact decode command, 624×480 I420 geometry, and 1800 frames of Y/U/V hashes.
  The loop-filter contract is explicit: FFmpeg decode with `-skip_loop_filter all`, matching the
  current pre-deblock RTL/output contract rather than final post-deblock presentation.

  Coverage sanity from the manifest: 1790 unique Y-plane hashes; U/V hashes differ on 1774/1800
  frames, so U/V swaps are scoreable on most of the clip but weak on the first grey/low-chroma
  frames. The convenience check `tests/unit/test_derived_validation_hashes.sh` verifies the
  full manifest when the untracked asset exists.

  **Always-on slice:** `derived_realcontent_624x480_baseline_ref1_nob_8f_i420_disabled.yuv`
  commits eight native-I420 frames selected from source frames
  `149,392,474,710,937,1183,1349,1675`. It is small enough for the repo (3.43 MiB) and
  makes the gate run on clean checkouts. Its manifest records `uv_distinct_frames=8/8`,
  `unique_y_hashes=8/8`, `y_min=0`, and `y_max=243`; the unit test red-checks both a
  corrupted Y-plane hash and a U/V-swapped raw slice, so the selected frames actually express
  the mutations being claimed. Candidate decoder outputs can be scored by running
  `tools/derived_h264_plane_hashes.py verify --candidate-planes ... --candidate-colorspace I420_NATIVE`.

  This closes the P3 measurement gap only for native-I420 exactness at the declared loop-filter
  stage. It can catch wrong final bytes from residual add, scan, dequant/IDCT, MC/reference,
  chroma placement, and U/V order **when this clip expresses the affected samples**. It cannot
  prove original library coverage, enabled deblock correctness, RGB/RGB565 presentation, pillar
  masking, timing/drop/repeat behaviour, parser coverage for unsupported streams, or mutations
  that alias on equal/zero coefficients or equivalent dequant classes. A green comparison is
  therefore a real-content frame-output score, not a total decoder proof.


Phase 3.1b (DDR bulk path — implemented this fire):
  **Measured F1 (lab 2026-07-24, 192.168.1.183, 320×240 RGB565 = 153600 B):**
    Historical SPI chunk sweep (earlier lab):
    | chunk | wall time | effective |
    |-------|-----------|-----------|
    | 8 KiB | ~220 ms   | ~0.70 MB/s |
    | 32 KiB| ~194 ms   | ~0.79 MB/s |  ← SPI default
    | 64–128 KiB | ~196–202 ms | ~0.76 MB/s |
    **Wall time after ARM kick batching + kick/frame verify (not busy-only):**
    | path | wall time | effective | unique fps |
    |------|-----------|-----------|------------|
    | legacy SPI F1 RGB path | retired/refused (non-YUV frame-store payload) | n/a | n/a |
    | DDR `push_frame --ddr` | **~16.5 ms** (5 runs: 16.0–16.8) | **~9.3 MB/s** | **≈60 fps** |
    mmap alone ~1.9 ms; remainder is one MainPause SPI session + DMA settle.
    Log: `/tmp/misterplex-ddr-agent.txt`. DDR ≈ **7× SPI** → real-time 24/30 @320×240 OK.
  **Why SPI is slow:** FIO_FILE_TX over HPS SPI with Main pause + per-chunk
    CS sessions; not a streaming DMA.

  **DDR path:**
    HPS `mmap(/dev/mem)` → bank layout is geometry-derived:
    `bank_stride = alignUp(frame_bytes, 0x40000)`, bank0 = `base`, bank1 =
    `base + bank_stride`, and doorbell = `base + bank_stride*2 - 0x1000`.
    With base `0x30000000`: 320×240 I420 (`frame_bytes=115200`) uses stride
    **0x40000**, bank1 **0x30040000**, doorbell **0x3007F000**; 624×480 I420
    (`frame_bytes=449280`) uses stride **0x80000**, bank1 **0x30080000**,
    doorbell **0x300FF000**. The addresses move with geometry; do not treat
    either worked example as a constant for all frame sizes.
    → pulse **status[12]** start (status[13]=bank, legacy SPI kick) or write the
    mmap doorbell high word (`[31]=bank`) → `ddram_frame_rd`/`ddr_frame_store` Avalon
    burst-reads f2sdram → dual-bank BRAM `frame_store` → present (same as F1).
    - RTL: `rtl/ddr_frame_store.sv` (`rtl/ddram_frame_rd.sv` is the legacy
      SPI-kick reader); Plex.sv no longer ties DDRAM_* to 0
    - ARM: `FpgaSpi::sendYuv420pFrameDdr` (I420 planar DDR payload + doorbell)
    - Tool: `push_frame --ddr [--bank 0|1] --yuv420p WxH file.yuv420p`
    - Verify: `ddr_busy` **or** (status[12] echo in status_in + `has_frame`); busy-only
      was a false negative — see diagnosis below
    - status_in[79] = ddr_busy during copy (`{ddr_busy,0,qp}` @ [79:72])
  **Diagnosis (ddr_busy never seen via UIO_GET_STATUS):**
    - RBF has `ddram_frame_rd` (map/fit + md5 match deployed).
    - status_in v2: kick bits [12]/[13] **work** (`lo=0x1000` after set; survives status_set).
    - Functional proof: after reset `has_frame=0` → mmap + status[12] 0→1 → `has_frame=1`.
    - `ddr_busy` rarely latched: status_req updates only on status_set; DMA ~1–3 ms so
      busy clears before SPI poll samples. Idle busy=0 is expected, not missing IP.
  **Does not break** Phase 2: PRESENT=fb0 never opens FPGA path; F1 remains DDR YUV420p-only.

  **RBF rebuild status (lab 2026-07-24):** Sole Quartus with `NUM_PARALLEL_PROCESSORS=2`
  completed map→fit→asm (ALMs ~22%, M10K ~74%). Deployed `_Utility/Plex.rbf` includes
  Template HSync, residual_dc, and `ddram_frame_rd` RTL. Product **uses DDR
  YUV420p only for F1**; kick/frame failures stay visible instead of falling
  back to legacy RGB/SPI.

  **Build / lab status:**
    - ARM static: `make arm-plexd` green (`misterplexd` + `push_frame --ddr` OK ~16 ms)
    - Residual HW: `test_f3_residual.sh` → `res_dc=-24` on lab DE10
    - Avoid concurrent raetro/quartus containers (OOM root cause earlier)

  **Still open after 3.1b:**
    1. Optional: sticky `ddr_done` / frames_done in status_in for tighter verify (RTL)
    2. Optional: present directly from DDR (skip BRAM) for larger modes
    3. Async double-buffer SPI — small gain only; deprioritized
```

### 3.0 HW bring-up

1. Build RBF: `make build-rbf` (Quartus via misterfpga-dev).
2. Deploy: `./scripts/deploy_plex_core.sh`.
3. `python3 scripts/gen_edge_markers.py --format yuv420p build/plex_test_320x240.yuv420p`.
4. Push with `push_frame --ddr --yuv420p 320x240 build/plex_test_320x240.yuv420p`.
5. Expect edge-marker frame and `has_frame=1`.

## H.264 soft-core evaluation notes

| Option | Pros | Cons for Cyclone V 5CSEBA6 |
|--------|------|----------------------------|
| Open hardh264-class / VexRiscv+accel | Real Baseline | ALM/BRAM cost; integration effort |
| Simplified Baseline intra-only | Fits fabric | Limited library titles |
| ARM demux + FPGA IDCT/MC only | Incremental | Still ARM-heavy |
| PMS ladder → Profile-1 elementary | Product path | Needs soft-core ready |

**Bring-up order:** F3 byte path (done scaffold) → NAL parse stats → Baseline decode IP → YUV→RGB565 → frame_store swap.

## Acceptance

- Same titles as Phase 2 cast path
- Product path: ARM decode + FPGA present stays green on viewed pixels (freeze/shear/colour/ledger)
- Fabric-decode product path (future): inventory gate green on the shipping fit **and** glass proof that pixels come from fabric recon — not merely that CAVLC ALMs exist
- A/V sync ≤ ±40 ms; audioUnderrun ≈ 0; no stuck frame
- Kill daemon / stop never hangs core
- **Not** an acceptance criterion: “ARM mostly idle because decode moved to FPGA” (retracted — scaler dominates CPU; fabric decode motivation is **direct-play**)

## Non-goals (Phase 3)

- Arbitrary 4K HEVC remux without PMS ladder
- Optical-flow interpolation
- Replacing PMS
- Claiming full H.264 in FPGA while CAVLC/intra are unfitted and `host_owns_fs` blocks stub present
