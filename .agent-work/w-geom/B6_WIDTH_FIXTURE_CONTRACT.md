# B6 WIDTH fixture contract — w-geom → w-asset480

**Do not build fixtures in parallel.** w-asset480 owns packaging/indexing.
w-geom owns vf policy + host gates + parent look-for on glass.

## Geometry contract (coded bank fixed)

| Field | Value | Notes |
|-------|------:|-------|
| coded | **624×480** I420 | reader / DDR bank = **449280** B |
| display | **618×480** | crop_right=6 |
| presented | 640×480 | HDMI present stretch of display |

## Deliverables needed from w-asset480 (playable H.264 in PMS)

| rank | WxH | purpose | expected product vf class (tip) |
|-----:|-----|---------|----------------------------------|
| W1 | **640×480** | WIDTH > bank, H exact | `crop_pad_no_v_scale_hfit` center-crop `(iw-618)/2` |
| W2 | **720×480** | DVD-ish WIDTH > bank | same hfit |
| W3 | **426×240** | parent measured PMS tier (≠ claim) | `scale_pad_crop` FOAR into 618 |
| V1 | **624×350** or **624×352** | vertical-only (already have BBB 624×352) | `scale_pad_crop` |
| CTRL | **624×480** | bank-exact control | `force_exact_crop_pad_unverified` (play-time) |

Optional OCR/counter overlay on W1/W2 (single TREK-style counter, full-bleed) so glass can show **one** counter when scale/crop is correct vs N≥2 when pipe desyncs.

## What parent should LOOK AT (device)

After deploy tip daemon + cast each asset ≥30 s:

1. **Log GEOM / MEASURED_DELIVERY**
   - `MEASURED_DELIVERY delivered_geom=<actual>x… src=ffmpeg_banner delivery_basis=measured`
   - W1: measured≈640×480; vf reason `crop_pad_no_v_scale_hfit`; **no** `force_original_aspect_ratio=decrease`
   - W3: measured≈426×240; `scale_applied=1`; pad=624:480
   - CTRL: `force_exact_crop_pad_unverified`; crop=618:480; **no** FOAR
2. **Teardown B5**
   - `pipe_align ok total_mod_frame=0` OR loud `PIPE_BYTE_MISALIGN` / `PIPE_DESYNC=1`
3. **Glass**
   - Single full-frame picture, no horizontal wrap/magenta
   - W1/W2: content fills display width (center crop of wider source) — **not** pillarboxed 640 island
   - If counter overlay: **N=1** legible copy (N≥2 ⇒ producer S≈449280/N desync class)

## Host gates already green (no device)

- `test_ffmpeg_vf` GREEN_WIDTH_MISMATCH w640/w720 hfit, v350/d426 scale
- `test_force_scale_ffmpeg_out.sh` crop_pad + scale paths pin 449280; identity RED leaks size
