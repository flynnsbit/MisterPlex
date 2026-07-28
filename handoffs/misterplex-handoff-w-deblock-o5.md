# Handoff — W-DEBLOCK-O5 (deblocking filter)

**Branch:** `w-deblock-o5` (worktree `.worktrees/w-deblock-o5`), branched from `w-deblock-seam` @ `2c2cb83`.
**Model:** claude-opus-5. **Predecessor:** `w-deblock` (`7225e00`, `a4ed0b9`, handoff `2c2cb83`).

**Zero frames have ever been decoded and displayed by the FPGA. Nothing below changes that.**
No Quartus fit was run (sole exclusive slot, `w-fit-o5`). No BUILD_OK / DEPLOY_OK is claimed.

---

## 0. Correction issued after w-audit broke the core-subtree gate

`w-audit` proved that `--root h264_decode_core --require <module>` can return rc=0 while
`--root emu --require h264_decode_core` returns rc=1 `parents=<none>` — the subtree gate goes
green while the core is dead. **A subtree proof without a trunk proof is vacuous.**

Measured on **this branch** (`w-deblock-o5`, which descends from `w-deblock-seam` and therefore
predates `stream_path -> h264_decode_core`):

```
--root h264_decode_core --require h264_deblock_mb_filter   rc=0
--root emu             --require h264_decode_core          rc=1   parents=<none>
```

So everything verified on `w-deblock-o5` alone is **CORE_SUBTREE_ONLY, NOT a product claim**.
Both deblock gates now print exactly that verdict themselves, so the mistake cannot be repeated
by reading their output.

`scripts/check_product_reachability.py` runs both directions plus a `files.qip` cross-check and
emits one verdict line: `scope=PRODUCT_REACHABLE` or
`scope=CORE_SUBTREE_ONLY NOT_PRODUCT_REACHABLE`. It hard-fails when `stream_path.sv`
instantiates the product root but `emu` cannot reach it — that is broken wiring, not pending
integration.

### Converged measurement (this is the result that matters)

Branch `w-deblock-o5-converge` = `w-deblock-o5` merged with `origin/w-decode-o5` (which has
`stream_path -> h264_decode_core`). Four trivial conflicts, all resolved:

| Conflict | Resolution |
|---|---|
| FSM state 9 claimed by both | `ST_P16_WIN_START=9`; deblock states renumbered to 10/11/12 |
| `bench_only_modules.txt` | union; then **four stale declarations removed** (see below) |
| `Makefile` / `test_unit_rollcall.py` reachability lines | union of both `--require` sets |

Removing the stale `bench_only` declarations for `h264_deblock_bs`, `h264_deblock_thresholds`,
`h264_deblock_edge`, `h264_deblock_edge_pipe` was **required**, not cosmetic: once the core is
emu-reachable and the filter is under the core, those four became genuinely product-reachable and
the checker correctly refused to accept a stale bench-only declaration.

Measured on the converged tree:

```
PRODUCT_REACH subtree root=h264_decode_core                 rc=0
PRODUCT_REACH trunk   root=emu require=h264_decode_core     rc=0
PRODUCT_REACH_OK scope=PRODUCT_REACHABLE  files_qip=checked
make unit                                                    rc=0
```

**This is the first time deblock filtering is provably in the `emu` lineage in both directions.**
It is still source-level. `make post-fit-hierarchy` remains the only oracle, and no fit has run.

### The blind spot the source checker cannot see, and what does see it

w-audit's disabled-generate mutation, applied to the real `u_core_deblock_mb` instantiation and
measured on the same tree:

| Instrument | Verdict |
|---|---|
| `check_product_reachability.py` (source graph) | **rc=0 — false green** |
| `test_h264_decode_core_deblock_rtl_sim.sh` (elaborate + simulate) | **rc=1** — `macroblock 0 produced 0 DPB writes, want 384` |

