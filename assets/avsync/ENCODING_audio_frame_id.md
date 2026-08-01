# Audio frame-ID contract (self-checking marker)

**Code:** `tools/audio_frame_id.py`  
**Generator:** `scripts/gen_avsync_audio_id_fixture.py`  
**Verify:** `tools/verify_audio_frame_id.py`

Labels: `caller_supplied` = design constant; `measured` = instrumented on a file.

## Why this exists

A bare click/beep cannot tell you *which* event you found. The video path became
trustworthy only when `c = digit_sum(n) mod 10` rejected bad OCR. Audio needs the
same property: **index + checksum in the signal**, accept only if checksum closes.

## Packet (one marker)

| segment | duration | content |
|---------|----------|---------|
| PREAMBLE | **80 ms** | sine **2500 Hz**, 1 ms linear attack |
| GAP | **10 ms** | silence |
| 20× BIT | **64 ms** each | FSK: **1000 Hz=0**, **1600 Hz=1** |

- **bits[0:16]** (MSB first) = `n & 0xFFFF` (video frame index at lock point)
- **bits[16:20]** = checksum nibble = `(nib0+nib1+nib2+nib3) & 0xF` of payload
- Packet duration = 0.08+0.01+1.28 = **1.37 s**
- Default period between packet *starts*: **2.000 s** (quiet gap ≈ 0.63 s)

### Example `n = 2358`

- payload `0x0936`
- nibbles 0x0+0x9+0x3+0x6 = 18 → checksum `0x2`
- word = `(0x0936 << 4) | 2`

## Lock to video

Marker index `k = 0,1,2,…` → content time `t_k = k * 2.000 s` → frame
`n_k = round(t_k * 24)` at **measured** `r_frame_rate=24/1`.

Video body flash (if present) thr-crosses at the same `t_k`. Audio packet onset
sample `i = round(t_k * 48000)` (plus optional deliberate `audio_delay_s`).

`offset_ms = (t_audio_onset - t_video_flash) * 1000` — same sign as
`tools/avsync_measure_hdmi.py`.

## Time resolution and sampling margin (load-bearing)

| quantity | value | src |
|----------|------:|-----|
| AAC-LC frame @ 48 kHz | **21.333 ms** (1024/48000) | caller_supplied |
| bit duration | **64.0 ms** = **3.00** AAC frames | caller_supplied |
| margin beyond 1 AAC frame | **+2.00** frames of steady tone | derived |
| onset attack | **1 ms** | caller_supplied |
| onset detect hop | **1 ms** Goertzel | caller_supplied |
| practical onset resolution | **~1–2 ms** on file | derived bound |

**ERROR 18/19 reminder:** never ship a marker shorter than the observation grid.
64 ms bit ≫ 21.3 ms AAC frame ⇒ positive margin after re-encode windowing.

If a future path uses heavier audio compression, **re-measure** decode success
after that encode; do not inherit this margin.

## Survive re-encode

Host gate re-encodes PCM→AAC (128k and 96k)→PCM and requires checksum-valid
recovery of every designed `n`. That approximates PMS/ffmpeg audio transcode,
**not** the full HDMI chain. Parent must confirm on device demodulation.

## Decoder algorithm

1. Goertzel power @ 2500 Hz, 1 ms hop, 8 ms window → preamble onsets.
2. From each onset skip preamble+gap; for each bit compare Goertzel(1000) vs (1600).
3. Parse payload+checksum; mismatch → `UNRESOLVED` (never guess `n`).
4. Optional cross-check: video bars/digits at flash frame must equal audio `n`.

## Long-soak drift arithmetic (duration justification)

Cumulative clock skew: `drift_ms = ppm × 1e-6 × T_s × 1000 = ppm × T_s × 0.001`.

| T | 5 ppm | 10 ppm | 50 ppm |
|---|------:|-------:|-------:|
| 600 s | 3 ms | 6 ms | 30 ms |
| **1800 s** | **9 ms** | **18 ms** | **90 ms** |
| 3600 s | 18 ms | 36 ms | 180 ms |

With ~2 ms onset noise, **1800 s (30 min)** makes ≥10 ppm drift a multi-σ
effect (18 ms). 600 s is marginal for 10 ppm (6 ms). Default long soak = **1800 s**.
