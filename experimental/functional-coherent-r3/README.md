# functional-coherent-r3

Frozen experimental publication of the complete independently approved coherent
functional FPGA source cohort. This is the supported **constrained source**
milestone only: 320x240, default 8192-byte AU plus separate 8192-byte VCL,
existing I/P/reference/filter/ingress/audio/reset/publication/original-DAR and
diagnostic painting. It is **not** approval of timing, hardware, glass, FPS or
resolution tiers. Tier bits 9..12 remain clear.

## Included

- full 149-member product source tree under `project/fpga/Plex_MiSTer`
- all 88 reviewed validation source/provenance members extracted from
  `validation-code.tar`
- exact `source.tar`, `inputs.tar`, `inputs.json`
- exact `functional.patch`, `central.patch`, `picture-r3-from-v15.patch`
- exact source/effective/validation maps and mode-preservation records
- final review receipt plus machine-readable publication metadata

## Key hashes

- source: `9217adef21e2bf54acd41d80faea9a0fbeb1e03bb69fa325841fcda92688608a`
- effective: `0d53325d4c3eaecb5793b584fe23b0939ed138b91539620df40f17c4e285666b`
- manifest: `7d175d19a63a054f6bf85f86ce1abcbf63191e27daf1bc62463ea24c50f7708a`
- source.tar: `f93b01ea7d84ae8cab1e143f4113b28c4fb03d62ec04ae7dc84bf22a1fb42a1a`
- inputs.tar: `8e66942cf667375c8dbf93f277899e4d921e81b88bfd41cd3f881c2ac6eaadfd`
- inputs.json: `39d9e2688d0509c020d1d6726b3e62a3ad2afc55691a0fd3c2e0a4c3f50fb477`
- functional.patch: `8f2a8333806688ced8a484a4035ccc50bbba79441925ffb0a5a49cdddcfa43a4`
- validation-code.tar: `0d156f4b99434120c26be8eae60f41677008a5dc664ef323e6c9e236b31c3970`

## Source scope and limits

Only three product members differ from V15: `Plex.sv`, `Plex.qsf` comments, and
`rtl/ddr_frame_store.sv`. All other 146 source members and 147 effective
members are unchanged. All 35 primary composed metric rows match V15 exactly,
while three recovery pictures intentionally lack separate historical CSV
baselines.

This published source still selects **SYS120**. The conservative **SYS20**
physical derivative is a separate in-flight identity and is **not** included,
inspected or qualified by this publication. For exact effective reconstruction,
use `inputs.tar` and `inputs.json`; do not substitute a different build ID,
clock selector, or active physical derivative output.

Exact sealed modes are recorded in `file-map.json`, `member-preservation.json`
and `fixture-preservation.json`; Git does not preserve original 0444-only
sealing beyond the executable bit.
