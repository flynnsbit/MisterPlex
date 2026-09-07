# Timing reporter v4 revision03 — reviewed experimental source

**Source publication only. Not SDK-qualified on an actual retained netlist, not fit-approved, and not a deployment or hardware grant.** This directory is isolated under `experimental/` so it does not replace the repository's canonical scripts.

## Exact reviewed source pins

- Source ID: `92580fbc869b70561d437cc8b779fbefae258cfad98f6050f098fdab54d6c876`
- Frozen source archive: `e4fb9cfa23c3f14ca81a53eec908441f0b5e2c2ace0aaf906e8d1e3cf0751749`
- Release manifest: `530b2addc834d7f83d99b6329c471d1e3f861f07073bbf8e51abce097ef683ca`
- Driver: `ea39c0f3867c61a63c87bf7a4593d865c99697967ea0ccbcfbfdd7fa2d7d8e1b`

Independent review found the prior retention-inventory finding resolved and no significant source issue in the exact reviewed r3 package. The accepted result keeps actual vendor-setter / same-netlist qualification **pending a separate V13 physical transaction**. Revision03 reuses the unchanged r2 SDK-component evidence only; it is **not** a new full SDK execution.

## What is published here

- `project/`: the exact 23 reviewed source files (`docs/`, `scripts/`, `tests/`)
- `source.tar`: the frozen archive for byte-exact execution/reconstruction
- `source-freeze.json`: the sealed source-file hash record
- `file-map.json`: the sealed file and mode map
- `source-delta-from-v3.*` and `source-delta-from-v4-r2.*`: the verified reconstruction patches
- `source-publication.json`: per-file hashes, limits, and usage summary

Ordinary Git checkouts do **not** recreate the original `0555` directory sealing. For exact replay, use the frozen `source.tar` together with `file-map.json`.

## Usage and limits

This experimental directory is for inspection and publication. To execute the
reviewed tool exactly, restore `source.tar` using `file-map.json` over a
checked-out MisterPlex tree, then run the preserved source-level commands from
that restored tool root:

```sh
python3 -m unittest tests/unit/test_rbf_build.py tests/unit/test_quartus_timing.py tests/unit/test_timing_observer.py
MISTERPLEX_ALLOW_LOCAL_FIT=1 scripts/build_rbf.sh --backend local-container SLOT PROJECT_PATH --retain-project
python3 scripts/rbf_build.py local-container SLOT PROJECT_PATH --retain-project
```

`--retain-project` is **local-container only**. It keeps the exact local
project/database on success or failure for a later separately granted physical
analysis. Remote cleanup/transfer policy is unchanged.

## Qualification boundary

This publication does **not** approve Quartus/SDK execution, a retained-database comparison, timing success, area success, hardware deployment, or playback acceptance. The associated V13 full-input cohort remains pinned privately and the next physical owner must run **one** new V13 fit, retain that database on success/failure, and compare uninstrumented vs instrumented STA on that same new netlist.
