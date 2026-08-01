# present_core.sv freeze vs tip — c5382bee + 78eff44e

**Standing rule:** every mechanism claim names the **artifact pair** (RBF md5 [+ daemon md5 if host-path]).  
**This check:** RTL freeze trees only — no device, no Quartus.  
**Repo HEAD at write:** `w-avsync-hdmi-measure` (re-check `git rev-parse --short HEAD`).

---

## 1. How each freeze was identified

### RBF `c5382bee73cecdee8220b811e529c297`

| Evidence | Value |
|----------|--------|
| Fit claim file | `.agent-work/w-fit/evidence-leftedge3-build-ok.txt` §6 |
| RBF path (claim) | `.agent-work/w-fit/leftedge3-proj/remote_out/w-fit-leftedge3/Plex.rbf` |
| RBF md5 (re-measured) | `c5382bee73cecdee8220b811e529c297` · `true rc=0` |
| Same RBF in mplex-builds | `/home/flynnsbit/mplex-builds/w-fit-leftedge3/leftedge3-proj/output_files/Plex.rbf` |
| Freeze RTL tree | `.agent-work/w-fit/leftedge3-proj/rtl/` (and mplex-builds twin) |
| `present_core.sv` md5 | `775c12f768fb36dcea7cd4ea0edc75db` |
| `ddr_frame_store.sv` md5 (claim) | `c139274e814a4696c485c0bba3781ad8` (differs from tip — already known) |
| QSF | `FRAME_W=640` `FRAME_H=480` |

**Identification rule used:** same as prior T1 pack freeze — BUILD_OK evidence that prints RBF md5 `c5382bee…` and the project tree that produced that RBF.

### RBF `78eff44ed32c7ce35d648e3da5e2b93f` (currently on user device per parent)

| Evidence | Value |
|----------|--------|
| Fit tree | `/home/flynnsbit/mplex-builds/fit-ceil-fd/Plex_MiSTer/` |
| RBF | `.../output_files/Plex.rbf` md5 `78eff44ed32c7ce35d648e3da5e2b93f` · `true rc=0` |
| `present_core.sv` md5 | `9c100fbace5aa4ae80d6ad87e6d5af7f` |
| `ddr_frame_store.sv` md5 | `6c39218e83f30a888841b3e1e0e94d6d` (= tip store at last check) |
| QSF | `FRAME_W=640` `FRAME_H=480` |

**Note on parent “fitted RTL 65d3d450”:** no file under `fit-ceil-fd` matched md5 prefix `65d3d450` in this pass. **Authoritative present_core freeze md5 for 78eff44e is `9c100fba…`.** If 65d3d450 was a different file/commit stamp, it is not this `present_core.sv`.

### Tip (repo working tree — **not** a deployed RBF)

| File | md5 |
|------|-----|
| `fpga/Plex_MiSTer/rtl/present_core.sv` | `9a5a9b2663a293099789cdf626420d79` |

`diff -q` tip vs both freezes: **differ** (`rc=1`). Tip ≠ 78eff44e present_core (parameterization drift after fit).

---

## 2. Diff summary

| Pair | `diff -q` | Notes |
|------|-----------|--------|
| LE3 (c5382bee) vs tip | **DIFFER** | ~80 hunk-lines in unified diff; Y-map is the load-bearing delta |
| fit-ceil-fd (78eff44e) vs tip | **DIFFER** | Tip uses `NATIVE_V_1TO1`; fit uses `V_STORE_SD/PROG` split — **same product scandouble intent**, different form |
| LE3 vs fit-ceil-fd | **DIFFER** | **Ceiling fix is here** |

### Load-bearing Y-map delta (LE3 → tip), quoted from `diff -u`:

