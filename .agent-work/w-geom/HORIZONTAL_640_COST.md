# Horizontal 640-column ceiling — cost (no implement)

**Author:** w-geom · **Rule 0:** numbers from quoted sources only.

## Locked today (product)

| Item | Value | Source |
|------|-------|--------|
| `FRAME_W` / `FRAME_H` | 640 / 480 | `fpga/Plex_MiSTer/Plex.qsf` VERILOG_MACRO |
| `clk_sys` | **20 MHz** | `ddr_bus_arbiter.sv` header; `tb_arb_beat_conservation.sv:8` |
| Present H_DE unique X | **529** | `STORE_X_SCALE=(640*39647)/320` path; H_DE kept this fit |
| Lines / frame (class) | 524 | present timing class (vsync period math) |
| Max H_total @60 Hz | `20e6/60/524 ≈ 636` | arithmetic |
| Full unique columns | **640 > 636** | **impossible at 20 MHz / 60 Hz / 524 lines** |

Parent verified: 640 unique columns are genuinely impossible in this timing class.

## What “full width” requires

Need `clk_sys / (refresh × V_total) ≥ 640` (plus blanking if H_total > active).

### Option A — Raise `clk_sys` only (same 524-line / 60 Hz class)

| Target H_total | Min clk_sys | Notes |
|----------------|-------------|-------|
| 640 (zero H blank — illegal for most monitors) | `640×60×524 = 20.1216 MHz` | Still fails real blanking |
| ~800 (modest blank, ~640 active) | `800×60×524 = 25.152 MHz` | Common 480p-ish pixel clock ballpark |
| 858 (CEA 480p H_total) | `858×60×525 ≈ 27.0 MHz` | Standard 720×480p60 uses 525 lines |

**Cheapest plausible full-width class:** ~**25–27 MHz** `clk_sys` **and** a timing table with H_total ≥ ~800 and H_active=640.

### Option B — Change timing class (line count / refresh)

- Drop refresh (e.g. 50 Hz): `20e6/50/524 = 763` → room for 640 active + blank **without** clock raise.
- Fewer lines (not product 480p glass).
- Interlace / dual-pixel / parallel fetch (architecture change).

### Option C — Partial win without clock (already refused as “full width”)

- Keep H_DE=529 (current) — **17.3% columns never fetched**.
- Stretch/scale content into 529 — not native 1:1 sharpness.

## Collateral cost if raising clk_sys (~25–27 MHz)

1. **PLL / MiSTer sys clock** — `pll` / `sysclk` assignments in QSF and any `ce_pix` enables derived from 20 MHz must retarget. Cross-domain ratios to HDMI/ascal paths change.
2. **DDR arbiter** — `ddr_bus_arbiter` comments and beat budgets assume 20 MHz video side vs ~90 MHz DDRAM. Higher video request rate tightens arbitration; M10K line-fill under 2×Y (T7) **plus** denser X must re-close.
3. **STA** — every path timed at 20 MHz gets ~25–35% less period. Fit risk is **real**; not a free macro flip.
4. **DE_LAG / FBAR** — H_DE and pipeline lag constants (`DE_LAG=3`, H_DE=529 today) must be re-derived; left-edge / FBAR gates re-baselined.
5. **Bandwidth model (order-of-magnitude)** — full 640×480×2 B @60 ≈ 36.9 MB/s raw RGB equiv; I420 store fetch still ≪ 180 MB/s @90 MHz×25% residual **if** arbiter still grants. BW is secondary to **pixel-clock geometry**.
6. **CPU** — horizontal fetch is FPGA-side; ARM publish size already 624×480 I420. No direct daemon CPU hit from H=640 fetch; overlay sharpness is the user win.

## Worth a future exclusive fit?

| | |
|--|--|
| **User value** | Sharp OSD/chrome + true 1:1 640 store sample (T7 already unlocks all **rows**). |
| **Risk** | PLL + STA + arbiter + DE/FBAR re-baselines — **high** for one fit. |
| **Dependency** | Should land **after** T7 vertical + `frames_done_d2` soak proves underruns flat. |
| **Recommendation** | **Defer.** Cost as separate design (new timing class card), not a piggyback on judder/swap fits. Prefer measuring post-T7 glass sharpness first — vertical-only may be “good enough” for OSD if glyph height was the complaint. |

## Not in this change

No RTL, no QSF clock edit, no fit. Costing only.
