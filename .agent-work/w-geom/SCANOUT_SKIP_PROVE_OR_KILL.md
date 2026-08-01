# Post-present scanout skip — prove or kill (w-geom)

**Branch:** `w-avsync-hdmi-measure`  
**Gate:** `tests/unit/test_ddr_frame_store_scanout_skip.sh`  
**true rc=0** (captured direct, not through a pipe)  
**Log:** `.agent-work/w-geom/scanout_skip_gate.out`

Parent evidence (caller-supplied): 22 glass +2 events / 1429 source (1.54%); daemon same session `publish_misses=0 unaccounted=0 residual=0`; ≥14 skips invisible to daemon counters.

---

## Verdict (loud)

### Under the product ARM free-bank contract, scanout does **NOT** skip a published frame.

**Evidence (measured in sim, product DUT `HOLDS=1 sticky=1 recycle=1`):**

```
PASS rtl_free_gated_24in60: never_swapped=0 glass_plus2=0 presents=121
summary ... fd_delta=120 never_swapped=0 glass_plus2=0 overwrites=0
```

Protocol: doorbell **only** when `!swap_pending` (mirrors `selectDdrWriteBank` refuse on `swap_pending || !anyFree` — `ddr_bank_release_select.hpp:66-67`).  
24-in / 60-out cadence for 300 display frames (~121 presents). Every published identity appears on a `frames_done` edge. Adjacent display identity never jumps by ≥2.

**Therefore:** if the soak’s ARM truly only published when PLXD showed free, **post-present scanout is eliminated** for the ≥14 daemon-invisible glass skips. That residual hands to **w-avsync pre-frameIndex supply**.

### Scanout **CAN** skip if a second doorbell lands while `swap_pending` (contract break)

**Evidence (same product RTL, hostile mode):**

```
REPRO_OK rtl_overwrite_pending: never_swapped=39 glass_plus2=39
summary ... presents=121 fd_delta=81 never_swapped=39 overwrites=40
```

Quoted RTL: doorbell edge **always** latches `pending_bank` with **no free check** (`ddr_frame_store.sv` sys-clk block ~263-269; DDR accept ~986-990).  
PLXD free contract is ARM-only: `free_bank_mask = swap_pending_d2 ? 2'b00 : (~disp)` (`ddr_frame_store.sv` ~1047-1048).

Displacing `pending_bank` before vsync swap → prior pending identity never becomes `disp_bank` → glass +2 class, while ARM still counted a successful present (`publish_misses` stays 0).

Product ARM is written to **Drop** after 50 ms, not force-write (`ddr_bank_release_select.hpp:20-21,66-67`; `fpga_spi.cpp` `kPlxdPollMaxIters=50`). Parent `publish_misses=0` ⇒ Drop path did not fire in that soak (measurement), **not** “overwrite impossible.” Stale PLXD free (documented in the same header and plxd handshake TB) remains the only product-shaped way to doorbell while live `swap_pending` without a Drop.

---

## H1 — 24/60 beat vs parent 1/65

| quantity | value | tag |
|---|---|---|
| TB `cyc_per_disp` | 14080 | TB geometry (shape, not MiSTer pixel clock) |
| P(publish lands on 1-cycle `vsync_pulse`) if uniform | 7.10e-5 | derived |
| max skip frac if every collide skips | 7.10e-5 | derived |
| parent skip frac | 22/1429 ≈ 0.0154 | caller-supplied |
| ratio parent / one-cycle | **≈217×** | derived |
| 24/60 rational lattice | **2 source / 5 display** | exact (`2*60=5*24`) |
| 1/65 | **not** that lattice | arithmetic |

**PASS H1:** pure 1-cycle vsync∩doorbell coincidence **cannot** be the sole cause of 1.54%.  
**907e5950 same-cycle class** is real on `HOLDS=0` (pure NBA model + sustained freeze gate) and **held closed** on product default `SWAP_REQ_HOLDS_PENDING_ACROSS_VSYNC=1` (`ddr_frame_store.sv:49`). It does **not** predict a 1/65 free-gated skip rate on product holds=1.

**Published miss check:** pre-register said “if beat math matches 1/65, open scanout beat.” **Miss on mechanism shape** — 1/65 ≠ 2/5 lattice; one-cycle window too narrow. Rate match alone was never a finding.

---

## H2/H3 — double buffer at 24 producer / 60 consumer

Free-gated double buffer is **sufficient**: late publish waits for free (repeat prior `disp_bank`); it does **not** skip under the product contract (H2 sim).  
Two banks + one pending slot: a **second present while pending** overwrites the pending pointer → **skip** (H3 REPRO). That is not “double buffer too small at 24/60”; it is “third frame admitted before second swapped.”

---

## 907e5950 re-exam

| | holds=0 | holds=1 (product default) |
|---|---|---|
| same-cycle vsync + new doorbell | swap old pending; **clear** `swap_pending`; new bank latched but not armed | swap old; **keep** `swap_pending` for new bank |
| pure model | `lost=1 stuck=1` | `keep=1 second_swap=1` |
| sustained gate | REPRO freeze | PASS motion |
| skip identity free-gated | n/a (product is holds=1) | never_swapped=0 |

Open latent **only** if working core `c5382bee` were built with `HOLDS=0` — **not proven here** (no bitfile parameter dump). Tree default and HEAD RTL are `1'b1`. No new fit authorized.

---

## RBF?

**No RBF required** to explain parent soak under free-gated ARM: scanout path is clean in sim.  
Optional defense-in-depth (RTL ignore doorbell while `swap_pending`) would need a fit **and** is unnecessary if ARM free contract holds. Do not fit without parent grant.

---

## Pre-register for parent device follow-ups

| check | PASS band | FAIL band | meaning |
|---|---|---|---|
| `publish_misses` 60s soak | 0 (already) | >0 | Drop path / free wait — counted, not glass-invisible |
| free-gated assumption | no doorbell while live `swap_pending` | any | opens H3 skip class |
| glass +2 rate if supply fixed | →0 | still ~1.5% | revisit scanout only with free-contract proof broken |
| `frames_done` (PLXD) vs presents | ≈ presents (drain) | presents ≫ frames_done | pending overwrite or freeze class |

**Commands (parent only — agent does not touch device):**

```bash
# During a 60s OCR soak, sample PLXD once per second (parent host→MiSTer path):
# Expect: when daemon presentCount advances, either swap_pending was 0 at select
# or a publish_miss wall_s= line exists. Any present without miss while swap was
# live is the H3 discriminator.
grep -E 'publish_miss|PLXD|free_mask|swap_pending' /path/to/daemon.log
```

---

## Gate wiring

- `tests/rtl/ddr_frame_store_scanout_skip_tb.cpp` + `_top.sv`
- `tests/unit/test_ddr_frame_store_scanout_skip.sh`
- `Makefile` `unit` + `rtl-sim-unlocked` lists

Markers required (EXECUTE, not compile-only): `PASS H1`, `PASS pure identity`, `PASS rtl_free_gated_24in60`, `REPRO_OK rtl_overwrite_pending`, `REPRO_OK rtl_holds0_collide`.
