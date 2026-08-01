# Pre-registration — pause path is already 12×16; tool localize fix + canvas/font log

Written **before** parent deploy. Scoring: viewed pixels + quoted logs.

## Binary

- Branch `w-osd-hires`
- `make arm-plexd` → **md5=`14b00f600aa62ac0948e24273e7030a1`**, true rc=0
- Includes: sticky PAUSED, opaque panelBg+title (black-rect), pause canvas/font log, readback localize fix

## S1–S2 finding (source + re-measure)

**Pause authoring canvas (cited):**
- `media_player.cpp` `publishPausedOverlayFrame`: `plex480pDdrFrameGeometry()` → `cw,ch` → `overlay_.renderYuv420p(yuv, cw, ch)` → log `… 624x480`
- Host probe: `OverlayLayoutMetrics::compute(624,480)` → **font=12x16 scale=2**

**Contradiction resolved:** parent 341 / tool 8×13 was a **right-side false peak** (norm x≈517, score 0.55). Exhaustive left-half search: **12×16@2 at x=76 y=349 score 0.62**, `ink_span_output_px=441–452`. Coarse y-step=4 skipped y=350. **No short-H pause canvas.** Keep measured-font rewrite; fix localization.

## Host gates (true rc=0)

```bash
python3 tools/readback_overlay_text.py --selftest-pause-localize; echo "true rc=$?"
python3 tools/measure_overlay_word_span.py \
  --image files/device-evidence/osd_pause_3883f5ab_PAUSED_PASS.png --expect PAUSED; echo "true rc=$?"
# → family=12x16 ink_span_output_px=452
python3 tests/unit/test_pause_canvas_font_static.py; echo "true rc=$?"
```

## Deploy predictions (pause ≥6s sticky)

| ID | PASS | FAIL |
|---|---|---|
| **Log** | `media: pause overlay canvas=624x480 font=12x16 scale=2` and `pause overlay DDR ok latch=1 624x480` | canvas≠624x480 or font=8x13 |
| **PAUSED ink @1920** | **420–500** (12×16@2; archive 452) | **300–360** (old false 8×13/341 class) |
| **Localize** | `font=12x16` and meta `x<200` (left label) | `font=8x13` and `x>400` |
| **P1 empty-center** | mean luma ~50–70 grey | ≤35 black hole |
| **P3 sticky** | panel past 6s; bar≈t/T | missing panel |
| **STOPPED** | no regression; span @1920 **480–580** | span≤400 |

```bash
python3 tools/measure_overlay_word_span.py --image CAP_PAUSE.png --expect PAUSED; echo "true rc=$?"
python3 tools/readback_overlay_text.py --image CAP_PAUSE.png --expect PAUSED; echo "true rc=$?"
grep -E 'pause overlay canvas=|pause overlay DDR ok' misterplexd.log
```

**Falsify worker (pause already 12×16):** new capture with left-label localize still measuring 8×13-class span 300–360 **and** log `font=12x16` at 624×480 — that would re-open a real geometry gap.  
**Confirm tool-only fix:** archive already 12×16 left; deploy log font=12x16; new capture span∈420–500.

Conf: do not change user DECODE/PRESENT.
