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

Phase 3.3h (host I-slice recon **bit-exact** vs FFmpeg no-deblock — done this fire):
  **Root causes fixed this arc:**
    1. I_16x16 missing `intra_chroma_pred_mode` → walk desync
    2. I4 MPM: unavailable neighbour → pred=DC(2)
    3. I4 top-right sample availability (scan order / `lumaReady`)
    4. I16 DC Hadamard butterfly = FFmpeg `ff_h264_luma_dc_dequant_idct`
    5. **I16 DC scan layout:** CAVLC zigzag must be loaded with FFmpeg `TRANSPOSE(zz[i])`
       into the Hadamard (column-major). ITU raster alone mapped scan-pos 2 → vertical
       frequency; FFmpeg places it at input[1] → gold top/bot pattern. Fixed
       `invQuantHadamardDc4x4` → **maeY=0 exact 300/300**.
    6. **Chroma DC pred rounding:** TL/BR 4x4 must use single-sum `(sA+sL+4)>>3`, not
       nested avgs. Fixed `predChroma8` mode 0 → **maeU=maeV=0** (full YUV exact).
  Host: FULL residual walk 300/300; recon real baseline **maeY=U=V=0** vs FFmpeg
        `-skip_loop_filter all`; tiny/gray mae=0; `h264_recon.hpp` → YUV420 + RGB565
  FPGA: ST_CHRPRED (I16) + ST_I4MODE/ST_CBP (I_NxN); gray I16 HW green earlier
  **Next was 3.3i (now done):** host SPI present + STREAM wire — see below.
    - Optional deblock filter (not needed for no-LF gold)
    - FPGA full MB residual + inv quant/IDCT path (extend beyond first-residual probe)

Phase 3.3i (done — host I-slice recon → F1 in misterplexd STREAM path):
  STREAM=1: annex-B demux → retain SPS/PPS → IDR/I VCL → `recon::reconISlice`
    → YUV420 → RGB565 → scale 320×240 → **F1** `sendRgb565Frame` (frame_store)
  Still feeds **F3** for FPGA decode_stub / residual probes (diagnostic)
  FFmpeg RGB: fallback F1 until first recon present; then recon owns F1
  PRESENT=both: FFmpeg continuous fb0 + recon F1; companion :3005 unchanged
  Logs: `recon frame ok #N WxH mb=…`; session `recon=N`
  Unit: `test_cavlc_dc` FULL walk + recon + maeY=U=V=0 vs FFmpeg; ARM `-I host`
  **HW lab 192.168.1.183 (this fire):**
    - Baseline smoke: `recon_ok=3 recon_fail=0 present=3` f1ms≈170
    - High/CABAC `test.mp4`: fail_reason=`cabac` → FFmpeg RGB F1 continues (frames>0)
    - Manual F1 push recon RGB565: `has_frame=1` (~172–200 ms / 153600 B ≈ 0.75–0.9 MB/s SPI)
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
    - CABAC: sticky skip after first `fail_reason=cabac` + clear log; re-probe on new SPS/PPS
  **Prefer direct elementary H.264 for STREAM:**
    - resolve `preferDirectH264` when STREAM=1 → direct Part if Media/Stream is h264/avc
    - avoids Chrome universal High/CABAC that host CAVLC cannot recon
    - local `.h264`/`.264` demux skips `h264_mp4toannexb` BSF
  **Optional skip heavy FFmpeg RGB** (`STREAM_SKIP_RGB=auto|on|off`):
    - auto + PRESENT=fpga: audio-only FFmpeg + stream demux; recon owns F1
    - PRESENT=both/fb0: always keep RGB (continuous fb0 / STREAM=0 path intact)
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
  **Fit / HW (this fire):**
    - Analysis & Synthesis **Successful** (regs ~13.9k; block mem bits ~3.17M — **no new M10K**).
    - Full Quartus fit→RBF **was** blocked on lab host OOM (pre-fix); **2026-07-24 sole fit OK** (NUM_PARALLEL=2, ALMs 22%, M10K 74%) → `releases/Plex.rbf` deployed `_Utility` (Template HSync + residual_dc wiring). Open: `res_dc` still 0 on lab (runv clear fix pending next RBF); HDMI capture still black (exit 137 / mid-fit kill under concurrent
      agents). Not a device BRAM over-util failure; hybrid + first-residual logic maps cleanly.
    - HW gate when RBF available: `test_f3_residual.sh` asserts `res_dc=-24` (golden coeff0).
  **Hybrid confirmed:** host recon owns F1 present (`host_owns_fs`); FPGA residual status/paint
    is F3 diagnostic only until inv-quant/IDCT mae is competitive.
  **Still open (3.3l+):** inv quant + 4x4 IDCT + Intra pred into frame_store for all MBs;
    optional deblock; full-slice residual walk on FPGA (BRAM neighbour/coeff buffers);
    complete RBF fit when host has exclusive ~8+ GB free.

