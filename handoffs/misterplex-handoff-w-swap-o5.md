# Handoff — W-SWAP-O5 (motion compensation into the product decode path)

Branch: `w-swap-o5-mc` (worktree `.worktrees/w-swap-o5`), forked from `w-decode-hour27` `ddb7c97`.
Commits: `406e583` (merge) -> `4f4312b` (MC integration) -> `650ab98` (full-frame proof) -> `054d146` (inherited fixes).
Pushed twice to `origin/w-swap-o5-mc`.

All statements below are **measured** unless explicitly marked assumed. Raw logs are committed under
`handoffs/evidence-w-swap-o5/` (`build/` is gitignored, so anything written there is **not** durable -
an earlier note in this repo that logs live in `build/w-swap-o5-logs/` was wrong).

---

## 1. Corrections to the task brief and to the predecessor handoff

Discovered by measuring, not by inheriting.

| Claim I was given | What I measured |
|---|---|
| "Run `check_rtl_module_instantiations.py --root h264_decode_core --require ...` on baseline `ddb7c97`" | On `ddb7c97` that script **has no argparse at all** (200 lines, zero `add_argument`). `--root`/`--require` are **silently ignored**; it prints `root=emu` and exits 0. A **vacuously green gate**. The real instrument exists only on `w-deblock-seam` / `w-gate-hour28`. |
| "Rebase `910c456` onto `ddb7c97`" | `ddb7c97`, `7225e00` (w-deblock-seam) and `w-swap-mc` are **siblings** off merge-base `205f6d4`; neither is an ancestor of the other. A rebase was not possible - this was a 3-way integration. `git cherry-pick -n 910c456` produced **5 semantic conflicts** in `h264_decode_core.sv` (HEAD had renamed `recon_mb_valid`->`product_recon_mb_valid`, added `ST_P16_TAP_REQ`/`p16_tap_idx`, moved `frame_done` onto `deblock_ref_ready_pulse`, added `intra_*_r`). I reset and re-implemented instead. |
| "Land 7 modules under `h264_decode_core`" | Done, plus `h264_deblock_writeback_ctrl` retained = 8 required modules. |

`--require` takes **one** value per flag; repeat the flag.

---

## 2. Measured RED baseline (before my RTL work, on `406e583`), rc=1

```
REQUIRED_RTL_MODULE_UNREACHABLE h264_chroma_epel_block_8x8 file=fpga/Plex_MiSTer/rtl/h264_dpb.sv parents=h264_inter_mc_16x16
REQUIRED_RTL_MODULE_UNREACHABLE h264_dpb_one_ref file=fpga/Plex_MiSTer/rtl/h264_dpb.sv parents=decode_stub,h264_decode_skeleton
REQUIRED_RTL_MODULE_UNREACHABLE h264_inter_mc_16x16 file=fpga/Plex_MiSTer/rtl/h264_dpb.sv parents=h264_inter_mc_part
REQUIRED_RTL_MODULE_UNREACHABLE h264_inter_mc_part file=fpga/Plex_MiSTer/rtl/h264_dpb.sv parents=decode_stub
REQUIRED_RTL_MODULE_UNREACHABLE h264_luma_qpel_block_16x16 file=fpga/Plex_MiSTer/rtl/h264_dpb.sv parents=h264_inter_mc_16x16
REQUIRED_RTL_MODULE_UNREACHABLE h264_luma_ref_tap_addr file=fpga/Plex_MiSTer/rtl/h264_inter_pred.sv parents=decode_stub,h264_decode_skeleton
REQUIRED_RTL_MODULE_UNREACHABLE h264_ref_clamp file=fpga/Plex_MiSTer/rtl/h264_inter_pred.sv parents=h264_luma_ref_tap_addr
RTL_MODULE_INSTANTIATION_FAIL: required RTL modules are not reachable from h264_decode_core
```
(`handoffs/evidence-w-swap-o5/core_require_pre.log`)

## 3. Measured GREEN (HEAD), rc=0

