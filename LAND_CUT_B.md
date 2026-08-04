# LAND_CUT_B — exact merge order for Cut B fit candidate

**Lane:** w-integ (Wave-2)  
**Date:** 2026-08-04  
**Scope:** Document land order + conflict map. **No FIT_GO. No merge to main.**  
**Companion:** `COMPOSE_ENABLE.md` (QSF recipe Cut B macros).

---

## 0. Tips inspected (after `git fetch origin`)

| Ref | SHA | Notes |
|-----|-----|--------|
| **origin/main** | `704aaae6` | Product land line (#16 canvas). define-parity **rc=0**. Present MULTI/PLL/DMA **OFF**. |
| **PR #17 head** `origin/integ/720p-compose` | `970889df` | Open → main. ENABLED Cut B QSF. define-parity **rc=0**. |
| **local `integ/720p-compose`** (unpushed) | `cb63da3b` | Merge `970889df` + `ab18a382` (#16). ENABLED retained. define-parity **rc=1** (doorbell VALUE-DIFF). **Do not treat as land tip until fixed.** |
| **PR #15 head** `w-nostub-integ-compose` | `a0774b49` | Base: `integ/720p-compose` @ `04e7caa3`. Host canvas `MISTERPLEX_PRODUCT_DDR_720P`. |
| **w-fpga MULTI glass** | `3b6e7a1c` | Branch `w-fleet-fpga` only. **Not** ancestor of #17. |
| **w-clock CLK_VIDEO** | `7a8fc578` / twin `deb3f133` | Branches `w-clock-720p-sv*`. **Not** ancestor of #17. |
| **w-integ-compose-enable** | `bd7592ac` | This lane tip (+ `COMPOSE_ENABLE.md` on `704aaae6`). |

PR #17 URL: https://github.com/flynnsbit/MisterPlex/pull/17  
PR #15 URL: https://github.com/flynnsbit/MisterPlex/pull/15  

### PR #17 vs main `704aaae6`

- Merge-base with product main line: `08b09aa2` (reconcile #12).
- **On #17, not on main:** compose path ABI + ENABLED QSF (`e5bdb984` … `6ffcbc60`) + merge `970889df`.
- **On main, not on PR origin tip:** product geometry chain `9c6d7335`…`ab18a382` + docs `fbbb9e25` `704aaae6`.
- Local unpushed `cb63da3b` already attempted main→integ merge; **left host/RTL 720p doorbell unpaired** (see §3).

### Content already inside #17 (no SHA land required)

| Claimed fix | SHA | Status on `970889df` |
|-------------|-----|----------------------|
| MULTI glass → store map + bank swap `mp_fstart` | `3b6e7a1c` (w-fpga) | **Equivalent already present** via `mp_store_*` / `fs_rd_*_w` / `fs_vsync_w = mp_fstart` in `present_core.sv` (path compose + multi path). Cherry-pick **conflicts**. |
| `CLK_VIDEO←clk_pix` under `PRESENT_CLK_PIX_PLL` + `VIDEO_AR=FRAME_W:H` | `7a8fc578` (w-clock) | **Already present** in `Plex.sv` (`assign CLK_VIDEO = clk_pix_pll` / `clk_sys`; AR from `` `FRAME_W`/`` `FRAME_H`). Cherry-pick **conflicts** on Makefile/QSF/Plex.sv. |
| Host 720p planes/PHYS constants | partial | Dual-header RTL + host `kPlex720p*` exist; **daemon product flag missing** until #15. |

---

## 1. Exact merge order (Cut B land stack)

Parent/integrator applies **in this order**. Do **not** merge to `main` until fit gates are parent-owned.

### Step A — Promote #17 base (RTL + ENABLED QSF)

1. **Start tip:** `970889df` (`origin/integ/720p-compose` / PR #17 head).  
2. **Gates at A:** `make define-parity` → **rc=0** (measured Wave-2). Cut B macros ON in QSF.  
3. **Ship SHAs already in tip (no re-cherry-pick):**

| Order | SHA | Subject |
|------:|-----|---------|
| A1 | `e5bdb984` | compose(720p): path ABI glue — mux, PHYS, define-parity tier, ENABLED QSF |
| A2 | `7866e168` | docs(rtl): M10K depth×width correction |
| A3 | `04e7caa3` | fix(test): EXPECTED_RED prefix on fault-binary red twins |
| A4 | `b15dc3df` | fix(define-parity): ignore comments when discovering test `-D` macros |
| A5 | `6ffcbc60` | fix(integ/720p): composition unit gates for enabled 720p path |
| A6 | `970889df` | merge: origin/main after reconcile #12 into integ/720p-compose |

### Step B — Merge current main (product #16) into integ tip

4. **Merge:** `704aaae6` / equivalent product land (`ab18a382` + follow-ons) **into** Step A tip.  
5. **Must resolve (blocker):** host `kPlex720pYuv420pDoorbellPhys` vs RTL dual-header.

| Side | Doorbell | Meaning |
|------|----------|---------|
| main product host / product RTL `DDR_FRAME_YUV420P_DOORBELL_PHYS` | `0x302FF000` | Identity product canvas as **default** DDR map on main |
| integ dual-header `DDR_FRAME_720P_YUV420P_DOORBELL_PHYS` + path ABI | `0x3047F000` | Option-C 720p tier (`base+2*stride-0x1000`) used by `ddr_frame_abi_select` when FRAME 1280×720 |

- Naive merge (`cb63da3b`) keeps host `kPlex720pYuv420pDoorbellPhys=0x302FF000` while integ define-parity still pairs it to `DDR_FRAME_720P_YUV420P_DOORBELL_PHYS=0x3047F000` → **VALUE-DIFF, `make define-parity` rc≠0**.  
- **Resolution rule for Cut B:** after merge, host **720p dual-header** doorbell must stay **`0x3047F000`** (match RTL `DDR_FRAME_720P_*` + abi_select). Product **default** 480p/identity mapping is Step C’s job via `-DMISTERPLEX_PRODUCT_DDR_720P`.  
- Prefer **re-merge + fix** over using unfixed `cb63da3b`. If reusing `cb63da3b`, apply host doorbell/layout fix **before** any fit.

### Step C — Land PR #15 (host canvas for integ QSF)

6. **Merge or rebased land:** `a0774b49` (`w-nostub-integ-compose` / PR #15) **onto** Step B tip.  
7. **Why after B:** #15 is authored on pre-product integ (`04e7caa3`); main product rewrite of `ddr_frame_layout.hpp` / Makefile unit lists collides with #15 host work.  
8. **Must-land semantic residual of #15** (even if full merge is messy — see §2):

| Path | Intent |
|------|--------|
| `Makefile` | `MPLEX_PRODUCT_DDR_FLAGS ?= -DMISTERPLEX_PRODUCT_DDR_720P=1` on `misterplexd` only |
| `host/libmisterplex/ddr_frame_layout.hpp` | `plex720pDdrFrameGeometry/Layout`, product `#if MISTERPLEX_PRODUCT_DDR_720P` switch, 720p plane/qword/crop SSOT, doorbell **`0x3047F000`** |
| `tests/fixtures/define_parity_allowlist.json` | allowlist `MISTERPLEX_PRODUCT_DDR_720P` |
| `tests/unit/test_present_720p_host_compose_static.py` | NEW host compose gate |
| `tests/unit/test_720p_l4_host_layout.cpp` | NEW layout C++ gate |
| `tests/unit/test_unit_rollcall.py` + Makefile unit hooks | register the two gates |

9. **#15 SHAs (reference; may need replay not raw cherry-pick after B):**

| SHA | Subject |
|-----|---------|
| `95321805` | feat(compose): host 720p product canvas for integ FRAME 1280×720 |
| `79f18edf` | fix(parity): stop FAULT_ false-positive in last_frame_latch red twin |
| `2d93c9c7` | fix(compose): green integ unit after path mux + 720p host canvas |
| `02c5b67f` | fix(compose): clk_ddr arith accepts integ PLL-on FRAME 1280×720 |
| `cc3df372` | fix(compose): proof-of-execution on path RTL sim gates |
| `bddf8569` | fix(avsync): checked-in measured PTS grid (also on main as `b6a26d54` / related) |
| `b312210b` | fix(compose): layout SSOT + abi_select present_core wiring |
| `930c30a7` | fix(compose): +incdir rtl for ddr_frame_store Verilator benches |
| `a0774b49` | fix(compose): clear rtl_lint WIDTHTRUNC/WIDTHEXPAND |

**Overlap note:** several #15 RTL/test fallout fixes are already absorbed on #17 via `6ffcbc60` / `b15dc3df` (store filelists, WIDTH casts, arith PLL tier, sim EXECUTED markers, define-parity comment scan). Prefer **#17 versions** on conflict; take **#15 host/Makefile/allowlist/new tests**.

### Step D — Do **not** land these SHAs (already content-equivalent)

| Item | SHA | Action |
|------|-----|--------|
| w-fpga MULTI glass | `3b6e7a1c` | **Skip.** Content in #17 `present_core` MULTI path. Cherry-pick → conflict on `present_core.sv`. |
| w-clock CLK_VIDEO | `7a8fc578` / `deb3f133` | **Skip RTL.** Content in #17 `Plex.sv`. Cherry-pick → conflicts Makefile/QSF/Plex.sv. Optional later: inventory tests only (`test_720p_clock_plan_static.py`, `test_clk_sys_20mhz_inventory.py`) if parent wants them — **not** required for Cut B enable. |
| Related historical | `0ce6ae1c` (mp_fstart vsync) | Same class as glass; already expressed as `fs_vsync_w = mp_fstart`. |

### Step E — Pre-fit gate (parent), not this lane

10. On final tip: `make define-parity` **rc=0**, `make quartus-sv-subset`, `make unit` as parent policy.  
11. Fit QSF = Cut B macros in `COMPOSE_ENABLE.md` §2 (already ON on integ tip).  
12. Host RBF pair: misterplexd **with** `MISTERPLEX_PRODUCT_DDR_720P=1`.  
13. **No FIT_GO from w-integ.** HDMI refresh proof parent-owned (~24 Hz with PLL).

---

## 2. Expected conflicts

### 2.1 Main (`704aaae6` / #16) → #17 (`970889df`)

| Area | Conflict class | Take |
|------|----------------|------|
| `host/libmisterplex/ddr_frame_layout.hpp` | product identity map vs dual-header 720p PHYS/doorbell | Keep dual-header **720P_*** = Option-C `0x30180000` / doorbell **`0x3047F000`**; product default may use 480p or flagged 720p |
| `fpga/.../ddr_frame_layout_params.svh` | product `DDR_FRAME_*` rewritten to 1280 vs integ dual 480p+720p headers | Keep **dual-header** integ form; product FRAME macros still 1280×720 in QSF via abi_select |
| `fpga/.../present_core.sv` | content_res / geom from #16 vs MULTI glass/path compose | Keep MULTI `fs_rd_*` / `mp_store_*` / PPC path from #17; accept 11-bit content_res from #16 where mechanical |
| `scripts/check_define_parity.py` | main pairs `kPlex720p*`→product `DDR_FRAME_*`; integ pairs →`DDR_FRAME_720P_*` + tier FRAME_W/H | **Keep integ tier-aware** parity |
| unit geometry / hw_visual / rollcall | both sides retarget 1280 | Prefer combined: product golden + integ ENABLED gates |
| `Plex.qsf` | main FRAME_LINES_8 vs integ FRAME_LINES_16 + MULTI/PLL/DMA | **Cut B:** keep integ ENABLED recipe (LINES_16, MULTI, PPC=2, PLL, DMA) |

**Observed bad tip:** `cb63da3b` — ENABLED QSF retained but define-parity **FAIL**:

```
kPlex720pYuv420pDoorbellPhys  host=0x302FF000  rtl_720P=0x3047F000  VALUE-DIFF
```

### 2.2 PR #15 (`a0774b49`) → #17-with-main

`git merge-tree` vs `970889df` already shows **changed-in-both** (pre-main), including:

- `Makefile`
- `fpga/Plex_MiSTer/rtl/ddr_i420_store_width_check.sv`
- `fpga/Plex_MiSTer/rtl/ddr_publish_engine.sv`
- `scripts/check_define_parity.py`
- `tests/unit/test_720p_clk_ddr_arith.py`
- `tests/unit/test_present_store_scale_math.cpp`
- `tests/unit/test_rtl_invariants.py`
- `tests/unit/test_unit_rollcall.py`
- multiple `test_ddr_frame_store_*.sh` / abi_select / width_check / publish budget sims

After Step B, expect **harder** conflicts on:

- `host/libmisterplex/ddr_frame_layout.hpp` (main product + #15 flag switch)
- `Makefile` unit-unlocked list (`test_product_720p_geometry_static.py` vs host_compose / l4_host_layout)
- define-parity comment-scan already on #17 — keep it

**Resolution policy:**  
- RTL lint/width/incdir/arith: **#17 (`6ffcbc60` family)**  
- Host product canvas + misterplexd flag + new host tests + allowlist: **#15**  
- Doorbell dual-header: **`0x3047F000`**

### 2.3 Cherry-picks attempted (Wave-2) — not clean

| Cherry-pick onto `970889df` | Result |
|----------------------------|--------|
| `3b6e7a1c` (glass) | **CONFLICT** `present_core.sv` — abort. Content redundant. |
| `7a8fc578` (CLK_VIDEO) | **CONFLICT** Makefile, `Plex.qsf`, `Plex.sv` — abort. Core assigns already present; would only add inventory docs/tests. |
| `deb3f133` (CLK_VIDEO twin) | **CONFLICT** `Plex.qsf`, `Plex.sv` — abort. |

**Conclusion:** do **not** force these SHAs onto integ; document as **content-landed / SHA-not-landed**.

---

## 3. Cherry-pick / SHA land checklist (operator)

```
# A — base
git checkout -B land/cut-b-720p 970889df
make define-parity   # expect rc=0

# B — main product (resolve doorbell/layout; do NOT ship cb63da3b unfixed)
git merge 704aaae6
# fix: kPlex720pYuv420pDoorbellPhys == 0x3047F000 with DDR_FRAME_720P_*
make define-parity   # must rc=0 before C

# C — host canvas (#15); expect conflicts → take host residual
git merge a0774b49
# or: replay residual files from #15 only if merge too dirty
make define-parity   # must rc=0

# D — skip
# git cherry-pick 3b6e7a1c   # NO
# git cherry-pick 7a8fc578   # NO

# E — parent only
# fit / HDMI — not w-integ
```

### SHA quick reference

| Role | SHA |
|------|-----|
| PR #17 tip (good base) | `970889df` |
| main tip | `704aaae6` |
| product geometry land | `ab18a382` (#16) |
| PR #15 tip | `a0774b49` |
| local bad main∪integ (reference only) | `cb63da3b` |
| glass (skip) | `3b6e7a1c` |
| CLK_VIDEO (skip) | `7a8fc578` |

---

## 4. Wave-2 measured gates (this lane)

| Tree | SHA | `make define-parity` |
|------|-----|----------------------|
| PR #17 origin | `970889df` | **rc=0** |
| main | `704aaae6` | **rc=0** |
| local product∪integ | `cb63da3b` | **rc=1** (doorbell VALUE-DIFF) |
| glass/CLK_VIDEO cherry onto #17 | — | **not clean**; not applied |

No Quartus fit. No device. No merge to main.

---

## 5. Cut B QSF reminder (must stay ENABLED on land tip)

```tcl
PRODUCT_NO_STUB=1
DDR_FRAME_STORE=1
FRAME_W=1280 FRAME_H=720 FRAME_LINES_16=1
PRESENT_MULTI_PIXEL=1 PRESENT_PX_PER_CLK=2
PRESENT_CLK_PIX_PLL=1 + SDC Plex_clk_pix.sdc
FABRIC_FRAME_DMA=1
# ABSENT: L4, BEAM_960, CLK_PIX_74_25, hollow 640x480
```

**Host:** `-DMISTERPLEX_PRODUCT_DDR_720P=1` (PR #15).  
**Refresh:** 29.7e6/(1650×750)=24.000 Hz with PLL — geometry alone ≠ refresh PASS.