Elaboration plus simulation catches what no source-level graph can. That mutation is now a
permanent regression case inside the core gate, and the source-checker rc is *recorded, not
asserted*, so w-gate-o5 fixing the checker registers as an improvement rather than a failure.

`tests/unit/test_product_reachability_redproof.sh` red-proves the helper against four more
mutations — subtree broken, module undefined, RTL file tracked in git but absent from
`files.qip`, escaped instance name — and asserts the tree is restored clean afterwards.
Both red mutations are deliberately **self-contained** (they mutate our own instantiation rather
than depending on a peer module being absent); an earlier version depended on
`h264_inter_mc_part` not being under the core and went stale the moment `w-decode-o5`
legitimately landed MC there. The gate caught its own staleness, which is the correct failure
mode, but the fragility was real and is now removed.

### Two integration defects found and fixed while converging

1. `tests/unit/test_bench_rtl_filelists.py` flagged my core bench as stale because the converged
   core pulls in `h264_decode_top`, `h264_intra_nb_ctx` and `h264_intra_pred`. Rather than chase
   the file list forever, the core bench now hands Verilator **the `files.qip` list itself**, so
   a peer adding a submodule under the core can never make it stale — and a module whose file is
   missing from `files.qip` now fails the *simulation*, not just a declarative check. The guard
   was taught to recognise this narrowly (only when `"${QIP_RTL[@]}"` is actually expanded) and
   the change is red-proved by removing `rtl/h264_decode_top.sv` from `files.qip`.
2. `scripts/check_rtl_module_instantiations.py` aborts with a spurious
   `duplicate module <X>: <same file> and <same file>` during an **unresolved merge**, because
   `git ls-files` emits one row per conflict stage. It fails closed, so it is safe, but the
   diagnostic is misleading. **For `w-gate-o5`.**

### Third oracle: files.qip coverage (w-fit-o5's gate, adopted not rebuilt)

w-fit-o5 measured two product RTL files tracked in git and **never handed to Quartus** on the
branch the deployed RBF `fb4bad84` came from. I re-measured their gate myself rather than
taking the number on trust:

| branch | `check_qip_coverage.py` |
|---|---|
| `w-deblock-o5` (mine, descends from `w-deblock-seam`) | **rc=1** — `NOT_COMPILED h264_decode_top.sv`, `h264_intra_nb_ctx.sv` |
| `w-deblock-o5-converge` | **rc=0** — `product=37 compiled=35`, 2 allow-listed |

So my own branch carries the defect too, confirmed independently. `check_product_reachability.py`
now **delegates** to `scripts/check_qip_coverage.py` instead of duplicating it, and folds the
result into the *product* verdict exactly as the trunk result is folded: a branch whose trunk is
green while its Quartus file list is incomplete is a hard failure, because it claims to be
integrated and is not. rc=77 is reported as a skip, never as a pass. The verdict line now carries
`qip_coverage_rc=`.

Red-proved: removing `rtl/h264_deblock.sv` from `files.qip` must be seen **twice** — once by the
per-module check and once, independently, by the whole-tree gate. The per-module check only sees
files defining a `--require`d module, so the whole-tree gate is what catches a product file nobody
happened to name.

### `test_companion_eof` is FLAKY, not a known-broken test — measured and fixed

The brief lists `tests/unit/test_companion_eof` key `/library/metadata/3` as a known unrelated
failure. It is not a stable failure. Measured:

| branch | before fix | after fix |
|---|---|---|
| `w-deblock-o5` | **15/40 failures (~38%)** | **0/60** |
| `w-deblock-o5-converge` | **13/40 failures (~33%)** | 0 |

Cause: the test fires two `playMedia` HTTP requests and then indexes the captured callbacks
positionally (`captured[0]`, `captured[1]`). They are served on separate HTTP worker threads, so
the append order is undefined; when it inverts, `captured[0].key` is `/library/metadata/3` —
exactly the reported message. **Not a product defect:** `pathResp` and `uriResp` are already
asserted synchronously before this block.

