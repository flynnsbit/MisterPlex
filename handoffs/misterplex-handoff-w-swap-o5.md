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

## 10b. Answering w-fit-o5: files.qip coverage, and two blind spots I had

w-fit-o5 measured, with the sole Quartus token, that on `parent/integ-hour27` (the source of the
deployed `fb4bad84`) two product files were tracked in git and **never handed to Quartus**, and that
post-fit hierarchy confirms they are absent from the bitstream. They also measured that the trunk is
orphaned on both `parent/integ-hour27` and `w-deblock-seam`, and told me not to base MC on either.

**Measured on my branch, using their instrument, unmodified** (extracted with `git cat-file -p
ee2ed89:scripts/check_qip_coverage.py`), rc=0:

```
Scope: 36 files in fpga/Plex_MiSTer/files.qip; 39 .sv tracked under rtl/
product RTL: 37  (testbenches excluded: 2)
tracked but NOT compiled: 2 / 37
  ALLOWED_ABSENT cos.sv                    -- unused helper
  ALLOWED_ABSENT h264_decode_skeleton.sv   -- retired lineage
QIP_COVERAGE_OK product=37 compiled=35
```

So my branch is clean on their criterion. Base check: my merge-base with `w-decode-hour27` is
`ddb7c97`, i.e. I am on the lineage they call the only viable one, and I already carry the fixed file
list (37 qip entries). I am **not** based on `w-deblock-seam` or `parent/integ-hour27`.

Their finding did expose a genuine hole in my gate, now closed. Two blind spots, both measured:

1. **A named-module list cannot catch a module you do not own.** My gate required 9 modules; had
   the intra sub-engine dropped out, it would still have gone green. Fixed by `source_closure()`:
   the gate now reads every module `h264_decode_core` instantiates transitively from RTL source
   (`CORE_CLOSURE_COMPLETE modules=20`) and requires all of them.
2. **Elaboration cannot see a files.qip gap at all.** I assumed it could and was wrong twice over.
   First, `-I<dir>` makes Verilator auto-find a module by searching for `<module>.sv`; I replaced
   the `-I` flags with `+incdir+` (include-only). It still did not catch it, because Verilator also
   treats the directory of **every file it has already read** as a module-search fallback - so once
   any `rtl/` file is in the list, every other module in `rtl/` is found by filename anyway. The
   gate now reports this explicitly: `red-check E ... elaboration alone still reported everything
   present (elab_blind=True)`. The files.qip check therefore has to be textual and separate, which
   is exactly the design w-fit-o5 chose.

   Corollary worth carrying: **red-check C passes by naming coincidence, not by strength.** Dropping
   the DPB file works only because no module in it is named after the file. Do not generalise from
   it; check E is the load-bearing one.

Five red proofs now ship with the green (`handoffs/evidence-w-swap-o5/trunk_elab.log`, rc=0):
cut instantiation, disabled `if(0)` generate, files.qip removal, escaped identifier (must NOT flip),
core closure vs files.qip. `make unit` rc=0.

**Capacity, per w-fit-o5's fit report for `fb4bad84`: M10K 453/553 = 82%, of which `decode_stub`
alone holds 256 M10K (46% of the device) and 33 DSP.** My MC block buffers
(`p16_luma_ref[0:440]`, `p16_chroma_u_ref[0:80]`, `p16_chroma_v_ref[0:80]`) plus the combinational
full-window predictor are **unmeasured for area** and may well not fit until the stub is retired.
Treat `decode_stub` retirement (w-decode-o5) as **on the critical path for MC**, not parallel to it.
I have not run Quartus and will not.

**Still-honest limits.** Elaboration is stronger than regex but is still not the fitted design.
`make post-fit-hierarchy` remains the only real oracle and I have not run Quartus (sole exclusive
slot). And no frame has been decoded or displayed by the FPGA.

## 10c. Capacity: my modules are NOT the M10K tenant. The risk is ALM and timing.

The parent's ruling 2 frees 46% of the device by retiring `decode_stub` and names my seven modules
as "the intended tenant". **Measured, I do not need it, and I should not be allocated it.**

Storage actually declared by the MC path:

