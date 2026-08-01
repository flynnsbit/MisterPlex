# T1–T4: 240-line verify, Inc-1 spec, (a) vs (b), DO-NOT-SHIP

**Lane:** w-fit · branch `w-fit-integ-c5382bee-dequant-swap`  
**No Quartus fit. Slot CLOSED. No device access.**  
**Parent ERROR 18/19 accepted:** frame-loss % figures are **withdrawn**; judder remains the open timing question (owned by w-geom measurement, not this doc).

---

## T1 — Independent verify / refute of “only 240 distinct vertical samples”

### T1.1 Product geometry macros (not assumed)

| Symbol | Value | Source |
|--------|------:|--------|
| Quartus `FRAME_W` | **640** | `fpga/Plex_MiSTer/Plex.qsf:83` `VERILOG_MACRO "FRAME_W=640"` |
| Quartus `FRAME_H` | **480** | `Plex.qsf:84` |
| `FRAME_LINES_8` | **1** | `Plex.qsf:85` |
| `DDR_FRAME_STORE` | **1** | `Plex.qsf:82` |
| Fallback ifndef | 320/240 | `Plex.sv:262-269` — **overridden by QSF in product** |
| Coded DDR | **624×480** | `ddr_frame_layout_params.svh:5-6` |
| Display crop | **618×480** | same file `:7-8` |
| Presented canvas | **640×480** | same file `:9-10` (= QSF FRAME_*) |

**Correction vs parent brief:** product **presented** `FRAME_W` is **640**, not 624.  
624 is **coded** pitch (`DDR_FRAME_CODED_WIDTH`). Parent’s vertical arithmetic still holds under **FRAME_H=480**.

`define-parity` explicitly treats QSF FRAME_W/H as **presented** scanout, not coded pitch (`scripts/check_define_parity.py` ~318–331).

### T1.2 Address path (quoted)

```systemverilog
// present_core.sv:161-164
localparam H_DE    = 10'd529;
localparam V_STORE = 10'd240;
localparam int STORE_X_SCALE = (FRAME_W * 39647) / 320;
localparam int STORE_Y_SCALE = (FRAME_H * 65536) / 240;

// present_core.sv:170-171
wire [9:0] py = scandouble ? (vc >> 1) : vc;
wire in_content = (hc < H_DE) && (py < V_STORE) && ~hb && ~vb;

// present_core.sv:181-182
wire [9:0] read_hc = hc;   // exact alias — same counter as colorbars hc
wire [31:0] store_x_prod = read_hc * STORE_X_SCALE;

// present_core.sv:194-198
wire       past_last_row = (py >= 10'd240);
wire [9:0] store_y_clamped = past_last_row ? 10'd239 : py;
wire [31:0] store_y_prod = store_y_clamped * STORE_Y_SCALE;
wire [15:0] store_y_comb = store_y_prod[31:16];
```

`ddr_frame_store` is driven by registered `store_x`/`store_y` only (`present_core.sv:259-261` `.rd_x(store_x), .rd_y(store_y)`).  
CODED geometry is applied **inside** the store for DDR fetch (`CODED_W=624` etc.), not by inventing extra vertical samples beyond `rd_y`.

### T1.3 Integer arithmetic (DERIVED from product FRAME_H=480)

| Quantity | Value |
|----------|------:|
| `STORE_Y_SCALE` | `(480 * 65536) / 240` = **131072** = **2.0 × 65536** |
| `store_y` for `py∈[0,239]` | `py * 2` → **0,2,4,…,478** |
| Unique `store_y` | **240** |
| Odd store rows hit | **0** |

```
# python, product FRAME_H=480
unique store_y for py 0..239: 240  min0 max478  all even
```

With **scandouble=1**: `py = vc>>1` still yields at most 240 distinct `py` while `in_content` requires `py < 240` (`:170-171`).  
With **scandouble=0**: colorbars `py=vc` and VBlank opens at vc≈240 (`colorbars.sv:117-119` NTSC path) — still ≤240 content rows before V_STORE.

### T1.4 Horizontal (nuance vs parent “529→624”)

Product `STORE_X_SCALE = (640 * 39647) / 320` = **79294** (DERIVED).

| | |
|--|--:|
| Unique `store_x` for `hc∈[0,528]` | **529** |
| Range | min **0**, max **638** (clamped to FRAME_LAST_X=639) |

So: **every DE column is a distinct presented X**, spanning almost the full **640** canvas — not “529 samples of 624 coded.”  
Coded 624 is reached **after** pillar/crop inside `ddr_frame_store` (`DISPLAY_W=618`, `PRESENT_X=11`, `CROP_*`).  
Horizontal is **non-integer resample into 640 then map to 618/624**, which matches parent’s weak horizontal period on capture.  
**Vertical** is the hard subsample: **exactly 2×** and **half the bank rows never addressed**.

### T1.5 Nothing downstream restores full vertical rate

