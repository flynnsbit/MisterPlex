# Product-decoder presence: reachability is not presence

W-GATE, hour 28. Raw numbers first, interpretation second.

## 1. What this document exists to stop

The project's dominant failure mode is *a true number about the wrong thing*.
Defect #19 was its purest form: the shipped RBF contained no decoder at all
while every module testbench passed. The instantiation gate
(`scripts/check_rtl_module_instantiations.py`) closed that hole by proving
*instantiation from the product root*.

Hour 28 measured the next hole in the same family. Instantiation from the
product root is **necessary but not sufficient** for a module to be in the
bitstream. Three further conditions must hold, and none of them were checked:

| # | Condition | Failure if unchecked | Gate |
|---|-----------|----------------------|------|
| 1 | Instantiated from `emu` | module absent from source graph | `RTL_MODULE_INSTANTIATION_OK` |
| 2 | Its source file is compiled by a tracked `.qip` | Quartus never reads the file | `REACHABLE_MODULE_NOT_COMPILED` |
| 3 | Its outputs reach a real consumer | synthesis prunes the whole cone | `DECODE_OUTPUT_SINK` |
| 4 | Capabilities live under the *product* decoder | a retired lineage donates them | `DECODE_CAPABILITY scope=product_decoder_subtree` |

## 2. Measurement: the rewired topology on `w-decode-hour27`

Independently re-derived with the 551-line W-GATE instrument, not the 200-line
variant carried on the decode branch.

### 2.1 Reachable-set delta, by name

```
default_reachable  41 -> 46
gained: h264_cavlc_residual_block, h264_decode_core, h264_decode_top,
        h264_intra16x16_pred, h264_intra4x4_pred
lost:   <none>
default_off_dropouts        15 -> 0
default_off_real_decode_dropouts 14 -> 0
```

Nothing silently left the reachable set. The 14-module MC/MV/DPB/deblock
dropout under `DECODE_REAL_INTRA=1` is genuinely retired.

W-DECODE reported `reachable=49`. That number is real but comes from the older
200-line script, which does not model `DDR_FRAME_STORE` and therefore counts
`ddram_frame_rd`, `frame_store` and `sdram_memtest` — three legacy paths that
are *not* in the checked-in product configuration. Product-default reachable is
**46**, not 49.

### 2.2 Output-sink liveness — the finding

```
DECODE_OUTPUT_SINK decoder=h264_decode_core parent=stream_path status=FAIL
  outputs=13 live=0 dead_end=13 unconnected=0
  terminal_nets=_keep,core_dpb_rd_valid,<none>

decode_stub in the same stream_path: outputs=10 live=10 dead_end=0
```

Every one of `h264_decode_core`'s thirteen connected outputs terminates on

```systemverilog
wire _keep = keep_si | keep_bf | ... | core_dpb_wr_en | |core_dpb_wr_addr | ...;
```

`_keep` has no `(* keep *)` attribute and **zero fanout**. `decode_stub` is
still the only module in the product graph that drives `fs_wr_en`,
`fs_wr_pixel`, `fs_wr_reset` and `fs_swap`.

Interpretation: `h264_decode_core` is structurally the product decoder and
functionally a synthesis keep-alive. Reachability gates go green; the bitstream
gains nothing. This is the same defect class as #19, one level deeper.

Negative control (the analyser is not trivially pessimistic): on the pre-rewire
branch, `decode_stub` scored 10/10 live at `DECODE_REAL_INTRA=0` and
`h264_decode_top` scored 3/3 live at `DECODE_REAL_INTRA=1`.

### 2.3 Capability donation

Capabilities were previously scored against the whole product-reachable set. On
the rewired tree that yields:

```
inter_prediction_mc_subpel   PASS   (scored over all reachable modules)
dpb_reference_management     PASS
```

Scored against the `h264_decode_core` subtree instead:

```
inter_prediction_mc_subpel   FAIL  donated_by_non_product_lineage=
    h264_inter_mc_part, h264_inter_mc_16x16, h264_luma_qpel_block_16x16,
    h264_chroma_epel_block_8x8, h264_luma_ref_tap_addr, h264_ref_clamp
dpb_reference_management     FAIL  donated_by_non_product_lineage=h264_dpb_one_ref
deblocking_writeback         FAIL  donated_by_non_product_lineage=h264_deblock_writeback_ctrl
```

All eight donated modules are reachable **only through the retired
`decode_stub`**. Deleting the stub — which the binding ruling requires — would
have turned two green categories red with no RTL change. The gate now scores
inside the product decoder subtree and names the donor.

## 3. Lineage enumeration (final)

Measured parents on the rewired tree:

