# W-GATE handoff — MiSTerPlex (hour 28)

Supersedes the hour-27 handoff on `w-gate-inst-vacuity`. That document is still
accurate about the instantiation gate, pipe-safety gate, capture-rig guard and
geometry vacuity audit; everything below is what changed.

## 1. Identity

- Worker ID: W-GATE
- Branch: `w-gate-hour28` (branched from `origin/w-gate-inst-vacuity`)
- Worktree: `/home/flynnsbit/Projects/MisterPlex/.worktrees/w-gate-hour28`
- Scratch verify worktree (detached at `origin/w-decode-hour27`):
  `.worktrees/w-gate-hour28-verify` — used only to run W-GATE instruments
  against W-DECODE's tree. Delete when convenient; it holds no committed work.
- Handoff path: `handoffs/misterplex-handoff-w-gate-hour28.md`

## 2. Headline result

**W-DECODE's topology rewire is structurally real and functionally empty.**

`stream_path` now instantiates `h264_decode_core`, and `h264_decode_top` is
correctly a sub-engine beneath it. But every one of the core's thirteen
connected outputs terminates on a dangling, zero-fanout anti-prune net. The
core drives nothing. `decode_stub` is still instantiated by `stream_path` and is
still the only module that writes the frame store.

This is the project's signature defect one level deeper than #19: not "the
module is absent from the bitstream", but "the module is present in the source
graph and will be pruned out of the bitstream, while every reachability gate
reports green".

## 3. RAW MEASUREMENTS (measured, not assumed)

All re-derived with the 551-line W-GATE instrument. **W-DECODE's evidence was
produced by a different, 200-line variant of `check_rtl_module_instantiations.py`
carried on `w-decode-hour27` from parent commit `9f887a6`.** That variant does
not model `DDR_FRAME_STORE`, does not compute default-off dropouts and does not
classify non-default configurations.

### 3.1 Reachable-set delta, by name (task 1)

```
default_reachable                 41 -> 46
gained:  h264_cavlc_residual_block, h264_decode_core, h264_decode_top,
         h264_intra16x16_pred, h264_intra4x4_pred
lost:    <none>
default_off_dropouts              15 -> 0
default_off_real_decode_dropouts  14 -> 0
```

Nothing silently left the reachable set. The 14-module MC/MV/DPB/deblock
dropout is genuinely retired. W-DECODE's `reachable=49` is 46 product-default
modules plus `ddram_frame_rd`, `frame_store`, `sdram_memtest`, which are not in
the checked-in product configuration.

### 3.2 Output-sink liveness

```
DECODE_OUTPUT_SINK config=DECODE_REAL_INTRA=0 decoder=h264_decode_core
  parent=stream_path status=FAIL outputs=13 declared_outputs=13
  live=0 dead_end=13 unconnected=0
  dead_end_ports=rbsp_request_offset,rbsp_request_valid,dpb_wr_en,dpb_wr_addr,
                 dpb_wr_data,dpb_rd_en,dpb_rd_addr,frame_done,frame_mb_count,
                 busy,decode_state,current_mb_addr,error
  terminal_nets=<none>,_keep,core_dpb_rd_valid

decode_stub in the same stream_path: outputs=10 live=10 dead_end=0
```

The terminal net is `stream_path.sv:626`:

```systemverilog
wire _keep = keep_si | keep_bf | ... | core_dpb_wr_en | |core_dpb_wr_addr | ... ;
```

`_keep` has no `(* keep *)` attribute and zero fanout.

Negative control (proves the analyser is not trivially pessimistic): on the
pre-rewire branch, `decode_stub` scored 10/10 live at `DECODE_REAL_INTRA=0`,
`h264_decode_top` 3/3 live at `DECODE_REAL_INTRA=1`.

### 3.3 Capability donation

Old scoping (whole reachable set) vs new scoping (`h264_decode_core` subtree),
same tree, same commit:

| Category | old | new | donated by |
|---|---|---|---|
| inter_prediction_mc_subpel | PASS | FAIL | `decode_stub` (6 modules) |
| dpb_reference_management | PASS | FAIL | `decode_stub` (`h264_dpb_one_ref`) |
| deblocking_writeback | FAIL | FAIL | `decode_stub` (`h264_deblock_writeback_ctrl`) |
| mv_prediction | PASS | PASS | — |
| bitstream_entropy | FAIL | FAIL | nowhere in the tree |
| residual_dequant_transform | FAIL | FAIL | — |
| intra_prediction | FAIL | FAIL | — |

Core subtree size: 14 modules. Product-reachable: 46. Outside the core: 32.

### 3.4 Lineage enumeration (task 3)