Path (product tree):

```
present_core RGB @ clk_sys / colorbars DE (H_DE=529, V_STORE=240)
  → emu VGA_* (Plex.sv assigns)
  → sys_top scanlines/sync (hr_out from vga path ~1713-1719)
  → ascal i_* (sys_top.v:749-757)  // upscales whatever DE it is given
  → hdmi_data (764-768)
  → shadowmask (1159-1174)
  → osd (1183-1200)
  → HDMI_TX mux (1317-1320)
```

- **ascal** scales **input** DE → HDMI `WIDTH×HEIGHT`; it does not re-read DDR at 480 src lines.  
- **shadowmask / osd** operate on ascal output pixels; they do not fetch `store_y`.  
- **No second DDR scanout** of the content bank at full height exists in this path.

### T1.6 Verdict

| Claim | Result |
|-------|--------|
| Only **240 distinct vertical store samples** reach the display path | **CONFIRMED** from RTL + product `FRAME_H=480` arithmetic |
| Product canvas is 624×480 presented | **REFUTED** — presented **640×480** (QSF); coded **624×480** |
| `read_hc` is same as `hc` | **CONFIRMED** (`read_hc = hc`) |
| Downstream full-rate re-sample of store | **None found** in present→ascal→TX chain |

Parent’s period-3 measurement on 720p capture is **consistent** with 240 src lines × 3 = 720; this lane did **not** re-run capture (no device).

---

## T2 — Inc-1 concrete (HW rectangle post-ascal, 0 M10K)

### T2.1 Insertion point (quoted)

**Clock domain:** `clk_hdmi` (`sys_top.v:712` `wire clk_hdmi = hdmi_clk_out`).

**Tap after shadowmask, before framework osd** (F12 menu stays on top):

| Signal | Role | Lines |
|--------|------|------:|
| `hdmi_data` | ascal RGB out | 706, 766-768 |
| `hdmi_data_mask` | after shadowmask | 1153, 1174 |
| `hdmi_hs_mask`, `hdmi_vs_mask`, `hdmi_de_mask` | timed with mask | 1171-1173, 1154 |
| **NEW blend here** | replace `osd.din` source | between 1174 and 1183 |
| `osd` `din(hdmi_data_mask)` today | 1192 | change to `din(hdmi_data_chrome)` |

Exact current osd input:

```verilog
// sys_top.v:1183-1200
osd hdmi_osd (
  ...
  .clk_video(clk_hdmi),
  .din(hdmi_data_mask),   // <-- Inc-1: feed blended bus instead
  .hs_in(hdmi_hs_mask),
  .vs_in(hdmi_vs_mask),
  .de_in(hdmi_de_mask),
  ...
);
```

**Do not** insert inside `present_core` — that is pre-ascal and cannot prove output-pixel edges.

### T2.2 Module behaviour (Inc-1)

```text
module plex_chrome_rect (
  input  clk_hdmi,
  input  [23:0] din,          // hdmi_data_mask
  input  hs_in, vs_in, de_in,
  input  enable,              // strap / status bit / localparam 1 for bring-up
  output [23:0] dout,
  output hs_out, vs_out, de_out
);
```

- Counters: free-run X/Y on `de_in` rising edges within frame (reset X on `~de & de_d`, Y on `vs` edge) — same style as many HDMI overlays; **1-cycle match to `osd` pipeline** (register dout with hs/vs/de).
- **Fixed rectangle in output pixels** (parameters, HDMI active space):

| Param | Default (for parent score) | Meaning |
|-------|----------------------------|---------|
| `X0` | 64 | left |
| `Y0` | 64 | top |
| `X1` | 320 | right exclusive |
| `Y1` | 196 | bottom exclusive (= 64+132) |
| `RGB` | 24'hFF00FF | magenta |

Rectangle size **256×132** is large enough for period analysis and small enough not to hide all content.

- Blend: `in_rect && enable && de ? RGB : din` (opaque replace, **0 M10K**, no DDR).

### T2.3 What the rectangle looks like (parent eyes + metric)

- Solid **magenta** block, upper-left quadrant-ish.  
- Edges axis-aligned to **HDMI pixel grid** (not core DE).  
- Content video continues around it, still soft/period-3.

### T2.4 Pass / fail (falsifiable, single frame)

Parent method (your period contrast on row-to-row MAD), **same capture**:

| Region | Expect |
|--------|--------|
| **Inside rectangle** (inset 4 px to avoid edge mix) | period-3 contrast ratio **≈ 1.0** (no 240-line structure); row-to-row MAD flat / only encoder noise |
| **Video area outside rect** (same frame) | period-3 contrast still **≫ 1** (your f_02400 class ~8–11) |
| **Rect edge** | transition completes in **≤2 output pixels** (prefer 1) when stepping perpendicular to edge; **not** a 3-row staircase |

