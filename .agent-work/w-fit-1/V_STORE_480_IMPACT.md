# V_STORE=480 scanout impact analysis (no fit requested)

**Baseline (parent silicon / fit metrics):** ALM 21,095/41,910 · DSP 74/112 ·
RAM **465/553 (88 free)** · setup +0.165 · hold +0.245. Working core **c5382bee**.

## What the RTL does today (quoted)

`fpga/Plex_MiSTer/rtl/present_core.sv`:

```systemverilog
localparam H_DE     = 10'd529;
localparam V_STORE  = 10'd240;
localparam int STORE_Y_SCALE = (FRAME_H * 65536) / 240;
// ...
wire [9:0] py = scandouble ? (vc >> 1) : vc;
wire in_content = (hc < H_DE) && (py < V_STORE) && ~hb && ~vb;
wire [23:0] y_scaled = {14'd0, py} * STORE_Y_SCALE[23:0];
wire [9:0]  store_y  = y_scaled[25:16];
```

Product QSF (`Plex.qsf`): `FRAME_W=640`, `FRAME_H=480` (defines on `present_core` /
`ddr_frame_store`). Layout contract (`ddr_frame_layout_params.svh`): coded/display/
presented height **480**.

**With product FRAME_H=480:**

- `STORE_Y_SCALE = 480 * 65536 / 240 = 131072` = **2.0** in 16.16.
- `store_y = py * 2` for `py ∈ 0..239` → **even rows only**; odd store rows never
  scanned → **half of a 480-row DDR store is discarded at scanout**.
- DE window is **529×240** into `ascal` → 1080p. Vertical overlay resolution is
  fundamentally capped at **240 unique source rows** regardless of ARM 480p publish.

`colorbars.sv` is also a **240-line content** generator (`py < 240`; scandouble still
maps `py = vc>>1` into ~240). So “set V_STORE=480” alone does **not** create 480
active display lines under current timing.

## What a real vertical fix requires

| Piece | Needed? | Notes |
|---|---|---|
| `V_STORE=480` | Yes | Opens content window to 480 lines **if** `py` can reach 479 |
| Timing / scandouble path | **Yes** | Need progressive **480 active** lines (or scandouble path that does **not** half `py`) into ascal; else py never leaves 0..239 |
| `STORE_Y_SCALE = (FRAME_H*65536)/V_STORE` | Yes | With FRAME_H=480 and V_STORE=480 → scale **1.0** (identity row map) |
| DDR bank geometry | Likely no change | Layout already 480-row / 640-presented; banks already sized for 480p |
| ARM publish | Likely no change | Already publishes 480p correctly on silicon (parent) |
| `ascal` / HDMI mode | Verify | Input active height doubles; scaler coefficients / min-max may need retune |
| define-parity / TBs | Yes | Any hardcoded 240 in present/scanout tests must track |

**Blast radius (files/concepts):**

- `present_core.sv` — V_STORE, STORE_Y_SCALE denominator, `past_last_row`/`py >= 240`
  guards, comments about 241-row bug.
- `colorbars.sv` / video timing — 480-line mode or scandouble semantics.
- `Plex.sv` / sys ascal wiring — active video size into scaler.
- `ddr_frame_layout_params.svh` / host `ddr_frame_layout.hpp` — **heights already 480**;
  parity may stay green if only scanout map changes.
- Unit/sim: `test_ddr_frame_store_scanout_*.sh`, shear/colour/freeze/sustained;
  any TB assuming 240 DE lines.
- `make define-parity` — must stay green after macro/param touch.
- Docs / geometry map — display path description 240→480.

**Does NOT interact with:** PLXC @ doorbell+0x130, `907e5950` swap_pending hold,
comb dequant DSP work (orthogonal).

## Bandwidth (verify, not assume)

Parent figures: ~6.91 MB/s scanout @240p-class, ~27 MB/s @480p-class, vs ~720 MB/s
peak DDR window. Even at 640×480×2 B × 60 Hz ≈ **36.9 MB/s** RGB565 read, headroom
is **~20×**. **DDR read bandwidth is not the killer** for V_STORE=480.

Throughput cy/MB budget (decode/write path) is a **separate** constraint from scanout
read; do not conflate 2,965 cy/MB write RMW with scanout.

## Area / timing pre-registration (BUNDLE of V_STORE path only)

Assumptions: FRAME_H already 480 in fit baseline; frame store M10K **already**
provisioned for 480 rows; change is mostly counters, compare width, and possibly
timing generator / ascal input geometry — **not** doubling frame buffer RAM.

| Metric | Baseline c5382bee | Predict after V_STORE=480 + 480-line DE | Confidence |
|---|---:|---:|---|
| ALM | 21,095 | **21,150 … 21,400** (+55…+300) | med — extra V counters/compares + timing mode |
| DSP | 74 | **74** (0) | high — no new multipliers if scale const 1.0 folds |
| RAM (M10K) | 465/553 | **465 … 470** (0…+5) | med-high if store already 480; **+0 expected** |
| setup slack | +0.165 | **+0.05 … +0.165** (risk: ascal/path length) | low-med — thin margin historically |
| hold | +0.245 | **≥ +0.20** | med |

**If RAM jumps by tens of blocks**, the fit picked up a second buffer or FRAME_H was
not actually 480 in the baseline netlist — treat as **HARD finding**, not rounding.

**Kill criteria (do not ship):** any freeze-class RBF; setup negative; do-not-ship md5s;
scanout shear/colour/freeze sims not RED→GREEN with **TB execution proven**
(`PINNOTFOUND`/`%Error` → rc=2 via `run_verilator.sh`).

## RED→GREEN sim gate (required before any fit ask)

1. **RED on current RTL:** TB drives `py` 0..239, FRAME_H=480, asserts store_y sequence
   is **0,2,4,…** (or samples only even rows) — documents half-store discard.
2. **GREEN on fix:** V_STORE=480, scale 1.0, timing with 480 active lines; store_y == py
   for py in 0..479; no odd-row starvation.
3. Elaboration must **run**; compile fail = RED not skip.

**No fit requested in this write-up.** Product justification for a solo V_STORE fit is
stronger than PLXC/−32 DSP (user-visible sharpness) **but** only after timing path is
designed and the RED→GREEN TB exists. Until then: **analysis only / keep accumulating**.

## Honest product note

Shipping `c5382bee` already paints correct 240p and 480p **content** into a **240-line
scanout** upscaled by ascal. V_STORE=480 is the honest path to a sharper OSD/overlay
vertical axis; it is **not** required to “make DDR work” (DDR already works).
