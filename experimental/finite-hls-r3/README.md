# Finite HLS revision03 — reviewed experimental source

**Source publication only. Not actual PMS-qualified, not ARM-runtime approved, and not hardware/playback acceptance.** This directory is isolated under `experimental/` so it does not replace the repository's canonical source.

## Exact reviewed pins

- Release manifest: `6a314a76c4019bb3e3c7434e092aac47a57acbdeb64688a2f4107288446dad56`
- Frozen source archive: `eda65ccbf506509beabbc59a78286c6408911f93b06a0498981ba9ab65a82961`
- Baseline patch: `4b410156847bdb73b46b982386bb428fc25c070a075f0b9cb63915b2ff804f0c`
- Revision-02 delta patch: `1d3fd4630e16386619299234181a44bc7d60720841f192142c44c51b8032e066`
- Review receipt: `713f1f842ffda732be8c917a6aefdc55970ee2ff9d4ac715b32651ffc9a6d96b`

Independent review reported `PRIOR_FINDING_RESOLVED_NO_SIGNIFICANT_ISSUES` for the exact reviewed revision03 package. That approval is limited to **source publication only**.

## What is published here

- `project/`: the exact 86-file reviewed first-party source cohort
- `source.tar.gz`: the frozen archive for byte-exact reconstruction
- `source-manifest.json`: release hash map from the frozen review package
- `file-map.json`: archived file and directory mode map for reconstruction
- `source-freeze.json`: exact file hash record for the published cohort
- `source.patch`: verified reconstruction patch from the original reviewed baseline
- `r2-delta.patch`: verified two-file patch from reviewed revision02
- `dependency-provenance.json`, `test-provenance.json`, `preservation.json`: preserved source-level provenance records
- `source-publication.json`: publication scope, lineage, limits, and restoration coordinates

Ordinary Git checkouts do **not** recreate the archived directory-mode sealing. For exact replay or later build work, restore `source.tar.gz` using `file-map.json` over a checked-out MisterPlex tree.

## Supported candidate contract only

This reviewed candidate source is limited to a finite muxed MPEG-TS HLS path with:
- `#EXT-X-ENDLIST`
- verifiable resource lengths
- fixed direct origin
- eight additive XML HLS targets while preserving the prior HTTP targets

The source deliberately still refuses or leaves unqualified:
- chunked or unknown-length resources
- redirect or cross-origin children
- segment or MAP byte ranges / MAP resources
- rendition/window/discontinuity qualification
- actual PMS compatibility claims
- ARM build/runtime approval
- Web/HDMI/glass/audio approval

## Restoration coordinates

Restore the exact cohort over a checked-out tree before any later build or preflight work:

```sh
tar -xzf source.tar.gz --strip-components=1 -C /path/to/MisterPlex
```

Any later HLS-capable ARM build must use this exact restored 86-file cohort together with a **separately staged FFmpeg 8.1.2 HLS dependency build**. Do not accidentally reuse the old static ARM archives that lack HLS support.
