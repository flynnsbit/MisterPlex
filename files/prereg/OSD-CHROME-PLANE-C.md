# Pre-register: option (c) post-scale chrome plane

**Doc:** `docs/osd-chrome-plane-design.md`  
**Worker:** w-osd-hires  
**Fit:** NOT requested. Slot stays closed until G0 + solo-module area ceilings.

## Architecture (one line)

`plex_chrome` after ascal on HDMI path; **display-list** glyph/icon rasterizer;
geometry from **HDMI W×H**; font/list in **≤24 M10K** (budget ceiling 40).

## Resource pre-reg (estimates — not Quartus)

| Resource | Estimate | Hard ceiling before fit grant |
|---|---|---|
| M10K | 16–24 | **≤40** delta vs baseline 465 |
| ALM | 1.5k–4k | **≤5k** |
| DSP | 0–2 | **≤4** |

Baseline free: **88 M10K**, 20815 ALM, 38 DSP. Full-frame BRAM = REJECT.

## G0 host (now)

```bash
python3 tests/unit/test_chrome_output_layout_static.py; echo "true rc=$?"
```

PASS: panels in-bounds for 1920×1440 / 1080 / 720 / 800×600 / 640×480 / 320×240;
bodyScale monotonic; mode12 scale=6 advance=78.

## Silicon gates (after RBF only)

| ID | PASS | FAIL |
|---|---|---|
| S-sharp | glyph stem edge median ≤2 grabber px @ mode12 | ≥4 (today mush) |
| S-adv | advance ≈ 13×bodyScale(H) ±10% **and** sharp | soft edges + bank-stretch signature |
| S-240 | panel on-screen @ 240p-class | overflow |
| S-area | fit RAM delta ≤40, no neg STA | over budget / STA fail |

**Falsify (c):** sharp PASS but chrome still tracks F1 even-row / 624 bank.

## Not the fix

`bodyScale=3` on 624×480 bank → larger mush, not output-native chrome.
