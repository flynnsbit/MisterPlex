# Pre-registration — black-rectangle P1 (deploy ARM md5 `14b00f600aa62ac0948e24273e7030a1`)

Written **before** parent deploy/capture. Tip docs may be later; **binary md5** is the score key.

## O1 — fix intact

- `playback_overlay.hpp`: `panelBg{42,46,54}` full `alpha` fill of `panelBounds` before icons/text/bar
- Title band optional (`setTitle` / `setOverlayTitle` on play)
- Host: `test_playback_overlay` → `Ywhite=Yblack=Ymid=55.6 |d|=0.0` (content-independent)
- Static: `test_panel_empty_center_static.py` true rc=0
- Sticky PAUSED + pause publish still present (not regressed by `4ed6a096` / `eab6471a` / `1c531e3f`)

## O3 — score region @ **1920×1080 grabber** (not canvas)

Archive **pre-fix** (`osd_pause_3883f5ab_PAUSED_PASS.png`, translucent black era):

| region | x0–x1 | y0–y1 | mean luma (measured) |
|---|---:|---:|---:|
| **P1 empty-centre (score box)** | **760–1220** | **810–910** | **~31–34** |
| parent hand band | 740–1190 | 809–910 | ~31.1 |
| video above panel | 800–1100 | 600–700 | **253** (near-white) |

Layout map (product 624×480 → grabber): empty band mid-panel between label row and time row, middle third width — maps to approximately the box above (`247–397 × 360–404` canvas × `1920/624` × `1080/480`).

### PASS / FAIL (mean luma of score box, pause ≥6 s sticky)

| | mean luma in **x∈[760,1220], y∈[810,910]** |
|---|---|
| **PASS** | **45–80** (opaque chrome grey; host YUV empty-centre ≈55.6) |
| **FAIL** | **≤35** (pre-fix hole class; archive ~31) |
| UNSCORED | panel missing / wrong geometry / tool rc=77 |

### Content independence

Host unit paints empty centre on Y=16 / 128 / 235 video fills → same Y≈55.6 (|d|<8).  
**PASS band 45–80 is intended to hold for both dark and bright video** behind the panel.  
If bright video still punches through (mean tracks video toward 200+), that **falsifies** opaque fill.

**Falsify the fix:** score-box mean **≤35** on a capture that also shows sticky PAUSED chrome (panel edge/luma high elsewhere), **or** mean on white video exceeds mean on black video by **>15** in the same box.

### Expected log (pause path)

```
media: pause overlay canvas=624x480 font=12x16 scale=2
media: pause overlay DDR ok latch=1 624x480
```

(Geometry/font log is diagnostic; P1 is **pixels**.)

### Parent measure sketch

```bash
# after deploy md5=14b00f60… pause ≥6s capture CAP.png 1920x1080:
python3 - <<'PY'
from pathlib import Path
# reuse tools
import sys
sys.path.insert(0,'tools')
from readback_overlay_text import load_png_luma
w,h,rows=load_png_luma(Path('CAP.png'))
assert (w,h)==(1920,1080)
xs,ys=range(760,1221),range(810,911)
vals=[rows[y][x] for y in ys for x in xs]
m=sum(vals)/len(vals)
print(f'mean_luma={m:.2f} n={len(vals)} PASS={45<=m<=80} FAIL={m<=35}')
PY
echo "true rc=$?"
```

## O4 — localize red-before-green (host)

```bash
python3 tools/readback_overlay_text.py --selftest-pause-localize; echo "true rc=$?"
# RED_legacy: font=8x13 x>400 (ghost)
# GREEN_fixed: font=12x16 x=76
# verdict=PAUSE_LOCALIZE_PAIR_OK  true rc=0
```

## Settled (not P1)

PAUSED=STOPPED=**12×16@624×480**. Output-native chrome = RTL (c) later. Do not PASS resolution bug on this deploy.
