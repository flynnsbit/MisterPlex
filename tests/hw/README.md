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
