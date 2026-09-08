# Minimal original HTTP explicit-offset cohort — reviewed experimental source

**Source publication only. Not an accepted ARM runtime, PMS contract, or playback result.** This directory is isolated under `experimental/` so it does not replace the repository's canonical or prior HLS-oriented source.

## Exact reviewed pins

- Release manifest: `55fa84b8c6359200b305a311140504d8a125094f6fd474feec4259af6b1a80a5`
- Frozen source archive: `b0f5fe51c912d131d10d9ac62cf8dc957fe7cbed2d73bb5b485744b8f21556bd`
- Frozen patch: `fde1fc209945486fcdac9cb150ae77e6d0c13007ce6591bba9eaf44470d766e3`
- Review receipt: `0ad57b2091a287f26b430decb0d340f8c446ac93d6bfab3dadf6da330932b0e5`
- Original build-input record: `903b13b39b5a92854bf1d11073f0804b16c0fb0d0d8ab00cd697955ec83e6c3f`
- Authoritative build correction: `23379d7b8aa3aa08c5a19d969721c3284c45ef0eb334b8e65895f6c615ed24c6`

Independent review reported `SOURCE_ARCHIVE_READY_BUILD_REQUIRES_EXPLICIT_LIVE_TRACE_FLAG` for this exact 82-file cohort. The accepted delta preserves the known original HTTP success basis while **not** adopting any HLS source or dependency work.

## What is published here

- `project/`: the exact reviewed 82-file first-party source cohort
- `source.tar.gz`: the frozen archive for byte-exact reconstruction
- `source-manifest.json`, `file-map.json`, `source-freeze.json`: sealed source membership and mode records
- `source.patch`: verified reconstruction patch from the reviewed baseline
- `build-input-correction-v1.json`: the required next-build correction (`ARM_PLEXD_AV_TRACE=1`)
- `preservation.json`, `test-provenance.json`: preserved source-level provenance records
- `source-publication.json`: scope, hashes, restoration coordinates, and corrected build guidance

Ordinary Git checkouts do **not** recreate the archived source exactly. For exact replay, restore `source.tar.gz` with `file-map.json` over a checked-out MisterPlex tree.

## Accepted scope and limits

This source publication preserves the exact reviewed minimal original-HTTP path only. The accepted quantitative basis is the private curated result showing explicit offset `0` returned the same `1535396`-byte / `384`-AU body twice with full audio while omitted offset returned no body. That measured result is **not** a new public runtime/build claim here.

Any later ARM build must keep the frozen original build-input record as history **and** apply `build-input-correction-v1.json` so `ARM_PLEXD_AV_TRACE=1` / `MPX_FPGA_AV_TRACE=1` stay explicit. No HLS dependency adoption, runtime approval, or glass acceptance follows from this source publication.
