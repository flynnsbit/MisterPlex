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
