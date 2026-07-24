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
| `test_soak.sh` | multi-title play/stop soak (Phase 5: auto conf + PMS discover) |

```bash
./scripts/deploy_misterplexd.sh
./tests/hw/test_media_fb.sh
# Soak: loads conf from MiSTer (or MISTER_CONF), discovers PMS titles when token set
SOAK_HOLD_S=5 SOAK_ROUNDS=1 ./tests/hw/test_soak.sh
# Longer multi-round soak + Wi-Fi/Ethernet matrix label (logs net snapshot via ssh)
SOAK_HOLD_S=15 SOAK_ROUNDS=5 SOAK_PROGRESS=1 SOAK_NET_LABEL=wifi ./tests/hw/test_soak.sh
# Ethernet row when cable is default route:
# SOAK_NET_LABEL=eth SOAK_HOLD_S=15 SOAK_ROUNDS=5 ./tests/hw/test_soak.sh
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

## Phase 3.3i/k host I-slice recon → F1 (product STREAM)

1. Conf: `PRESENT=both` (or `fpga`) and `STREAM=1` in `/media/fat/misterplex/misterplex.conf`.
2. Deploy: `./scripts/deploy_misterplexd.sh`.
3. Play Baseline 320×240 annex-B or direct H.264 Part (STREAM prefers direct H.264 over CABAC universal).
4. Log should show:
   - `STREAM=1 host I-slice recon →F1 +F3`
   - `recon frame ok #1 320x240 mb=300 …` (multi-IDR increments `idr=`)
   - session `recon=N` (N≥1 after first IDR); CABAC logs sticky skip once if High profile
5. Frame store shows reconstructed I-frame (not only decode_stub green border).
6. Fallback: if recon fails, FFmpeg RGB still drives F1 until first recon success (`PRESENT=both`).
7. Seek/stop: both FFmpeg groups killed; seek restarts demux at offset.
8. Optional: `STREAM_SKIP_RGB=auto` + `PRESENT=fpga` drops heavy RGB (audio kept).
9. Smoke: `./tests/hw/test_stream_recon.sh` (local Baseline + companion play).

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

## Phase 3.3f/j residual probe + hybrid present

1. Deploy RBF with residual token probe + 3.3j hybrid mux (`host_owns_fs`).
2. `./tests/hw/test_f3_residual.sh` — F3-only: `res_ok=1 res_tc=8 res_t1=3` (I_NxN first MB),
   `mb0=0 qp=25 has_frame=1` (stub diagnostic paint; no F1 so host_owns_fs clear).
3. Unit: `test_cavlc_dc` (host CAVLC + bit-exact recon maeY=U=V=0).
4. STREAM hybrid: host recon F1 owns product present; F3 residual status must not wipe F1.