```
REQUIRED_RTL_MODULE_REACHABLE h264_inter_mc_part root=h264_decode_core
REQUIRED_RTL_MODULE_REACHABLE h264_inter_mc_16x16 root=h264_decode_core
REQUIRED_RTL_MODULE_REACHABLE h264_dpb_one_ref root=h264_decode_core
REQUIRED_RTL_MODULE_REACHABLE h264_luma_qpel_block_16x16 root=h264_decode_core
REQUIRED_RTL_MODULE_REACHABLE h264_chroma_epel_block_8x8 root=h264_decode_core
REQUIRED_RTL_MODULE_REACHABLE h264_luma_ref_tap_addr root=h264_decode_core
REQUIRED_RTL_MODULE_REACHABLE h264_ref_clamp root=h264_decode_core
REQUIRED_RTL_MODULE_REACHABLE h264_deblock_writeback_ctrl root=h264_decode_core
RTL_MODULE_INSTANTIATION_OK rtl_modules=68 reachable=21 bench_only=18 root=h264_decode_core
```

## 4. Red/green proof (a green with no red-proof is not evidence)

`tests/unit/test_h264_decode_core_mc_reachability_redgreen.py` mutates each product instantiation
site (10 sites, 8 modules), requires rc=1 with `REQUIRED_RTL_MODULE_UNREACHABLE`, restores, and
requires rc=0. rc=0, `handoffs/evidence-w-swap-o5/redgreen_final2.log`:

```
Scope: red/green reachability proof for 8 required RTL modules rooted at h264_decode_core (10 product instantiation sites mutated)
OK ... h264_deblock_writeback_ctrl unreachable when its 1 product instantiation site(s) are cut (rc=1)
OK ... h264_inter_mc_part          unreachable when its 1 product instantiation site(s) are cut (rc=1)
OK ... h264_inter_mc_16x16         unreachable when its 1 product instantiation site(s) are cut (rc=1)
OK ... h264_dpb_one_ref            unreachable when its 1 product instantiation site(s) are cut (rc=1)
OK ... h264_luma_qpel_block_16x16  unreachable when its 1 product instantiation site(s) are cut (rc=1)
OK ... h264_chroma_epel_block_8x8  unreachable when its 2 product instantiation site(s) are cut (rc=1)
OK ... h264_luma_ref_tap_addr      unreachable when its 2 product instantiation site(s) are cut (rc=1)
OK ... h264_ref_clamp              unreachable when its 1 product instantiation site(s) are cut (rc=1)
OK h264_decode_core MC reachability red/green: 8/8 required modules proved reachable via a mutated-red edge
```

Registered in `Makefile` and `tests/unit/test_unit_rollcall.py`, so the requirement is permanent.

### 4a. Second, independent oracle: elaboration-aware hierarchy (parent caveat #4)

The parent's binding standard notes the registered checker is **source/regex level**, not
elaboration aware, so a core-subtree rc=0 is *necessary but not sufficient*. Quartus post-fit
hierarchy is the strongest oracle but Quartus is a sole exclusive slot I must not touch, so I built
the strongest oracle available to me instead.

`tests/unit/test_h264_decode_core_mc_elab_hierarchy.py` (new, registered) elaborates the product
core with Verilator (`--lint-only --dump-tree-json`), reconstructs the **real module instance graph**
from post-parameter `CELL -> MODULE` links, and checks two properties:

1. all 8 required modules are in the elaborated subtree of `h264_decode_core`;
2. **`decode_stub` is not elaborated at all under this root** - so the masking effect that made
   plain `emu` reachability worthless is structurally impossible here, not merely assumed absent.

A module can only appear in this graph if the elaborator actually built it, so regex blind spots do
not apply. Red proof is by **cutting the instantiation out of the source** and requiring the module
to disappear. rc=0 (`handoffs/evidence-w-swap-o5/elab_hierarchy.log`):

