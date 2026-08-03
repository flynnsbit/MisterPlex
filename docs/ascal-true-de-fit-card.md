# Asca-native true-DE (max tier 960×540) — fit card (w-scaler → w-nostub)

**Architecture lock:** `ascal_true_de_960` — core emits **true DE == content extent**; ascal (`iauto=1`) upscales DE to 1280×720.  
**Raster policy (parent 2026-08-03):** **runtime-variable** DE tracking PMS-delivered geometry. **960×540 is the maximum tier, not a fixed raster.** PMS does **not** upscale (lab: `/library/metadata/1` 320×240 source stays 320×240 at rung 540). Gate **B13** fails fixed-only beam/core binds.  
**Gate:** `make fit-gate` / `scripts/fit_release_gate.sh` — leg0 architecture + macros + elab + counted true_de.  
**Ruler identity:** `docs/fit_gate_identity.json` binds gate scripts; divergent lane copies get `LEG0_COUNT_REFUSED` (do not compare counts across rulers).  
**Integration (w-osd only grant path):** run the **fitgate ruler** against the **merged tree**:
```bash
RULER=/home/flynnsbit/Projects/MisterPlex-wt-fitgate
MERGE=/path/to/merged-tree
"$RULER/scripts/fit_release_gate.sh" --root "$MERGE" --qsf "$MERGE/fpga/Plex_MiSTer/Plex.qsf"
# true rc=$?   — only this count can release the fit; per-lane counts cannot
```
`--root` unifies QSF+RTL (B11). Sibling fix tags are **live-scanned** at gate time (`tip=` + timestamp; `tip_newer=1` if static table lagged).  

**B19 MERGE-LOSS (parent 2026-08-03 observed on integ/fab-720p-product):** when a fix commit **is** an ancestor of gated HEAD but the **evidence string is absent** from the artefact, status=`merge_loss` and leg0 emits hard `B19_MERGE_LOSS` (independent of whether the matching Bn_* also fires). Ancestry alone never clears a missing-evidence fix. Inverse under-take: `B19_LANE_TIP_NOT_MERGED` when partial integration absorbed some sibling commits but a live tip is not an ancestor.  

**B16 product file list (rd-duck hold):** merged `files.qip` must list beam + `plex_present_geom_mux` + `plxg_ddr_poller` + `present_geom_latch` + q5 aspect/fps module; product QSF must active-`PRESENT_BEAM_960=1`.  

**B20 full-hierarchy tests (rd-duck hold a–g):** **explicit manifest** `tests/unit/B20_HIER_MANIFEST.json` v2 — gate **loads + runs** each named script **twice** (not keyword regex).  
**GREEN:** `CASE EXECUTED` + `PASS` + `measured_*=` + `require_stdout` + **true rc=0** + **sim evidence** (Verilator tool fingerprint in stdout **or** `SIM_ARTIFACT=` path to existing binary ≥32B).  
**FAULT twin** (`B20_HIER_FAULT=1` default): same `CASE EXECUTED` + **true rc≠0** (≠77) — behavioral fail of a load-bearing DUT condition.  
Script **body** must invoke **`verilator` / `scripts/run_verilator.sh` / `make …sim|tb` / python TB**.  
**Banned positive oracles:** `test -f` / `rg` / `grep` alone, echo `SIM_RUN=1` / `DUT_TOUCHED=1` / `HIER_TB_RUN=1`, comment prose with `PLXC_EXT_WE…`. Soft-skip 77 ≠ PASS.  
G requires: `measured_cdc_async=1`, `measured_host_we_beats=2`, `measured_ctrl_beats=1`, `measured_plxc_ext_we_rising≥2`, `clk_host_ne_clk_plxc=1`.

