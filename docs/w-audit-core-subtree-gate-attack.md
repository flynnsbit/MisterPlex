# W-AUDIT core-subtree reachability gate attack

Branch/commit attacked: `w-deblock-seam` code commit `7225e00` (`origin/w-deblock-seam` tip was `2c2cb83`, a handoff commit, when rerun). This does not contradict `w-decode-hour27 ddb7c97`; it is a branch-specific audit of the new `--root h264_decode_core --require ...` instrument.

## Raw results

Repro:

```bash
scripts/w_audit_core_subtree_attack.py --ref 7225e00 > build/w_audit_core_subtree_attack_7225e00.log 2>&1
```

Measured output highlights:

- Dead-root false green:
  - `python3 scripts/check_rtl_module_instantiations.py --root h264_decode_core --require h264_deblock_writeback_ctrl` returned `rc=0`.
  - Same snapshot: `--root emu --require h264_decode_core` returned `rc=1` with `parents=<none>`.
  - Therefore the core-root gate can prove a module is inside the `h264_decode_core` source definition while the core itself is not product-reachable.
- Baseline red for absent MC under core:
  - `--root h264_decode_core --require h264_inter_mc_part` returned `rc=1`, `parents=decode_stub`.
- Disabled-generate false reachable:
  - Injecting `if (0) begin h264_inter_mc_part u_false(); end` under `h264_decode_core` made `--root h264_decode_core --require h264_inter_mc_part` return `rc=0`.
- Escaped-instance false unreachable:
  - Injecting legal escaped instance syntax `h264_inter_mc_part \w_audit.escaped_inst ();` still returned `rc=1`.
- files.qip omission false reachable:
  - Adding a tracked RTL file `w_audit_qip_missing_core_child.sv`, instantiating it under core, and not adding it to `files.qip` returned `rc=0`; `files_qip_contains=0`.

## Interpretation

The core-subtree gate is a useful necessary check for masking by `decode_stub`, but it is not a product oracle by itself. It roots from the `h264_decode_core` module definition, not from a product instance path such as `emu -> stream_path -> h264_decode_core`. A green can therefore be true about a dead core definition.

The gate also retains the earlier regex/source-level blind spots: parameter/generate false reachable, legal escaped-instance false unreachable, and tracked-file-vs-Quartus-file-list false reachable. The strongest current corroboration remains post-fit hierarchy evidence, e.g. `scripts/w_audit_postfit_decode_oracle.py --fit-rpt ... --expect-core-root`, once a fit from the decode-root branch exists.

## Recommended evidence standard refinement

For any future product-completeness claim, require both:

1. Source subtree: `--root h264_decode_core --require <module>` green with a red mutation.
2. Product root/path proof: either `emu` reaches `h264_decode_core` in source without passing through `decode_stub`, or preferably post-fit hierarchy shows `|stream_path:spath|h264_decode_core:<inst>` and does not show `|stream_path:spath|decode_stub:stub`.
