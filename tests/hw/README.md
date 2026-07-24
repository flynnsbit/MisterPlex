# Hardware tests

Require a live MiSTer (`MISTER_HOST`, default `192.168.1.183`).

## Phase 1 / 2 (misterplexd)

| Script | What |
|--------|------|
| `test_media_fb.sh` | play/pause/resume/stop via companion |
| `test_playqueue_bind.sh` | scrubber play-queue fields |
| `test_audio_mraudio.sh` | `/dev/MrAudio` PCM path |
| `test_single_process.sh` | one FFmpeg demux for A/V |
| `test_seek_kill.sh` | seek + kill/restart recovery |
| `test_soak.sh` | multi-title play/stop soak (Phase 4 skeleton) |

```bash
./scripts/deploy_misterplexd.sh
./tests/hw/test_media_fb.sh
```

## Phase 3.0 frame store (FPGA)

1. Deploy core: `./scripts/deploy_plex_core.sh`
2. Generate frame: `python3 scripts/gen_test_frame.py /tmp/plex_test_320x240.rgb565`
3. Copy to SD: `scp … root@MiSTer:/media/fat/plex_test_320x240.rgb565`
4. On OSD (Plex core):
   - Open file menu (**F1**), select `plex_test_320x240.rgb565`
   - Set **Video source = Frame store**
5. Display should show yellow border + color bars + orange diagonal (not the internal moving block alone).

Continuous ARM→FPGA stream (misterplexd) is Phase 3.1.

## Phase 3.2 audio FIFO

1. Deploy latest `Plex.rbf`.
2. `python3 scripts/gen_test_pcm.py /tmp/pcm.s16le`
3. `push_frame --index 2 /tmp/pcm.s16le` on MiSTer (F2).
4. Core should play tone from FIFO (~1s) instead of OSD square wave.
5. LED blinks faster while `has_audio`.
6. Append + continuous: `./tests/hw/test_f2_append.sh` (multi-chunk SPI + live f2==bytes).

## Phase 3.3 elementary bitstream (F3)

1. Deploy RBF with `stream_path` / F3 menu entry + status readback.
2. `python3 scripts/gen_test_annexb.py /tmp/plex_test_annexb.h264`
3. `./tests/hw/test_f3_bitstream.sh` — SPI index 3 + `push_frame --status` asserts `nalu≥4`, `has_stream=1`.
4. Manual: `push_frame --status` on MiSTer dumps has_frame/audio/stream + nalu_count.

## Phase 3.3b decode_stub (F3 → pixels)

1. Deploy latest RBF (`decode_stub` wired into `frame_store`).
2. `./tests/hw/test_f3_decode_stub.sh` — asserts `has_idr`, `stub_frames≥1`, `has_frame`.
3. Display shows green-border diagnostic frame after F3 push (not color bars alone).
4. Continuous product path: `STREAM=1` in `misterplex.conf` (+ `PRESENT=fpga|both`)
   demuxes annex-B → F3 while playing (decode_stub until real H.264 IP).

## Phase 3.3i host I-slice recon → F1

1. Conf: `PRESENT=both` (or `fpga`) and `STREAM=1` in `/media/fat/misterplex/misterplex.conf`.
2. Deploy: `./scripts/deploy_misterplexd.sh`.
3. Play weak Baseline 320×240 (PMS ladder / test annex-B cast) via companion.
4. Log should show:
   - `STREAM=1 host I-slice recon →F1 +F3`
   - `recon frame ok #1 320x240 mb=300 …`
   - `fpga`/session `recon=N` (N≥1 after first IDR)
5. Frame store shows reconstructed I-frame (not only decode_stub green border).
6. Fallback: if recon fails, FFmpeg RGB still drives F1 until first recon success.

## Phase 3.3c SPS parse (real Baseline)

1. Deploy RBF with `sps_parser`.
2. `./tests/hw/test_f3_sps.sh` — ffmpeg Baseline 320×240 annex-B → `sps_valid=1 sps=320x240`.
3. Unit: `make unit` includes `test_sps_parse`.

## Phase 3.3d PPS + I-slice header

1. Deploy RBF with `pps_parser` + `slice_hdr_parser`.
2. `./tests/hw/test_f3_slice_hdr.sh` — `pps_valid=1 slice_type=7` (I/IDR) + `sps=320x240`.
3. Unit: `test_slice_hdr`. Display: MB grid diagnostic on VCL.

## Phase 3.3e first MB type + slice QP

1. Deploy RBF with extended slice_hdr (qp/deblock/mb0).
2. `./tests/hw/test_f3_mb0.sh` — `mb0=7` (I_16x16) `qp=14` on real Baseline IDR.
3. Unit: `test_slice_hdr` asserts mb0+qp.

## Phase 3.3f first I16 DC residual CAVLC

1. Deploy RBF with residual token probe in slice_hdr_parser.
2. `./tests/hw/test_f3_residual.sh` — `res_ok=1 res_tc=2 res_t1=2` on real Baseline IDR.
3. Unit: `test_cavlc_dc` (host CAVLC golden).