```
parents(h264_decode_core)     = {stream_path}
parents(decode_stub)          = {stream_path}
parents(h264_decode_top)      = {h264_decode_core}
parents(h264_decode_skeleton) = {}
parents(h264_dpb_one_ref)     = {decode_stub, h264_decode_skeleton}
```

* **Decode tops instantiated by `stream_path`: two** — `h264_decode_core` and
  `decode_stub`. The rewire added the core; it did not remove the stub.
* `h264_decode_top` is correctly a sub-engine: exactly one parent, the core.
* `h264_decode_skeleton` is **dead code, not a fourth lineage**: zero
  instantiating parents, not product-reachable, and absent from `files.qip`, so
  Quartus never compiles it. It nevertheless instantiates 21 direct children
  including every deblock and CAVLC module, which makes it the single richest
  source of "the module exists, the testbench passes" confusion. It must stay
  bench-only and must never become reachable.
* `h264_dpb_one_ref` has **two** instantiating parents, not four.
  `h264_decode_core` still does not instantiate it. `h264_dpb.sv` defines it;
  `h264_decode_core.sv` mentions it only in comments.
* **`decode_stub` cannot be deleted yet.** It is the only live pixel writer and
  the only product-reachable parent of the MC/DPB/deblock machinery. Deleting it
  today removes motion compensation from the product graph and leaves zero
  frame-store writers. It becomes deletable when `h264_decode_core` both
  instantiates those modules and has live `dpb_wr_*` sinks.

Also measured: `h264_baseline_syntax_parser`, `h264_rbsp_filter` and
`h264_sps_geometry_parser` have **zero instantiating parents anywhere in the
tree**. `bitstream_entropy` is not merely missing from the core; it is missing
from the entire RTL graph. `h264_intra_nb_ctx` (W-OSD) likewise has zero
parents and is in no `.qip`.

## 4. The gates

### 4.1 `DECODE_OUTPUT_SINK`

`scripts/rtl_sink_analysis.py` + `scripts/check_decode_completeness.py`.

Literal comparison: for every instance of the product decoder inside
`stream_path`, each output port connection is resolved to its net(s); a
liveness fixpoint marks a net live if it reaches a parent output port, escapes
into another module instance, or feeds any net that is itself live. Anything
else is `dead_end`.

Does not cover: functional correctness, timing, whether Quartus actually prunes
(only Quartus can say that), or SystemVerilog interfaces/structs.

Can it fail:

```bash
python3 scripts/check_decode_completeness.py --synthetic-complete                        # rc=0, live=4 dead_end=0
python3 scripts/check_decode_completeness.py --synthetic-complete --synthetic-dead-outputs
# rc=1  problems=all_outputs_dead_end,required_output_not_live=dpb_wr_en:dead_end
```

Adversarial cases covered in `tests/unit/test_rtl_sink_and_qip_gate.py`:
multi-hop anti-prune chains, part-select and concatenation connections,
generate-block duplicate instances (a live decoy instance must not vouch for a
dead product instance), and nets escaping into a third module.

### 4.2 `REACHABLE_MODULE_NOT_COMPILED`

Every product-reachable module's source file must appear in some tracked
`.qip`. Measured today: 77 tracked `.qip` source entries, 42 product-reachable
modules, **0 gaps**.

Red proof:

```bash
grep -v "rtl/nalu_scanner.sv" fpga/Plex_MiSTer/files.qip > q && mv q fpga/Plex_MiSTer/files.qip
python3 scripts/check_rtl_module_instantiations.py   # rc=1 REACHABLE_MODULE_NOT_COMPILED nalu_scanner
```

Note that nine tracked RTL files are on disk and in no `.qip`: `cos.sv`,
`h264_decode_skeleton.sv`, `h264_intra_nb_ctx.sv`, `lfsr.v`, `mycore.v`,
`pll/pll_0002.v`, `pll.v`, `tb_arb_beat_conservation.sv`,
`tb_audio_fifo_cdc.sv`. `pll*` are covered by their own `.qip`; the rest are
not product-reachable, so the gate is correctly silent about them today and
will fire the moment one of them is instantiated.

### 4.3 `SKIP_EXIT_CODE_OK`

`scripts/check_skip_exit_codes.py`. A skip that exits 0 is indistinguishable
from a pass to `make`, to `run_with_skip_summary.py`, and to the fleet log.

Raw scan before the fix: **93 shell files, 21 skip paths exiting 0**. Three of
them (`test_h264_baseline_syntax_rtl_sim.sh`,
`test_h264_sps_geometry_rtl_sim.sh`,
`test_stream_path_ddr_ring_integration.sh`) exited 0 with **no opt-in guard at
all** — a missing Verilator produced a silent green. All 21 now exit 77.