| array | site | bits |
|---|---|---|
| `p16_luma_ref [0:440]` x 8b | `h264_decode_core.sv:315` | 3,528 |
| `p16_chroma_u_ref [0:80]` x 8b | `h264_decode_core.sv:316` | 648 |
| `p16_chroma_v_ref [0:80]` x 8b | `h264_decode_core.sv:317` | 648 |
| **total** | | **4,824 bits** |

`h264_dpb.sv` declares no storage at all beyond three `wire` arrays (`full_y[0:255]`, `full_u[0:63]`,
`full_v[0:63]`, `:561-563`) which are combinational nets, not memory. The reference frame lives in
external DDR; `h264_dpb_one_ref` is an address generator plus a read port, not a frame store.

Further, the whole 441-entry luma window is read **combinationally and in full** (it is passed as a
port, `h264_decode_core.sv:563-565`). A 441-wide simultaneous read cannot be an M10K; it must
synthesise to registers. So **my MC path costs roughly 4.8 Kbit of flip-flops and zero M10K.**

**The real risk is somewhere nobody has been looking.** Measured: `h264_luma_qpel_block_16x16`,
`h264_chroma_epel_block_8x8`, `h264_inter_mc_16x16` and `h264_inter_mc_part` contain **zero clocked
processes** - grep for `always_ff|always @(posedge` across all four returns 0. They are one
combinational cloud producing **256 luma + 128 chroma samples per macroblock in a single delta**.
Each luma qpel sample is a 6-tap FIR, and the diagonal half-pel phases need a vertical 6-tap on top
of a horizontal one. That is on the order of ten thousand adders of combinational logic with no
pipeline stage anywhere in it.

**Consequences a successor must not discover the hard way:**

- Freeing M10K does **not** make room for this block. The constraint I will hit is **ALM count and
  combinational depth / Fmax**, and neither has ever been measured because no fit has included these
  modules (post-fit hierarchy for `fb4bad84` confirms all seven were ABSENT).
- The full-frame gate proves **functional** correctness (1170/1170 MBs exact) at zero cycles of
  latency per sample. It says nothing about timing closure. A green there is not evidence the block
  can be clocked.
- The likely fix is to **time-multiplex**: compute N samples per cycle instead of 384, trading
  latency for area. At 1170 MBs x 384 samples = 449,280 samples/frame, even 4 samples/cycle is
  ~112k cycles/frame, comfortably inside a frame period. **This is the first thing to change if the
  fit reports an ALM or Fmax failure - do not start by shrinking buffers, they are not the problem.**

I have not run Quartus and will not; these are analytic figures from the RTL, stated as such.

## 10d. WITHDRAWAL, and the third failure mode detected at source

**I withdraw the implication that my reachability and elaboration greens mean the MC path is in the
product design. They do not.** w-fit-o5 measured with Quartus Analysis & Synthesis on
`w-decode-hour27` `2f165ed` that `h264_decode_core` is instantiated unconditionally, compiled,
elaborated - and then **deleted, because it contributes zero resources**. Every gate I built reports
GREEN on that design, correctly, because the instantiation genuinely is there. **Source and
elaboration graphs are structurally incapable of seeing this.** My §10a/§10b greens remain true as
far as they go, and they go less far than I implied.

Failure modes now enumerated: (1) not compiled - absent from `files.qip`; (2) not instantiated -
orphaned; (3) **instantiated, compiled, elaborated, then optimized away as dead logic.**

**Measured: mode 3 is present on this branch too.** `stream_path.sv:608-621`:

```
wire _keep = keep_si | ... | core_dpb_wr_en | |core_dpb_wr_addr | |core_dpb_wr_data |
             core_dpb_rd_en | ... | core_frame_done | ... | core_error;

endmodule
```

`_keep` ORs 47 signals, 15 of them the decode core's outputs, and **`_keep` is never read** -
`endmodule` follows immediately. Synthesis deletes the wire, then everything feeding it, then the
instance. So this branch would also have fitted a decoder-less bitstream. The MC work is sound and
is not in silicon.

