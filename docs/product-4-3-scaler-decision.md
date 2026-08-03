# Product 4/3 scaler decision (w-scaler)

**Commit:** `6deb5af7` `present_scale_4_3.sv` · tip follow-ups on branch `w-scaler-window`  
**Path:** PMS **960×540** → ARM 34.50 ms (margin **+7.16**) → fabric **1280×720 OUTPUT**

## 1. Exact 4/3 — specialised (not general bilinear)

| | General `present_content_window` | Product `present_scale_4_3` |
|--|----------------------------------|-----------------------------|
| Map | Q16 `ceil((cw-1)·65536/(de-1))` × hc | `src = dst·3/4` integer |
| Phase | free-running frac from mul residue | **4 fixed phases** `dst[1:0]` |
| Weights | runtime frac | **4-entry ROM** 0,¼,½,¾ |
| Pixel arith | 11×20 mul + >>16 | `*3` + `>>2` |
| Divider | on reg update | **none** |
| Use | PMS 720×404, arbitrary PLXG | **ship 960×540 only** |

**Resource delta (pre-fit estimate, honest):**
- ALM: 4/3 **cheaper** (~50–150 ALM less when it replaces a general instance on the product path)
- M10K address path: **both 0**
- DSP: both 0 (lerp optional small)
- Fmax @29.7 MHz clk_pix: both OK; 4/3 easier (no 20b mul on ce_pix)

Endpoints of both families agree within 1 px (`test_scale_4_3_vs_general`).  
Gate: `tests/unit/test_present_scale_4_3_rtl_sim.sh` (RED invert + phase_obo).

## 2. Vertical taps — **ship 2-tap**

| | Lines held (source 960 B) | M10K budget | Quality |
|--|--------------------------:|------------:|---------|
| **2-tap biline V** | 2 | **2** | Soft; possible residual line-twitter on hi-contrast motion |
| 4-tap V | 4 | **4** | Better twitter control |

Free M10K post-nostub: **356**. Area is not the constraint — **wiring complexity** into present_core before w-clock’s real `clk_pix` PLL is.  
**Decision:** ship **2-tap**. Enable `PRESENT_SCALE_4_3_VTAPS4` only if parent glass shows twitter.

## 3. Four-lane geometry freeze

| Role | Value | Owner |
|------|------:|-------|
| Source content | **960×540** | PMS / ARM publish |
| Product bank stride | **960** | w-mem WRITE / w-scaler READ |
| Product bank bytes | **777600** | I420 |
| STORAGE vs CANVAS | Storage **960×540/777600** drives plane bases; canvas **1280×720** is DE only. Conflating → U=921600 vs 518400. | rd-duck; `DdrNativeContentLayout` |
| Option-C bank map | Select when I420 **> usable** `stride-0x1000` (legacy **520192**). Full-stride 524288 is wrong (720×482 trap). | w-mem WRITE / w-scaler READ |
| SPS coded H | 544 ring/decoder only; product bank = 540 after FFmpeg crop. | parent SPS + rawvideo wc |
| Glass DE | **1280×720** | w-clock `PRESENT_MULTI_PIXEL` |
| HUD canvas | **1280×720** | w-osd `kTargetOut` |
| Scale | exact **4/3** | w-scaler `present_scale_4_3` |
| clk_pix | **≈29.7 MHz** for 720p24 CEA | w-clock PLL (grant blocked until real) |

Macros default **OFF** — bit-identical to control at reset.

## Parent verify

```bash
tests/unit/test_present_scale_4_3_rtl_sim.sh; echo s43=$?
./build/test_scale_4_3_vs_general; echo cmp=$?
./build/test_720p_geometry_lane_agree; echo geom=$?
```
