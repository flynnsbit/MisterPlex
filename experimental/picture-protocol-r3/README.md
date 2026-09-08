# picture-protocol-r3

Frozen experimental publication of the independently reviewed picture R3 leaf.
This is exact reviewed source/provenance for the legacy HPS frame ownership and
replacement protocol only; it is **not** approval of central capability wiring,
coherent integration, timing, hardware, FPS, tiers, or glass playback.

## Included

- full 149-member V15-derived product source tree under `project/fpga/Plex_MiSTer`
- 62 directly reviewed validation/project inputs plus `validate_guarded.py`
- exact `source-files.tar`, `project-inputs.json`, `manifest.json`
- exact `picture-r3-from-v15.patch` and `picture-r3-from-r2.patch`
- independent review receipt and machine-readable file maps

## Key hashes

- manifest: `c5d2ce5623c5298e4bb48903ba815aa8070129d28ffd71d03c0429f403c223a9`
- project inputs: `ce7028875909b86e3aa93c539527e4a5e2e7a06317c9860a2836498879c25a30`
- source-files.tar: `bdfdb753c43af9f6b61b6bdc0bbbbaa61ae80910c82559ebafc0d67e74f9c8f6`
- picture-r3-from-v15.patch: `caaad09faf701f3db712b5354483caf0687305eb8228a410469879b6aa00fd6c`
- picture-r3-from-r2.patch: `9985d18b4e042b48c4da55af03160b17123b943b228b599d299e363355fb7245`
- ddr_frame_store.sv: `042659f2c58bc97f2bf706af969a7a40709e96bad112d7f955f615954a45154b`
- validate_guarded.py: `e99ac125ec4e6737cbfce9e29b3e0cf06f1ad1a9fdf06afa6381865ddbe3b469`

## Limits and reconstruction

The plain tree intentionally excludes unrelated V15 validation members and any
recursive build outputs, binaries, raw logs, captures, DB/RBF files or active
coherent integration source. For exact sealed reconstruction, use the V15 base
archive `experimental/coherent-v15/source.tar` (sha256
`7c68c129c201c59b767aea6b1642684bd746c3ffccb80443970ba32cab6b18f5`) with
`source-files.tar`, `project-inputs.json`, `manifest.json`, and the maps here.
Git does not preserve original 0444/0544 sealing; exact modes remain recorded
in the manifest/maps, including the unchanged-byte `scripts/run_verilator.sh`
execute-bit restore.