Fixed by matching callbacks on key instead of arrival index, keeping every field assertion and
additionally requiring exactly one of each — strictly stronger than the positional check.
Red-proved: changing the expected key gives
`FAIL: path callback key mismatch: no callback bound /library/metadata/4` (rc=1), restore rc=0.

This matters beyond the test: roughly **one `make unit` run in three was going red fleet-wide for
a reason unrelated to any worker's change**, which corrupts exactly the evidence standard the
parent is trying to tighten. Workers may have attributed it to their own work.

### Merge base

`w-deblock-o5-converge` contains `w-decode-hour27` `2f165ed` (via `w-decode-o5`), which w-fit-o5
identified as the only branch green on both new criteria. Verified with
`git merge-base --is-ancestor`. **Do not base deblock work on `w-deblock-seam` or
`parent/integ-hour27`** — both have an orphaned core *and* an incomplete file list, so a module
would be invisible twice over.

### Capacity — honest limitation

`check_onchip_ram_budget.py` on the converged tree: `block_ram_bits=7,458,816` of which
**7,372,800 is `decode_stub`'s painter DPB alone**. Everything else, my top line buffer included,
is ~86 kbit. So my filter is not a block-RAM problem. It **is** an unmeasured flip-flop problem:
the 20x20 luma + 2x12x12 chroma skirt neighbourhood is registers, estimated ~5.5k FF, and no gate
in the repo measures FFs. With w-fit-o5 reporting M10K at 82% and `decode_stub` holding 46% of the
device, **`DEBLOCK_IN_LOOP` should not be flipped to 1 until `decode_stub` is retired.** That is a
prediction, not a measurement — only a fit can settle it.

---

## 1. What I confirm from my predecessor

Measured by reading the RTL and the benches, not inherited:

| Claim | Verdict |
|---|---|
| `h264_deblock_writeback_ctrl` is instantiated in `h264_decode_core` and gated with `--root h264_decode_core` | **CONFIRMED** (`h264_decode_core.sv`, still there, still gated) |
| Core-rooted reachability is the right policy; plain `emu`-rooted reachability is masked by `decode_stub` | **CONFIRMED and now demonstrated again**: `h264_deblock_writeback_ctrl` passes emu-rooted reachability *only* because the retired `decode_stub` painter instantiates it |
| DPB ref promotion is delayed past writeback; `frame_done` comes from the deblock `ref_ready_pulse`, not raw terminal commit | **CONFIRMED**, and now proven per-cycle at 1170-macroblock scope with a red proof (`H264_DEBLOCK_FAULT_REF_READY_EARLY`) |
| `2271/2271` bS decisions are genuinely RTL-driven | **CONFIRMED** — `evalBs()` reads `dut.bs_derived`. But see §2: MB-boundary edges only, bench-top only |
| The QPy/QPc trap concept at 40/36 | **CONFIRMED as a concept** — and it is now real product RTL, which it was not (see §2) |

---

## 2. What is NOT true / was overstated

**There was no deblock *filtering* in the product decode core at all.**

Per-module reachability with `--root h264_decode_core`, measured before any of my changes:

```
h264_deblock_writeback_ctrl  REACHABLE
h264_deblock_bs              UNREACHABLE   parents=h264_decode_skeleton
h264_deblock_edge            UNREACHABLE
h264_deblock_edge_pipe       UNREACHABLE
h264_deblock_thresholds      UNREACHABLE
```

Consequences, all measured:

1. **`h264_deblock_writeback_ctrl` does not filter anything.** It counts samples and orders commits. In `h264_decode_core.sv` the "filtered" sample stream was
   `deblock_filtered_sample_valid = product_wb_en | p16_sample_wb_en`, and `dpb_wr_data` came straight off `lat_recon_*`. Samples labelled *filtered* were **bit-identical to reconstructed samples**.