```
Scope: elaboration-aware (Verilator AST) reachability for 8 required MC/DPB/reference modules under h264_decode_core, with a cut-instantiation red proof for each
ELAB_MODULE_REACHABLE h264_inter_mc_part root=h264_decode_core
ELAB_MODULE_REACHABLE h264_inter_mc_16x16 root=h264_decode_core
ELAB_MODULE_REACHABLE h264_luma_qpel_block_16x16 root=h264_decode_core
ELAB_MODULE_REACHABLE h264_chroma_epel_block_8x8 root=h264_decode_core
ELAB_MODULE_REACHABLE h264_dpb_one_ref root=h264_decode_core
ELAB_MODULE_REACHABLE h264_luma_ref_tap_addr root=h264_decode_core
ELAB_MODULE_REACHABLE h264_ref_clamp root=h264_decode_core
ELAB_MODULE_REACHABLE h264_deblock_writeback_ctrl root=h264_decode_core
OK ... elab red-check: h264_inter_mc_part absent from the elaborated subtree when its 1 product instantiation site(s) are cut
OK ... elab red-check: h264_inter_mc_16x16 absent ... 1 site(s) cut
OK ... elab red-check: h264_luma_qpel_block_16x16 absent ... 1 site(s) cut
OK ... elab red-check: h264_chroma_epel_block_8x8 absent ... 2 site(s) cut
OK ... elab red-check: h264_dpb_one_ref absent ... 1 site(s) cut
OK ... elab red-check: h264_luma_ref_tap_addr absent ... 2 site(s) cut
OK ... elab red-check: h264_ref_clamp absent ... 1 site(s) cut
OK ... elab red-check: h264_deblock_writeback_ctrl absent ... 1 site(s) cut
OK h264_decode_core MC elaboration hierarchy: 8/8 required modules present in the elaborated subtree;
decode_stub not elaborated under this root; elaborated_modules=32 subtree_modules=20
dump=Vh264_decode_core_p16z_tb_009_param.tree.json
```

It cannot exit 0 without doing work: a missing Verilator gives **rc=3** with an explicit refusal, a
failed elaboration gives rc=1, and sources are restored in a `finally` block.

### 4b. Structural corroboration (read the RTL, per the standard)

Independent of both instruments, the chain read directly out of the RTL - all instantiations
unconditional, none inside a `generate ... if`:

```
h264_decode_core
├── h264_inter_mc_part          u_product_p16_mc        (h264_decode_core.sv:562)
│   └── h264_inter_mc_16x16     u_full
│       ├── h264_luma_qpel_block_16x16   u_luma
│       └── h264_chroma_epel_block_8x8   u_chroma_u, u_chroma_v
├── h264_dpb_one_ref            u_product_dpb_ref       (h264_decode_core.sv:789)
│   ├── h264_dpb_mb_write_addr  u_write_addr → h264_dpb_i420_addr u_addr
│   └── h264_luma_ref_tap_addr  u_luma_win_addr, u_chroma_win_addr
│       └── h264_ref_clamp      u_clamp
└── h264_deblock_writeback_ctrl u_core_deblock_wb       (h264_decode_core.sv:742)
```

### 4c. Functional corroboration (strongest of the three)

The full-frame gate in section 5 roots at the decode-core testbench top whose **only** DUT instance
is `h264_decode_core`, and it produces 449280 exactly-correct qpel/epel samples covering 16/16 luma
and 64/64 chroma sub-pel phases. Those samples cannot exist unless the MC chain is instantiated
inside the core and load-bearing; the `drop_pred` red-check confirms removing it fails the
scoreboard. This is behaviour, not a name lookup.

**Still not sufficient:** none of these is post-fit. `make post-fit-hierarchy` remains the strongest
oracle and requires the Quartus slot I must not take.

## 5. Full-frame MC correctness (deliverable #4), rc=0

`tests/unit/test_h264_decode_core_full_frame_mc_rtl_sim.sh` (`handoffs/evidence-w-swap-o5/ff_final.log`):

```
Scope: product h264_decode_core P16x16 motion compensation over 1170/1170 macroblocks of a real
624x480 frame (39x30 MBs), 449280/449280 predicted samples checked against an independent
qpel/epel model
OK h264_decode_core full-frame MC: 1170/1170 P16x16 macroblocks predicted exactly;
samples Y=299520 U=74880 V=74880 total=449280; reads=705510 (all addresses exact);
luma_qpel_phases=16/16 chroma_epel_phases=64/64 sub_pel_luma_samples=280064
edge_clamped_mbs=96 differ_from_colocated=230469/299520 pred_range=0..197 cycles=1162986
OK ... red-check: perturbed motion vector failed the 1170-macroblock scoreboard
OK ... red-check: dropped prediction failed the 1170-macroblock scoreboard
```

