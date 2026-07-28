# Retiring `decode_stub`

**Status: BLOCKED — contained, not retired.**
Branch `w-decode-o5`, commits `e9d5fab` / `272b0db`. All numbers below are
measured on that branch, not inherited.

## 1. What `decode_stub` is

`fpga/Plex_MiSTer/rtl/decode_stub.sv` (812 lines) is the Phase 3.3b diagnostic
frame-store painter. It is *not* the intended decoder. It is, however, still the
only thing in `stream_path` that writes pixels:

```
stream_path.sv:595-598
    .wr_en(fs_wr_en), .wr_pixel(fs_wr_pixel),
    .wr_reset_ptr(fs_wr_reset), .swap_req(fs_swap)
```

Measured driver of the frame-store write port
(`scripts/check_decode_core_seam.py`):

```
DECODE_CORE_SEAM_OK core_inputs=53 constant_inputs=30 core_outputs=13 \
    unobserved_outputs=13 presentation_driver=decode_stub
DECODE_CORE_SEAM_NOTE product pixels are NOT produced by h264_decode_core; \
    frame-store writes come from decode_stub
```

## 2. Why it could not simply be deleted

### Blocker A — it is the sole source of picture

`h264_decode_core` is instantiated by `stream_path` as `product_decode_core`,
but **instantiation is not connection**. Measured on `w-decode-o5`:

* **30 of 53** core inputs are tied to constants
  (`rbsp_byte`→0, `recon_y`→0, `recon_u/v`→128, all `p16_residual_*`→0,
  `recon_mb_valid`→0, `p16_zero_mv_valid`→0, `dpb_rd_data`→0, all MVs→0, …).
* **13 of 13** core outputs terminate in `stream_path`'s `_keep` anti-prune wire
  and have no product consumer. `dpb_wr_en/addr/data` go nowhere: the core has
  no memory behind its DPB port.

So the core cannot decode, and nothing it produces is observable. Deleting the
stub today removes the picture and puts nothing in its place. The full port-level
inventory with per-port reasons and owners is
`fpga/Plex_MiSTer/rtl/decode_core_seam_debt.txt`.

### Blocker B — seven real modules hang off it

Measured with `scripts/check_rtl_module_instantiations.py`:

| root | reachable | product_reachable |
|---|---|---|
| `emu` | 50 | **42** |

The eight-module gap is `decode_stub` itself plus seven genuine
motion-compensation / DPB modules whose *only* parent chain runs through the
diagnostic painter:

```
h264_inter_mc_16x16      h264_inter_mc_part        h264_dpb_one_ref
h264_luma_qpel_block_16x16  h264_chroma_epel_block_8x8
h264_luma_ref_tap_addr   h264_ref_clamp
```

Deleting `decode_stub` before those land under `h264_decode_core` would make
them unreachable and force them into `bench_only_modules.txt` — i.e. it would
convert a false green into a real regression. **W-SWAP owns moving them**
(`w-swap-mc` `910c456` instantiates `h264_inter_mc_part u_product_p16_mc` inside
`h264_decode_core`; that branch still has to be reconciled with the intra
sub-engine rework in `cd9fe29`).

### Blocker C — the full-frame testbench probes stub internals

`tests/rtl/stream_path_full_frame_tb_top.sv` reads ~20 internal stub signals
through `dut.gen_diagnostic_present.stub.*` (QP, residual TC/DC, coefficients,
IDCT stages, recon pixels, inter capture, DPB write address, and it *prefills*
`stub.dpb_mem`). Those probes must move to `h264_decode_core` before the stub
can be removed. This test is a `make unit` prerequisite; commit `272b0db` had to
repair its hierarchy path after `cd9fe29` renamed the generate block.

Note that test's own honest scope line:

```
INTEGRATED_PIPELINE_COVERAGE: 16/76800 = 0.021% (decode_stub single 4x4 block)
```

## 3. What was done instead: structural containment

Since it cannot be retired yet, `decode_stub` was made **structurally incapable
of satisfying a product reachability proof**.

