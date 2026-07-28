# W-AUDIT pre-fit elaboration / map hierarchy attack

Branch under audit: `parent/integ-hour27` at `a8aa8eb`.

Gate under audit:

- `scripts/check_prefit_elaboration.sh`
- `scripts/check_map_hierarchy.py`

I did **not** run Quartus. W-AUDIT's standing constraint is no Quartus. This
audit attacks the parser and evidence semantics using existing post-fit reports
and synthetic report snippets.

## Raw results

Known-good control on the deployed `fb4bad84` fit report:

```
CASE direct_stub_child_control_red rc=1
truth=TRUE_MASKED: direct child only under decode_stub
PRESENT h264_dpb_one_ref instances=1 subtree_rows=19 parents=decode_stub
  MASKED h264_dpb_one_ref -- reachable ONLY through decode_stub
independent_fit_path=|sys_top|emu:emu|stream_path:spath|decode_stub:stub|h264_dpb_one_ref:u_stream_dpb
```

Nested stub-only false green:

```
CASE nested_stub_child_false_green rc=0
truth=TRUE_MASKED: nested descendant only under decode_stub
PRESENT h264_dpb_i420_addr instances=1 subtree_rows=1 parents=h264_dpb_mb_write_addr
PREFIT_HIERARCHY_OK required=1 rows=827
independent_fit_path=|sys_top|emu:emu|stream_path:spath|decode_stub:stub|h264_dpb_one_ref:u_stream_dpb|h264_dpb_mb_write_addr:u_write_addr|h264_dpb_i420_addr:u_addr
```

Elaboration classifier summary loses the stub ancestor unless the full path is
read:

```
CASE elab_summary_parent_masks_stub_ancestor rc=1
ABSENT h264_inter_mc_16x16 -- ELABORATED_BUT_OPTIMIZED_AWAY parents=h264_inter_mc_part
    elaborated_as: emu:emu|stream_path:spath|decode_stub:stub|h264_inter_mc_part:u_stream_mc|h264_inter_mc_16x16:u_full
```

Synthetic unbounded-table false green:

```
CASE unbounded_trailing_table_false_green rc=0
truth=NOT_ENTITY_ROW
Scope: 2 entity rows parsed from fake_unbounded_map.rpt
PRESENT h264_decode_core instances=1 subtree_rows=1 parents=<top>
PREFIT_HIERARCHY_OK required=1 rows=2
```

The fake report has a real `Resource Utilization by Entity` section title and
then a later unrelated semicolon row shaped like `|h264_decode_core:not_entity|`;
the parser accepts it as an entity because it never bounds the table after the
section starts.

## Interpretation

### Could not break the central new W-FIT conclusion

I did not find evidence contradicting W-FIT's claim that `w-decode-hour27`
compiled, instantiated, and elaborated `h264_decode_core`, then A&S optimized it
away as dead logic. I also did not run Quartus to reproduce it. The new failure
mode is plausible and matches the known post-fit pattern: compile/elaboration
messages are not silicon/resource evidence.

### BROKE: `--forbid-only-under decode_stub` only catches direct children

The option checks the direct parent set:

```
parents == {args.forbid_only_under}
```

That catches `h264_dpb_one_ref` because its direct parent is `decode_stub`. It
does **not** catch `h264_dpb_i420_addr`, even though the full hierarchy proves it
is reachable only through `decode_stub`. Any nested module under the stub can be
reported `PREFIT_HIERARCHY_OK`.

Fix shape: test whether every exact hit has the forbidden module anywhere in
its ancestor chain, not merely as its immediate parent.

### BROKE/NARROWED: `parents=` summary is direct-parent only

For an absent-but-elaborated nested module, the summary says
`parents=h264_inter_mc_part` while the full elaboration path shows the real
product concern: it is under `decode_stub`. The full path is printed, so the raw
evidence is available; the short summary must not be cited alone.

### BROKE: parser is still not provenance/bounds-safe

`check_map_hierarchy.py` starts parsing at `Resource Utilization by Entity` but
does not stop at the end of that table. A later table row with a similar first
column shape can manufacture a false `PRESENT`. This is the same family as
W-FIT's corrected `1204 -> 827` denominator bug, although the specific parser is
stricter than the old helper.

The parser should bound the section using Quartus section/table markers or
header shape, and should reject rows that do not have the expected resource
columns.

## Reproduction

```
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-audit
python3 scripts/w_audit_prefit_elaboration_attack.py
```

No Quartus, deploy, `load_core`, DDR writes, or video capture are used.
