# FOAR-into-618 filter defect (parent miss + product fix)

## PREDICTION MISS (publish)

| Item | Value |
|------|--------|
| Pre-registration | rk6 Transcoder argv would show `scale=…:h=350` (vs 348/352/480) |
| Measured (parent) | rk6 **and** rk36: identical `scale=w=624:h=480:force_divisible_by=4` |
| Verdict | **MISS** — mechanism is **not** PMS output height |

Asset-class DAR/SAR analysis (rk6 `aspectRatio=1.78` SAR `160:117` vs AdvReal `1.33`/`1:1`) remains useful for *why* FOAR letterboxes 16:9 harder than 4:3. The *locus* was wrong: loss is our daemon `-vf`, not PMS.

## Where 350 came from (device evidence)

Live `/proc/<pid>/cmdline` on misterplexd’s ffmpeg:

```
-vf fps=24/1,scale=618:480:flags=fast_bilinear:force_original_aspect_ratio=decrease,\
    pad=624:480:0+(618-iw)/2:0+(480-ih)/2:color=black
```

| content | FOAR box | picture rows | frac of 480 |
|---------|----------|--------------|-------------|
| rk6 16:9 DAR | 618×480 | ~348 | ~72.5% |
| rk36 4:3 | 618×480 | ~464 | ~96.7% |

Byte check: `624×350×1.5 = 327600` (producer_bytes when measured short).

## RCA: why 618?

| Constant | Value | Role |
|----------|-------|------|
| `DDR_FRAME_CODED_WIDTH` | 624 | I420 bank / reader frame (= 39 MB × 16) |
| `kPlex480pDisplayWidth` | **618** | Visible window; `crop_right=6` for present/RTL |
| `DDR_FRAME_PRESENTED_WIDTH` | 640 | HDMI present (+11+11 pillar) |

**618 is deliberate and bitstream-grounded — not a chroma typo.**

Quoted product contract (`host/libmisterplex/ddr_frame_layout.hpp:11-24`):

```cpp
//   coded 624x480  — H.264 payload and DDR bank layout
//   display 618x480 — after right crop of 6
//   presented 640x480 — VGA scanout after 11+11 pillarbox
constexpr DisplayWidth kPlex480pDisplayWidth{618};
constexpr int kPlex480pCropRight = 6;
```

PMS H.264 SPS (docs/pms-baseline-profile.md): `coded=624x480 display=618x480 crop_lrtb=0,3,0,0 crop_unit=2x2` → frame_crop_right_offset 3 × unit 2 = **6 px** → 624−6=**618**. RTL `DDR_FRAME_DISPLAY_WIDTH=618` matches (`fpga/.../ddr_frame_layout_params.svh`).

So 618 is the **H.264 frame-crop / silicon display window**, not unjustified. The **defect** is using 618 as a **FOAR scale target** in `-vf` (destroys rows) instead of applying it only at present/crop_pad.

**Device still showing `scale=618:480:FOAR`:** deploy tip **≥ e96dabae** (FOAR→coded 624). Pre-deploy binaries still emit the old string.

## Loss 2 (parent 2026-08-02) — independent, compounds

| maxVideoBitrate request | measured delivery | samples |
|-------------------------|-------------------|---------|
| 397 | **312×240** | 40 |
| 2000 | **624×480** | 39 |
| 397 (repeat) | **312×240** | 40 |

Asset is truly 624×480 @ ~397 kbps. Low bitrate request → PMS half-res before our filter runs. At 397 we upscale 312×240 → bank (Loss2 × Loss1).

Telemetry: `BANK_FILL` + `DELIVERY_MISMATCH_FINAL` carry `delivered_v_frac`, `delivered_area_frac`, `post_scale_picture`, `compound_vertical_detail_frac`, `loss2_half_res=1` when mw*2==bank_w && mh*2==bank_h.

**Bitrate ownership: w-cpu-1** — this lane does not change `plex_resolve` bitrate.

## Product policy (16:9 in a 624×480 bank)

Square-pixel 16:9 at 480 rows needs ~854 px width — **exceeds** synthesis-fixed coded bank (`ddr_frame_layout_params.svh`). No authorised RBF widen.

