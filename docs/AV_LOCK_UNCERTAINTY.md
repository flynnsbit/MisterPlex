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

## Video markers vs pipeline (H.264 + V_STORE=240 + 2 resamples)

### Established device fact (parent, RBF `c5382bee`, product `publishDdrFrame`, codec out)

Even/odd flat-field card on glass: control mid_grey mean=137 std=**0.00**; even_black→black, even_white→white; **odd_black→white, odd_white→black** (inverted solids). **std=0.00** ⇒ odd store rows are **entirely absent** — not attenuated stripes. Vertical path fetches only even rows (`store_y = py*2`). **50% of coded rows never reach display.** Horizontal 529-of-640 remains **arithmetic-only** on this card (not glass-proven here).

### Fixture design under that fact

- Body flash/ramp: full width, y∈[88,480) — many consecutive **even** rows so the flash survives 2:1 vertical fetch. **Not** 1-line stripes (H.264 kills Nyquist; parent spectral test was INCONCLUSIVE for the same reason).
- Glass ID: opaque plate + 31×32 bar cells + **even_row_paint** (odd source rows copy even−1 so the kept phase still carries ID after cull). Digits fixed-width + checksum.
- Audio: 64 ms FSK bits = 3 AAC frames margin (independent of video row cull).

Host measured body contrast after H.264 decode + even-row cull sim: **255** (AudioID 60s marker neighborhood). Device glass still parent-owned.

### Do not score these names (derivation in the same breath)

| name | derivation on `c5382bee` | implication |
|------|--------------------------|-------------|
| `frames_done` | **vsync counter**, not bank swaps | frozen picture can look “live”; `[STALE]` may never fire |
| `presents` | call returned, not glass | not display |
| `drops` / `residual` / `unaccounted` | ARM supply; `unaccounted` ≡ residual printed twice | **no FPGA observation** |

## Nyquist cast MP4s are **not** the 240-vs-480 test

`disc_nyquist_*.mp4` are host-sim only. H.264 band-limits below the ceiling; **w-instr `publishDdrFrame` even/odd card already settled vertical B2 on glass.** Do not cast disc_nyquist to re-prove tier. Post-fix (w-geom T7 → 480 unique rows) the same card must **break** solid-field collapse — that is the after bank, not a cast MP4.
