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