**B20_UNCONNECTED_PRODUCER (parent 2026-08-03, integ miss #11):** correct producer + correct consumer never wired (e.g. latch `dar_*` ports omitted while `plex_video_ar` reads undriven nets). B19 content-presence greps stay green. Gate runs Verilator **PINMISSING** (product-rtl **output** ports) + **UNDRIVEN** (product nets) over the Quartus file list — log `build/vl_connectivity_sweep.log`. Also flags primary `files.qip` modules never instantiated (`plex_content_fps_sel` class). **LIMITATION (wrong-producer twin):** has-a-driver ≠ intended-driver (e.g. `content_fps=8'd24` while `fabric_content_fps` is driven but unused) — not covered by this sweep; say so rather than imply coverage.  

**B2 raster SoT:** `present_video_timing_960.sv` is **constants/math only by w-clock design** — not a defect. Product raster SoT is `present_beam_content_de` (hc/vc + qip). `B2_NO_RASTER_GENERATOR` retired as noise; `B2_NO_PRODUCT_RASTER` fires only if the beam is missing.  

**B21 hierarchy constants (rd-duck, observed):** product `Plex.sv` currently `assign HDMI_BLACKOUT=0` and `assign VGA_SCALER=0`. ascal's 3-frame resolution-change blackout (`ascal.vhd` `swblack` → `o_newres<=3`) is **disabled** when BLACKOUT=0 — **do not claim it protects runtime geometry changes**. `VGA_SCALER=0` leaves `vga_force_scaler` low so sys_top may take **direct_video / raw VGA** paths that **bypass ascal** for the nonstandard ~16.92 kHz 24/30 Hz beam. Runtime-beam product must force **`HDMI_BLACKOUT=1`** and **`VGA_SCALER=1`** (or hard-reject bypass). Gate asserts exact hierarchy: emu assigns, `.HDMI_BLACKOUT(hdmi_blackout)`, `.VGA_SCALER(vga_force_scaler)`, `.swblack(hdmi_blackout)`, and `vga_fb`/`vga_scaler` OR of `vga_force_scaler`.  

**B10:** `discover_design(macro_qsf=)` must actually run (`LEG0_DISCOVER_DESIGN EXECUTED`); TypeError/stale `rtl_lint` → `B10_DISCOVER_DESIGN_DID_NOT_RUN` (check did not execute).  
**B14:** `coded_w` 16-align reject required (`rt_coded_w[3:0]==0`); PMS AR-fit 468/638/626 is an observed defect class.  

**B22 present_core merge-semantics (rd-duck c5bd6009):**  
w-scaler `present_core` **must not win wholesale**. That tip dropped w-mem B16 `geom_live_seq`/`geom_live_valid`, `stat_geom_hold_black`/`stat_geom_hollow`, store `.rt_geom_*` / `.geom_hold_black` nets, and Option-C `#()` wiring; and lacked w-clock B15 `beam_film_class` → `cadence_display_hz` (24/30) into `present_cadence.display_hz`.  
**Same-symbol opposite-direction green-in-isolation:** each lane alone is green; ancestry/file presence stay green after a bad merge; **connections** are gone. Gate asserts **ports + instance nets + Plex.sv hierarchy wiring**, not ancestor SHA. Measured: mem has B16 ports+nets+Plex; scaler/clock tip core OK but Plex unconnected; c5bd6009 core missing ports+cadence.  

**B23 single-owner table (parent arbitration #3):**  
Three whole-file-adoption incidents (ddr_frame_store / Plex.sv q5 nets / present_core) share one root cause: multi-owner files resolved by taking "the good copy".  
**SoT:** `docs/rtl_single_owner_table.json` — owners: w-mem (store, latch, mailbox_abi), w-clock (present_core, beam, fps_sel), w-scaler (window, plex_video_ar), w-osd (**Plex.sv integration only — patches not copies**), w-fitgate (this gate).  
**Rule:** non-owner NEVER whole-file-copies; submit precise patch/port contract to owner.  
**Canonical ABI #2 nets:** `plxg_*` (w-mem producer wins). `fabric_dar_*` / `fabric_content_fps` without `plxg_*` → `B23_ABI2_FABRIC_NETS_NOT_PLXG` (incident #2 / undriven class).  
**Gate backstop:** `B23_OWNER_MARKERS_MISSING` when owner contract markers drop; ownership is the **cure**, gate is not. B19 catches content drop #1; B20_UNCONNECTED catches #2 wiring; B22 catches #3 present_core ports — B23 names the process class.  

**B24 q5 bit34 fps_1001 ABI merge-loss (rd-duck 2026-08-03):**  
w-path `f31a6eb9` packs **q5[34]=fps_1001**, reserved **[63:35]**, host `24000/1001` → `content_fps=24` + flag.  
w-mem latch: `q5_reserved_nz = |sh5[63:34]` → **E4 / wholesale geom reject** when film flag set.  
w-clock: **no fps_1001 consumer** (integer bucket alone outruns 23.976 → bank miss ~40s).  
**Static q5@0x828 / B17 presence is insufficient.** Gate requires executable  
`tests/unit/test_b24_q5_fps_1001_merged_path.sh` (manifest `B24_Q5_FPS_1001_MANIFEST.json`):  
host-pack canonical 24000/1001 → merged **poller+latch+consumer** → prove  
`measured_latch_accept=1`, `measured_q5_reserved_reject=0`, `measured_q5_bit34_fps_1001=1`,  
`measured_consumer_fps_1001=1`, `content_fps=24`, `fps_num=24000`, `fps_den=1001`.  
Also static: `B24_Q5_BIT34_LATCH_REJECTS_1001`, `B24_Q5_FPS_1001_NO_CONSUMER`.  

**B1 OPTION_C vs geom-off legacy (rd-duck — architecture):**  
Host `makeDdrPublishPlan` (ddr_present_bank.hpp) on mode-exit / PLXG disable programs **legacy** phys base + doorbell **`0x300FF000`**. FPGA `geom_enable=0` must poll that map.  
**Forbidden:** `` `ifdef OPTION_C `` rebinding `LEG_BASE_W0`/`LEG_DOORBELL_W` to `PHYS_BASE_720P`/`DOORBELL_PHYS_720P` — then geom-off still polls Option-C and **ignores host legacy frames**. Gate token **`B1_OPTION_C_REBASES_LEGACY`**.  
**Required:** Option-C bank only via **runtime `rt_need_optc`** (B7 capacity); `LEG_*` stay `PHYS_BASE` / `DOORBELL_PHYS`.  
**Retired:** `B1_NO_COMPILE_TIME_OPTC` (demanding OPTION_C compile path was the defect).  
**B20_HIER_A** must print measured `geom_enable=0`, `map=LEGACY`, `doorbell_phys=0x300FF000` (not PASS prose).  

**Max-tier measured (beam+window TB):** `true_de=1 de_w=960 de_lines=540 de_pixels=518400 store_req=518400 store_oracle=1 store_x_range=0..959` @ `H_TOT=1182 V_TOT=564` (`fps@20M=30.0008`) — **not** product hierarchy proof (inspect `Plex.sv`).  
**RED:** `PRESENT_BEAM_FAULT_ISLAND_1280` → `de=1280x720 true_de=0` rc≠0 + EXECUTED  
**Also RED (rd-duck):** DE-only greenwash — `de_pixels=518400` with `store_req=517860` (959×540, x=0 dropped) is **not** fit-ready. Beam blank/sync must use **same counter epoch** as registered `hc`/`vc` (`hc_next`).

## Synthesis / QSF (drop-in)

| Item | Value |
|------|--------|
| Macro | **`PRESENT_BEAM_960`** (default OFF today — must be **on** for this fit) |
| Do **not** set | `PRESENT_MULTI_PIXEL`, `PRESENT_SCALE_4_3`, `PRESENT_SCALE_2X`, `PRESENT_BEAM_FAULT_ISLAND_1280` |
| `FRAME_W` / `FRAME_H` | **960 / 540** (storage = content) |
| RTL files | `present_beam_content_de.sv` **must be in `files.qip`** (not only Verilator TB hand-list), existing `present_content_window.sv`. `present_video_timing_960.sv` is constants cargo — product beam is `present_beam_content_de`. Gate B10 + leg2 elaborate the **Quartus qip file list** under fit macros. |
| Beam class | w-clock **MODE=0**: H_DE=960 V_ACT=540 **H_TOTAL=1182 V_TOTAL=564** (Hblank=222, Vblank=24) |
| clk | `clk_sys` **20 MHz**, `ce_pix=1` (1 px/clk) |
| DE_LAG | keep **3** (present_core) |
| **Aspect (VIDEO_ARX/ARY)** | **Required for scalar/ascal proof.** Live `Plex.sv` defaults `status[122:121]==Original` → **`VIDEO_ARX=4`, `VIDEO_ARY=3` (4:3)**. 960×540 true-DE is **16:9** content — Original will present as 4:3. Must force **Full Screen** (`ARX=ARY=0`, OSD second option) or **16:9** (`16/9`) under `PRESENT_BEAM_960` (or known conf/status gate). Gate B9 inspects real top-level assigns + requires an AR pin test — fit-card prose alone is not evidence (rd-duck). |

## Runtime mailbox / PLXG (before first present)

**REQUIRED values for product** (fit-card table ≠ live `Plex.sv` until B8 clears):

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

### Product hierarchy reality check (gate B8 — inspect `Plex.sv`, not thin TB)

As of scaler/fitgate tip, **live `fpga/Plex_MiSTer/Plex.sv`**:

- `plxg_wr_en = 1'b0`, `plxg_commit = 1'b0` → latch stays reset-zero → `fabric_geom_enable=0`, `fabric_win_enable=0`
- Idle `content_width_base` = O[4] **640/320** (not 960)
- Only force macro `FABRIC_NATIVE_720P_GEOM` sets content+geom to **1280×720**, not 960
- Thin `present_true_de_count` TB drives 960 ports directly — **that is not product wiring**
- `PRESENT_BEAM_960` alone → 960 DE around legacy content/storage — **not fit-ready**

Identity (when ports actually get 960): content_w==win_h_de and content_h==win_v_de → Q16 SX=SY=65536 → `store_x==hc`, `store_y==py` (1-cycle window register lag).

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