**Denominator, stated explicitly: 1170/1170 macroblocks, 449280/449280 predicted samples.**
The golden model is evaluated directly on the reference picture, not on the RTL's fetched window.

### What this does NOT prove (do not overstate)
- MVs and the reference picture are **supplied by the testbench**, not parsed from a bitstream.
- Residual is zero in this gate; residual add is covered separately by the p16z gate.
- **Zero frames have still been decoded and displayed by the FPGA.** No Quartus fit was run.
- Resource/timing cost of a combinational full-window `h264_inter_mc_part` inside the core is
  **unmeasured** (Quartus is the sole exclusive slot, owned by `w-fit-o5`).

---

## 6. What changed in RTL

`h264_decode_core.sv`
- P16 path converted from per-sample qpel/epel taps to block MC.
  FSM `ST_P16_TAP_REQ`/`ST_P16_TAP_WAIT` -> `ST_P16_REF_SEED`/`ST_P16_WIN_START`/`ST_P16_WIN_FETCH`.
- `h264_dpb_one_ref u_product_dpb_ref` is the core's POST-deblock reference store **and** write
  address generator; `h264_inter_mc_part u_product_p16_mc` (`part_w=part_h=16`) is the predictor.
- Reference buffers: `p16_luma_ref[0:440]`, `p16_chroma_u_ref[0:80]`, `p16_chroma_v_ref[0:80]`.
- Fetch is **603 reads/MB** (441 luma + 81 U + 81 V), down from 21248 per-sample tap reads.
- Removed `h264_luma_qpel_sample`/`h264_chroma_epel_sample`/`h264_dpb_i420_addr`/
  `h264_dpb_mb_write_addr` from the core (superseded; still reachable via `decode_stub`).

**Binding contracts honoured**
- PRE/POST deblock separation: `u_product_dpb_ref.filtered_sample_valid` =
  `deblock_filtered_sample_valid`, i.e. the same committed POST-deblock stream that feeds the
  deblock writeback controller. Intra/neighbour taps stay PRE-deblock.
- Ordering contract (w-deblock `7225e00`): promotion is `deblock_ref_ready_pulse`; core
  `frame_done` still comes from the deblock controller pulse, not raw terminal commit. No signal
  renamed.
- Bank ownership stays outside: `h264_dpb_one_ref` addresses are rebased
  (`p16_ref_base_r + (mem_raddr - reference_base)`, `wb_base + (mem_waddr - current_base)`).
  i420 addressing is plane-linear so the rebase is exact. `stream_path.sv` untouched.

`h264_dpb.sv`
- `h264_dpb_one_ref` window tap math replaced by two `h264_luma_ref_tap_addr` instances
  (`#(.TAP_COLS(21),.TAP_ORIGIN(2))` luma, `#(.TAP_COLS(9),.TAP_ORIGIN(0))` chroma). Verified
  bit-identical: `test_p3_dpb_mc_rtl_sim.sh` rc=0.
- **Real bug fixed:** `PH_DRAIN` retired only **one** of the **two** in-flight reads, so
  `fetch_done` fired one cycle early and the **final chroma-V window sample (index 80)** was lost.
  Symptom was exactly one wrong sample per MB (sample 383). Added `PH_DRAIN2`. The 2-3 MB gates
  could not see this; the 1170-MB gate found it on its first run.

`h264_inter_pred.sv`
- `h264_luma_ref_tap_addr` parameterised with `TAP_COLS`/`TAP_ORIGIN`; `tap_idx` widened to `[8:0]`.
  Defaults (9/4) reproduce the original centred 9x9 grid bit-exactly for the three existing sites
  (`decode_stub`, `h264_decode_skeleton`, `h264_inter_pred_tb_top`).

