# Fmax risk: present modules on main@3fa01a9b + residual_csum fix

**MEASURE_REF_MAIN:** detached `3fa01a9b` (`MisterPlex-wt-clock-pin-3fa01a9b`)  
**Branch tip (this work):** see `git rev-parse HEAD` on `w-clock-bump`  
**No Quartus fit run by w-clock** (parent exclusive; HELD).

## Prior Fmax (MEASURED — different netlist)

| Artifact | clk_sys Fmax | Owner | Corner |
|---|---|---|---|
| fit-nostub-chrome `c74c6863` | **32.59 MHz** | `slice_hdr_parser` `r_tc[*]` → `residual_csum[*]` | Slow 1100mV 100C Final |
| stub-in `8fdf440f` | 23.46 MHz | `decode_stub` (placeholder) | same |

Source path dump (this repo):  
`.agent-work/w-clock/nostub-path-dump/clk_sys_emu_sameclk.txt` L26:  
slack 19.318, data delay **30.062 ns**, From `r_tc[1]`, To `residual_csum[5]`.

**32.59 is NOT a property of main@3fa01a9b.** New fit required.

---

## Task 1 — Eleven present modules vs timing (SOURCE, no fit)

Modules on main@3fa01a9b `files.qip` (L2 compiled; product ENABLE mostly off):

| Module | clk domain (source) | INST on default product | Sameclk cone with residual_csum? |
|---|---|---|---|
| present_video_timing_720p | noprune / obs | L3* obs | No direct |
| present_video_timing_960 | similar | off | No |
| present_beam_content_de | clk (clk_sys) | only if BEAM on | No — present tree |
| present_beam_ppc | clk | BEAM off | No |
| present_npx_path | clk_sys + clk_pix | MULTI off | No |
| present_pix_rate_match | clk | off | No |
| present_content_window | clk | off / dead | No |
| present_geom_latch | clk | often INST=0 | No |
| present_vtotal_bresenham | clk | off | No |
| yuv_bt601_npx | combo/clk | MULTI off | No |
| plex_present_geom_mux | combo | mux | No |

**Mechanism (INFERRED from hierarchy, not STA):**
1. **Logic cone:** residual_csum lives in `stream_path`/`slice_hdr_parser`. Present modules hang under `present_core` / Plex video. **No shared combinational path** from place/csum to beam DE in source.
2. **Clock:** both use `clk_sys` when present is enabled → **placement/congestion** can still move Fmax without sharing a cone.
3. **Default-off (L2):** Quartus may strip uninstantiated logic; noprune timing_720p is small. Risk while ENABLE off is mostly **router noise**, not a new critical cone.
4. **L4 enable (FRAME_1280 / BEAM / store):** adds sameclk logic + DDR related-edge paths (`y_line`/`c_line` already appear in nostub related-edge dumps). That is a **separate** risk class from residual_csum.

### Risk rating

| Build | Risk | Why |
|---|---|---|
| main L2 default-off (640×480, store off) | **MEDIUM** | New cells in qip; residual_csum owner may still dominate; Fmax unknown until fit |
| L4 content-1280 + BEAM/store | **HIGH** | Area+route pressure; related-edge CDC paths; residual_csum fix helps but does not bound overall Fmax |

Honest: **cannot know product Fmax without a fit.**

### STA checklist (one-pass after parent fit)

1. Corner **Slow 1100mV 100C Final** Fmax Summary for clk_sys / clk_ddr  
2. Owner **name** From/To — fail if missing  
3. Fail if owner is `decode_stub`  
4. Grep: is `residual_csum` still in top sameclk paths? (expect **drop** after this RTL)  
5. If BEAM/store on: related-edge `clk_sys`↔`clk_ddr` slack ≥ 0; note `y_line`/`c_line`  
6. Record Fmax vs 20.000 MHz period (ship PLL) and vs any unparked target  

---

## Task 2 — residual_csum RTL fix (APPLIED default-ON)

### PRE-REGISTER (before any fit measure)

| Claim | Value |
|---|---|
| Change | ST_PLACE: `residual_csum <= csum_acc` (running XOR), remove combo 16×sat8+XOR into residual_csum |
| Equivalence | zeros free under XOR; csum_acc ^= sat8(each level) during T1/LVL |
| Expected effect on **named path** | `r_tc → residual_csum` cone **eliminated** (no longer D-input of residual_csum) |
| Expected **product Fmax delta** | **UNKNOWN until fit** — next-worst path owns Fmax; do not claim +N MHz |
| Paper only | prior path data delay 30.062 ns @ 50 ns period → that path class gone |

**Publish miss later:** parent fit reports new Fmax/owner; compare to PRE-REGISTER.

### Faults (sim only)

- `FAULT_RES_CSUM_XOR1` — residual_csum = csum_acc^1 at place_pulse  
- `FAULT_RES_CSUM_ONE_CYCLE_DELAY` — residual_csum latched in ST_DONE (naive pipeline twin)

Gate: `tests/unit/test_residual_csum_acc_equiv.sh` (+ math unit).

### Default-ON

Yes — optimization of existing product behaviour with equivalence + RED faults. Not a new feature flag.
