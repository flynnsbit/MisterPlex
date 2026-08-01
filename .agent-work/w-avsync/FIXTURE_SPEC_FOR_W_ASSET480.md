# w-asset480 — A/V marker requirements (w-avsync)

Relay from w-avsync-lane. Full text: `docs/AVSYNC_REPLACEMENT_METRIC.md`.

## Must ship on every geometry (624×350, 426×240, 624×480, 640×480, 720×480, 624×352) @ 24.000 and 30.000

| Item | Spec |
|------|------|
| Period | **2.000 s** |
| Primary offset | **0 ms** flash↔beep |
| Twin | `*_audioPlus100ms` audio **+100.0 ms** |
| Flash | full-frame white, peak≥220, floor≤20, **≥2 frames** |
| Beep | 1 kHz, 50 ms, −1…−3 dBFS, 1 ms attack |
| FPS | exact **24/1** or **30/1** (never 23.976) |
| H.264 | Constrained Baseline, no B-frames |
| Duration | ≥120 s (prefer 600 s one 480p) |
| Counter | **every frame including flash**; on white: **black text or yellow-in-black-box** (w-instr OCR hallucinated yellow-on-white) |

## Host gate before PMS
```bash
python3 tools/verify_avsync_glass_fixture.py --mp4 ZERO --expect-offset-ms 0 --period-s 2 --tol-ms 5
python3 tools/verify_avsync_glass_fixture.py --mp4 PLUS --expect-offset-ms 100 --period-s 2 --tol-ms 5
```

## Grabber audio (for parent)
MS2109 = `/dev/video0` + ALSA `hw:0,0` — lipsync measurable. Do not omit audio markers.