After: `exit_zero_sites=9 skip_dominated_exit_zero=0` (the nine remaining are
ordinary successful-completion exits).

Red/green in `tests/unit/test_skip_exit_code_gate.py`; the block-structure scan
is proven not to flag a script's trailing `exit 0` after a real assertion.

## 5. `make unit` harness defect — root-caused

Reported symptom: `make unit` rc=2, `missing derived geometry contract: coded
624x480/display 618x480`, after resource preflight.

Root cause, measured:

```
default_conf_file()      = /home/flynnsbit/.config/misterplex/misterplex.conf
live_pms_missing_reason() = ''
registry_skips("make-unit") = 0 records
```

The pre-fix `run_with_skip_summary.py --self-test` asserted the geometry string
appears in `summarize(registry_skips("make-unit"))`. That registry only emits
the inventory record **when live PMS credentials are missing**. On this host the
credentials are present, so the summary is empty and the assertion fails.

The self-test was therefore environment-coupled in the worst direction: green
exactly when the credentials were absent, i.e. green when it had least to
check. It is not a geometry problem — geometry is correct
(`FRAME_W=640`, `CODED_W=624`, `DISPLAY_W=618`, `(640-618)/2=11`).

Fixed on the W-GATE lineage by forcing the record
(`make_unit_pms_inventory_record("self-test forced inventory record")`).
`w-decode-hour27` still carries the broken version and will fail `make unit`
rc=2 on any host with credentials configured. Verified: `make unit` on this
branch is **rc=0**.

## 6. Known limits of these gates

Stated plainly for W-AUDIT.

* The sink analysis is textual, not elaborated. It does not evaluate parameters,
  does not resolve `generate`-`for` index expressions, and treats any statement
  carrying named port connections as a live sink.
* It is deliberately biased toward reporting `live`. Anything it cannot prove
  dead is called live, so it under-reports rather than producing false reds.
* `_keep`-style nets are not pattern-matched by name. The classification is
  purely "does this net's consumer chain terminate without escaping the module".
  Renaming `_keep` does not evade it; giving `_keep` a real fanout does, and
  that is correct — it would then be real logic.
* `.qip` membership proves Quartus reads the file. It does not prove the module
  survives fitting. `make post-fit-hierarchy` remains the authority for that.
* All of this is source-structural. **A green result here still proves nothing
  about pixels.** No FPGA-decoded frame has ever been displayed.

## 7. Non-product query roots (`--root` / `--require`)

Added after auditing W-DEBLOCK commit `7225e00` on `w-deblock-seam`.

### 7.1 What was claimed

> `h264_decode_core` now instantiates `h264_deblock_writeback_ctrl` … structural
> gate registered in `make unit`:
> `check_rtl_module_instantiations.py --root h264_decode_core --require h264_deblock_writeback_ctrl`

### 7.2 Raw measurements on `origin/w-deblock-seam` (`2c2cb83`)

| Measurement | Value |
|---|---|
| `h264_decode_core.sv:627` instantiates `h264_deblock_writeback_ctrl` | **yes** — the claim is literally true |
| decode roots instantiated in `stream_path.sv` | `decode_stub` **only** (line 289) |
| `DECODE_REAL_INTRA` references in `stream_path.sv` | **0** |
| `h264_decode_core` product-reachable from `emu` | **no** — `instantiating_parents=<none>` |
| `h264_deblock_writeback_ctrl` product-reachable from `emu` | **yes**, via `decode_stub` |
| `default_reachable` before the change | 41 |
| `default_reachable` after the change | 41 |

### 7.3 Adversarial control

The core's writeback instantiation was renamed to a non-existent module in a
scratch worktree. Product reachability was then re-measured:

```
default_reachable=41   REACHABLE_MODULE h264_deblock_writeback_ctrl   rc=0
```

Identical. **Commit `7225e00` is product-neutral by structural measurement.**
The registered gate cannot fail for a product reason, because the capability it
requires was already reachable through `decode_stub` and remains so with the new
instantiation destroyed.

### 7.4 The vacuity

The `w-deblock-seam` variant of the checker skips its bench-only cross-check
whenever `--root != emu` and never asks whether the root is itself in the
product. Measured consequence:

```
--root h264_decode_core     --require h264_deblock_writeback_ctrl  -> rc=0
--root h264_decode_skeleton --require h264_deblock_writeback_ctrl  -> rc=0
```

`h264_decode_skeleton` is confirmed dead code: zero instantiating parents, in no
`.qip`. **A gate that passes identically when rooted at dead code carries no
product evidence.** Its help text nevertheless reads "Require a specific RTL
module to be product-reachable from the product root".

### 7.5 The guard

`--root` / `--require` are now implemented on the canonical checker with the
missing precondition:

