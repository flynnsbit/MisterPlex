# Validated lab pair: ddr-c5382bee-509b0c75

Stamped ARM daemon built from main `ba2ec313` (`--version` → `git_rev=ba2ec3139133`).
Replaces the historical md5-only pin `e9f79de2`, which **regresses 480p** on the
user PMS delivery geometry (parent-measured 2026-08-02: delivered **624x350**
vs coded 624x480 → green field + duplicated TREK24 counter).

| file | md5 (full) | bytes | role |
|------|------------|------:|------|
| Plex.rbf | c5382bee73cecdee8220b811e529c297 | 3970492 | DDR lab core |
| misterplexd | 509b0c7592e0e9e38686f9eb8e2cb047 | 13095524 | stamped ARM daemon |

## Ship

```bash
./scripts/package_validated_pair.sh
```

Requires `daemon_stamp_check --require-stamped` (no historical unstamped allow).
`pair_ship_policy` → `PAIR_OK id=ddr-c5382bee-509b0c75`.

## Capability marker

This daemon contains delivery-geometry telemetry (`measured=` / `desync_risk=` /
`DELIVERY_MISMATCH measured=`). The retired `e9f79de2` pin does **not**.

## Not daily glass

Still lab DDR (`c5382bee`); daily promote needs `daily_promote_ready` / glass_ok.

## Verify

```bash
cd release_artifacts/ddr-c5382bee-509b0c75 && md5sum -c MANIFEST.md5
qemu-arm-static misterplexd --version   # git_rev=ba2ec3139133
```