### Read-latency contract (important, easy to get wrong)
The external DPB returns data **one** edge after the address is registered. `h264_dpb_one_ref`
aligns returned data with `pending_*_d1`, i.e. **two** edges after issue (the same 2-edge contract
documented in `tests/rtl/h264_dpb_mc_tb.cpp` and in `PHASE_BACKLOG` ~line 550). The core adds a
one-cycle skid (`dpb_rd_valid_q`/`dpb_rd_data_q`) to adapt. **Do not "simplify" this away** -
deleting the `_d1` stage turns tests green while breaking hardware, which this project has already
been burned by once.

---

## 7. Four defects inherited from the merge (all red on `406e583` before my work)

Confirmed pre-existing by running them in a throwaway worktree at `406e583`.

1. `h264_cavlc_residual.sv` indexed its rbsp window with a fixed `bit_pos[8:3]`. Correct only for
   `MAX_BYTES=64`; `slice_hdr_parser` instantiates it with `MAX_BYTES=96`, so **every byte >= 64
   silently wrapped to byte 0**. Byte index now sized from `MAX_BYTES` via `$clog2` (bit-identical
   for 64-byte instances). This also cleared the `scripts/rtl_lint.py` WIDTHEXPAND regression.
2. `tests/rtl/stream_path_full_frame_tb_top.sv` still reached into `dut.gen_decode_stub.stub`
   after `stream_path` renamed the block to `gen_diagnostic_present` - the full-frame compare gate
   could not elaborate (46 Verilator errors).
3. `tests/unit/test_p3_stream_path_recon_rtl_sim.sh` lost its line-continuation backslash after
   `h264_intra_pred.sv`, truncating the Verilator file list before `stream_path.sv`.
4. `tests/fixtures/define_parity_allowlist.json` was missing the three `H264_INTRA_NB_CTX_FAULT_*`
   macros, so `check_define_parity.py` was rc=1 on `ddb7c97` too.

Side effect worth noting: after the `PH_DRAIN2` fix, `test_stream_path_full_frame_compare.sh`
native inter score moved from `inter=0/3300` to `inter=1610/3300`. That path is the **diagnostic**
`decode_stub` painter, not the product core, so I make no product claim from it - but the number in
`PHASE_BACKLOG` row "P-slice / motion compensation full-frame output" is now stale.

---

## 8. Gate results (raw rc, none read through a pipe)

| Gate | rc |
|---|---|
| `check_rtl_module_instantiations.py --root h264_decode_core --require x8` | 0 |
| `test_h264_decode_core_mc_reachability_redgreen.py` | 0 |
| `test_h264_decode_core_full_frame_mc_rtl_sim.sh` | 0 |
| `test_h264_decode_core_p16z_rtl_sim.sh` | 0 |
| `test_h264_decode_core_real_slice_rtl_sim.sh` | 0 |
| `test_h264_decode_core_writeback_rtl_sim.sh` | 0 |
| `test_p3_dpb_mc_rtl_sim.sh` | 0 |
| `test_p3_inter_rtl_sim.sh` | 0 |
| `test_p3_inter_stream_path_rtl_sim.sh` | 0 |
| `test_h264_p_slice_modes_rtl_sim.sh` | 0 |
| `test_p3_stream_path_recon_rtl_sim.sh` | 0 |
| `test_stream_path_full_frame_compare.sh` | 0 |
| `test_rtl_invariants.sh` | 0 |
| `scripts/rtl_lint.py` | 0 |
| `scripts/check_define_parity.py` | 0 |
| `scripts/check_pipe_exit_safety.py` | 0 |
| `tests/unit/test_unit_rollcall.py` | 0 |
| `make quartus-sv-subset` | 0 |
| `test_h264_decode_core_mc_elab_hierarchy.py` (elaboration oracle) | 0 |
| **`make unit`** | **0** (`handoffs/evidence-w-swap-o5/make_unit_with_elab.log`) |

`make unit` was rc=0 at HEAD with the new elaboration gate registered and executing inside the
suite (`handoffs/evidence-w-swap-o5/make_unit_with_elab.log`, `MAKE_UNIT_RC=0`;
`UNIT_ROLLCALL_OK actual_commands=97 protected_commands=94 expected_commands=94`).
It reports 2 **declared** gate skips (`GATE_SKIP CRITICAL live-pms-baseline-profile` and the
`skip-not-pass` red-check), both because live PMS credentials (`PLEX_BASE`/`PLEX_TOKEN`/
`MISTERPLEX_BASELINE_KEY`) are absent in this environment. Nothing was silently skipped and no guard
was overridden.