**The claim that mode 3 is undetectable at source level is measurably false.** The parent ruled
"No source-level tool can ever detect mode 3 ... They are blind by construction." That is true of
the three tools we had - reachability, files.qip, RTL reading - but it is not a property of source
analysis. Two independent source-level signals reproduce the Quartus verdict in about a second:

```
NO_PATH_TO_PORT h264_decode_core outputs influence none of stream_path's 66 output
                ports, so synthesis has no reason to keep the instance: predict
                ELABORATED_BUT_OPTIMIZED_AWAY
CORE_OUTPUT_NETS 13 traced from 13 declared output ports
DEAD_END_AGGREGATOR _keep: ORs 47 signals and is never read
```

Synthesis keeps logic only where it observably affects an output. That is a **dataflow** property,
and dataflow is visible in source. What was missing was a tool that asked the question, not the
ability to ask it. Quartus A&S remains the oracle and the arbiter; this is a ~1s pre-filter that
makes iteration cheap, and its value is precisely that it is 250x faster than the 4m23s oracle.

Getting it conservative took two corrections, both worth carrying:

- Adding graph edges between all connections of one instance over-approximates so badly that every
  core output appeared to reach **30** of `stream_path`'s ports on a design Quartus had already
  deleted. Removed: only real continuous assignments create edges.
- Tracing from *all* port connections rather than only the core's **outputs** counted paths that
  exist with or without the instance, giving 7 false reached ports. Now the sources are the 13 nets
  driven by the core's 13 declared output ports, and the answer is 0.

**A predictor of deletion must never emit a false "alive".** It may emit false alarms - a submodule
that genuinely forwards a signal - and those cost one Quartus A&S run to clear. That asymmetry is
deliberate.

**`scripts/check_output_sink_liveness.py`** (new) detects this shape at source level in under a
second instead of four minutes of Quartus, and names the signals. It ships with `--self-test` (rc=0, four cases) that
red-proves the dead-end detector and the no-path detector on fixtures with those defects, and
green-proves both on fixtures without them - a detector that never fires would otherwise look like a clean repo. Against real source it
returns **rc=1**, matching Quartus:

```
DEAD_END_AGGREGATOR _keep: ORs 47 signals and is never read ...
  product signals lost: core_busy, core_current_mb_addr, core_decode_state, core_dpb_rd_addr,
  core_dpb_rd_en, core_dpb_wr_addr, core_dpb_wr_data, core_dpb_wr_en, core_error,
  core_frame_done, core_frame_mb_count, core_luma4x4_valid, core_luma_feed_active,
  core_rbsp_request_offset, core_rbsp_request_valid
SINK_LIVENESS_FAIL aggregators=1 product=h264_decode_core parent=stream_path
```

**It is deliberately NOT registered in `make unit`,** because it currently fails on real source and
registering it would either break the fleet's green or tempt someone to allowlist the defect - which
is how this project has manufactured false greens four times. Register it the moment the defect is
fixed; it is cheap and it closes mode 3 permanently.

**A second finding that is specifically MC's problem, and is not fixed by consuming outputs.** The
same run reports 23 input ports of the core tied to literals at `stream_path.sv:484`:

```
CONSTANT_TIED_INPUTS h264_decode_core: 23 input ports wired to literals:
  cbp_chroma, cbp_luma, chroma_pred_mode, dpb_rd_data, dpb_ref_base, dpb_write_base,
  mb_residual_bit_offset, mv_x_qpel, mv_y_qpel, mvd_x_qpel, mvd_y_qpel, p16_mb_is_ref,
  p16_mb_x, p16_mb_y, p16_zero_mv_valid, part_idx, pps_chroma_qp_index_offset,
  rbsp_window_base, recon_mb_is_ref, recon_mb_valid, recon_mb_x, recon_mb_y, ref_idx_l0
```

Three of those are fatal to motion compensation specifically: **`dpb_rd_data(8'd0)`** makes every
reference sample a constant zero, and **`mv_x_qpel(16'sd0)` / `mv_y_qpel(16'sd0)`** make every motion
vector zero. Even after the core's outputs are consumed and the instance survives, the entire qpel
FIR constant-folds to zero and MC is optimized away a second time. **Consuming outputs is necessary
but not sufficient for MC.** Whoever lands the parser seam must drive `dpb_rd_data` from real DPB
reads and the MVs from parsed syntax, or MC will keep vanishing while every gate stays green.