* `Scope:` is printed first, always, including `product_root` and `query_root`.
* A `--root` that is not itself product-reachable is a **hard fail**
  (`NON_PRODUCT_ROOT`), naming its instantiating parents.
* `--allow-non-product-root` permits the query but downgrades every result to
  `SUBTREE_ONLY_CLAIM … product_reachable=no`. The string
  `REQUIRED_RTL_MODULE_PRODUCT_REACHABLE` is never emitted for such a root.

Run under the guard, W-DEBLOCK's registered command becomes:

```
Scope: rtl_files=43 rtl_modules=68 product_root=emu query_root=h264_decode_core requires=1
NON_PRODUCT_ROOT h264_decode_core product_reachable=no instantiating_parents=<none>
RTL_MODULE_INSTANTIATION_FAIL: --root h264_decode_core is not reachable from the product root emu
rc=1
```

Red/green in `tests/unit/test_rtl_require_root_guard.py` (7 synthetic cases plus
one end-to-end). Mutation-proved: disabling the `NON_PRODUCT_ROOT` fail makes the
test rc=1 with `a requirement rooted at a non-product module must not pass
silently`.

### 7.6 Three variants of one filename

`check_rtl_module_instantiations.py` currently exists in three divergent forms:

| Branch | Lines | `--root`/`--require` |
|---|---|---|
| `w-decode-hour27` | 200 | no |
| `w-deblock-seam` | 237 | yes, unguarded |
| `w-gate-hour28` | 665 | yes, guarded |

They report different numbers for the same tree. Any quoted figure must name the
branch that produced it. On integration the canonical version must win, or
W-DEBLOCK's registered `make unit` line will either break on unknown arguments
or silently revert to the unguarded semantics.

## 8. Core-subtree standard (parent ruling 2026-07-28)

### 8.1 Ruling re-derived independently at `w-decode-hour27` `ddb7c97`

The parent's core-subtree lists were re-measured module-for-module with the
W-GATE instrument. **All 15 confirmed**, 8 present and 7 absent, exactly as
stated. Aggregate:

| Quantity | Value |
|---|---|
| `emu`-reachable RTL modules | 47 |
| `h264_decode_core` subtree | 15 |
| `decode_stub` subtree | 18 |
| stub-masked (emu-reachable only via the stub) | **9** |

### 8.2 Two additions to the ruling

**(a) The masked list is 8 real modules, not 7.** `h264_deblock_writeback_ctrl`
is also stub-masked at `ddb7c97`:

```
h264_chroma_epel_block_8x8   h264_deblock_writeback_ctrl  h264_dpb_one_ref
h264_inter_mc_16x16          h264_inter_mc_part           h264_luma_qpel_block_16x16
h264_luma_ref_tap_addr       h264_ref_clamp
```

**(b) Core-subtree membership is still not sufficient, for a reason beyond
elaboration blind spots.** At `ddb7c97` the core is instantiated in
`stream_path` but every one of its outputs is dead:

```
h264_decode_core: outputs=13 {'dead_end': 13}
decode_stub:      outputs=10 {'live': 10}
```

All 13 terminate on the zero-fanout `_keep` net. Moving the 8 masked modules
under the core therefore does not by itself produce a frame: the core's
`dpb_wr_en/dpb_wr_addr/dpb_wr_data` must reach the frame store, and today only
`decode_stub` writes pixels. `DECODE_OUTPUT_SINK` in
`scripts/check_decode_completeness.py` is the gate for that.

### 8.3 Per-category truth at `ddb7c97` (denominator = manifest modules)

```
bitstream_entropy           core=0/4  stub_masked=0  absent=4
residual_dequant_transform  core=4/5  stub_masked=0  absent=1
intra_prediction            core=2/4  stub_masked=0  absent=2
inter_prediction_mc_subpel  core=2/8  stub_masked=6  absent=0
mv_prediction               core=2/2  stub_masked=0  absent=0
dpb_reference_management    core=2/3  stub_masked=1  absent=0
deblocking_writeback        core=0/5  stub_masked=1  absent=4
```

12 of 31 capability modules are under the product decoder. Note that
`bitstream_entropy` is 0/4 with all four **absent, not masked** — a larger gap
than MC, and one no amount of stub-unmasking will close.

### 8.4 The gate: `scripts/check_decode_core_subtree.py`

Non-optional, registered in `make unit`. Prints `Scope:` first, classifies every
capability module as `CORE_REACHABLE` / `STUB_MASKED` / `ABSENT`, and ratchets
the stub-masked set against `fpga/Plex_MiSTer/rtl/stub_masked_modules.txt`:

* stub-masked but undeclared → hard fail (new masking);
* declared but no longer stub-masked → hard fail (stale entry must be deleted).

