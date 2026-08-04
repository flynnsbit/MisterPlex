# COMPOSE_ENABLE — G-COMPOSE land-line prep (w-integ)

**Branch:** `w-integ-compose-enable`  
**Base HEAD:** `704aaae6` (`origin/main` at branch create)  
**Scope:** QSF recipe + inventory only. No Quartus fit. No device.  
**Gate:** Soft-skip ≠ PASS; BUILD_OK ≠ product PASS; geometry ≠ refresh.

---

## 1. Inventory (open compose surface)

| Ref | Tip / base | Role | QSF present enable? |
|-----|------------|------|---------------------|
| **main** `704aaae6` | product land line | `PRODUCT_NO_STUB=1` + `FRAME_W/H=1280/720` + `FRAME_LINES_8=1` **ON**; L4/MULTI/PLL/DMA **OFF** | No present cut |
| **PR #17** `integ/720p-compose` → main | fit candidate | **ENABLED:** MULTI + `PRESENT_PX_PER_CLK=2` + `PRESENT_CLK_PIX_PLL` + `Plex_clk_pix.sdc` + `FABRIC_FRAME_DMA=1` + `FRAME_LINES_16=1`; 640×480 hollow | **Yes (Cut B live)** |
| **PR #14** `w-nostub-720p-compose` → reconcile | L4 host↔RTL contract | Default 640×480; L4 recipe **commented**; host `-DMISTERPLEX_PRODUCT_720P_L4=1` | Docs only |
| **PR #15** `w-nostub-integ-compose` → integ/720p-compose | Host canvas for integ QSF 1280×720 | Daemon `-DMISTERPLEX_PRODUCT_DDR_720P=1` | Host side of Cut B |
| Related (not full compose) | `w-plxd-720p-compose`, `w-path-720p-compose-reconcile`, `w-scaler-compose-reconcile`, `w-clock-720p-*`, `w-nostub-fabric-dma` | DMA kick / path ABI / PPC / clk_pix arithmetic | Partial |

### Main QSF macros (HEAD `Plex.qsf`)

