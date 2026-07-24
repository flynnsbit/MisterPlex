# Phase 3 — FPGA decode path (research + plan)

## Goal

Move **decode off dual-A9 FFmpeg** for Profile MiSTerPlex-1 so ARM is protocol/demux only and **FPGA owns unique frames + present + audio FIFO**.

Phase 2 remains valid bootstrap: FFmpeg → `/dev/fb0` + `/dev/MrAudio`.

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
| FPGA | Decode + cadence present + AUDIO_L/R |
| ARM | GDM/companion/resolve/demux, not pixel loop |

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
    [95:64] bytes_seen  [127:96] bytes_in
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

Phase 3.3h (walk+recon+FPGA residual — polish continues):
  **Root causes fixed this arc:**
    1. I_16x16 missing `intra_chroma_pred_mode` → walk desync (0x27 = chroma+empty, not 2-bit empty)
    2. I4 MPM: unavailable neighbour must force pred=DC(2), not min(...,2) — was decoding wrong modes
    3. **I4 top-right availability** (scan order): only use TR samples whose 4x4 is already
       reconstructed; else replicate above[3]. Fixes (1,1)/(1,3) and right-edge lx=3 TR bugs.
    4. I16 DC Hadamard butterfly aligned to FFmpeg `ff_h264_luma_dc_dequant_idct`
  Host: FULL residual walk 300/300; recon tiny/gray **maeY=0**; real **maeY≈0.95** vs FFmpeg
        no-deblock (was ≈1.28; exact MBs 212→221+; MB0 still pixel-perfect)
  Host: `h264_recon.hpp` → YUV420 + RGB565; tool dump `/tmp/recon_320x240.rgb565` for SPI push
  FPGA: ST_CHRPRED (I16) + **ST_I4MODE/ST_CBP** (I_NxN skip modes→cbp→first residual nC=0)
    gray I16 HW: mb0=3 qp=27 res_ok=1 res_tc=1
    real I_NxN HW target: mb0=0 qp=25 **res_ok=1 res_tc=8 res_t1=3**
  **Open (bit alignment):** first Y error at MB41 — CAVLC is **8 bits ahead** of the correct
    I16-DC residual start (offset −8 yields pure DC coeff[0]=−1 matching FFmpeg). MBs 0–40 Y are
    perfect → likely **chroma residual** over-read (cbp_c path) before MB41. Fix chroma AC/DC
    bit consumption next; then residual polish / deblock / full FPGA MB residual.

```

### 3.0 HW bring-up

1. Build RBF: `make build-rbf` (Quartus via misterfpga-dev).
2. Deploy: `./scripts/deploy_plex_core.sh`.
3. `python3 scripts/gen_test_frame.py /tmp/plex_test_320x240.rgb565` and copy to SD.
4. OSD: load frame via **F1**, set **Video source = Frame store**.
5. Expect yellow border + color bars + orange diagonal (not internal pattern block).

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
- ARM CPU mostly idle during play (protocol + demux)
- A/V sync ≤ ±40 ms; audioUnderrun ≈ 0; no stuck frame
- Kill daemon / stop never hangs core

## Non-goals (Phase 3)

- Arbitrary 4K HEVC remux without PMS ladder
- Optical-flow interpolation
- Replacing PMS
