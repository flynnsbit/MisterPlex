# Coherent H.264 V14 — reviewed experimental source

**Source review only. Not physically fitted, timing-qualified, deployed, or accepted for playback.** This directory does not replace the repository's canonical FPGA tree.

## Exact reviewed change

V14 source ID: `df9edd2c2c283ca574706401c1d253a5ca976394d8d33acf9456c18f2bb1ec59`

Release manifest: `be4dc86497aab4db2ae9c337d78ce19976b120de1220d07cd07a7b21650677a9`

Source archive: `9fad4f4441b26d3159ccd5d2f69dc10e27026f9021427a248226422914dac388`

Input archive: `e4023151efea0e72433e9e1ab81f8f2c5b923370be9eb5e35e6243c71d5a16a9`

Independent review reported `NO_SIGNIFICANT_ISSUES_SOURCE_PUBLICATION_READY` for the exact reviewed four-file V14 delta from V13. The complete 149-source / 150-effective bindings, protected modes, 61 validation-source members, and retained run bindings matched exactly.

Changed production members:
- `rtl/h264_deblock.sv`
- `rtl/h264_deblock_frame.sv`
- `rtl/h264_intra_pred.sv`
- `rtl/h264_mb_ctrl.sv`

`critical-cones.patch` is the unchanged reviewed delta against the frozen V13 source, **not** a patch against the development branch's canonical files.

## Why this is isolated

This public tree intentionally stays partial. It publishes the four exact changed production members, their direct RTL dependencies, and the exact 61-member validation-source cohort needed to inspect the reviewed change. It does **not** publish the full 149/150 ready-to-fit source/input release in ordinary Git form; the complete frozen source/input archives and maps remain the authoritative private record for later separately granted physical work.

## Preserved source-only qualification

The accepted V14 source review keeps the explicit latency costs:
- +3 system cycles per filter edge segment
- +5 system cycles per intra-chroma block
- `68340` extra system cycles for a full240 IDR promotion
- one modeled native-period startup shift (`2005872` system cycles) for the affected first display path

Those costs are preserved and visible; they do **not** become a physical 24-fps, area, Fmax, or playback claim.

## Validation slice and remaining limits

The included validation sources preserve the focused and composed oracle harnesses, but fixture-oracle bytes are still not bundled here. This focused public project is **not** a complete ready-to-fit MiSTer core. The separately assigned physical owner must use the authoritative frozen private 149/150 release if a later fit/STA transaction is granted.

V13 native setup still fails in all four native corners and its retained RBF remains unapproved. V14 cuts the reviewed source cones but has **no** Quartus/STA/fit, area/capacity, Fmax, deployment, or glass approval in this publication.