| Option | Rows | Aspect | Cost |
|--------|------|--------|------|
| **A** FOAR letterbox into bank | ~350 | correct | loses ~27% vertical detail (user: “not 480p”) |
| **B** crop_pad / identity on bank-exact 624×480 | **480** | anamorphic unless display applies SAR | keeps samples; prefer when PMS delivers bank-exact |
| **C** pan-scan | 480 | crop sides | loses horizontal |
| **D** wider bank ~854 | 480 | square 16:9 | **RBF** — not authorised |

**Policy shipped:**

1. Bank-exact claim (source==coded, unverified): **crop_pad**, no FOAR — keep 480 rows.
2. Non-exact / unknown needing resample: **FOAR into coded 624**, never display 618; center pad. Honest letterbox for true widescreen sources.
3. `buildScalePadCropped` = **LEGACY** only (unit red/mutation).
4. Do **not** force 4:3 geometry onto real 16:9 content.
5. Bitrate / `plex_resolve` floors: **w-cpu-1** — not this lane.

## Telemetry

- `FILTER_CHAIN_LOSS` at plan time (predicted FOAR picture height + frac).
- `FILTER_CHAIN_LOSS_FINAL` when FOAR predicted_h < bank_h.
- `ERROR FILTER_CHAIN_DEFECT` if `scale=618:480` ever appears (regression).
- Keep `REQUEST_VS_MEASURED` / `DELIVERY_MISMATCH_*` / `vertical_detail_frac`.

## 16:9 policy (recommend B when bank-exact)

| Opt | Behaviour | Rows kept | Aspect | Cost |
|-----|-----------|-----------|--------|------|
| **A** FOAR letterbox into bank | ~350 / 480 ≈ 72.5% | correct square-pixel | “not 480p” look |
| **B** crop_pad / keep samples on bank-exact 624×480 | **480** | anamorphic unless display SAR | preferred when PMS delivers bank-exact |
| **C** pan-scan | 480 | crop L/R | loses width |
| **D** wider coded bank ~854 | 480 | square 16:9 | **RBF / exclusive Quartus** — not authorised |

**Recommendation: B for bank-exact delivery; A only when source is not bank-exact.** Do not force 4:3 onto real 16:9. Wider bank is the only way to get square 16:9 at 480 rows inside product geometry — needs parent RBF authorisation.

## PRE-REGISTER — rk6/rk9 @ request=2000 (parent runs)

| Field | Prediction | Why |
|-------|------------|-----|
| `measured=` / `delivered_geom` | **624x480** | Parent A/B: request=2000 → 624x480; PMS Transcoder argv was `h=480` for rk6 (prior miss was predicting h=350 at PMS) |
| NOT 350 | yes | 350 was FOAR picture height / DAR fit, not Input banner size |
| NOT 312x240 | yes | 312 is Loss2 at request≈397, not 2000 |
| post-deploy `e96dabae+` vf | `crop=618:480…,pad=624:480` if claim exact 624x480; never `scale=618:480:FOAR` | product tip |
| `delivered_v_frac` | **1.0** | 480/480 |
| `compound_vertical_detail_frac` | **1.0** if crop_pad; **~0.73** only if FOAR letterbox still active | |
| `loss2_half_res` | **0** | |

**If measured=312x240 at request=2000 → MISS** (bitrate ladder / different asset).  
**If measured=624x350 → MISS** (banner/parser or unexpected).  
**If vf still `scale=618:480:FOAR` → deploy lag**, not tip regression.

## Parent device checks (agent does not run)

```bash
# After deploy tip ≥ e96dabae: no FOAR into 618
tr '\0' ' ' </proc/$(pgrep -n ffmpeg)/cmdline | grep -E 'scale=|crop='
# expect: crop=618:480… OR scale=624:480:FOAR=decrease — NEVER scale=618:480:FOAR

grep -E 'BANK_FILL|DELIVERY_MISMATCH_FINAL|FILTER_CHAIN_|MEASURED_DELIVERY_FINAL' daemon.log
# Loss2: delivered_geom=312x240 delivered_v_frac≈0.5 loss2_half_res=1
# Full:  delivered_geom=624x480 delivered_v_frac=1.0 compound≈1.0 (crop_pad)
```

## ARM-only

No RBF. Parent can test immediately after daemon deploy. No bitrate edits (w-cpu-1).
