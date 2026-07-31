# OSD / playback chrome sharpness (w-osd-hires)

Status: ARM implementation — **vscale≥2 + even-y snap + string read-back**.  
Related: `host/libmisterplex/playback_overlay.hpp`, `arm/misterplexd/media_player.cpp`,
`fpga/Plex_MiSTer/rtl/present_core.sv`, `tools/readback_overlay_text.py`.

## Parent brief (source of truth — supersedes earlier lattice / scale=1 notes)

1. **RTL DE ceiling:** `present_core.sv` `H_DE=529`, `V_STORE=240`,
   `STORE_Y_SCALE=(FRAME_H*65536)/240` with product `FRAME_H=480` → exactly 2.0
   in 16.16. Scanout fetches **only even store rows** `{0,2,…,478}`. Odd content
   rows are deleted, not blended. ascal then scales ~529×240 → HDMI.
2. **scale=1 is character corruption, not blur.** `drawText` at scale=1 puts each
   glyph row on one content row; alternate glyph rows die. Documented failures:
   `8→0`, `6→C`, `E` loses middle bar. **bodyScale must be ≥ 2.** Text y-origins
   snap to even content rows so the surviving phase is deterministic.
3. **STOPPED capture path (hardware):** `paintIdle()` RGB24 intermediate at coded
   624×480 → `overlay_.renderRgb24` → RGB→I420 → DDR (`PRESENT=fpga`). Not a
   bypass of DDR. Playback/pause still needed `renderYuv420p` + pause publish
   (YUV branch was `break;`; pause SIGSTOPs the decoder).
4. **Acceptance metric:** **string read-back** via glyph template match. Exact
   recovery of a known string (e.g. `STOPPED`). Not 10–90% edge width (gameable
   by NN). Not lattice pitch (vertical arm vacuous on DE; horizontal AA-gameable).
   Tool: `tools/readback_overlay_text.py` (prints `true rc=` directly).

## What changed (this branch)

| Item | Change |
|---|---|
| Font | CC0 8×13 + 12×16; drawn at **bodyScale≥2** (block cells, not scale=1) |
| Y origin | `(y) & ~1` in `drawText`; panel top even; label/time snapped |
| Icons | `iconScale≥2` so vertical features survive odd-row cull |
| Layout | Proportional to buffer W×H; panel grows to fit scaled text |
| YUV | `renderYuv420p` + dirty-rect; wired in `media_player` Yuv420p branch |
| Pause | `publishPausedOverlayFrame` before SIGSTOP; STREAM-safe skip |
| Idle fb0 | coded canvas (not hardcoded 320×240) on product path |
| Gate | `tools/readback_overlay_text.py` + `tests/unit/test_overlay_text_readback.sh` |

## Compositing point

Composite **into the existing coded/present buffer** (pre-DDR), after content
letterbox into that buffer, before F1 publish. Do **not** composite at HDMI
resolution — fabric throws away odd rows and ARM cost would be waste.

## Layout model

`OverlayLayoutMetrics::compute(w,h)`:

- `bodyScale = max(2, h>=720 ? 3 : 2)` — odd-row cull floor
- Font: 12×16 when `h>=480 && bodyScale==2`, else 8×13
- Panel height fits `2 * glyphH * scale + bar + pads`
- Margins `max(6, w/40)`; bar thickness ∝ panelH

## Acceptance

```bash
# Must be RED on parent mangled capture (recovered ≠ STOPPED)
python3 tools/readback_overlay_text.py --selftest-red --expect STOPPED; echo "true rc=$?"

# Must be GREEN on synthetic fixed render after even-row cull
python3 tools/readback_overlay_text.py --selftest-green --expect STOPPED; echo "true rc=$?"

# Unit (includes even-row STOPPED template match + scale=1 mid-bar death proof)
make -C . unit  # or targeted test_playback_overlay
```

Parent hardware check (parent only — agents do not touch the device):

```bash
# after arm deploy: stop/pause a cast, capture HDMI, then:
python3 tools/readback_overlay_text.py \
  --image /path/to/capture.png --expect STOPPED; echo "true rc=$?"
```

## Out of scope

Raising `V_STORE` / changing `STORE_Y_SCALE` (exclusive Quartus). Only after ARM
path still fails read-back on silicon with evidence.

## Licence

Overlay bitmaps: hand-authored geometric cells for MiSTerPlex, **CC0-1.0**.
