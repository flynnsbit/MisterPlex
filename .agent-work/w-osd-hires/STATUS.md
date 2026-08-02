# w-osd-hires status

## ≤10-line summary
1. ERROR-18 mechanism **retracted** (source hist): label runs multiples of scale; no 5×7 on tip.
2. Parent 5×7 cite is **stale**; prior tip was 12×16@2 cellH=32; now **24×32@2 cellH=64**.
3. Source LABEL hist PASS `true rc=0`; odd runs=0; display bins need stretch/bar not 1px theory.
4. Primary host fix: stroke-raster **Hires24x32** (not NN of 12×16) on product bank path.
5. Log: `font=24x32 cell=48x64 scale=2` + HALF A `source=ini:*`.
6. Fabric plane still required for true HDMI-native chrome (240-line even-row ceiling).
7. No device touch; no Quartus request.

## Parent glass check after daemon deploy
```bash
# pause STOPPED/PAUSED, capture 1080p HUD crop, compare stroke hist + glyph ink height
# Expect: taller unique stems (source maxVert~52 bank → ~117 @2.25×) vs BEFORE cell 32 path
# BEFORE archive: files/device-evidence/hud_1080p_BEFORE_8fdf440f.png
```
Expect log: `font=24x32 cell=48x64` not `font=12x16`. Soft blockiness may remain until plane=1.