```diff
-	localparam V_STORE = 10'd240;
-	localparam int STORE_Y_SCALE = (FRAME_H * 65536) / 240;
-	wire [9:0] py = scandouble ? (vc >> 1) : vc;
+	localparam bit NATIVE_V_1TO1 = (FRAME_H > 240);
+	localparam int V_STORE_I = NATIVE_V_1TO1 ? FRAME_H : 240;
+	localparam int STORE_Y_SCALE = (FRAME_H * 65536) / V_STORE_I;
+	wire [9:0] py = NATIVE_V_1TO1 ? vc : (scandouble ? (vc >> 1) : vc);
```

---

## 3. FROZEN c5382bee — does `store_y = py*2` / V_STORE 480/240 exist?

### `V_STORE_SD` / `V_STORE_PROG`?

**NO. Those identifiers do not exist in the c5382bee freeze.**

Frozen LE3 `present_core.sv` (md5 `775c12f7…`), quoted:

```systemverilog
// leftedge3-proj/rtl/present_core.sv:161-171
localparam H_DE    = 10'd529;
localparam V_STORE = 10'd240;
localparam int STORE_X_SCALE = (FRAME_W * 39647) / 320;
localparam int STORE_Y_SCALE = (FRAME_H * 65536) / 240;
...
wire [9:0] py = scandouble ? (vc >> 1) : vc;
wire in_content = (hc < H_DE) && (py < V_STORE) && ~hb && ~vb;
```

```systemverilog
// :196-200
wire [9:0] store_y_clamped = past_last_row ? 10'd239 : py;
wire [31:0] store_y_prod = store_y_clamped * STORE_Y_SCALE;
wire [15:0] store_y_comb = store_y_prod[31:16];
// store_y_addr ← store_y_comb (clamped to FRAME_LAST_Y)
```

With **product QSF `FRAME_H=480`**:  
`STORE_Y_SCALE = (480 * 65536) / 240 = 131072 = 2.0` in Q16.  
So **`store_y = floor(py * 2)`** (via mul-shift), **yes**.

`scandouble` pin on both freezes: `Plex.sv:741` `.scandouble(forced_scandoubler)`.

| `forced_scandoubler` | py | V window | store_y sequence (unique) |
|----------------------|----|----------|---------------------------|
| **0** (progressive) | `vc` | `py < 240` | 0,2,4,…,478 — **even only**, 240 DE lines |
| **1** (scandouble) | `vc>>1` | `py < 240` | same **even only**; each py held two display lines |

**B2 solid-field card (odd rows absent, std=0) is explained by this freeze**, not by tip’s `V_STORE_SD/PROG` names.

---

## 4. FROZEN 78eff44e (`fit-ceil-fd`) — mechanism

```systemverilog
// fit-ceil-fd/.../present_core.sv:170-206 (md5 9c100fba…)
localparam int V_STORE_SD   = 480;
localparam int V_STORE_PROG = 240;
localparam int STORE_Y_SCALE_SD   = (FRAME_H * 65536) / V_STORE_SD;   // 1.0 @480
localparam int STORE_Y_SCALE_PROG = (FRAME_H * 65536) / V_STORE_PROG; // 2.0 @480
wire [9:0] py = vc;   // Do NOT vc>>1
wire [9:0] v_store = scandouble ? 10'(V_STORE_SD) : 10'(V_STORE_PROG);
...
wire [31:0] store_y_scale = scandouble ? 32'(STORE_Y_SCALE_SD) : 32'(STORE_Y_SCALE_PROG);
wire [31:0] store_y_prod = store_y_clamped * store_y_scale;
```

| `forced_scandoubler` | Behavior on **78eff44e** |
|----------------------|---------------------------|
| **1** | `v_store=480`, scale **1.0**, `store_y=vc` → **all 480 store rows** (T7 vertical fix) |
| **0** | `v_store=240`, scale **2.0**, `store_y=py*2` → **still even-only over 240 DE** |

**Mechanism differs between c5382bee and 78eff44e** on the **scandouble=1** product path.  
If a measurement was taken with `forced_scandoubler=0`, **78eff44e still has the progressive even-row ceiling.**