2. The predecessor's headline **`full_frame_seam_filtered_mbs=1170/1170`** is real, but it is **ordering/bookkeeping scope, not filtering scope**. Nothing was filtered in any of those 1170 macroblocks.
3. The **`2271/2271` bS** evidence is genuine RTL evaluation but covers **MB-boundary edges only** (no internal 4×4 edges) and runs on a **bench top**, not under `h264_decode_core`.
4. **Chroma deblocking did not exist in the product at all.**
5. **No QPy→QPc mapping module existed in product RTL.** `h264_chroma_qp` appeared only in a comment; the only `chroma_qp_mapped` signal was a painter in `h264_decode_skeleton.sv`.
6. **The PRE/POST separation contract was physically vacuous.** With no filter anywhere on the path, PRE == POST by construction, so nothing could violate it and nothing was proving it.

### True deblock denominators before my work

| Thing | Denominator |
|---|---|
| Macroblocks **filtered** in the product core | **0 / 1170** |
| Luma edges filtered in the product core | **0** |
| Chroma edges filtered in the product core | **0** (no chroma path existed) |
| Samples filtered in the product core | **0 / 449280** |
| Macroblocks in the strongest *filtering* claim (`decode_core_writeback_mbs`) | 2 / 8 — and that gate measures **writeback bookkeeping**, not filtering |
| Samples through the filter *primitive* (bench tops only) | 641 |

---

## 3. What I built

### New product RTL — `fpga/Plex_MiSTer/rtl/h264_deblock.sv`

* **`h264_deblock_qpc`** — clause 8.7 / Table 8-15 `QPy + chroma_qp_index_offset → QPc`.
* **`h264_deblock_mb_filter`** — the macroblock-level clause 8.7 scheduler that did not exist.
  * 64 steps/MB: luma vertical (16) → luma horizontal (16) → chroma U (16) → chroma V (16), which is the normative order.
  * 20×20 luma + 12×12 chroma **skirt neighbourhood**, because filtering an MB edge normatively rewrites p2/p1/p0 on the *neighbour* side.
  * bS from the existing `h264_deblock_bs`; filtering through the existing `h264_deblock_edge_pipe` (2-cycle latency, 4 lanes); QPc from two `h264_deblock_qpc` instances.
  * Chroma uses 2-lane half-segments because a 4:2:0 chroma 4-line segment straddles two co-located luma 4×4 blocks while bS is derived from luma.
  * Disabled/unavailable edges are handled by forcing `bs=0` (pass-through), not by skipping steps, so timing is uniform and picture-boundary garbage in the skirt is harmless.
  * Observability outputs: `luma_modified_samples`, `chroma_modified_samples`, `edge_segments_filtered`, `bs4_segments`, `last_chroma_qp_avg`, `filter_pipe_error`.
  * Fault macros for red proofs: `H264_DEBLOCK_MB_FAULT_{DROP_CHROMA,QPY_FOR_QPC,MB_EDGE_ONLY,HORIZ_FIRST}`.

### Core integration — `fpga/Plex_MiSTer/rtl/h264_decode_core.sv`

The filter now sits **between the reconstructed macroblock and the DPB write**, not beside it.

* New FSM states `ST_DB_LOAD` → `ST_DB_RUN` → `ST_DB_STORE` ahead of `ST_WRITE`.
* Left-neighbour context in registers (4 columns); top-neighbour context in a **per-MB-column line buffer** staged in/out one byte per cycle so it infers RAM rather than a 2.5 kB register file.
* New core inputs `slice_disable_deblocking_filter_idc`, `slice_alpha_c0_offset`, `slice_beta_offset` — `stream_path.sv` already parses all three from the slice header, so they are real signals waiting on the core hookup, not constants.
* `DEBLOCK_IN_LOOP` parameter selects the filtered stream. **The filter is always elaborated** — only the DPB data selection and the extra states are parameterised — so this is a feature flag, not a painter switch. Verified both ways: the pre-existing core writeback / p16z / real-slice gates pass with it **0 and 1**.
* `disable_deblocking_filter_idc = 1` is a **true bypass** (0/449280 samples changed).
* New fault macro `H264_DECODE_CORE_FAULT_{PRE_DEBLOCK_TO_DPB,COMMIT_BEFORE_SAMPLES}`.

