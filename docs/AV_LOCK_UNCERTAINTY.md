# A/V marker lock guarantee and uncertainty

## Designed lock (caller_supplied)

One content timeline in `scripts/gen_avsync_audio_id_fixture.py` /
`gen_avsync_glass_sync.py`:

- Video frame index `n` at time `t = n / 24` (fps rational **24/1**).
- Marker times `t_k = k * 2.000 s` → `n_k = round(t_k * 24)`.
- Audio packet/beep onset sample `i_k = round((t_k + delay_s) * 48000)`.
- Video body flash thr-cross centered on same `t_k` (ID band y&lt;88 never flashed).
- Single ffmpeg mux of ordered frame pipe + PCM file — no second clock domain
  at generate time.

Designed offset: `delay_s = 0` or `+0.100` (plus100 twin).

## What is **guaranteed** vs **not**

| stage | lock claim | uncertainty |
|-------|------------|-------------|
| Generator PCM+frames before encode | sample-accurate by construction | 0 (integer sample index) |
| After AAC in output MP4 | **not** sample-accurate | AAC LC framing ~21.3 ms; measured file median **\|offset\|≈0.15 ms** on glass-sync / audio-id fixtures (see verify JSON) |
| PMS Direct Play / optional transcode | unknown until measured | may re-encode audio again |
| misterplexd → HDMI | **not guaranteed by fixture** | daemon servo / MrAudio path; parent measures |
| HDMI grabber capture | **not guaranteed** | USB startup, 30 fps quant |

**Stated ceiling:** generator guarantees **content-timeline coincidence of marker
indices** (same `n_k` / `t_k`). It does **not** claim sub-sample lipsync through
AAC+daemon+HDMI. File-level self-verify bounds post-AAC error at **≪1 ms median**
on host; device residual is w-avsync’s measurement, not a fixture promise.

An unstated “perfect lock through the box” would be a rule-0 violation.

## Survive 529×240 video path

- Flash/ramp: **body only** y≥88, full width — not 1-line features.
- Glass bars: 31×32 px cells + even_row_paint (odd=even).
- Digits: large bold plate.
- Audio FSK: independent of video decimation (64 ms/bit).

## Scorers must not use PLXD voids

On RBF `c5382bee…`, ARM-visible `frames_done` is `bank_vsync_count` (vsync), not
publish count. **Ignore `frames_done` / `presents` / `drops` from PLXD** until a
new RBF. Use glass ID + audio checksum only.
