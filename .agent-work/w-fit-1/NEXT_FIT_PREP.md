# NEXT FIT PREP — no slot requested

Date: 2026-08-01  
Lane: w-fit  
Branch: `w-fit-ceiling-fd-min` @ **`e3ed1960`**  
Deployed RBF (vindicated): **`8fdf440fbf4b8b51f5f98df559cc20e5`**  
Baseline metrics (parent): ALM **23585**/41910 · RAM **465**/553 · DSP **44**/112 ·  
min setup **+0.333** · min hold **+0.245** · **TNS 0.000 every row**

**Status: NOT requesting exclusive Quartus slot.**  
Both named priority candidates are **already inside `8fdf440f`**. No new RTL cargo is ready that is (a) unfitted, (b) bit-exact proven, and (c) on the product freeze path without thruput/sink merge risk.

---

## T7b glass result (parent) — recorded

Parent measured RBF `8fdf440f` with w-asset480 full-bleed rk=27 period-2 zone:

| Gate | Result |
|------|--------|
| D1 boot/conf | HIT |
| D2 idle chevron | HIT |
| D3 period-2 zone MEAN 133.58 STD **68.37** | **HIT — 240-row ceiling excluded** |
| D4 ledger 598/598 drops=0 | HIT |

Idle-logo D3 earlier MISS = **instrument** (byte-identical captures), not RTL. Noted.

---

## Candidate 1 — `907e5950` same-cycle vsync+doorbell NBA hold

### Present at freeze?

| Check | Evidence |
|-------|----------|
| `git merge-base --is-ancestor 907e5950 HEAD` | **true rc=0** |
| Product default | `parameter bit SWAP_REQ_HOLDS_PENDING_ACROSS_VSYNC = 1'b1` @ `ddr_frame_store.sv:49` |
| Hold on vsync+req | `:279-283` keeps `swap_pending<=1` when same-cycle req |
| Fitted tree md5 == worktree | `ddr_frame_store.sv` **6c39218e…** both sides |
| In deployed `8fdf440f` build tree | **YES** |

**Nothing to cherry-pick.** This already rode T7b’s fit (and freeze/render wins).

### Red-before-green — TB **executed** (not skip)

`tests/unit/test_ddr_frame_store_scanout_sustained.sh` **true rc=0**

| Arm | Build | Result (quoted log) |
|-----|-------|---------------------|
| A broken | holds=0 sticky=0 recycle=0 | `REPRO_OK sustained_nosticky: freeze-class… max_swap_stall=239` |
| B product | holds=1 sticky=1 recycle=1 | `PASS sustained_product: sustained swaps+motion fd_delta=240… freeze=0` |
| Race model | holds=0 drops / holds=1 retains | `PASS race model` |

Also freeze gate: `REPRO_OK src_y_line_9eb1431a` + product PASS · **true rc=0**.

No `PINNOTFOUND` / `%Error` in these logs.

---

## Candidate 2 — w-area comb shift-add dequant (−32 DSP)

### Present at freeze?

| Check | Evidence |
|-------|----------|
| `mul_norm_adjust` in `h264_iq_idct_4x4.sv` | **YES** (HEAD + fitted tree md5 `f9ae8812…` match) |
| Landed as | `a5d14f74` / twin `26622555` — ancestor of freeze |
| DSP story on silicon | c5382bee **74** DSP → 8fdf440f **44** DSP (**−30**, near −32 claim) |

**Already fitted.** No second ride needed for dequant alone.

### Bit-exactness re-run on freeze RTL (executed)

| Gate | true rc | Execution proof |
|------|---------|-----------------|
| `test_p3_idct_rtl_sim.sh` | **0** | Verilator build dirs entered; `OK real RTL sim… blocks=16 compared_values=768`; `recon_sig=0x3b`; red pred-only → `0x00` fails golden |
| `make unit` | **0** | includes above; `PASS gate_false_green_guard: … PINNOTFOUND hard-fail present` |
| `test_dequant_qp_sweep.py` | **1** | **RED 2236/1196** — same class as w-area commit note (“BASELINE too, not in unit rollcall”). **Not** treated as green. Not a ship gate today. |