---

## 4. Evidence — with denominators, and every green shipped with its red

### `tests/unit/test_h264_deblock_mb_full_frame.sh` — rc=0

```
Scope: deblock_mb_filter_mbs=1170/1170 skipped_mbs_filtered=928/928
       luma_samples_in_frame=299520 chroma_samples_in_frame=149760
       rtl_luma_modified=32099 rtl_chroma_modified=7895
       rtl_edge_segments_filtered=8265 rtl_bs4_segments=1920
       ref_luma_modified=32099 ref_chroma_modified=7895
       measured_nz4_blocks=726/18720 qp_range=3..33
       coded=624x480 display=618x480 cycles=226985
```

* **1170/1170** macroblocks of a real P frame, **928/928 P_Skip macroblocks included** (skipped MBs still deblock — they are not free), luma **and** chroma, **bit-exact** against an independent frame-level clause 8.7 model.
* Motion pass at frame scope: `ref_bs1_lines=121932 bs2=4264 bs3=4320 bs4=2560 bs0=15580` — the bS=1 motion-only path is covered, not just bS=2/4.
* Chroma QPc trap at frame scope: `qpy=40 expected_qpc=36 rtl_last_chroma_qp_avg=36`, and substituting QPy provably changes the picture.
* Bypass: `disable_deblocking_filter_idc=1` leaves all **449280/449280** samples untouched.
* **10 red proofs**, all confirmed rc=1: 6 reference-side (`no_chroma`, `qpy_for_qpc`, `horiz_first`, `skip_skipped`, `mb_edges_only`, `harness_skip_skipped`) and 4 product-RTL `+define+` faults (`DROP_CHROMA`, `QPY_FOR_QPC`, `MB_EDGE_ONLY`, `HORIZ_FIRST`).

### `tests/unit/test_h264_decode_core_deblock_rtl_sim.sh` — rc=0

```
Scope: core_deblock_mbs=1170/1170 dpb_sample_writes=449280/449280
       post_deblock_luma_samples=148004 post_deblock_chroma_samples=37287
       bypass_mismatches=0/449280
       rtl_luma_modified=271774 rtl_chroma_modified=61856
       last_chroma_qp=36 qpy=40 expected_qpc=36
       commits=1170 sample_valids=449280 wb_valids=1170
       boundaries=1 ref_ready_pulses=1 frame_dones=1 coded=624x480
Scope: core_mb0_anchor_mismatches=0/384
```

* Every one of **449280/449280** DPB sample writes from the product core captured in `wb_idx` order.
* **148004 luma + 37287 chroma** committed samples differ from the reconstructed macroblock — the DPB stream is **POST-deblock**, measured, not asserted.
* **Macroblock 0 is bit-exact (0/384 mismatches)** against the independent clause 8.7 reference — an unavailable-neighbour anchor that does not depend on the core's skirt policy.
* **Ordering contract enforced per cycle at frame scope**: 1170 commits each preceded by a complete 384-sample `filtered_sample_valid` run; **0** commits while `ref_ready_pulse` high; exactly **1** `ref_ready_pulse`, and it is preceded by `frame_boundary`; exactly **1** `frame_done`, driven from that pulse; `commit_order_error=0`; `filter_pipe_error=0`.
* **5 red proofs**, all confirmed rc=1:
  * `H264_DECODE_CORE_FAULT_PRE_DEBLOCK_TO_DPB` → *"DPB luma stream is PRE-deblock"*
  * `H264_DEBLOCK_MB_FAULT_DROP_CHROMA` → *"chroma deblocking is not on the core writeback path"*
  * `H264_DEBLOCK_MB_FAULT_QPY_FOR_QPC` → *"chroma edges used qp_avg=40, want QPc=36"*
  * `H264_DEBLOCK_FAULT_REF_READY_EARLY` → *"DPB promotion escaped the boundary"*
  * `H264_DECODE_CORE_FAULT_COMMIT_BEFORE_SAMPLES` → `commit_order_errors=586`

