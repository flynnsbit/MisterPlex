# STA V_TOTAL=705 + overclock ceiling (w-clock) — evidence only

**No Quartus fit by this lane. No invented BUILD_OK.**

## V_TOTAL=705 — what is and is not proven

| Claim | Status | Evidence |
|-------|--------|----------|
| Beam completes frames at V=705 without stall | **PROVEN** (sim) | oracle `V705_960x540 exact` whole-frame pix/lines |
| true_de remains 960×540 at V=705 | **PROVEN** (sim) | `line_acc=960..960`, pix=`960*540*frames` |
| fps ≈ 24.0007 Hz arithmetic | **PROVEN** (math) | `20e6/(1182*705)` awk |
| **Timing closure @20 MHz with V=705 latched** | **NOT PROVEN** | needs `Plex.sta.rpt` Fmax Summary on BEAM_960 netlist |
| Same RBF serves 564 and 705 | **Design intent** | `rt_vtotal` frame-boundary latch only — no second PLL |

### STA acknowledgement (pre-registered — not a pass)

- **Clock:** clk_sys remains **20.000 MHz** (`pll_0002.v`); no pix PLL.
- **Path class:** V=705 vs V=564 changes only the **value** in existing `vtot_act` register compares — not a new multi-cycle cone.
- **Prediction:** meet constrained 20 MHz on nostub-class BEAM_960 (confidence medium).
- **Miss:** Fmax_sys < 20.0 or any setup slack < 0 → HARD FAIL; publish miss.
- **Explicit:** oracle no-stall ≠ STA. Parent fit must quote Fmax Summary before BUILD_OK.

Prior measured Fmax (different netlists, still the only STA numbers on record):

| Netlist | Fmax clk_sys | Source |
|---------|-------------:|--------|
| stub-in `8fdf440f` | **23.46 MHz** | STA Fmax Summary |
| nostub `c74c6863` | **32.59 MHz** | STA Fmax Summary |
| parent nostub live | **32.04 MHz** | parent |

705 does not create a new clock; it cannot raise Fmax. It can only fail if placement of the compare cone worsens — unmeasured until fit.

---

## Overclock / pixel-clock ceiling (plain)

| Question | Answer | STA evidence |
|----------|--------|--------------|
| PLL applied? | **No** — still 20/90 | `pll_0002.v` |
| Can product ship 25 MHz clk_sys today? | **No on stub-in** | 25 > **23.46** measured Fmax |
| Headroom above 20 on stub-in | **3.46 MHz** (23.46−20) | same STA |
| Headroom on nostub empty-of-stub | **12.59 MHz** (32.59−20) | `c74c6863` |
| Realistic **pixel-clock ceiling** for this fit | **20 MHz constrained** until BEAM_960(+runtime) STA | no BEAM_960 sta.rpt yet |
| 25 MHz after nostub product default? | **Plausible only after** new STA ≥25 and CDC 25/90 review | not done |
| 29.7 / 37.125 clk_pix | Upgrade path macros OFF; needs own Fmax | no pix STA |
| Decode 720p24 via sys overclock alone? | **No** — paint-class wall ~349 MHz class | FABRIC_CLOCK_HEADROOM doc |

### Plain ceiling statement (user “max fabric” goal)

1. **Until stub is out of the product critical path**, measured ceiling that binds a stub-capable RBF is **Fmax ≈ 23.46 MHz** → **do not plan above 20 MHz ship** (17% margin only; 25 MHz is a hard STA fail class on that netlist).
2. **Nostub-only product** historically reached **~32–32.6 MHz** — that is the best *empty-stub* sys Fmax on record, **not** a BEAM_960 or runtime-geom proof, and **not** a license to ship 30 MHz without STA.
3. **No honest pixel-clock ceiling above 20 MHz exists for the ascal-native first fit** until parent runs the held fit and quotes Fmax. Anything else is aspiration.

**Cost of chasing >20 MHz now:** exclusive fit slot + CDC re-audit (related-edge shrink) + risk of burning the slot on a miss. **Benefit for first ascal-native 960@30 path:** none required — active rate 15.55 Mpix/s < 20.

---

## Runtime-geom oracle fix (this commit)

- Whole-frame window only (arm on first `frame_start`, stop after N completed frames).
- `de_pix == W*H*frames` equality; `line_acc == W..W` min..max.
- Ladder: **320×240, 640×360, 960×540**.
- Red twin `-DFAULT_DROP_ONE_PER_LINE` must fail equality (catches 959×H class).
