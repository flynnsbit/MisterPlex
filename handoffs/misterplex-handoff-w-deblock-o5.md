# Handoff — W-DEBLOCK-O5 (deblocking filter)

**Branch:** `w-deblock-o5` (worktree `.worktrees/w-deblock-o5`), branched from `w-deblock-seam` @ `2c2cb83`.
**Model:** claude-opus-5. **Predecessor:** `w-deblock` (`7225e00`, `a4ed0b9`, handoff `2c2cb83`).

**Zero frames have ever been decoded and displayed by the FPGA. Nothing below changes that.**
No Quartus fit was run (sole exclusive slot, `w-fit-o5`). No BUILD_OK / DEPLOY_OK is claimed.

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