Tip (`9a5a9b26…`): `NATIVE_V_1TO1=(FRAME_H>240)` → at FRAME_H=480 always `py=vc`, `V_STORE=FRAME_H`, scale 1.0 — **stronger** than fit (no PROG even-cull when FRAME_H>240). Tip is **not** the 78eff44e freeze.

---

## 5. Corrected one-sentence mechanism statements

### For B2 / “480p looks like 240p” measured on **c5382bee**  
**(RBF `c5382bee73cecdee8220b811e529c297`, freeze `leftedge3-proj/rtl/present_core.sv` md5 `775c12f7…`):**

> On RBF **c5382bee**, `present_core` hard-wires `V_STORE=240` and `STORE_Y_SCALE=(FRAME_H*65536)/240` (=2.0 at FRAME_H=480) with `py = scandouble ? (vc>>1) : vc`, so `store_y = floor(py*2)` only ever addresses **even** DDR store rows 0,2,…,478 — matching the B2 opposite-solid-field result (odd rows absent).

**Do not cite `V_STORE_SD`/`V_STORE_PROG` for that measurement — those symbols are not in the c5382bee freeze.**

### For glass on **78eff44e** (RBF `78eff44ed32c7ce35d648e3da5e2b93f`, freeze `fit-ceil-fd/.../present_core.sv` md5 `9c100fba…`):

> On RBF **78eff44e**, when `forced_scandoubler=1`, `py=vc` with `V_STORE_SD=480` and scale 1.0 so all 480 store rows are fetchable; when `forced_scandoubler=0`, `V_STORE_PROG=240` and scale 2.0 still fetch only even rows over 240 DE lines.

### Tip vs published sentence

Tip’s `V_STORE_SD/PROG` wording describes the **78eff44e-class / post-T7 fit form** (or tip’s NATIVE_V_1TO1 cousin), **not** the c5382bee freeze.  
**Conclusion “240 unique rows on c5382bee” remains device-safe; the tip citation was the wrong artifact.**

---

## 6. Cadence RCA — version stamp (resume; unchanged verdicts)

| Claim | Artifact |
|-------|----------|
| Swap window; no min-2; 907e HOLDS=1 | RBF **78eff44e** freeze `ddr_frame_store.sv` md5 `6c39218e…` @ fit-ceil-fd (byte-identical tip store at last check) |
| (a) 907e → early 1-hold | **KILLED** on that freeze (doorbell preserve, not prior-hold shorten); 907e **is fitted** on 78eff44e |
| (b) 1-hold RTL-legal | **CONFIRMED** — only `vsync && swap_pending && pending_ready` |
| Parent soak `p_d1=0.0335` as hold-1 | **Invalid field use** — `p_d*` = Δframes_done; need `p_hold_d1` on daemon that emits it |
| PLXD[63:48] on 78eff44e | **swap** `frames_done_d2` (same freeze store) |
| Parent soak session | Parent-stated RBF **78eff44e** + daemon **7c991e47** (agent did not re-md5 device) |

Full write-up: `SINGLE_REFRESH_HOLD_RCA.md`, `CADENCE_JITTER_RCA.md`, `DEVICE_CARD_CADENCE.md`.

---

## 7. Commands / rc (this check)

```
md5sum leftedge3 .../Plex.rbf  → c5382bee73cecdee8220b811e529c297 ; true rc=0
md5sum fit-ceil-fd .../Plex.rbf → 78eff44ed32c7ce35d648e3da5e2b93f ; true rc=0
md5sum LE3 present_core → 775c12f768fb36dcea7cd4ea0edc75db ; true rc=0
md5sum FIT present_core → 9c100fbace5aa4ae80d6ad87e6d5af7f ; true rc=0
md5sum tip present_core → 9a5a9b2663a293099789cdf626420d79 ; true rc=0
diff -q LE3 tip → differ rc=1
diff -q FIT tip → differ rc=1
diff -q LE3 FIT → differ rc=1
```
