# Route B content DE budget (rd-duck BLOCKING)

## Defect

w-path can auto-select `TranscodeHd720` / store 1280×720 for sources >720, while
first-fit fabric is `PRESENT_BEAM_960` **without** `PRESENT_MULTI_PIXEL` (1ppc @
20 MHz). A **content** DE of 1280×720 is not HDMI glass:

| Quantity | Value | Source |
|----------|-------|--------|
| Active @24 | 1280×720×24 = **22.118 Mpix/s** | > 20 MHz clk_sys |
| Beam min pads | H+32, V+16 | `present_beam_content_de.sv` |
| Totals if DE=1280×720 | 1312×736 | clamp floors |
| Beam fps | 20e6/(1312×736) = **20.712 Hz** | both film and TV classes |
| Result | Silent under-scan / drop | library HD>720 items |

Route B glass remains ascal → HDMI 1280×720; **core content max tier is 960×540**.

## Fix (this commit)

1. **Host** `MediaPlayer::setDecodeSize`: cap **960×540** (`kRouteBMaxContent*`).
   Removes silent `1280×720` ceiling.
2. **Constants/helpers** in `ddr_frame_layout.hpp`:
   `routeBContentDeExceedsClk`, `routeBBeamMinBlankMissesFps`.
3. **Fabric** `present_core` BEAM_960: `RT_MAX_HDE/VACT=960/540` clamp;
   elab forbids FRAME>960×540; keeps MULTI_PIXEL mutex.
4. **Gate** `tests/unit/test_route_b_content_de_budget.sh` — 1280 path RED;
   max-tier GREEN; host/fabric structure.

## w-path (sibling — do not merge bare)

`TranscodeHd720` auto for source>720 must **not** land on first-fit without:

- content/request/store ≤960×540, **or**
- loud reject/fallback, **or**
- fitted `PRESENT_MULTI_PIXEL` product (not first-fit ascal path).

## Not claimed

- No Quartus fit / no device.
- Does not enable multi-pixel 1280 content DE.
- B7 store maps for 720p banks remain w-mem; content **DE** still capped here.