Both directions fail, so the number can only move deliberately and the manifest
diff is the evidence of progress. `--update-baseline` regenerates it.

**Red/green by structural mutation of tracked RTL** (mutate → rc=1 → restore →
rc=0):

| Mutation | Result |
|---|---|
| instantiate `h264_deblock_bs` under `decode_stub` | rc=1 `STUB_MASKED_UNDECLARED h264_deblock_bs` |
| rename `h264_ref_clamp` instantiation in `h264_inter_pred.sv` | rc=1 `STUB_MASKED_STALE h264_ref_clamp` |
| restore both | rc=0 `DECODE_CORE_SUBTREE_OK` |

Repeatable version without RTL edits in `tests/unit/test_decode_core_subtree_gate.py`.

### 8.5 Caveat on ruling point 2

The ruling endorses `--root h264_decode_core --require <module>`. That form is
sound **only where `h264_decode_core` is itself product-reachable**. On
`w-deblock-seam` `2c2cb83` it is not — it has zero instantiating parents — and
the unguarded checker on that branch returns rc=0 for it, and equally rc=0 when
rooted at `h264_decode_skeleton`, which is dead code. The canonical checker now
refuses a non-product `--root` (§7). On `w-decode-hour27` the two agree, because
there the core really is a child of `stream_path`.

## 9. `make unit` geometry contract: branch survey

Corrected measurement. There are **two independent fixes** for the same defect,
so a single marker grep mis-reports it:

* `FIXED(w-gate)` — forces the record via `make_unit_pms_inventory_record`;
* `FIXED(w-deblock)` — clears credential env and points `MISTERPLEX_CONF` at a
  deliberately absent file, driving the real registry.

Survey of 22 remote branches: **8 fixed, 14 broken**. `parent/integ-hour27` is
fixed. Still broken and in active use: `w-decode-hour27`, `w-osd-o5`,
`w-arm-bitstream-feed`, `w-arm-present-gap`, `w-cast-play-init`,
`w-cast-play-state`, `w-e2e-playwright`, `w-deblock`, `w-swap-livelock`.

`w-gate-hour28` now carries **both** paths, so it merges cleanly with
`parent/integ-hour27` and asserts the contract twice. Red-proved by pointing the
second path at the real credentialed conf: rc=1 with
`missing derived geometry contract from registry: coded 624x480/display 618x480`.

## 10. `w-audit` mutations folded in as permanent regressions

`w-audit` (gpt-5.5) attacked the reachability instrument and reported four
defects. **Important scoping fact, measured:** w-audit ran against the
**237-line unguarded variant** of `check_rtl_module_instantiations.py` that
lives on `w-deblock-seam`, and against a *different* `check_qip_coverage.py`
on `parent/integ-hour27`. Three copies of that filename exist with different
behaviour, so a defect report must name its branch. Re-testing each attack
against the ~750-line canonical checker on `w-gate-hour28` gives:

| # | w-audit attack | Status on `w-gate-hour28` before the parent's message | Now |
|---|---|---|---|
| 1 | dead root: `--root h264_decode_core --require X` green while the core does not reach `emu` | **already closed** by `ab08ae3` (`NON_PRODUCT_ROOT` precondition) | closed + regression test |
| 2 | instantiation inside a disabled `if (0)` generate counted as reachable | **genuinely open** | closed by `select_constant_generate_ifs()` |
| 3 | escaped instance name (`\name `) read as *not* instantiated | **genuinely open** | closed by `INSTANCE_NAME` |
| 4 | RTL file tracked in git but absent from `files.qip` | **already closed** by the hour-28 `REACHABLE_MODULE_NOT_COMPILED` check | closed + extended to every `--require`d module at every root |

Two further hardenings arising from the same review:

* **Trunk proof is now mandatory and printed.** Every `--require` invocation
  emits `TRUNK_PROOF <root> path=emu->...->root hops=N via_masking_lineage=...`
  and **hard-fails** when the only product path launders through a masking
  lineage (`decode_stub`). A subtree proof without a trunk proof is vacuous;
  the gate now refuses to issue one silently.
* **`files.qip` parsing tightened.** `tracked_qip_sources()` strips `#`
  comments and requires `set_global_assignment` on the line, so a commented-out
  assignment no longer counts as coverage.

### Red/green table (measured, `w-gate-hour28`)

