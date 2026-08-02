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
| `DDR_FRAME_CODED_WIDTH` | 624 | I420 bank / reader frame |
| `kPlex480pDisplayWidth` | **618** | Visible window; `crop_right=6` for present/RTL |
| `DDR_FRAME_PRESENTED_WIDTH` | 640 | HDMI present |

**618 is deliberate** (`ddr_frame_layout.hpp`) as the **display crop** width, **not** a FOAR scale target. Product comments already banned FOAR-into-618 for bank-exact claims (`force_exact_crop_pad_unverified` → `crop=618:480,pad=624:480`). The **non-exact Always path** still called legacy `buildScalePadCropped(618,…)` → live defect on any source that did not take the exact-crop branch (or on older binaries that FOAR’d exact claims).

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

## Parent device checks (agent does not run)

```bash
# After deploy tip: no FOAR into 618
tr '\0' ' ' </proc/$(pgrep -n ffmpeg)/cmdline | grep -E 'scale=|crop='
# expect: crop=618:480… for bank-exact claim OR scale=624:480:FOAR=decrease (never scale=618:480:FOAR)

grep -E 'FILTER_CHAIN_|REQUEST_VS_MEASURED|DELIVERY_MISMATCH|MEASURED_DELIVERY_FINAL' /path/to/daemon.log
# expect: foar_into_618=0; bank-exact rk6 → filter_vertical_detail_frac=1.0 (crop_pad)
```

## ARM-only

No RBF. Parent can test immediately after daemon deploy.