The last two are **the guard for §3 of my mission**: `w-swap-o5` and `w-decode-o5` can no longer break PRE/POST separation or promotion ordering silently. Note one discarded candidate: `H264_DEBLOCK_FAULT_MB_COMMIT_EARLY` is a **no-op fault** in this configuration (the core only raises `filtered_mb_valid` in `ST_COMMIT`, after all 384 samples), so it was replaced with a fault that actually changes behaviour rather than shipped as a fake red.

### Regression sweep (all rc captured by redirect, never through a pipe)

| Command | rc |
|---|---|
| `scripts/check_rtl_module_instantiations.py --root h264_decode_core --require {mb_filter,edge_pipe,edge,thresholds,bs,qpc,writeback_ctrl}` | 0 |
| `scripts/check_rtl_module_instantiations.py` (emu root) | 0 |
| `tests/unit/test_h264_deblock_mb_full_frame.sh` | 0 |
| `tests/unit/test_h264_decode_core_deblock_rtl_sim.sh` | 0 |
| `tests/unit/test_p3_deblock_rtl_sim.sh` | 0 |
| `tests/unit/test_p3_dpb_mc_rtl_sim.sh` | 0 |
| `tests/unit/test_stream_path_deblock_integration.sh` | 0 |
| `tests/unit/test_h264_decode_core_writeback_rtl_sim.sh` | 0 (also 0 with `DEBLOCK_IN_LOOP=1`) |
| `tests/unit/test_h264_decode_core_p16z_rtl_sim.sh` | 0 (also 0 with `DEBLOCK_IN_LOOP=1`) |
| `tests/unit/test_h264_decode_core_real_slice_rtl_sim.sh` | 0 (also 0 with `DEBLOCK_IN_LOOP=1`) |
| `scripts/rtl_lint.py` | 0 |
| `scripts/check_define_parity.py` | 0 |
| `scripts/check_pipe_exit_safety.py` | 0 |
| `make quartus-sv-subset` | 0 |
| `tests/unit/test_unit_rollcall.py` | 0 |
| **`make unit`** | **0** |

Both new gates run inside `make unit`. The two "known unrelated failures" quoted in my brief (geometry `624x480/618x480`, `test_companion_eof`) did **not** reproduce on this branch — `make unit` is fully green.

---

## 5. Honest limitations — read these before quoting any number above