Getting there took 13 attempts, blocked by the four inherited defects in section 7 and by the
`tests/unit/test_companion_eof` flake. **I root-caused and fixed that flake rather than tolerating
it** - see section 7a.

Expected-red manifest ordinals were **re-measured**, not guessed, for the 603-read ordering:
`p16z_perturb_mv` ordinal 0, `p16z_drop_mv_neighbor` ordinal 603, `p16z_swap_chroma_read`
ordinal 441, `real_slice_swap_chroma_read` ordinal 441.

### 7a. `test_companion_eof` flake - root-caused and fixed (was "known unrelated harness failure")

Measured failure rate of the unmodified test: **1 failure in 6 runs** (`FAIL: path callback key
mismatch: /library/metadata/3`).

Root cause is a **test defect, not a product defect**. `companion.cpp` (~line 925) dispatches
`onPlay_` on a **detached thread**, spawned *after* the HTTP ACK has already been written:

```cpp
if (onPlay_) {
    std::thread([this, pr]() { ... onPlay_(pr); ... }).detach();
}
```

so the arrival order of the two captured `PlayRequest` callbacks is deliberately **not** a product
guarantee. The test asserted positionally (`captured[0].key == "/library/metadata/4"`), which loses
whenever the second detached thread is scheduled first.

Fix (test-only, `tests/unit/test_companion_eof.cpp`): match the two callbacks **by key** instead of
by index. Assertion strength is unchanged - both callbacks are still fully checked
(`ratingKey`, `playQueueItemId`, `serverMachineId`), and a missing callback still fails.

Evidence:
- red-proof: mutating the expected key to `/library/metadata/999` gives rc=1 and
  `FAIL: path callback key mismatch: /library/metadata/4 /library/metadata/3`
  (`handoffs/evidence-w-swap-o5/ceof_red.log`) - the check is not vacuous.
- green: restored, rc=0 (`ceof_green.log`).
- stress: **40 consecutive runs, 0 failures** (`companion_eof_40runs.txt`), versus 1-in-6 before.

---

## 9. Open work for a successor

1. **Nothing drives MC from parsed syntax yet.** `p16_zero_mv_valid` is still a testbench-driven
   port. `stream_path` must route parsed `mb_type`/`mvd`/`ref_idx` into the core's P16 path and the
   MV predictor before a real P-slice can decode.
2. **Only P16x16.** `h264_inter_mc_part` supports 16x8/8x16/8x8 and sub-shapes, and
   `h264_dpb_one_ref` latches `part_w`/`part_h`, but the core hardwires `part_w=part_h=16` and
   always fetches the full 21x21 window. `h264_mv_pred_part` is present under the core but unused
   for partitioned MBs.
3. **P_Skip is not wired.** 928/1170 MBs of a real P-frame are skipped; that path must be free.
4. **Resource/timing unmeasured.** A combinational 16x16 qpel block plus 441+81+81 window
   registers inside the core is a large flat structure. `make post-fit-hierarchy` /
   `make post-fit-timing` evidence is required before any RBF claim. **Do not start a Quartus fit** -
   it is the sole exclusive slot.
5. `PHASE_BACKLOG` row "P-slice / motion compensation full-frame output" is stale (see section 7).

## 10. Compliance with the parent reachability-evidence standard

- I have **never** cited plain `emu` reachability for any product-completeness claim; every claim in
  this handoff is rooted at `h264_decode_core`. **Nothing to withdraw.**
- Every reachability green ships with its red, at two independent levels (regex checker: mutate
  instantiation name; elaboration checker: cut the instantiation), plus a functional red-check.
- The `decode_stub` masking caveat is discharged positively, not assumed: the elaboration gate
  asserts `decode_stub` is **not elaborated at all** under this root.
- Caveat carried forward: core-subtree rc=0 is necessary, not sufficient. Post-fit hierarchy
  evidence is still absent and I did not take the Quartus slot to get it.