| Mutation | Expected | Measured |
|---|---|---|
| baseline, all fixes in | `default_reachable=41` | `default_reachable=41` (unperturbed) |
| `if (0)` generate injected in `stream_path.sv` | rc=1 | rc=1 `REQUIRED_RTL_MODULE_UNREACHABLE ... parents=<none>` |
| same, with `select_constant_generate_ifs` disabled (control) | false green | printed `PRODUCT_REACHABLE ... yes` — fix is load-bearing |
| escaped `\w_audit.escaped_inst` injected | reachable | `PRODUCT_REACHABLE ... yes` |
| same, with `INSTANCE_NAME` narrowed (control) | false red | regression suite rc=1 — fix is load-bearing |
| `nalu_scanner.sv` line commented out in `files.qip` | rc=1 | rc=1 `REACHABLE_MODULE_NOT_COMPILED nalu_scanner` |
| `--root mycore --require cos --allow-non-product-root` | rc=1 | rc=1 `REQUIRED_RTL_MODULE_NOT_COMPILED cos` |
| `--root h264_inter_mc_16x16 --require h264_ref_clamp` | rc=1 | rc=1 `TRUNK_PROOF ... via_masking_lineage=decode_stub` |

`tests/unit/test_w_audit_reachability_regressions.py` reproduces all seven
classes on **synthetic** SystemVerilog, so the regressions hold without editing
tracked RTL and survive the topology rewire. Both parser fixes were
mutation-proved by disabling them and observing rc=1.

### Pre-emptive: the defect that later broke the sibling post-fit tool

w-audit's next attack (`docs/w-audit-prefit-elaboration-attack.md`, branch
`w-audit` `a9eac7e`) broke `check_map_hierarchy.py` on `parent/integ-hour27`
because `--forbid-only-under decode_stub` inspects **direct children only**, so
`h264_dpb_i420_addr` -- a grandchild of `h264_dpb_one_ref` under the stub --
went green. That parser is not on this branch, but the identical blind spot is
now a permanent regression here: `case_trunk_nested_under_masking_lineage`
requires a leaf four hops below `decode_stub` and asserts the trunk proof still
reports `via_masking_lineage=decode_stub`. Mutation-proved by narrowing the
lineage test to `trunk[-2]` (the direct parent), which reproduces the sibling
tool's defect exactly:

```
AssertionError: TRUNK_PROOF i420_addr
  path=emu->stream_path->decode_stub->one_ref->mb_write_addr->i420_addr
  hops=5 via_masking_lineage=no
```

The `.qip` case was also converted to drive the shipped helper
`rtl.qip_sources_from_text()` rather than a local re-implementation of it: a
test that re-implements the logic it is guarding keeps passing after the product
regresses, which is this project's signature failure in miniature.

### w-audit's third finding, closed by declaring it undecidable

`scripts/w_audit_gate_hygiene.py` on branch `w-audit` reports three
"synthetic reachability findings". Two of them -- `FALSE_REACHABLE_QIP_OMISSION`
and `FALSE_UNREACHABLE_ESCAPED_INSTANCE` -- are already closed here. **Measured
caveat: that scanner uses its own `candidate_edges()` re-implementation, not
this parser**, so its findings describe w-audit's model, not a measurement of
the shipped gate. Running its three synthetic sources through *this* parser:

| synthetic | this parser's `emu` children | verdict |
|---|---|---|
| qip omission | `qip_missing_child` | reachable, but `REACHABLE_MODULE_NOT_COMPILED` fires -- closed |
| escaped instance | `escaped_child` | reachable -- closed |
| parameter generate | `gen_parent` -> `{disabled_child, live_child}` | **genuinely false-reachable** |

The third is real and stays real: resolving `if (USE_DISABLED)` against
`#(.USE_DISABLED(1'b0))` is parameter propagation, i.e. elaboration. Guessing it
would let the parser invent absence, which is the one error it must never make.
So instead the condition is declared **undecidable**:

* `unresolved_generate_sites()` finds every module whose *entire* set of
  instantiation sites sits inside a generate condition that is neither a literal
  nor a macro;
* the default run always prints `UNDECIDABLE_GENERATE_MODULES count=N ...`, so
  the blind spot is never silent;
* a `--require` naming such a module is a **hard fail**
  (`REQUIRED_RTL_MODULE_UNDECIDABLE`), directing the claim to
  `make post-fit-hierarchy`.

Measured denominator on `w-gate-hour28`: `UNDECIDABLE_GENERATE_MODULES count=0`.
There are three generate-`if` sites in `fpga/Plex_MiSTer/rtl` today
(`ddr_frame_store.sv:144`, `:149`, `stream_path.sv:294`); the first two contain
only `assign` statements and the third is macro-controlled and therefore already
resolved. `default_reachable=41` is unchanged, so the instrument is loud without
perturbing any real measurement -- it exists to catch the *next* parameterised
subtree swap, which is exactly the shape of the retired `DECODE_REAL_INTRA` one.