1. **Samples are synthetic.** Deterministic blocky pseudo-random content. Nothing in this project has decoded a real frame, so no real reconstructed samples exist to filter. What *is* measured from the real bitstream: macroblock kinds (928 skip / 197 inter / 45 intra), per-MB QP (3..33), per-4×4 luma coded-block flags (726/18720 non-zero), and geometry (coded 624×480 / display 618×480, 39×30 = 1170).
2. **Sample amplitude had to be tuned.** My first full-frame run gave `luma_modified=0` — with large per-block DC steps the normative `filterSamplesFlag` rejects every edge and the whole frame is a vacuous no-op. Both RTL and reference agreed on "nothing", which is exactly the shape of a gate that passes without doing work. The vacuity guard caught it; the generator now keeps steps inside the α/β activity window. **The QPc trap needed a larger chroma step still** — with tiny steps the clause 8.7.2.3 delta never reaches `tc`, so `tc0(indexA)`, the only place QPc differs from QPy, cancels out.
3. **Pass 1's motion field is measured MVD, not MV.** The MV predictor chain is `w-swap-o5`'s scope. Pass 2 uses a synthetic varied motion field specifically to cover bS=1.
4. **The core's per-4×4 coded-block mask is derived from `cbp_luma` at 8×8 granularity** — an over-approximation that can raise bS from 1 to 2 but never lowers it. The core does not expose a per-4×4 mask yet. The standalone gate uses the real per-4×4 mask.
5. **The core commits only the current-macroblock part of the filtered neighbourhood.** Rewriting the skirt of already-committed neighbour macroblocks needs a one-macroblock commit delay and is **OPEN**. The normatively complete filter behaviour is what the standalone 1170/1170 gate proves.
6. **Reachability is source/regex-level.** `w-audit` proved `check_rtl_module_instantiations.py` is not elaboration-aware. Core-subtree rc=0 is necessary, not sufficient — which is why both gates *simulate* the filter rather than stopping at reachability. Prefer `make post-fit-hierarchy` when a fit exists.
7. **My C++ reference carries the same normative α/β/tc0 numbers as the RTL.** A shared *table* typo would not be caught; only structural differences (addressing, scheduling, bS derivation, QPc application) are cross-checked. I did spot-check ~12 `tc0` entries and the α/β LUTs against Table 8-17 by hand — all matched.
8. **Not fit-verified.** Rough register estimate for the filter is ~5.5k FFs plus ~2k FFs of core staging, and the top line buffer should infer M10K, but **no fit has been run**. `w-fit-o5` owns that.
9. **`h264_deblock_mb_filter` and `h264_deblock_qpc` are listed in `bench_only_modules.txt`** — not because they are bench modules, but because `h264_decode_core` itself is listed there ("not driven by stream_path in this branch"). They inherit that status. When `w-decode-o5` wires the core into `stream_path`, all three entries should be removed together.

---

## 6. The ordering contract, restated (signal names unchanged — `w-swap-o5` depends on them)

* `filtered_sample_valid` precedes `filtered_mb_valid` / `wb_valid` — **enforced**, 384 samples per commit, 1170/1170.
* Terminal MB commit occurs while DPB `ref_ready` is still LOW — **enforced**, 0 violations.
* A later `frame_boundary` produces a one-cycle `ref_ready_pulse` — **enforced**, exactly 1 pulse, preceded by the boundary.
* DPB/MC reference visibility only after that post-boundary promotion — **enforced** via the pulse count and `frame_done`.
* Core `frame_done` driven from the deblock ref-ready pulse, not raw terminal commit — **enforced**, 0 stray assertions.
* **PRE/POST split**: intra/neighbour taps are PRE-deblock; DPB/MC references are POST-deblock only — **now physically real**, and enforced by `H264_DECODE_CORE_FAULT_PRE_DEBLOCK_TO_DPB`.

---

## 7. Next work, in priority order

1. **Skirt writeback.** Give the core a one-macroblock (and one-MB-row) commit delay so the filtered neighbour skirt reaches the DPB too. Until then the core's committed picture is not normatively complete, even though the filter is.
2. **Per-4×4 coded-block mask into the core.** Replace the `cbp_luma`-derived over-approximation once `w-decode-o5` exposes a real per-4×4 mask.
3. **Remove the three `bench_only_modules.txt` entries** (`h264_decode_core`, `h264_deblock_mb_filter`, `h264_deblock_qpc`) the moment `stream_path` drives the core, and flip `DEBLOCK_IN_LOOP` on at that instantiation. `stream_path.sv` already exports `disable_deblocking_filter_idc`, `slice_alpha_c0_offset` and `slice_beta_offset` — they connect straight across.
4. **Fit cost.** Ask `w-fit-o5` for register/M10K numbers on `h264_deblock_mb_filter`; the 400+144+144-byte skirt buffer is the obvious risk, and if it does not fit it should become a line-buffered streaming filter rather than a whole-neighbourhood register file.
5. **Real samples.** Every number in §4 becomes far stronger the moment any real reconstructed frame exists to filter.