`fpga/Plex_MiSTer/rtl/diagnostic_only_modules.txt` declares it as a diagnostic
root. `scripts/check_rtl_module_instantiations.py` now prunes every diagnostic
subtree *before* computing product reachability, and answers `--require` from
the pruned graph only:

```
$ python3 scripts/check_rtl_module_instantiations.py --require h264_inter_mc_16x16
REQUIRED_RTL_MODULE_UNREACHABLE h264_inter_mc_16x16 file=.../h264_dpb.sv \
    parents=h264_inter_mc_part reachable_only_via_diagnostic_root=1
RTL_MODULE_INSTANTIATION_FAIL: required RTL modules are not product-reachable \
    from emu (diagnostic subtrees pruned: decode_stub)      # rc=1
```

The `[debt]` list must match the measured stub-only set **exactly**, so:

* a new module placed under the stub fails with `UNDECLARED_DIAGNOSTIC_ONLY_MODULE`;
* a module that has since moved under `h264_decode_core` fails with
  `STALE_DIAGNOSTIC_DEBT_ENTRY` until the line is deleted.

The same exact-match discipline applies to the seam manifest, so vacuity can
only shrink and every reduction is recorded in the diff.

## 4. Retirement order

1. **W-SWAP** lands `h264_inter_mc_part` (and its seven-module subtree) under
   `h264_decode_core`; delete those lines from `[debt]`.
2. **W-CAST** feeds the core a real RBSP window and real macroblock syntax
   (`cbp_luma`, `cbp_chroma`, `chroma_pred_mode`, `mb_residual_bit_offset`);
   delete those lines from `[constant_inputs]`.
3. **W-DECODE** drives the recon handoff (`recon_mb_valid` + `recon_y/u/v`) and
   attaches real memory to the core's DPB port; delete those lines.
4. **W-DECODE** moves `fs_wr_en/fs_wr_pixel/fs_wr_reset/fs_swap` onto the core
   and flips `[presentation_driver]` to `h264_decode_core`.
5. Move the full-frame testbench probes off `gen_diagnostic_present.stub.*`.
6. Only then `git mv` `decode_stub.sv` out of `files.qip` and the RTL tree, and
   delete `diagnostic_only_modules.txt`.

Step 4 is the first point at which "the FPGA decoded and displayed a frame" can
even be claimed, and it still requires a Quartus fit (W-FIT) and a capture
(W-E2E) to be true. **Zero frames have been decoded and displayed by the FPGA
to date.**

## 5. `h264_decode_skeleton.sv` — measured, for the record

It is **not** a fourth decoder lineage. Its own header says so:

> THIS IS NOT A DECODER. It does not process data correctly. It exists solely to
> hold area in the fitter so we get a real resource measurement.

Measured facts:

* Owner `w-rel`, consumer `w-cap` (Quartus fit) — an area-estimation harness.
* **Not listed in `fpga/Plex_MiSTer/files.qip`**, so it is not even compiled into
  the product Quartus project.
* Not reachable from `emu`; correctly declared in `bench_only_modules.txt`.
* It is, however, a *second* source-graph confuser: it instantiates real deblock
  and intra modules, so it shows up in `parents=` diagnostics
  (e.g. `parents=decode_stub,h264_decode_skeleton`). It cannot inflate
  `emu`-rooted or core-rooted reachability because nothing reaches it.

No action required beyond awareness. It does not need to be retired with
`decode_stub`.

## 6. Gate caveats (binding)

`scripts/check_rtl_module_instantiations.py` and
`scripts/check_decode_core_seam.py` are **source/regex-level, not
elaboration-aware** (W-AUDIT, gpt-5.5). Both have false-reachable and
false-unreachable blind spots. A green from either is *necessary and not
sufficient*; corroborate with `make post-fit-hierarchy` on a real fit report.

The seam gate also cannot see vacuity that lives inside a register default
rather than a port tie. A known example it does **not** flag today:
`stream_path.sv` drives `core_luma4x4_total_coeff <= 5'd16` and
`core_luma4x4_trailing_ones <= 2'd0` unconditionally, so the core receives
synthetic nC/T1 metadata for every block regardless of the real CAVLC values.