## 10a. Compliance with the REVISED standard (both directions, files.qip)

The parent's revised ruling followed `w-audit` breaking the core-subtree gate: on `w-deblock-seam`
`7225e00` a module was provably inside `h264_decode_core` while `h264_decode_core` was provably not
connected to `emu`. A subtree proof without a trunk proof is vacuous.

**Measured on this branch, the trunk is alive.** Regex checker:

```
$ python3 scripts/check_rtl_module_instantiations.py --root emu --require h264_decode_core ; echo rc=$?
REQUIRED_RTL_MODULE_REACHABLE h264_decode_core root=emu
RTL_MODULE_INSTANTIATION_OK rtl_modules=68 reachable=50 bench_only=18 root=emu
rc=0
```

That is a source/regex result, so it is only a pre-filter. `tests/unit/test_h264_decode_core_trunk_elab.py`
(new, registered in `Makefile` and `test_unit_rollcall.py`) is the elaboration-aware version, and it
answers all four of w-audit's mutations. Raw output in `handoffs/evidence-w-swap-o5/trunk_elab.log`,
rc=0:

```
FILES_QIP_PRESENT h264_deblock.sv / h264_decode_core.sv / h264_dpb.sv / h264_inter_pred.sv
ELAB_STAGE dump=Vemu_022_const.tree.json (post-elaboration, dead generate arms pruned)
TRUNK_REACHABLE h264_decode_core root=emu
ELAB_MODULE_REACHABLE x8 root=emu
OK trunk red-check A: h264_decode_core unreachable from emu when its instantiation is cut
OK trunk red-check B: h264_decode_core unreachable from emu when its instantiation is wrapped in
                      a disabled if(0) generate
OK trunk red-check C: MC modules unreachable from emu when h264_dpb.sv is dropped from files.qip
OK trunk mutation-check D: escaped instance name still resolves; h264_decode_core and 8/8 MC
                      modules remain reachable from emu
OK ... quartus_files=66 red_proofs=4
```

Design decisions worth keeping:

- The file list is **not** hardcoded. It comes from `rtl_lint.discover_design()`, which parses
  `Plex.qsf` + `files.qip`. So w-audit's attack 3 (RTL tracked in git but absent from `files.qip`)
  cannot pass by construction: an unlisted file is never handed to the elaborator. Red-check C
  proves that empirically.
- **The AST dump stage is load-bearing and was measured, not assumed.** With the core instantiation
  wrapped in `if (1'b0)`, `h264_decode_core` is still present at `002_cellsort`, `008_linkinc`,
  `009_param` and `010_linkdotparam`; it disappears at `014_width` (emu subtree 49 -> 42). From
  `033_inline` onward the dump has no CELL nodes at all. **The only usable window is stages 14..32.**
  Reading below 14 produces a false pass; reading above 32 produces an empty graph. My first
  implementation read `009_param` and w-audit's attack 1 defeated it — caught by the gate's own red
  check, which is exactly what red checks are for.
- Verilator's `V3Param` dies with an internal error on the Altera PLL megafunctions, which is why the
  earlier probe could only reach pre-param dumps. The gate substitutes local PLL stubs
  (`PLL_STUB`), after which elaboration runs through to `990_final`.
- No literal RTL filename appears in the gate source; owning files are resolved from module
  declarations. Hardcoding them both goes stale and makes `test_bench_rtl_filelists.py` misread the
  `files.qip` assertion as a Verilator input list.

**Still-honest limits.** Elaboration is stronger than regex but is still not the fitted design.
`make post-fit-hierarchy` remains the only real oracle and I have not run Quartus (sole exclusive
slot). And no frame has been decoded or displayed by the FPGA.

## 11. Rules that cost me time - obey them

- Use `--root h264_decode_core`. **Never** plain `emu` reachability: `decode_stub` masks everything.
- Confirm the checker actually parses your flags before trusting a green (it silently ignored them
  on the baseline).
- `--require` = one module per flag.
- A 2-3 macroblock gate will not find window-boundary bugs. The 1170-MB gate found one immediately.
- Redirect to a file and read `rc` directly; never through a pipe.
- Push twice.
