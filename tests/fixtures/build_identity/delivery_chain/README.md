# Build-identity delivery chain — evidence

Branch `w-osd-o5`. Captured by W-OSD-O5 after the parent's revised standard made
a `files.qip` cross-check mandatory.

## What these logs show

| File | Shows |
|---|---|
| `quartus_file_list_sys_osd.log` | The true Quartus file list is **80** source files, not the **35** in `files.qip`. `sys/osd.v` and `sys/hps_io.sv` are in the design and absent from `files.qip`. |
| `build_id_delivery_ok.log` | All five links of the build-ID delivery chain are intact on this branch. |
| `test_build_identity_pass.log` | The full gate, including the six delivery reds and four resolver reds. |

## The two findings

**1. A `files.qip` membership test answers the wrong question.** This project pulls
the MiSTer framework in through Tcl, not through `files.qip`:

```
Plex.qsf     source sys/sys.tcl
sys/sys.tcl  set_global_assignment -name QIP_FILE sys/sys.qip
sys/sys.qip  set_global_assignment -name VERILOG_FILE [file join $::quartus(qip_path) osd.v]
```

so a naive check reports `sys/osd.v` — the OSD compositor that draws the build id —
as *not in the design*. It is in the design; the core does not boot without the
framework. Use `scripts/quartus_file_list.py --gate --require <path>` instead.

The resolver's governing property is that **an unresolved reference is never
reported as absent**. Anything it cannot resolve is `UNRESOLVED` and `--gate`
fails. Silently dropping references it does not understand is precisely how a
checker produces a short file list that hides a real input.

**2. The build-ID delivery chain was never gated, and neither were my own tests.**
`test_build_identity.sh` only ever proved the SRC *digest* behaved; it passed
regardless of whether the identity reached the bitstream. Separately, that test
and my two other unit gates were not referenced by the `Makefile` at all, so no
`make unit` run had ever executed them.

## The sharpest red

`consumer dropped from files.qip`: `Plex.sv` still contains a perfectly correct

```systemverilog
"V,v",`BUILD_ID     // line 83
```

— any grep-based check calls this green — while `Plex.sv` is absent from the
Quartus file list and therefore not in the design. This is the parent's
mutation #3 reproduced against the OSD build id, and the gate catches it.

## What this does not prove

Source-level wiring only. It does not prove a fit ran, that an RBF was deployed,
or that the string is rendered on a screen. `make post-fit-hierarchy` remains the
only real oracle for what survived into a bitstream.