Phase 3.1b (DDR bulk path — implemented this fire):
  **Measured SPI F1 (lab, 320×240 RGB565 = 153600 B):**
    | chunk | wall time | effective |
    |-------|-----------|-----------|
    | 8 KiB | ~220 ms   | ~0.70 MB/s |
    | 32 KiB| ~194 ms   | ~0.79 MB/s |  ← SPI default
    | 64–128 KiB | ~196–202 ms | ~0.76 MB/s |
    Ceiling ≈ **4–5 unique fps** on SPI F1 alone (not real-time 24/30).
  **Why SPI is slow:** FIO_FILE_TX over HPS SPI with Main pause + per-chunk
    CS sessions; not a streaming DMA.

  **DDR path (new):**
    HPS `mmap(/dev/mem)` → bank @ **0x30000000** / **0x30040000** (256 KiB stride)
    → pulse **status[12]** start (status[13]=bank) → `ddram_frame_rd` Avalon
    burst-reads f2sdram → dual-bank BRAM `frame_store` → present (same as F1).
    - RTL: `rtl/ddram_frame_rd.sv`; Plex.sv no longer ties DDRAM_* to 0
    - ARM: `FpgaSpi::sendRgb565FrameDdr` / `sendRgb24FrameDdr`
    - Tool: `push_frame --ddr [--bank 0|1] file.rgb565`
    - misterplexd: prefers DDR for F1; one-shot verifies `ddr_busy` (status_in[39]);
      falls back to SPI if RBF lacks 3.1b
    - status_in[39] = ddr_busy during copy
  **Target:** ≥30 fps @320×240 (mmap + kick << SPI 200 ms). Measure with
    `push_frame --ddr` wall time on lab 192.168.1.183 after RBF deploy.
  **Does not break** Phase 2: PRESENT=fb0 never opens FPGA path; SPI F1 still works.

  **RBF rebuild status (lab fire):** ARM DDR path is in tree and prefers DDR with
  SPI fallback. Quartus map for DDR+current residual FSM hit segfaults / OOM (exit
  137) under concurrent docker builds on the 16 GB host. Last green RBF remains
  **3.3j hybrid** (no ddram_frame_rd). Until a clean sole fit+asm lands, product
  path is SPI F1 (~5 fps) + PRESENT=both. Retry: kill all quartus containers,
  `rm -rf db incremental_db`, single `quartus_sh --flow compile`, then asm if needed.


  **Build / lab status (this fire):**
    - ARM static: `make arm-plexd` green (`misterplexd` + `push_frame --ddr`)
    - Quartus: `ddram_frame_rd` elaborates; full RBF fit OOM'd on 15 GiB host
      (exit 137 during map/fit). Re-run when ≥12 GiB free:
      `mister-dev build …/Plex_MiSTer --qpf Plex.qpf`
    - Lab 192.168.1.183: ICMP ok; SSH key not configured from this agent —
      measure after deploy: `tests/hw/test_ddr_frame.sh`

  **Still open after 3.1b:**
    1. Complete RBF + lab measure push_ms / sustained fps
    2. Optional: present directly from DDR (skip BRAM) for larger modes
    3. Async double-buffer SPI — small gain only; deprioritized

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
