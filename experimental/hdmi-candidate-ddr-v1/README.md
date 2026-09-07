# HDMI DDR Timing Candidate — EXPERIMENTAL / UNINTEGRATED

**Status:** SOURCE EQUIVALENCE ONLY — not physically fitted, not timing-qualified, not glass-verified.

This directory preserves the isolated HDMI scaler (`ascal.vhd`) candidate developed
by agent 54884ac8 (a09-hdmi-timing). It is preserved here for continuity, **not as a
replacement for V12** or any other production source tree.

## Key pins

| File | SHA-256 |
|------|---------|
| `fpga/Plex_MiSTer/sys/ascal.vhd` | `2cfb74522b5d046066bcf54bd99f865687445092cd79b8af6c9ed6c5912ed409` |
| `reference/sys/ascal.vhd` (baseline) | `c789b2fe9ba9c6954e9005d5f79296248029101eaf24d69378cad7dfd29bd826` |
| `reference/rtl/ddr_frame_store.sv` | `fd11ebcf5b0851db4093a583366c4cc4dc4903a7aa5fc324e264fff33f6cbd58` |
| `hdmi-terminal-count.patch` | `12b7c8a9b7ed7c353f521180b42fa0f881bd2b3ad6474b78f4a5d30da028703f` |
| `validation-final-results.json` | `da2f7e4f9ec1e50303c4670adb35cef56baaf4f3923b6669d2c9e2ef2547eaf0` |

## Validation scope

`validation-final-results.json` status: `PASS_FOCUSED_SOURCE_EQUIVALENCE_ONLY_NOT_PHYSICAL_TIMING_OR_GLASS`

- HDL testbench equivalence sweep only
- No Quartus fit, no timing netlist, no hardware
- V12 (`fpga/Plex_MiSTer/`) remains the sole qualified FPGA source
- The HDL window for this candidate has ended; no outstanding jobs

## Structure

```
fpga/Plex_MiSTer/sys/ascal.vhd         candidate VHDL (DDR terminal-count fix)
reference/sys/ascal.vhd                 baseline reference
reference/rtl/ddr_frame_store.sv        supporting reference RTL
hdmi-terminal-count.patch               delta from baseline to candidate
prepared/ascal_sweep_tb.vhd            sweep testbench
build/.../ascal_timing_tb.vhd          timing testbench (only copy in build tree)
tests/                                  harness source
witnesses/timing/                       curated Quartus timing reports (evidence only)
validation*.json / *.log                harness results and operational logs
```