Red/green: downgrading the hard fail to advisory (`gated = []`) makes
`case_parametric_generate_undecidable` fail. Note the trap that caught me first
time -- asserting only `rc == 1` passed under the mutation, because the synthetic
file is in no `.qip` and *that* check failed it instead. The case now asserts the
undecidability verdict text specifically. `rc == 1` for an unexamined reason is
the same vacuity class this document exists to hunt.

### What this still does not prove

Source-level reachability remains a **pre-filter**. It is not elaboration-aware:
parameter-dependent and non-literal generate conditions are deliberately
resolved *towards* reachable, so the tool under-reports absence rather than
inventing it. `make post-fit-hierarchy` remains the only oracle that reflects
what survived synthesis. Additionally, on `w-gate-hour28` and `ddb7c97` all 13
`h264_decode_core` output ports terminate on a fanout-free `_keep` wire with no
`(* keep *)` attribute, so core-subtree membership does not imply the core
contributes to a pixel.

## 11. Scope discipline: the measured state of the house rule

The house rule is that every gate prints `Scope:` first and that `Scope: 0`
cannot claim a PASS. It was never enforced. Measured on `w-gate-hour28`:

| quantity | value |
|---|---|
| registered `make unit` commands | **100** |
| commands whose source can emit a `Scope:` line | **11** |
| commands that cannot | **89** |
| `Scope:` lines actually printed by a full `make unit` run | 19 |

89 of 100 registered commands can exit 0 without ever stating what they
compared. That is the population `w-audit`'s "24 paths that exit 0 without doing
any work" was drawn from.

Flipping the rule to a hard fail today would red the whole fleet's `make unit`,
and a broken `make unit` blinds every worker -- worse than the disease. So
`scripts/check_scope_discipline.py` is a **two-directional ratchet** over
`tests/unit/scope_discipline_exempt.txt`, the same pattern as
`stub_masked_modules.txt`:

* an unscoped command missing from the manifest -> `SCOPE_DISCIPLINE_UNDECLARED`,
  rc=1. The debt cannot grow.
* a listed command that has since gained a `Scope:` line ->
  `SCOPE_DISCIPLINE_STALE`, rc=1. Progress must be recorded, so the manifest
  diff is the evidence and the number can only move deliberately.

### The three questions

* **What it literally compares.** The set of registered `make unit` commands
  whose *source* contains a `Scope:` emission, against the declared manifest.
* **What it does not cover.** Whether the denominator printed at runtime is
  non-zero, and whether it counts the right thing. Static presence of the line
  is a floor, not a proof -- a gate can print `Scope: 1170` and compare nothing.
  Runtime `Scope: 0` stays the individual gate's own responsibility.
* **Can you make it fail.** Yes, in four ways, all in
  `tests/unit/test_scope_discipline_gate.py`: empty command set (`Scope: 0`
  refused), undeclared unscoped command, stale exemption, and unattributable
  command source.

### One defect found while building it

The first implementation resolved `$(ROOT)/build/test_osd_menu` to the compiled
binary, because `build/test_osd_menu` *is* a file. A compiled object still
contains the string literals of whatever source last built it, so deleting a
`Scope:` line from the `.cpp` would have kept reporting green until the next
rebuild. The `build/` -> `tests/unit/<stem>.cpp` mapping is now tried first and
the binary is never read. `case_binary_maps_to_its_source` locks that in.

## 12. The degraded checker: an exit-0 that survives the ruling

W-FIT-O5 reported that on `parent/integ-hour27` the 200-line variant of
`check_rtl_module_instantiations.py` has no argument parser. Reproduced at
`1ad5706`:

```
$ python3 scripts/check_rtl_module_instantiations.py \
      --root h264_decode_core --require h264_decode_top ; echo $?
RTL_MODULE_INSTANTIATION_OK rtl_modules=68 reachable=44 bench_only=24 root=emu
0
$ python3 scripts/check_rtl_module_instantiations.py --zzz-nonexistent ; echo $?
0
$ python3 scripts/check_rtl_module_instantiations.py --help ; echo $?
0
```

It ignores every flag, answers the plain masked `emu` question, **prints
`root=emu` while you asked for `h264_decode_core`**, and exits 0. The parent's
mandated command line therefore *silently degrades to the exact evidence the
ruling forbids* on any branch carrying that variant.

Nothing shipped on one branch can repair another branch's file, so
`scripts/check_reachability_gate_capability.py` is built to work **against** a
degraded copy. The load-bearing probe is negative and needs no cooperation: a
checker that **exits 0 on an invalid flag cannot be parsing flags**, therefore
cannot be honouring `--root`, whatever it printed. Four probes: unknown-flag
rejection, `--help` advertising `--root`/`--require`/`--allow-non-product-root`,
a bogus `--root` being fatal, and the default run emitting `TRUNK_PROOF` +
`UNDECIDABLE_GENERATE_MODULES` so logs are self-identifying after the fact.