## 10e. MC survives *inside* the core - measured, and red-proved by mutation

The core being deleted is w-decode-o5's to fix. The question that is mine is what happens *after*
they fix it: when the core survives, does motion compensation survive with it, or does it collapse
separately? Reachability cannot answer this and neither can the full-frame correctness proof - a
predictor whose samples are computed and then dropped passes both and occupies no logic.

Measured, `gate=path-to-port`, rc=0:

```
OUTPUTS_REACH_PORTS h264_inter_mc_part -> h264_decode_core: dpb_wr_data
```

Structurally: `p16_pred_y -> p16_pred_sample -> p16_pred_term -> p16_recon_sum ->
dpb_ref_filtered_sample -> dpb_wr_data`. The predicted sample is added to the residual, clipped, and
written to the reference store through a real output port. **MC is not separately dead logic.**

Registered as `tests/unit/test_h264_mc_output_reaches_core_port.py`, in `make unit` (rc=0), with a
control and two mutations, because a green with no red proves nothing:

| proof | result |
|---|---|
| green on real source, and specifically via `dpb_wr_data` | rc=0 |
| control: unmutated copy in the staging dir | rc=0 - the copy is not the variable |
| red A: the six MC output connections rewired to nets nobody reads | rc=1 `NO_PATH_TO_PORT` |
| red B: `assign dpb_wr_data = 8'd0` | rc=1 |
| checker `--self-test` | rc=0, six cases |
| unrecognised flag | rc=2, not a silent green |

The control matters. Without it a red could be caused by staging the files rather than by the
mutation, which is the vacuity class w-fit-o5 found in the SDC exoneration: four slots agreeing on an
identical input demonstrate determinism, not neutrality. **A comparison must vary the thing it claims
to test.**

### Two false-alive bugs found by red-proving my own detector

The first run reported MC reaching **two** ports, `dpb_wr_data` and `dpb_rd_addr`. The second was
fabricated, and tracing the chain showed why:

```
dpb_rd_addr <- p16_win_rd_addr <- p16_rd_offset <- p16_chroma_plane_sz <- FRAME_W <- dpb_wr_data
```

`parameter int FRAME_W = 320,` is a parameter declaration, and the right-hand side was allowed to run
to the next semicolon, swallowing the entire port list. Two guards followed:

- parameter, localparam and port declarations create no dataflow edges - a parameter is an
  elaboration-time constant and cannot carry runtime data;
- a right-hand side is truncated at the first top-level comma, so the second declarator in
  `wire a = x, b = y;` no longer appears to drive the first.

Each guard has its own self-test case, and **each case was mutation-proved**: disabling the parameter
guard gives `SELF_TEST_FAIL: a parameter declaration invented a path to dout`, disabling the comma
guard gives `SELF_TEST_FAIL: a second declarator on the same line invented a path to dout`. The first
version of the parameter case passed with the guard removed - it was **vacuous**, saved by the other
guard - and was rewritten until it flipped. A self-test that cannot fail is not a self-test.

This is the third and fourth false-alive I have removed from this tool. The pattern is consistent:
every over-approximation in a deletion predictor shows up as a confident, specific, wrong "alive".

### A second dead-end aggregator, inside the core

Running the detector with the core as parent found one the deployed-design analysis had reported only
as a Quartus warning:

```
DEAD_END_AGGREGATOR _keep_decode_core_inputs: ORs 51 signals and is never read
```

That is `Warning (10036)` at `h264_decode_core.sv:997` reproduced from source, by a tool that was
never told the warning existed. There are therefore **two** keep-alives in the lineage that keep
nothing: one in `stream_path` for the core's outputs, one in the core for its own inputs. Both must
go, and neither is mine to remove.

### Scope limits, declared up front

- It is a **predictor**, not the oracle. Quartus A&S arbitrates. Green here is necessary, not sufficient.
- It is built so it cannot report a false alive, so it can report a false alarm - for example where a
  submodule genuinely forwards a signal through a path this tracer does not model. A false alarm costs
  one 4-minute A&S run; a false alive costs a six-hour fit and a decoder-less bitstream.
