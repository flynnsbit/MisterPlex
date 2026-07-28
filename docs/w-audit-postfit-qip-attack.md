# W-AUDIT post-fit hierarchy / files.qip attack

Branch under audit: `parent/integ-hour27` at `ee2ed89`.

Fit artifact under audit:
`fpga/Plex_MiSTer/remote_out/wfit-hour27-bdiag-b/Plex.fit.rpt`
for resident/deployed RBF `fb4bad849ad2db782a5004ce5a3471ce`.

## Raw results

Default hierarchy gate:

```
python3 scripts/check_quartus_fit_hierarchy.py \
  --fit-rpt .../wfit-hour27-bdiag-b/Plex.fit.rpt \
  --map-rpt .../wfit-hour27-bdiag-b/Plex.map.rpt \
  --log .../wfit-hour27-bdiag-b/compile.log

rc=0
ddr_frame_store present: 4757 ALUT / 2298 reg / 159744 block bits / 96 M10K
stream_path present:     11189 ALUT / 2707 reg / 2360260 block bits / 291 M10K
PASS fit hierarchy: critical modules present with non-trivial resource usage
```

Decode-specific post-fit oracle on the same fit report:

```
rows=827
decode_stub under |stream_path:spath:       1
h264_decode_core under |stream_path:spath:  0
h264_decode_top under |stream_path:spath:   0
stub hierarchy: |sys_top|emu:emu|stream_path:spath|decode_stub:stub
```

`files.qip` membership versus fitted reality:

```
h264_decode_core active in files.qip:        1
decode_stub active in files.qip:             1
h264_decode_core post-fit under stream_path: 0
```

Current new qip coverage gate (`scripts/check_qip_coverage.py`, `ee2ed89`):

```
rc=1
Scope: 34 files in fpga/Plex_MiSTer/files.qip; 39 .sv tracked under rtl/
tracked but NOT compiled: 4 / 37
  NOT_COMPILED h264_decode_top.sv
  NOT_COMPILED h264_intra_nb_ctx.sv
REQUIRED_FILE_COMPILED h264_decode_core.sv
QIP_COVERAGE_FAIL unexplained_absent=2 (h264_decode_top.sv, h264_intra_nb_ctx.sv)
```

Synthetic qip parser attacks:

```
comment-only line:
  "# set_global_assignment -name SYSTEMVERILOG_FILE rtl/w_audit_comment_only.sv"
  naive_text_contains=1
  active_assignment_contains=0

wrong-directory same basename:
  "set_global_assignment -name SYSTEMVERILOG_FILE rtl_old/h264_decode_core.sv"
  basename_match=1
  exact_rtl_path_match=0
```

Synthetic post-fit parser attack:

```
forged_non_quartus_report rc=0
PASS fit hierarchy: critical modules present with non-trivial resource usage
```

The forged report is a short hand-written hierarchy table, not Quartus output.

## Interpretation

### BROKE: default `make post-fit-hierarchy` is not a decode-product proof

The default config proves large product modules survived fitting, but it does
not ask which decoder is rooted under `stream_path`. On `fb4bad84` it is green
while the fitted stream path contains `decode_stub` and contains neither
`h264_decode_core` nor `h264_decode_top`.

This is not a contradiction of W-FIT: `fb4bad84` was a display-path fit and
`decode_stub` was expected there. It is a warning about evidence wording:
default post-fit hierarchy is a product-module presence gate, not a decode
lineage oracle unless the decode modules are explicitly in its config.

### BROKE: `files.qip` membership is necessary but not sufficient

`h264_decode_core.sv` is in `files.qip`, yet no `h264_decode_core` entity
survived under the fitted product `stream_path`. A qip cross-check closes the
"source file absent from Quartus" hole, but it does not prove instantiation,
elaboration through enabled generate branches, or retention after fitting.

### BROKE: current `check_qip_coverage.py` is already red and has parser blind spots

The new qip coverage gate correctly returns `rc=1` on current integration
because `h264_decode_top.sv` and `h264_intra_nb_ctx.sv` are tracked product RTL
but not compiled. That is useful and should stay red until owned.

However, its parser records `os.path.basename(...)` only and does not skip
comment lines before applying its assignment regex. A commented-out assignment
or a wrong-directory file with the same basename can satisfy a required module
name. The cross-check should use active, exact, normalized `rtl/<file>.sv`
assignments, not basenames or raw text membership.

### BROKE: hierarchy script accepts non-Quartus/stale-shaped reports

`check_quartus_fit_hierarchy.py` is intentionally a hierarchy-table parser. It
does not prove the report is real, fresh, tied to the RBF, or tied to the current
source/QIP manifest. A hand-written table with sufficient resource numbers
returns `rc=0`.

This does not make a real Quartus `Plex.fit.rpt` useless. It means any claim
using the script must also carry report provenance: fit directory, RBF md5,
compile log, source commit/manifest, and preferably the exact hierarchy rows for
the modules being claimed.

## Reproduction

```
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-audit
python3 scripts/w_audit_postfit_hierarchy_attack.py
```

No Quartus, deploy, `load_core`, sentinel writes, or video capture are used.
