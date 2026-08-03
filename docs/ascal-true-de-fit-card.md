# Asca-native true 960×540 DE — fit card (w-scaler → w-nostub)

**Gate:** counted RTL sim `tests/unit/test_present_true_de_count_rtl_sim.sh`  
**Measured product 30:** `true_de=1 de_w=960 de_lines=540 de_pixels=518400 de_uniform=1 store_full=1 store_req=518400 store_x=0..959`  
`H_TOT=1182 V_TOT=564 clks/frame=666648 fps@20M=30.0008`  
**Measured product 24:** same DE + store_full, runtime `V_TOT=705 clks/frame=833310 fps@20M=24.0007`  
**Blank epoch:** beam registers HBlank/VBlank from *next* hc/vc (same epoch as `hc_out`). Old NBA-from-prior-hc dropped store x=0 every line (`517860=959*540`).  
**RED island:** `PRESENT_BEAM_FAULT_ISLAND_1280` → `de=1280x720 true_de=0` rc≠0 + EXECUTED  
**RED rate+bad DE:** `PRESENT_BEAM_FAULT_VTOT_BAD_DE` → rt V=705 but `de_w=1280` → `true_de=0` rc≠0 + EXECUTED

## Synthesis / QSF (drop-in)

| Item | Value |
|------|--------|
| Macro | **`PRESENT_BEAM_960`** (default OFF today — must be **on** for this fit) |
| Do **not** set | `PRESENT_MULTI_PIXEL`, `PRESENT_SCALE_4_3`, `PRESENT_SCALE_2X`, `PRESENT_BEAM_FAULT_*` |
| `FRAME_W` / `FRAME_H` | **960 / 540** (storage = content) |
| RTL files | `present_beam_content_de.sv`, `present_video_timing_960.sv`, `present_content_window.sv` — **must be in `files.qip`** (not only Verilator TB lists) |
| Elab gate | `tests/unit/test_present_beam_fit_elab.sh` → QIP list + Verilator under `PRESENT_BEAM_960 FRAME_W=960 FRAME_H=540` |
| Beam class | fixed **H_TOTAL=1182**, default **V_TOTAL=564** (30.0008 Hz); runtime **V=705** (24.0007 Hz) |
| clk | `clk_sys` **20 MHz**, `ce_pix=1` (1 px/clk) |
| DE_LAG | keep **3** (present_core) |

## Runtime mailbox / PLXG (before first present)

| Port / field | Value | Notes |
|--------------|------:|-------|
| `win_enable` / fabric_win_enable | **1** | window owns map |
| `content_w` | **960** | STORAGE width |
| `content_h` | **540** | STORAGE height (libavcodec crop, not 544) |
| `content_x0` / `content_y0` | **0** | |
| `win_h_de` | **960** | **== content_w** — never 529, never 1280 |
| `win_v_de` | **540** | **== content_h** — never 480, never 720 |
| `geom_coded_w/h` | **960 / 540** | bank payload 777600; w-mem usable-capacity path |
| `geom_display_*` | canvas/HDMI only | do **not** feed into coded/store |
| `beam_use_rt_vtotal` | **0** default | **1** when host selects film 24 Hz |
| `beam_rt_vtotal` | **564** or **705** | only when `beam_use_rt_vtotal=1`; clamp ≥ V_ACTIVE+16 |

Identity: content_w==win_h_de and content_h==win_v_de → Q16 SX=SY=65536 → store identity (1-cycle window lag).

### Cadence select (one beam class, one RBF)

```
H_TOTAL = 1182  (fixed; no PLL retune)
V_TOTAL = 564   → 1182*564 = 666648 clks → 20e6/666648 = 30.0008 Hz  (TV / 30 fps)
V_TOTAL = 705   → 1182*705 = 833310 clks → 20e6/833310 = 24.0007 Hz  (film / 24 fps)
exact-24 solve  = 20e6/24/1182 ≈ 705.02  (705 is 0.003% off)
```