- `--gate path-to-port` narrows the verdict to the survival question. It is **not** an allowlist: the
  dead-end aggregators are still printed, `UNGATED_DEAD_ENDS` says explicitly that they were not
  gated, and the default `--gate all` still fails on them.
- The wider detector still exits **1** on the real source and is still **not** registered in
  `make unit`. Registering a failing gate is how a fleet acquires an allowlist.

## 10f. Cross-branch measurement: w-cast-o5 fixes mode 3 and loses MC

`origin/w-cast-o5` `8cd5eed` is the first branch in the fleet where the core is not dead logic.
Measured with my instrument against their tree:

```
OUTPUTS_REACH_PORTS h264_decode_core -> stream_path: 33 ports
  luma4x4_valid, luma4x4_idx, luma4x4_qp, luma4x4_coeff_zigzag, i4_modes,
  mb_syntax_* (22 of them), luma4x4_source_busy/done/ok/bit_end, ...
```

Thirty-three of `stream_path`'s output ports now depend on the core. **That is the mode-3 fix**, and it
is real. Two things do not follow from it.

**1. MC is not in their core at all.** Their core instantiates the *per-sample* predictor lineage:

```
h264_luma_qpel_sample u_product_p16_luma_pred
h264_chroma_epel_sample u_product_p16_chroma_pred
```

`h264_inter_mc_part` appears only in two comments. `h264_dpb_one_ref`, `h264_inter_mc_16x16`,
`h264_luma_qpel_block_16x16` and `h264_chroma_epel_block_8x8` are absent. My MC commit `4f4312b` is
**not an ancestor** of their branch, and neither branch is an ancestor of the other. **Converging onto
their core as-is deletes the block MC landing and reinstates the per-sample tap path at 21248 reads
per macroblock instead of 603.** A merge must take my core changes, not just resolve conflicts.

**2. Twenty-three constant-tied inputs remain, including all the MC-critical ones.** `dpb_rd_data`,
`dpb_rd_valid`, `mv_x_qpel`, `mv_y_qpel`, `p16_mb_x`, `p16_mb_y`, `p16_zero_mv_valid`, `ref_idx_l0`,
`recon_mb_valid`. The core now survives; the *inter* path inside it still constant-folds. This is the
"necessary but not sufficient" case, now measured on the branch that fixed the necessary half.

### The false alarm this exposed in my own tool, and the fix

My first run on their tree said MC reached nothing, and the reason was **my bug, not their design**:

```
p16_wr_data_r <= clip_u8(p16_recon_sum);      // procedural, non-blocking
```

The tracer followed only *continuous* assignments, so every path through a register read as dead -
which is most real RTL. Procedural assignments are now traced, with the left-hand side required to
start the line so that `if (a <= b)` cannot be mistaken for an assignment to `a`. Self-test case
added and mutation-proved: disabling procedural edges gives
`SELF_TEST_FAIL: missed a path that goes through a register`.

This is the failure direction I said the tool was allowed to have - a false alarm, never a false
alive - and it cost one cross-branch measurement to find. **Seven self-test cases now, every one
mutation-proved.** The conclusion above was re-measured after the fix and is unchanged.

## 10g. MC sizing harness, and why the convergence merge was aborted

### The merge I tried and stopped

w-fit-o5's capacity numbers cannot be applied to my modules until the core survives synthesis, and
the only branch where it does is `w-cast-o5`. So I attempted the convergence merge in a scratch
branch. **I aborted it, deliberately**, and the reason is a design fork, not a textual conflict:

```
mine   ST_P16_REF_SEED = 8'd2   ST_P16_WIN_FETCH = 8'd3     block window fetch, 603 reads/MB
theirs ST_P16_TAP_REQ  = 8'd2   ST_P16_TAP_WAIT  = 8'd3     per-sample taps, 21248 reads/MB
```