**PASS iff** all three hold on one still.  
**FAIL if** rect interior still shows period-3 (tap still pre-scale or scaled) or video period-3 disappears (broke content path).

### T2.5 Resources (Inc-1)

| Resource | Value |
|----------|------:|
| M10K | **0** |
| DSP | **0** |
| ALM | **ESTIMATE &lt;200** (counters + compare + mux) — label ESTIMATE until map |
| Product QSF change | none required if `enable` tied off by default |

**Not fitted. Not requested.** Stage as design until grant.

---

## T3 — (a) post-ascal chrome only vs (b) full 480-line video

### T3.1 What each fixes

| | (a) chrome plane post-ascal | (b) raise native content raster |
|--|--|--|
| User overlay sharpness | **Yes** | Indirect only if chrome stays in content |
| Video vertical detail | **Unchanged (240)** | **Yes — up to 480 store rows** |
| Touches working `store_y` path | No (if pure post-ascal) | **Yes — high regression class** |

### T3.2 Cost of (b) — quoted / derived / estimate

**Already paid (DDR content):** bank is already **624×480** coded (`ddr_frame_layout_params.svh:5-6`, `YUV420P_BYTES=449280`). Raising fetch does **not** grow the HPS frame buffer size.

**Blocker is not bank depth — it is the core DE + `V_STORE` contract:**

1. `V_STORE=240` and `STORE_Y_SCALE=(FRAME_H*65536)/240` must become a **1:1** map, e.g. `V_STORE=480` and `STORE_Y_SCALE=(FRAME_H*65536)/480` → **65536** when FRAME_H=480 (DERIVED).  
2. **colorbars** timing is 240-class content (`colorbars.sv:135-136` `py < 240`; NTSC VBlank @ 240/480 scandouble). A true 480 progressive DE is a **new raster**, not a one-line localparam poke.  
3. Line buffers: `LINE_COUNT=8`, `LINE_SLOTS=16` (`ddr_frame_store.sv:25,111`).  
   - Y line = `CODED_W/8=78` qwords × 64b = 4992 b  
   - U+V = 2 × 39 qwords × 64b = 4992 b  
   - 16 slots × 9984 b = **159744 b ≈ 16 M10K** (DERIVED ceil 159744/10240).  
   - **Same M10K if LINE_COUNT stays 8** — height does not multiply line-buffer RAM.  
4. **Scanout BW / refill pressure:** 480 unique lines per core frame vs 240 → **~2×** line fills per content period at same line rate (DERIVED factor). Underrun/freeze class risk **rises**; this is the same subsystem that burned `9eb1431a` / `f0d3a385` / `2890baac`.  
5. **ALM/timing:** **ESTIMATE** non-trivial (new V timing, DE_LAG re-sweep comments at `present_core.sv:364+`, ascal input rate change). **No map number** — do not invent.  
6. **RAM free:** baseline **88 M10K free** (parent). (b) need not spend them if LINE_COUNT unchanged; risk is **timing/underrun**, not the 4320-M10K chrome-BRAM failure mode.

### T3.3 Ship order (recommendation)

1. **Ship (a) path first, starting at Inc-1** — matches the **stated user bug** (overlays), **0 M10K**, does not reopen scanout freeze class, falsifiable in one frame.  
2. **(b) second** as its own program: new core raster + RED→GREEN scanout TBs at 480 lines + parent pixel period-2 (or period matching HDMI/480) — **not** bundled with first chrome fit.

If video softness becomes the next user complaint after sharp chrome, (b) is justified then with eyes-on evidence; do not spend the exclusive slot on (b) “while we’re there.”

---

## T4 — DO-NOT-SHIP (ERROR 18/19 applied)

| md5 prefix | Status | Justification (current) |
|------------|--------|-------------------------|
| `8832824e`, `75da8bb1`, `4d6ee356`, `4deaf6cc`, `dabdaeb0` | **BANNED** | historical banned set (orchestration) |
| `9eb1431a` | **DO-NOT-SHIP** | freeze on silicon |
| `ff2e3ca3` | **DO-NOT-SHIP** | STA HARD_FAIL (setup −0.233 / hold −0.517 class) |
| `f0d3a385` | **DO-NOT-SHIP** | freeze class |
| `2890baac` | **DO-NOT-SHIP** | freeze class |
| **`c5382bee`** | **NOT banned / NOT do-not-ship** | Renders correct DDR video (parent eyes-on). Prior “1.54% defect” / “0.070% skip” **void (ERROR 18/19)**. Residual open issues (judder histogram; 240-line architecture) are **product backlog**, not ship-ban hashes. |

Promote/replace `c5382bee` only with a **new** intentional BUILD_OK + parent pixel gates — not because it is on a ban list.

---

## Explicit non-actions

- **No Quartus fit requested or started.**  
- **No cadence / judder RTL** (still waiting w-geom fabric histogram).  
- **No device.**  
- Inc-1 is **specified**, not wired into `files.qip` in this commit.