Recon path mae=0 class is what product unit enforces; full QP-matrix sweep remains an open honesty item for w-area/w-lint — **not** silently ignored as pass.

---

## Other w-area DSP (Hadamard `e120842d`) — **not integrated**

| Fact | Evidence |
|------|----------|
| Not ancestor of HEAD | `merge-base --is-ancestor e120842d HEAD` → rc=1 |
| Files | `h264_i16_dc_hadamard.sv` + `_serial.sv` |
| On product freeze path? | **No** — modules absent under w-fit `rtl/`; product tip does not instantiate them. They live on w-area **sink** (`h264_i_res_recon_sink.sv`) |
| Risk | Pulling them means thruput/sink merge, not a surgical DSP patch |

**Dropped for next fit** until w-area delivers a product-path, bit-exact, red/green gated patch that applies cleanly onto `e3ed1960` without sink rebase.

RMW A–D / traverse window-reuse: same class — thruput stack, not next minimal fit.

---

## Gate matrix on freeze (shipping SHA) — true rc direct

| Gate | true rc | Actually executed? |
|------|---------|-------------------|
| make define-parity | **0** | yes (does **not** cover T7 structure — known) |
| make quartus-sv-subset | **0** | yes |
| make unit | **0** | yes; PINNOTFOUND guard PASS |
| test_ddr_frame_store_scanout_freeze.sh | **0** | REPRO broken + PASS good |
| _shear.sh | **0** | REPRO + CLEAN |
| _colour.sh | **0** | REPRO chroma/bars + PASS product |
| _sustained.sh | **0** | REPRO holds=0 + PASS holds=1 |
| test_p3_idct_rtl_sim.sh | **0** | Verilator elab+compare+red |
| test_dequant_qp_sweep.py | **1** | executed RED (not rollcall) |

COMPILE-FAIL → would be rc=2; none observed on these.

---

## Pre-registration table — **only if** a future fit carries **new** cargo

Baseline = **`8fdf440f`** (current daily driver after T7b):

| Metric | Baseline | If cargo = none (rebuild only) | If cargo = Hadamard-on-product (hypothetical) |
|--------|----------|--------------------------------|-----------------------------------------------|
| ALM | 23585 | ±50 noise | −0..+150 (shift-add vs mult IP) |
| DSP | 44 | **flat 44** | **predict −1..−16** if serial scale was DSP; **MISS if flat** |
| RAM | 465 | flat | flat |
| min setup | +0.333 | ≥ +0.300 | ≥ +0.250 (combo depth) |
| min hold | +0.245 | ≥ +0.200 | ≥ +0.200 |
| TNS all rows | 0.000 | 0.000 hard | 0.000 hard |

**No new false_path proposed.** Any future SDC cut must list exact endpoints + sync proof before fit.

### Do-not-ship (unchanged)
`c5382bee`, `9eb1431a`, `ff2e3ca3`, `f0d3a385`, `2890baac`,  
banned `{8832824e,75da8bb1,4d6ee356,4deaf6cc,dabdaeb0}`, and do not thrash `8fdf440f` as “new” without source delta.

---

## What would unlock a slot request

1. **New product-path RTL** not already in `8fdf440f`, with  
2. **Bit-exact** gate that executes (elab+compare) and  
3. **Red-before-green** demonstrated on that RTL, and  
4. **Separate commit** from unrelated work, and  
5. Parent grants slot after reviewing this prep.

Until then: **hold.** Daily driver is T7b-vindicated `8fdf440f`. Do not burn a fit on already-shipped `907e5950` + dequant.

---

## Summary for parent

| Item | Action |
|------|--------|
| T7b | Credit taken; glass HIT on proper instrument |
| `907e5950` | **Already in `8fdf440f`**; sustained red/green executed |
| Comb dequant | **Already in `8fdf440f`** (DSP 44); p3_idct executed green |
| Hadamard / RMW | **Not** on product freeze — deferred |
| Slot | **Not requested** |
| Device | Not touched |