Measured red/green against the real files:

```
canonical (w-gate-hour28)      4/4 probes OK   rc=0
degraded  (parent/integ-hour27) 0/4 probes OK   rc=1
```

**Two defects found in my own probe while building it**, both the same vacuity
class it exists to hunt:

1. The first draft scored the degraded copy's `rejects_unknown_flag` probe as
   **OK**, because that copy exited 1 for an unrelated missing-manifest reason.
   `rc != 0` for an unexamined reason is not evidence. The probe now demands the
   specific signature of a real parser: argparse's rc=2 plus an
   `unrecognized`/`unknown` diagnostic.
2. The first draft ran the foreign checker with **this** worktree as cwd, which
   produced `missing explicit NONDEFAULT_CONFIG_REACHABLE list` -- a phantom
   failure from branch-state manifests. It now runs each checker in its own tree.

## 13. The fit evidence ladder: "ABSENT" is four different facts

The ruling names post-fit hierarchy the strongest oracle. It is, but *absent from
the fit report* conflates four conditions with four different owners and fixes.
Measured on the deployed bitstream `fb4bad849ad2db782a5004ce5a3471ce`
(fit `wfit-hour27-bdiag-b`, source `5b68cc2`), reading reports only -- no Quartus
run, no deploy:

```
FIT_LADDER_SUMMARY not_compiled=3 compiled_only=1 elaborated_only=10 fitted=4

NOT_COMPILED     h264_decode_skeleton, h264_decode_top, h264_intra_nb_ctx
COMPILED_ONLY    h264_decode_core        <- compiled; nothing instantiates it
ELABORATED_ONLY  h264_inter_mc_part, h264_inter_mc_16x16,
                 h264_luma_qpel_block_16x16, h264_chroma_epel_block_8x8,
                 h264_luma_qpel_sample, h264_chroma_epel_sample,
                 h264_luma_ref_tap_addr, h264_ref_clamp,
                 h264_mv_pred_16x16, h264_mv_pred_part
FITTED           decode_stub, h264_dpb_one_ref, h264_dpb_i420_addr,
                 h264_dpb_mb_write_addr
```

Every `ELABORATED_ONLY` module carries its Quartus hierarchy, e.g.

```
emu:emu|stream_path:spath|decode_stub:stub|h264_luma_ref_tap_addr:u_inter_fetch_diag|h264_ref_clamp:u_clamp
```

### Why the rungs matter more than the verdict

* `NOT_COMPILED` is a `files.qip` bug.
* `COMPILED_ONLY` is an instantiation bug -- and it is the *only* rung the
  source-level reachability graph can detect.
* `ELABORATED_ONLY` is a **sink** bug. The module *was* instantiated into a real
  hierarchy and the fitter deleted it as dead logic. Instantiating it somewhere
  else will reproduce the deletion.
* `FITTED` is the only rung that means "in the bitstream".

**Ten MC/MV/interpolation modules were instantiated under `decode_stub` and then
pruned.** That is the `_keep`-wire dead-end finding, confirmed in silicon rather
than inferred. It means relocating those modules under `h264_decode_core` is
necessary and *not* sufficient: without a real consumer for `dpb_wr_*` the fitter
will delete them again, exactly as it just did.

### Cross-check status

This instrument is deliberately **grep-level, not a table parse**. `w-audit` has
broken two entity-table parsers in this repo (unbounded trailing tables;
direct-children-only), and a table parse can only lose rows relative to a raw
scan, so this is independent of that defect class by construction. Run *with*
`make post-fit-hierarchy`, not instead of it; where they disagree, that is the
finding.

Run against W-FIT-O5's 15 named modules it **agrees with all 15**, by a method
that shares no code with theirs. I set out to break their claim and corroborated
it instead. The source-level graph at the fitted commit `5b68cc2` also agrees on
every `COMPILED_ONLY`/`NOT_COMPILED` verdict, and *disagrees* on the ten
`ELABORATED_ONLY` ones -- correctly, because source reachability cannot see
synthesis pruning. That disagreement is the ladder's whole reason to exist.

Red/green, all mutation-proved:

| mutation | result |
|---|---|
| unanchored `Elaborating entity .*<mod>.*` scan | rc=1 -- `mod_ghost` promoted a rung by `mod_ghost_helper`'s line |
| missing reports treated as pass instead of 77 | rc=1 |
| `--require-fitted h264_decode_core` on the real fit | rc=1 `REQUIRED_MODULE_NOT_FITTED ... rung=COMPILED_ONLY` |
| `--require-fitted decode_stub` on the real fit | rc=0 |