| Macro | main HEAD | integ/720p-compose tip |
|-------|-----------|------------------------|
| `PRODUCT_NO_STUB=1` | **ON** | **ON** |
| `DDR_FRAME_STORE=1` | **ON** | **ON** |
| `FRAME_W=1280` `FRAME_H=720` | **ON** (PR #16) | **ON** |
| `FRAME_LINES_8` / `_16` | **8 ON** | **16 ON** |
| `PLEX_PRESENT_720P_L4` | OFF (comment) | OFF (comment alternate) |
| `FABRIC_NATIVE_720P_GEOM` | OFF | OFF (comment) |
| `PRESENT_MULTI_PIXEL` | OFF | **ON** |
| `PRESENT_PX_PER_CLK` | OFF (comment `=1`) | **`=2` ON** |
| `PRESENT_CLK_PIX_PLL` + `Plex_clk_pix.sdc` | OFF | **ON** |
| `PRESENT_CLK_PIX_74_25` | OFF | OFF (do not enable) |
| `FABRIC_FRAME_DMA` | **absent from main RTL/QSF** | **ON** (idle hierarchy) |

**RTL prerequisite gap:** `FABRIC_FRAME_DMA` / `ddr_frame_dma.sv` and MULTI **PPC=2** N-wide store path exist on **integ tip**, not on main HEAD. Main `present_core.sv` still `$error`s if `PRESENT_MULTI_PIXEL && PPC!=1`.

---

## 2. One intentional cut (recommend for parent fit)

### Chosen primary: **Cut B — MULTI + PPC2 + clk_pix PLL + FABRIC_FRAME_DMA**

Matches open PR **#17** / backlog **G-COMPOSE** / measured 24 Hz claim path.  
Do **not** double-enable L4.

#### Exact QSF macros (fit candidate only)

```tcl
set_global_assignment -name VERILOG_MACRO "DDR_FRAME_STORE=1"
set_global_assignment -name VERILOG_MACRO "PRODUCT_NO_STUB=1"
set_global_assignment -name VERILOG_MACRO "FRAME_W=1280"
set_global_assignment -name VERILOG_MACRO "FRAME_H=720"
set_global_assignment -name VERILOG_MACRO "FRAME_LINES_16=1"
set_global_assignment -name VERILOG_MACRO "PRESENT_MULTI_PIXEL=1"
set_global_assignment -name VERILOG_MACRO "PRESENT_PX_PER_CLK=2"
set_global_assignment -name VERILOG_MACRO "PRESENT_CLK_PIX_PLL=1"
set_global_assignment -name SDC_FILE Plex_clk_pix.sdc
set_global_assignment -name VERILOG_MACRO "FABRIC_FRAME_DMA=1"
# ABSENT: PLEX_PRESENT_720P_L4, FABRIC_NATIVE_720P_GEOM, PRESENT_BEAM_960,
#         PRESENT_CLK_PIX_74_25, FRAME_W=640/FRAME_H=480
```

**Host for Cut B RBF:** rebuild misterplexd with product 720p DDR canvas  
(`-DMISTERPLEX_PRODUCT_DDR_720P=1` per PR #15) so banks/phys match fabric.

#### Alternate (not simultaneous): **Cut A — L4**

```tcl
# PRODUCT_NO_STUB + FRAME 1280×720 already ON main
set_global_assignment -name VERILOG_MACRO "PLEX_PRESENT_720P_L4=1"
set_global_assignment -name VERILOG_MACRO "FABRIC_NATIVE_720P_GEOM=1"
# Host: -DMISTERPLEX_PRODUCT_720P_L4=1 (PR #14)
# No PRESENT_MULTI_PIXEL / PPC / FABRIC_FRAME_DMA / CLK_PIX_74_25
```

Works against **current main RTL** without integ merge. Refresh @ product 20 MHz ≈ **16.16 Hz** unless w-clock moves clk_sys ≈24 MHz.

---

## 3. Tradeoffs

| | **Cut A L4** | **Cut B MULTI+PPC2+PLL+DMA** |
|--|--------------|------------------------------|
| RTL base | main HEAD | **needs integ/720p-compose (PR #17)** (+ host #15) |
| Beam | compact 1312×762 | CEA compact 1650×750 @ clk_pix |
| 24 Hz claim | needs **clk_sys≈24** (not on by default) | **PLL 29.7 MHz** → fps = 29.7e6/(1650×750)=**24.000** |
| Pixel rate vs clk_sys | 1 px/clk on L4 path | PPC=2 → 40 Mpix/s @20 MHz ≥ 29.7 |
| Fabric DMA area | not in cut | bounce ≤2 M10K EST; start held idle |
| Host flag | `MISTERPLEX_PRODUCT_720P_L4` | `MISTERPLEX_PRODUCT_DDR_720P` |
| Line slots | `FRAME_LINES_8` (main) ok | tip uses `FRAME_LINES_16` |
| Mutual exclusion | vs MULTI / BEAM_960 | vs L4 / BEAM_960 |

---

## 4. Risk (STA / false-PASS)

1. **STA / SDC:** Enabling `PRESENT_CLK_PIX_PLL` adds `outclk_3` + `Plex_clk_pix.sdc` — new CDC domains (clk_sys ↔ clk_pix). Multicorner is OFF in QSF; parent fit must still publish timing margin (rd-duck attacks unbacked STA claims).
2. **Refresh trap:** Geometry or still HDMI can look “720p” at **~16.16 Hz** without PLL/24 MHz sys. **Eyes-on rate measure required** for 24 Hz PASS.
3. **Host/fab phys mismatch:** Wrong daemon define → 480p banks vs 720p fabric bases → black/shear (not “almost”).
4. **FABRIC_FRAME_DMA on main alone:** macro/RTL missing → no-op or compile fail; do not enable until integ RTL lands. Even on integ, DMA is **idle** until G-PUBLISH kick — area ≠ delivery.
5. **PPC=2 on main alone:** sim/synth `$error` until N-wide store land.
6. **M10K:** post-strip free **356**; 720p linebuf EST **~192–197** (64b qword class); full stack ALM/M10K **UNKNOWN until fit**. PR #17 PREREG mid **~295** EST — class ESTIMATE only.
7. **No device token this lane** — parent exclusive fit + HDMI.

---

## 5. What this branch does / does not

| Does | Does not |
|------|----------|
| Inventory PRs/branches + main QSF | Quartus fit / RBF / SSH |
| Document exact Cut A / Cut B macros | Flip present macros **ON** on default path |
| Align `Plex.qsf` comments with product geom + OFF recipes | Claim BUILD_OK or product PASS |
| `make define-parity` on HEAD | Merge to main |

**Land sequence for parent:** merge/reconcile PR **#17** (and host #15) → exclusive fit with Cut B QSF → measure M10K vs PREREG → HDMI rate proof → then G-PUBLISH DMA kick.

---

## 6. Default path (must stay clear)

On `w-integ-compose-enable` / main-style QSF:

- **ON:** `PRODUCT_NO_STUB`, `DDR_FRAME_STORE`, `FRAME_W/H=1280/720`, `FRAME_LINES_8`
- **OFF:** L4, MULTI, PPC, `PRESENT_CLK_PIX_PLL`, `Plex_clk_pix.sdc`, `FABRIC_FRAME_DMA`, `PRESENT_CLK_PIX_74_25`

Fit candidates live on `integ/720p-compose` or a parent-granted fit QSF copy — not silent default enable.