**V_TOTAL latch (hardware):** host may write `rt_vtotal` anytime. Beam *captures* the request every cycle and *applies* it only on **frame wrap** (`v_wrap`) or reset — not combinational into `v_last`. Mid-frame 705→564 with `vc>563` must still complete the film frame then switch (see `test_present_vtot_latch_rtl_sim.sh`).

Plex.sv currently ties `beam_use_rt_vtotal=0` (safe default 564 / first-proof fixed-30). Host/PLXG wiring is the integrator step — ports exist on `present_core`.

## What “true DE” means at the pin

After DE_LAG on HBlank (present_core outs):

1. Count cycles with `~HBlank & ~VBlank` per line → **960** every active line (`de_uniform=1`)
2. Count such lines per frame → **540**
3. `de_pixels` → **518400**
4. ascal `iauto=1` will measure **ihsize=960 ivsize=540** from `i_de`

Rate must not change DE extent: V_TOTAL switch with win/content still 960×540 keeps `true_de=1`.

## Forbidden (RED in sim)

| Mistake | Measured DE | ascal sees |
|---------|------------:|------------|
| Beam/canvas 1280×720, content 960×540 island | 1280×720 | full canvas → content fraction wrong |
| Template H_DE=529 left on | ≤529 × … | never 960 |
| `win_h_de=1280` with content 960 | stretch map + wrong denom | soft + wrong |
| V_TOTAL→705 but DE left at 1280-wide | 1280×540 @ ~20 Hz | not product true_de |

## ascal (quoted — rate switch + buffering)

**Default triple buffer (no tear on whole-frame hold):**
- `ascal.vhd:88-90` MODE[3] 0=single FB, 1=triple
- `sys_top.v:329` `lowlat=0`; `:791` `.mode({~lowlat,...})` → **MODE[3]=1** unless low-latency
- Input end-frame toggles write buf (`ascal.vhd:1256-1258`, `1918-1929`)
- Output swaps **at VS falling** when `o_bufup*` (`1934-1940`) → **whole-frame** hold/repeat
- Single-FB force-zero when `o_mode(3)='0'` (`1974-1979`) — tear-prone; not default

**Rate-only V_TOT change (same 960×540 DE):**
- `swblack` blackout is on **resolution** change: `o_ihsize /= i_hrsize or o_ivsize /= i_vrsize` (`1951-1952`, port `:226`)
- Rate-only does **not** hit that path → **no 3-frame black** from size detector
- No dedicated “frame-rate re-lock” state machine in ascal — input keeps writing on `i_endframe*`; output keeps scanning at HDMI 60
- **Conclusion:** runtime 564↔705 with stable true DE should re-acquire without size blackout; mid-frame V_TOT write still undefined on the **core beam** (not ascal)

**Judder note:** ascal DDR FB decouples **clocks**, not the **repeat pattern**. Core@24→HDMI@60 is 5:2 whole-frame repeats under triple buffer (standard film class). Fixed core@30 with 24 content re-quantises upstream — worse distribution. Parent’s V_TOT track-content plan is consistent with triple-buffer whole-frame hold.

## w-clock coordination

| Class | H×V | Status |
|-------|-----|--------|
| MODE=0 | 1182×**564** | STA-owned primary; **count-sim confirmed** DE+fps |
| Parent film | 1182×**705** | **count-sim confirmed** DE+fps; **needs w-clock STA ack** (longer V blank only — comparators, same H, no PLL) |
| MODE=2 film (legacy copy) | 1389×600 | still in `present_video_timing_960.sv` — **not** this runtime class |

If w-clock rejects 705, alternative is MODE=2 1389×600 (~24.03 Hz) — would need **new** counted sim (different H_TOTAL); do not assume.

## Parent verify

```bash
cd <wt-scaler>
tests/unit/test_present_true_de_count_rtl_sim.sh; echo tde=$?
# expect product30+product24 true_de=1 de=960x540; RED island + vtot_bad true_rc=1
```
