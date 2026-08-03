# Asca-native true 960×540 DE — fit card (w-scaler → w-nostub)

**Gate:** counted RTL sim `tests/unit/test_present_true_de_count_rtl_sim.sh` + `make fit-gate`  
**Measured product:** `true_de=1 de_w=960 de_lines=540 de_pixels=518400 store_req=518400 store_oracle=1 store_x_range=0..959` @ `H_TOT=1182 V_TOT=564` (`fps@20M=30.0008`)  
**RED:** `PRESENT_BEAM_FAULT_ISLAND_1280` → `de=1280x720 true_de=0` rc≠0 + EXECUTED  
**Also RED (rd-duck):** DE-only greenwash — `de_pixels=518400` with `store_req=517860` (959×540, x=0 dropped) is **not** fit-ready. Beam blank/sync must use **same counter epoch** as registered `hc`/`vc` (`hc_next`).

## Synthesis / QSF (drop-in)

| Item | Value |
|------|--------|
| Macro | **`PRESENT_BEAM_960`** (default OFF today — must be **on** for this fit) |
| Do **not** set | `PRESENT_MULTI_PIXEL`, `PRESENT_SCALE_4_3`, `PRESENT_SCALE_2X`, `PRESENT_BEAM_FAULT_ISLAND_1280` |
| `FRAME_W` / `FRAME_H` | **960 / 540** (storage = content) |
| RTL files | `present_beam_content_de.sv`, `present_video_timing_960.sv` (w-clock constants), existing `present_content_window.sv` |
| Beam class | w-clock **MODE=0**: H_DE=960 V_ACT=540 **H_TOTAL=1182 V_TOTAL=564** (Hblank=222, Vblank=24) |
| clk | `clk_sys` **20 MHz**, `ce_pix=1` (1 px/clk) |
| DE_LAG | keep **3** (present_core) |

## Runtime mailbox / PLXG (before first present)

| Port / field | Value | Notes |
|--------------|------:|-------|
| `win_enable` / fabric_win_enable | **1** | window owns map |
| `content_w` | **960** | STORAGE width |
| `content_h` | **540** | STORAGE height (libavcodec crop, not 544) |
| `content_x0` | **0** | |
| `content_y0` | **0** | |
| `win_h_de` | **960** | **== content_w** — never 529, never 1280 |
| `win_v_de` | **540** | **== content_h** — never 480, never 720 |
| `geom_coded_w/h` | **960 / 540** | I420 payload **777600 B** > legacy usable **520192** (0x80000−0x1000) → **must Option-C**. Stale trees that pick OPTC only when `coded_w>=1280` **overrun LEG banks** — not fit-ready (rd-duck). Require w-mem `rt_need_optc` capacity select + `present_core` `.PHYS_BASE_720P`/stride720/doorbell720 wiring. **Do not treat this row as present until gate B7 is clear.** |
| `geom_display_*` | canvas/HDMI only | do **not** feed into coded/store |

Identity: with content_w==win_h_de and content_h==win_v_de, Q16 SX=SY=65536 → `store_x==hc`, `store_y==py` (1-cycle window register lag).

## What “true DE” means at the pin

After DE_LAG on HBlank (present_core outs):

1. Count cycles with `~HBlank & ~VBlank` per line → **960** every active line  
2. Count such lines per frame → **540**  
3. `de_pixels` → **518400**  
4. **`store_req` / coordinate oracle** → **518400** requests, **x=0..959** every active line (identity `store_x==hc`). DE count alone is insufficient.  
5. ascal `iauto=1` will measure **ihsize=960 ivsize=540** from `i_de`

## Forbidden (RED in sim)

| Mistake | Measured DE | ascal sees |
|---------|------------:|------------|
| Beam/canvas 1280×720, content 960×540 island | 1280×720 | full canvas → content fraction ~0.56 |
| Template H_DE=529 left on | ≤529 × … | never 960 |
| `win_h_de=1280` with content 960 | stretch map + wrong denom | soft + wrong |

## w-clock coordination

Primary split **confirmed in count sim** against w-clock `present_video_timing_960` MODE=0:

```
20e6 / (1182 * 564) = 30.0008 Hz
clks/frame = 666648
Hblank = 222  Vblank = 24
```

If w-clock moves H_TOTAL/V_TOTAL, re-run this sim with matching beam params; DE active must stay 960×540.

## Parent verify

```bash
cd <wt-fitgate>   # or tree with hc_next beam + store oracle
tests/unit/test_present_true_de_count_rtl_sim.sh; echo "true rc=$?"
# expect: store_req=518400 store_oracle=1 store_x_range=0..959 true_de=1; RED island true_rc=1
make fit-gate-selftest; echo "true rc=$?"
```
