# Encoding contract — `gen_avsync_glass_sync.py`

**Generator:** `scripts/gen_avsync_glass_sync.py`  
**ID band:** `tools/glass_frame_id.py` + `docs/glass_frame_id_contract.md`  
**Self-verify:** `tools/verify_avsync_glass_fixture.py`

Every element below is **caller_supplied** design. Timings marked **measured** come
from running the verifier on the produced file (not from HDMI).

## Coded stream

| field | value |
|-------|-------|
| geometry | **624×480** (DDR bank) |
| frame rate | **24/1 exactly** (NOT 23.976) |
| duration default | **600 s** → ground-truth **14400** frames |
| video | H.264 Constrained Baseline, `bf=0`, CAVLC, yuv420p |
| audio | AAC **48 kHz** stereo |
| marker period | **2.000 s** (every 48 content frames) |

## Per-frame identity (always on — never gated)

Same OCR-proof contract as rk=13 soak. Full detail: `docs/glass_frame_id_contract.md`.

| element | encoding |
|---------|----------|
| opaque plate | y∈[0,56), solid black RGB(0,0,0) — **not** alpha |
| text | yellow `G n=DDDDDD c=C` at (8,6), DejaVu Bold 40, stroke 3 |
| **DDDDDD** | zero-padded frame index, **fixed width 6** |
| **checksum C** | `(d0+d1+d2+d3+d4+d5) mod 10` of those six digits |
| bar strip | y∈[56,88), **20 cells × 31 px**, x=`[i*31,(i+1)*31)` |
| bar bits MSB-left | START=1 \| grey bit15…0 \| even parity \| STOP=0 \| LOCK=1 |
| grey | `g=(n&0xFFFF)^((n&0xFFFF)>>1)` |
| parity | `popcount(g)&1` |
| even-row paint | odd rows copy even (STORE_Y_SCALE=2 survival) |

**Example n=2358:** text `G n=002358 c=8` (2+3+5+8=18→8); grey `0x0DAD`;
bits `[1,0,0,0,0,1,1,0,1,1,0,1,0,1,1,0,1,0,0,1]`.

Bars are **authoritative**; digits secondary. Disagree → UNRESOLVED.

## A/V sync marker (period T=2.000 s)

### Designed offset

| variant | `audio_delay_ms` | designed `t_audio − t_video` |
|---------|-----------------:|-------------------------------|
| sync0 | **0** | **0.000 ms** |
| sync100 | **+100** | **+100.000 ms** (audio LAGS video; beep after flash) |

Sign convention matches `tools/avsync_measure_hdmi.py`:
`offset_ms = (t_audio_onset − t_video_flash) * 1000`.

### Video marker (body only — ID band never flashed)

- Region: **y ≥ 88** (below bars). Plate+bars+text stay opaque black / yellow
  every frame so OCR/checksum survive the marker (FLASH-destroys-OCR failure mode).
- Shape: **4-frame linear luma ramp** black→white centered on each marker time
  `t_k = k * T`, then 1-frame peak hold, then black.
- Why ramp: capture at 30 fps needs multi-frame rise for `flash_onset_n_interp`
  (see `scripts/gen_avsync_ramp_soak.py` derivation).
- Simultaneity (sync0): ramp is centered so instrument thr
  (`floor + 0.5*contrast` ≈ mid luma) crosses at **phase 0 of the marker period**,
  same content time as the beep attack.

Marker content times: `t_k = 0, 2, 4, …` while `t_k < duration`.
Frame index of thr-crossing (ideal): `n_k = round(t_k * 24)`.

### Audio marker

- 1 kHz tone, **50 ms** body, **1 ms** linear attack envelope (sharp onset).
- Onset sample (sync0): `i_k = round((k*T + audio_delay_s) * 48000)`.
- Stereo identical L/R s16le → AAC 48 kHz.

Both streams muxed in **one** ffmpeg process from one ordered frame pipe + one
PCM file. No second timeline, no `itsoffset` on the zero-offset variant.
The +100 ms variant delays beep times inside the PCM generator only
(`audio_delay_ms=100`); video unchanged.

## Self-verify (required before ship)

```bash
python3 tools/verify_avsync_glass_fixture.py --mp4 path.mp4 --expect-offset-ms 0
python3 tools/verify_avsync_glass_fixture.py --mp4 path_plus100.mp4 --expect-offset-ms 100
```

Verifier reports measured median `(t_audio−t_video)` from **file** PTS/samples
(labelled `measured`), designed offset (`caller_supplied`), and PASS/FAIL.
