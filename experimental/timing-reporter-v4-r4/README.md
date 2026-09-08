# Timing reporter v4 revision04 — reviewed experimental source

**Source publication only. Not SDK-qualified on an actual retained netlist, not fit-approved, and not a deployment or hardware grant.** This directory is isolated under `experimental/` so it does not replace the repository's canonical scripts.

## Exact reviewed source pins

- Source ID: `ab1d8301d76b2281d8e1bc904d3a4e7b8ee84e2a787a94b6e732a6721a893d27`
- Frozen source archive: `48292a5b9dc7b9ce3cc6bffce894fc91e2f9d82460a4c65e8b17eadf36fe2180`
- Release manifest: `0befbd3bbfea1d6a0aad2a28acd18e6c9ca99258ac7ead48493a695c614a9a9d`
- Driver: `0be637ccb53ecb6bd1335b53bec7bdef1a87bbb8671c3e1c055172ca32441e16`
- Checker: `9a93d2544b4ecea76c16bdec7fa563f18150c0e07bc7d28dcec4a6310b9f12eb`
- Launcher wrapper: `6bb45ccad27edcbdc29af026606a9e922e5b52e27f87a368dd702aa6dce835e9`

Independent review reported `SOURCE_PUBLICATION_READY_BOUNDED_HOST_CORRECTION` for the exact reviewed r4 package. This remains **source publication only**. Revision04 keeps the original r3 SDK-component evidence for unchanged components; it is **not** a new full SDK or retained-netlist execution.

## What is published here

- `project/`: the exact reviewed 25-file source cohort
- `source.tar`: the frozen archive for byte-exact reconstruction
- `manifest.json`, `file-map.json`, `source-freeze.json`: sealed source membership and mode records
- `source-delta-from-v3.*`, `source-delta-from-v4-r3.*`, `launcher-delta-from-v13.patch`: verified lineage patches
- `source-publication.json`: per-file hashes, limits, and usage summary

Ordinary Git checkouts do **not** recreate the archived directory sealing. For exact replay, use `source.tar` together with `file-map.json`.

## Usage and limits

To execute the reviewed tool exactly, restore `source.tar` using `file-map.json` over a checked-out MisterPlex tree, then run the preserved source-level commands from that restored tool root:

```sh
python3 -m unittest tests/unit/test_quartus_fit_hierarchy.py tests/unit/test_quartus_timing.py tests/unit/test_rbf_build.py tests/unit/test_timing_observer.py
MISTERPLEX_ALLOW_LOCAL_FIT=1 scripts/build_rbf.sh --backend local-container SLOT PROJECT_PATH --retain-project
python3 scripts/rbf_build.py local-container SLOT PROJECT_PATH --retain-project
```

`--retain-project` is **local-container only**. It preserves the same local project/database on success or failure for a later separately granted physical comparison.

## Qualification boundary

This publication does **not** approve Quartus/SDK execution, a retained-database comparison, timing success, area success, hardware deployment, or playback acceptance. The accepted review also preserves the old V13 shell failure, historical `afterhash` gap, and historical argv uncertainty as unresolved history rather than silently rewriting it.
