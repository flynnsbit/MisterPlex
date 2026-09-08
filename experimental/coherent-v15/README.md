# Coherent H.264 V15 — reviewed experimental source

**Source publication only. Not timing-closed, fit-approved, deployed, or accepted for playback.** This isolated directory does not replace the repository's canonical FPGA tree.

## Exact reviewed source pins

- Source ID: `4f09a4176a6b954463e0d6b7484c3d421efdb686421bcf67f7bf254bf34604ef`
- Frozen source archive: `7c68c129c201c59b767aea6b1642684bd746c3ffccb80443970ba32cab6b18f5`
- Effective input archive: `f9ccd38a41ad12a7f8359d59cd9023459a1b83053bea6dfd3870e61fb8063096`
- Effective input manifest: `45beb03f791b0f23bbdb529a59741bebfe7a71ff763ee889f52006f4d975e306`
- Release manifest: `b32dd240e54cbafca70262bf4d149b2fb5d5ca877c6b86d4b05cda5b49417a51`
- Patch delta: `058f7c3a44e327ac68ab958b283363b605330cfa92c66b922d2f8338976141a7`

Independent review reported `READY_FOR_SOURCE_PUBLICATION` for the exact V15 cohort. The complete 149-source / 150-effective bindings, five-member RTL delta, 73 validation-source members, and preserved prior-fixture provenance matched exactly.

Changed production members:
- `rtl/ddr_frame_store.sv`
- `rtl/h264_i16_dc_hadamard.sv`
- `rtl/h264_inter_pred.sv`
- `rtl/h264_mb_ctrl.sv`
- `rtl/present_core.sv`

`critical-cones.patch` is the unchanged reviewed delta against the frozen V14 source, **not** a patch against the development branch's canonical files.

## What is published here

- `project/fpga/Plex_MiSTer/`: the full exact 149-member reviewed FPGA source cohort extracted from `source.tar`
- validation-source files extracted from `validation-code.tar`
- `source.tar`, `inputs.tar`, `inputs.json`, `validation-code.tar`, `original-added-benches.tar`: frozen archives for byte-exact reconstruction and provenance
- `manifest.json`, `source-map.json`, `effective-input-map.json`, `validation-source-map.json`, `member-preservation.json`, `fixture-preservation.json`: sealed membership and provenance records
- `source-freeze.json`, `file-map.json`, `source-publication.json`, `review-receipt.json`: publication metadata, per-file hashes, and qualification limits

Ordinary Git checkouts do **not** recreate the original read-only sealing or the extra effective `build_id.v` fit input. For exact replay, use the archived inputs together with the accompanying maps.

## Qualification boundary

This publication preserves the functional-first priority and the explicit limits:
- V15 physical timing **failed**; RBF `86fb35567a0967fa5154736cf037f8a67c42f94453e958c1efbfed73238e3b95` remains `UNAPPROVED_DO_NOT_DEPLOY`
- setup slack remained `-0.452 / -1.746 / -12.462 / -12.243 ns`; observer and hierarchy gates passed; native/instrumented semantic mismatches stayed `0`
- inherited equal-token full-range refresh stale-image defect remains unfixed and unwaived
- current LAN Web control path observations do **not** establish timing closure, 24 fps, clean A/V, glass acceptance, or DE10 deployment approval

The user priority after this source publication is to finish functional FPGA correctness on the reviewed code before any separately granted real DE10-Nano run, FPS optimization, or optional overlays/features.
