# W-AUDIT qip coverage gate attack

Branch under audit: `parent/integ-hour27` at `fc89526` (gate introduced at
`ee2ed89`).

Gate under audit: `scripts/check_qip_coverage.py`.

## Raw results

Baseline on the integration branch:

```
Scope: 34 files in fpga/Plex_MiSTer/files.qip; 39 .sv tracked under rtl/
product RTL: 37  (testbenches excluded: 2)
tracked but NOT compiled: 4 / 37
  ALLOWED_ABSENT cos.sv
  ALLOWED_ABSENT h264_decode_skeleton.sv
  NOT_COMPILED h264_decode_top.sv
  NOT_COMPILED h264_intra_nb_ctx.sv
REQUIRED_FILE_COMPILED h264_decode_core.sv
REQUIRED_FILE_NOT_COMPILED h264_decode_top.sv
REQUIRED_FILE_NOT_COMPILED h264_intra_nb_ctx.sv
QIP_COVERAGE_FAIL unexplained_absent=2
rc=1
```

Synthetic mini-repo cases using the real gate code:

```
CASE control_missing_is_red rc=1
truth=NOT_COMPILED: tracked rtl/foo.sv is absent from active qip

CASE commented_assignment_false_green rc=0
truth=NOT_COMPILED: assignment is a comment, Quartus will not compile foo.sv
QIP_COVERAGE_OK product=1 compiled=1

CASE wrong_directory_basename_false_green rc=0
truth=NOT_COMPILED: qip names rtl_old/foo.sv, not product rtl/foo.sv
QIP_COVERAGE_OK product=1 compiled=1

CASE allowed_absent_false_green rc=0
truth=NOT_COMPILED: allowlist hides missing tracked RTL without checking reachability
ALLOWED_ABSENT h264_decode_skeleton.sv
QIP_COVERAGE_OK product=1 compiled=0

CASE qsf_direct_assignment_false_red rc=1
truth=COMPILED_ELSEWHERE: Plex.qsf directly lists rtl/foo.sv but files.qip omits it

CASE missing_qip_returns_skip rc=77
truth=UNSCORED: no file-list oracle exists
```

## Interpretation

### Could not break the branch-level red

The gate correctly catches the current integration defect:
`h264_decode_top.sv` and `h264_intra_nb_ctx.sv` are tracked RTL and are not in
`files.qip`. That `rc=1` is real and useful.

### Broke the gate as a general file-list oracle

The parser can produce false greens because it:

- matches assignments inside comments;
- compares only basenames, so `rtl_old/foo.sv` satisfies tracked `rtl/foo.sv`;
- allows `ALLOWED_ABSENT` files without proving they are unreachable or retired
  on the current branch.

It can also produce a false red for a file compiled from `Plex.qsf` or another
included qip because it reads only `fpga/Plex_MiSTer/files.qip`.

### Evidence standard

`check_qip_coverage.py rc=0` should be treated as necessary but not sufficient:
it proves neither instantiation nor post-fit survival, and in the current form it
does not even prove exact active-path membership. The fix should parse active
assignments only, normalize and compare exact project-relative paths, and make
the allowlist conditional on reachability/retirement evidence.

## Reproduction

```
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-audit
python3 scripts/w_audit_qip_coverage_attack.py
```

No Quartus, deploy, `load_core`, DDR writes, or video capture are used.