```
parents(h264_decode_core)     = {stream_path}
parents(decode_stub)          = {stream_path}
parents(h264_decode_top)      = {h264_decode_core}
parents(h264_decode_skeleton) = {}
parents(h264_dpb_one_ref)     = {decode_stub, h264_decode_skeleton}
```

- **Two** decode tops are instantiated by `stream_path`: `h264_decode_core` and
  `decode_stub`. The rewire added the core; it did not remove the stub.
- `h264_decode_top`: one parent, the core. Sub-engine ruling satisfied.
- `h264_decode_skeleton`: **dead code, not a fourth lineage.** Zero parents, not
  product-reachable, and absent from `files.qip` so Quartus never compiles it.
  It instantiates 21 direct children including every deblock and CAVLC module,
  which makes it the richest source of "module exists / testbench passes"
  confusion in the repository. Keep it bench-only.
- `h264_dpb_one_ref`: **two** parents, not four. `h264_decode_core` still does
  not instantiate it. My predecessor's correction stands after the rewire.
- **`decode_stub` cannot be deleted yet.** It is the only live pixel writer and
  the only product-reachable parent of MC/DPB/deblock. Deleting it now removes
  motion compensation from the product graph and leaves zero frame-store
  writers. Deletable once `h264_decode_core` instantiates those modules **and**
  has live `dpb_wr_*` sinks.

Additional: `h264_baseline_syntax_parser`, `h264_rbsp_filter` and
`h264_sps_geometry_parser` have **zero instantiating parents anywhere**.
`bitstream_entropy` is missing from the entire RTL graph, not just the core.
`h264_intra_nb_ctx` (W-OSD) also has zero parents and is in no `.qip`.

### 3.5 `make unit` harness defect — root-caused (task 4)

Not a geometry problem. Geometry is correct (`FRAME_W=640`, `CODED_W=624`,
`DISPLAY_W=618`, `(640-618)/2 = 11`).

```
default_conf_file()         = /home/flynnsbit/.config/misterplex/misterplex.conf
live_pms_missing_reason()   = ''
registry_skips("make-unit") = 0 records
```

The pre-fix self-test asserted the geometry string appears in
`summarize(registry_skips("make-unit"))`. That registry only emits the record
**when live PMS credentials are missing**. Credentials are present on this host,
so the summary is empty and the assertion fails → rc=1 → `make` rc=2.

The self-test was green exactly when it had least to check. My predecessor
already fixed it on the W-GATE lineage by forcing the record;
**`w-decode-hour27` still carries the broken version** and will fail `make unit`
rc=2 on any host with credentials configured. Anyone merging that branch must
take the W-GATE version of `scripts/run_with_skip_summary.py`.

Verified: `make unit` on `w-gate-hour28` is **rc=0** (no Quartus was active).

### 3.6 Vacuity sweep (task 5)

```
pipe exit safety:   40 files with pipes, 432 pipe sites, 0 unsafe  (unchanged)
skip exit codes:    93 shell files, 21 skip paths exiting 0 -> all now exit 77
                    after: exit_zero_sites=9 skip_dominated_exit_zero=0
qip membership:     77 tracked .qip source entries, 42 reachable modules, 0 gaps
```

Three of the 21 skip sites had **no opt-in guard at all** — a missing Verilator
produced a silent green, not even an `ALLOW_MISSING_VERILATOR=1` acknowledgment:
`test_h264_baseline_syntax_rtl_sim.sh`, `test_h264_sps_geometry_rtl_sim.sh`,
`test_stream_path_ddr_ring_integration.sh`.

## 4. Gates I own

| Gate | Command | State |
|---|---|---|
| RTL instantiation + `.qip` compile membership | `python3 scripts/check_rtl_module_instantiations.py` | green |
| Decode completeness / topology / output sinks | `python3 scripts/check_decode_completeness.py` | **red on purpose** |
| Decode gate unit wrapper | `python3 tests/unit/test_decode_completeness_gate.py` | green |
| Sink + qip unit | `python3 tests/unit/test_rtl_sink_and_qip_gate.py` | green |
| Skip exit codes | `python3 scripts/check_skip_exit_codes.py` | green |
| Skip exit unit | `python3 tests/unit/test_skip_exit_code_gate.py` | green |
| Pipe exit safety | `python3 scripts/check_pipe_exit_safety.py` | green |
| Capture rig guard | `python3 tests/unit/test_capture_rig.py` | green |
| Rollcall | `python3 tests/unit/test_unit_rollcall.py` | green, 94 expected commands |

`check_decode_completeness.py` returning rc=1 on the product tree is the
**correct, honest baseline**. Do not suppress it. Its unit wrapper is green
because it asserts that expected red plus the synthetic red/green pairs.

### Red/green proofs