Both encode state 2 and 3 differently for two different MC designs. The merge left two dangling
`ST_P16_TAP_REQ` references that will not compile. Seventeen files conflict; the RTL ones are mostly
additive and resolvable as take-both, but **seven test harnesses diverge on variable naming**
(`$RTL_DECODE_CORE` vs `$RTL_CORE`, `$RTL_SYNTAX` added, `$RTL_DECODE_TOP`/`$RTL_NB_CTX` removed) and
their conflicts are whole-line file lists where take-both produces two `for` loops.

Resolving the FSM fork is a **design decision across two workers**, not a merge decision, and doing it
unilaterally would produce a plausible core that nobody had reviewed. Recorded resolutions for whoever
does it, all measured:

| file | resolution |
|---|---|
| `h264_decode_core.sv` | take both on all five hunks, then `ST_P16_TAP_REQ` -> `ST_P16_REF_SEED` at both sites |
| `stream_path.sv` | header comment theirs, `_keep` list both |
| `nalu_scanner.sv` | theirs - widens capture 96 -> 128 bytes, matches their `MAX_BYTES` |
| `h264_cavlc_residual.sv` | theirs - their `RBSP_IDX_W` is my `BYTE_IDX_W` formula plus a fault hook |
| `bench_only_modules.txt` | theirs - they instantiate `h264_cavlc_nc_predictor` in core |
| `check_rtl_module_instantiations.py` | theirs, a superset; my `--root`/`--require` spelling is unchanged |
| `Makefile` | both |
| `test_companion_eof.cpp` | either - we independently made the same order-independence fix |
| seven `test_*stream_path*.sh` | union of the file lists, by hand; the merged design has both lineages |

### The harness, so MC can be priced without waiting for the merge

w-fit-o5's constraint is exact: my modules cannot be measured while their outputs dangle, because
Quartus collapses them to zero. So I built a top whose only purpose is to make them un-collapsible.

`fpga/Plex_MiSTer/sizing/mc_sizing_top.sv` + `mc_sizing.qip`. Deliberately **outside** `rtl/` so it is
not swept into `files.qip` coverage or product reachability - it is not product RTL and must never be
reachable from `emu`. Verified: `check_qip_coverage` rc=0, trunk rc=0, bench file lists rc=0 with it
present.

- every input comes from a 64-bit shift register fed by a real pin, so **`constant_tied_inputs=0`**;
- every output of both instances is XOR-reduced into one registered output pin;
- measured with my own detector: `OUTPUTS_REACH_PORTS h264_inter_mc_part -> mc_sizing_top: serial_out`
  and the same for `h264_dpb_one_ref`, both rc=0;
- Verilator lint rc=0, zero warnings.

Covers five of seven: `h264_inter_mc_part` pulls in `h264_inter_mc_16x16`,
`h264_luma_qpel_block_16x16`, `h264_chroma_epel_block_8x8`; plus `h264_dpb_one_ref`.
`h264_luma_ref_tap_addr` and `h264_ref_clamp` are the retired per-sample lineage.

**Ask for w-fit-o5:** run Analysis & Synthesis on `mc_sizing_top` and report ALM, register, DSP and
M10K. It is not a fit and does not consume the token. My analytic prediction, to be graded against it:
storage **4,824 bits in flip-flops, zero M10K**, because the 441-entry window is read combinationally
in full; the cost lands in **ALMs and DSP**, because all four block modules have zero clocked
processes and emit 384 samples per macroblock in one combinational delta. **If the M10K figure comes
back non-zero my model is wrong and I want to know.**

### Honest reading of whatever number comes back

It prices the windows and the interpolation, and nothing that drives them. It is a floor. It also does
not prove the design closes timing at the product clock - a purely combinational 384-sample delta is
an Fmax risk before it is an area risk, and the remedy if it fails is to time-multiplex the sample
loop, not to shrink the buffers.

## 11. Rules that cost me time - obey them

- Use `--root h264_decode_core`. **Never** plain `emu` reachability: `decode_stub` masks everything.
- Confirm the checker actually parses your flags before trusting a green (it silently ignored them
  on the baseline).
- `--require` = one module per flag.
- A 2-3 macroblock gate will not find window-boundary bugs. The 1170-MB gate found one immediately.
- Redirect to a file and read `rc` directly; never through a pipe.
- Push twice.
