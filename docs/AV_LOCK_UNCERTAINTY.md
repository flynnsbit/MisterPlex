# A/V marker lock — guarantee and **measured** uncertainty

**Fixtures:** `sync_audio_id_glass_*`, `sync_glass_av_*`  
**Generators:** `scripts/gen_avsync_audio_id_fixture.py`, `scripts/gen_avsync_glass_sync.py`  
**Verify artifacts (checked in):** `assets/avsync/verify_sync0_600.json`, `verify_p100_600.json`, `verify_audio_id_1800.json`

## Designed lock (caller_supplied construction)

One content timeline, one ffmpeg mux (frame pipe + PCM):

| quantity | definition |
|----------|------------|
| fps | **24/1** (must be ffprobe-measured on output; never inherit PMS) |
| marker times | `t_k = k * 2.000 s`, `k = 0,1,…` while `t_k < duration` |
| video frame | `n_k = round(t_k * 24)` |
| video event | **body-only** luma ramp (y ≥ 88), 4 frames centered on `t_k`; ID band never flashed |
| audio event (AudioID) | FSK packet onset sample `i = round((t_k + delay_s) * 48000)` |
| audio event (AVSync glass) | 1 kHz beep, 1 ms attack, same `i` |
| designed offset | `delay_ms ∈ {0, +100}`; sign = `(t_audio − t_video) * 1000` |

Pre-encode PCM/frame indices are **integer-exact** (sample-accurate by construction).

## What is **not** guaranteed

| stage | claim |
|-------|--------|
| After AAC in the MP4 | **not** sample-accurate (AAC-LC frame 1024/48000 ≈ 21.333 ms) |
| PMS optional re-transcode | unknown until you measure that path |
| misterplexd → MrAudio → HDMI | **not** guaranteed by the fixture |
| Grabber capture | **not** guaranteed (USB / 30 fps quant) |

**Saying “sample-accurate through the box” would be a rule-0 lie.** The fixture guarantees **coincident marker indices on the content timeline** and ships file-level bounds after AAC.

## Measured file-level bounds (src=measured, host verify)

From `tools/verify_avsync_glass_fixture.py` on **600 s** encodes (n_pairs=300):

| file | expect_ms | median_ms | min_ms | max_ms |
|------|----------:|----------:|-------:|-------:|
| `sync_glass_av_480p24_600s.mp4` | 0 | **−0.145** | −0.146 | 0.000 |
| `…_audioPlus100ms.mp4` | +100 | **+99.856** | +99.531 | +99.856 |

Flash recovery: n_flashes=300, **n_interp=299** (ramp path).  
ffprobe both: 624×480, **r_frame_rate=24/1**, nb_frames=14400, CB, has_b=0, AAC 48 kHz.

AudioID packet recovery after AAC in MP4 (`verify_audio_frame_id.py`):

| file | markers checksum-OK |
|------|--------------------:|
| 60 s | **30 / 30** |
| 1800 s | **900 / 900** |

AudioID onset times on 1800 s head (measured): t≈0.000, 1.997, 3.997, … (≈3 ms early vs integer seconds — AAC/decoder delay class, stable).

**Summary bound to quote:** post-AAC file median |error vs design| **≤ 0.15 ms** (0-offset) and **≤ 0.15 ms** (+100 design). Device lipsync uncertainty is **your** measurement on top of this.

## Video markers vs pipeline (H.264 + 529×240 + 2 resamples)

Designed large on purpose:

- Body flash/ramp: full width, y∈[88,480) — **not** 1-line stripes (H.264 kills those; see Nyquist note).
- Glass ID: opaque plate + 31×32 bar cells + even_row_paint; digits fixed-width + checksum.
- Audio: 64 ms FSK bits = 3 AAC frames margin (independent of video decimation).

Do **not** use PLXD `frames_done` / `presents` / `drops` / `unaccounted` (void/mislabelled on live RBF).

## Nyquist cast MP4s are **not** the 240-vs-480 test

`disc_nyquist_*.mp4` remain in-tree as host-sim toys only. **H.264 destroys 1-row Nyquist** before the core — same failure mode as the inconclusive spectral test. **w-instr owns `publishDdrFrame` raster publish** for B2. Do not cast disc_nyquist to settle tier.