```bash
# output-sink liveness
python3 scripts/check_decode_completeness.py --synthetic-complete                          # rc=0 live=4 dead_end=0
python3 scripts/check_decode_completeness.py --synthetic-complete --synthetic-dead-outputs # rc=1 all_outputs_dead_end
python3 scripts/check_decode_completeness.py --synthetic-complete --synthetic-drop-category mv_prediction  # rc=1
python3 scripts/check_decode_completeness.py --synthetic-complete --synthetic-bad-topology # rc=1

# qip compile membership
grep -v "rtl/nalu_scanner.sv" fpga/Plex_MiSTer/files.qip > q && mv q fpga/Plex_MiSTer/files.qip
python3 scripts/check_rtl_module_instantiations.py   # rc=1 REACHABLE_MODULE_NOT_COMPILED nalu_scanner
git checkout -- fpga/Plex_MiSTer/files.qip           # rc=0

# skip exit codes: fixture-based, see tests/unit/test_skip_exit_code_gate.py
```

## 5. What other workers must do

**W-DECODE** — the rewire is half done. Required to make `DECODE_OUTPUT_SINK`
green:

1. Route `h264_decode_core`'s `dpb_wr_en / dpb_wr_addr / dpb_wr_data` into the
   frame-store write path that `decode_stub` currently owns
   (`fs_wr_en / fs_wr_pixel / fs_wr_reset / fs_swap`).
2. Delete the `core_*` terms from the `_keep` OR-reduction as they become real
   fanout. `_keep` itself is dead (declared, never used, no `(* keep *)`); it is
   a synthesis-pruning hazard for everything it "protects".
3. Move MC/MV/DPB/deblock instantiation from `decode_stub` into
   `h264_decode_core` — the completeness gate now names exactly which eight
   modules are being donated.
4. Take the W-GATE `scripts/run_with_skip_summary.py` on merge, or `make unit`
   will fail rc=2 on any credentialed host.

**W-CAST** — `h264_baseline_syntax_parser`, `h264_rbsp_filter` and
`h264_sps_geometry_parser` have zero instantiating parents anywhere in the tree.
Parser testbench coverage (1170/1170 MBs) is real and valuable, but the
`bitstream_entropy` category cannot go green until these are instantiated under
`h264_decode_core`.

**W-OSD** — `h264_intra_nb_ctx` has zero parents and is in no `.qip`. When it
lands under the core, add it to `files.qip` or the new
`REACHABLE_MODULE_NOT_COMPILED` check will fire.

**W-DEBLOCK** — `deblocking_writeback` requires all five of `h264_deblock_bs`,
`h264_deblock_thresholds`, `h264_deblock_edge`, `h264_deblock_edge_pipe`,
`h264_deblock_writeback_ctrl` under `h264_decode_core`. Only the last is
currently reachable, and only via `decode_stub`.

**W-AUDIT** — attack surface, stated honestly, in
`docs/test-decode-product-presence-audit.md` §6. The sink analysis is textual,
not elaborated: it does not evaluate parameters, does not resolve
`generate`-`for` index expressions, and treats any statement carrying named port
connections as a live sink. It is deliberately biased toward reporting `live`,
so it under-reports rather than producing false reds. Covered adversarial
shapes: multi-hop anti-prune chains, part-select and concatenation connections,
generate-block duplicate instances (a live decoy must not vouch for a dead
product instance), nets escaping into a third module. **If you break it, that is
the correct outcome.**

## 6. Things I believe are wrong / open risks

1. The whole `_keep` idiom in `stream_path.sv` is load-bearing for nothing.
   `_keep` is declared and never used, so Quartus is free to prune everything it
   references, including `keep_si`/`keep_bf`'s intent. This deserves a separate
   look by whoever owns `stream_path`.
2. `REQUIRED_LIVE_OUTPUT_PORTS` is hard-coded to `dpb_wr_en/addr/data`. If the
   product decoder's pixel egress is renamed, update it deliberately and prove
   red/green — do not let the rename silently empty the requirement.
3. The instantiation gate parses source; `.qip` membership proves Quartus reads
   the file; neither proves post-fit survival. `make post-fit-hierarchy` remains
   the authority and only W-FIT can run it.
4. `.worktrees/w-gate-hour28-verify` contains uncommitted instrument copies used
   for cross-branch measurement. It is a scratch tree, not evidence.
5. All of this remains source-structural. **A green result here still proves
   nothing about pixels.** No FPGA-decoded frame has ever been displayed.

## 7. Discipline notes carried forward

- Every gate prints `Scope:` first; `Scope: 0` cannot claim a PASS.
- Skips exit 77, never 0. Now statically enforced.
- Never read an exit code through a pipe. Now statically enforced.
- Register new unit commands in `tests/unit/test_unit_rollcall.py`.
- Do not override the resource preflight refusal when Quartus is active. No
  Quartus was running for this session's `make unit`; it completed rc=0.
