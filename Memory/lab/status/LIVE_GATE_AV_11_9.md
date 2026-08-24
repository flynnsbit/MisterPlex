# Live 720p gate (parent 2026-08-14 00:14Z)

Automated: `scripts/run_720p24_live_gate.sh` (lessons).
Clip `/tmp/real720p_1500k_av.mp4` (same video + 1 kHz AAC).
j copied onto `Plex.rbf` for probe prefix, menu→Plex, play, restore `07f54d9f`.

| | silent T7b | **this gate** |
|--|--|--|
| audio | off (`-an`, no stream) | **on** `audio_s=7.765` |
| pfps / hw_fps | 14.1 / 14.10 | **11.9 / 11.95** |
| av_drift_ms | 991→5916 (dead clock) | **~427 stable** |
| drops | 0 | 0 |
| ACK | 16:9 | 16:9 |
| glass | L4 leftover magic | L4 disk `968b828a` |

**GATE FAIL.** Unique still the ~15 class (worse with audio on). Video lead ~427 ms.
Audio on **adds** DDR3 contention. Isolated F=32.31 still the producer ceiling.

Next unique-24 lever is **PATH_SDRAM** (scanout off the stick), not another sidecar.
Soft-skip ≠ PASS.
