# HISTORICAL ONLY — DO NOT DEFAULT-SHIP

**Parent HW 2026-08-02:** this daemon (`e9f79de2`) **regresses 480p** vs live
`ea643e99` on PMS delivery **624x350** (green field, duplicated TREK24,
climbing drops). It is unstamped (md5-only) and lacks `desync_risk=` /
`DELIVERY_MISMATCH measured=` telemetry.

Default package path is now `release_artifacts/ddr-c5382bee-509b0c75/`
(stamped `git_rev=ba2ec3139133`). Kept here only as a matrix/history artifact.
`package_validated_pair.sh` refuses this directory as PAIR_DIR.

---

# Validated lab pair: ddr-c5382bee-e9f79de2

Tracked release binaries so a clean clone can assemble a shippable tarball
without machine-local scratch under `.agent-work/` or gitignored `artifacts/`.

| file | md5 (full) | bytes | role |
|------|------------|------:|------|
| Plex.rbf | c5382bee73cecdee8220b811e529c297 | 3970492 | DDR lab core (PAIR_MATRIX) |
| misterplexd | e9f79de217982aff44207664fdb945c5 | 12925900 | validated ARM daemon |

## Ship (clean checkout)

```bash
./scripts/package_validated_pair.sh
```

Equivalent expanded form:

```bash
RBF_PATH=release_artifacts/ddr-c5382bee-e9f79de2/Plex.rbf \
DAEMON_PATH=release_artifacts/ddr-c5382bee-e9f79de2/misterplexd \
VERSION=ddr-c5382bee-e9f79de2 \
PACKAGE_ALLOW_NO_FFMPEG=1 \
  ./scripts/package_release.sh
```

`scripts/pair_ship_policy.sh check` must report `PAIR_OK id=ddr-c5382bee-e9f79de2`.

For a self-contained tarball that also bundles armhf ffmpeg, either set
`FFMPEG_ARMHF` to a verified static binary or run `./scripts/fetch_release_ffmpeg.sh`
first (md5-gated). Without ffmpeg the packager still produces a pair tarball when
`PACKAGE_ALLOW_NO_FFMPEG=1` (daemon will need ffmpeg supplied on-device).

## Not daily-driver glass

`c5382bee` is a **lab** DDR pair row. Daily promote still requires
`rbf_ship_policy.sh daily_promote_ready` (glass_ok). A successful package is not
daily-driver promotion.

## Daemon stamp gap

This daemon binary predates commit `d44d5d1c` git-rev stamping. It is
matrix-pinned by **content md5** only. Promotion must refuse unstamped /
untraceable daemons (`scripts/daemon_stamp_check.sh`). Live device md5
`ea643e99` is not a git object and must not be matrix-pinned until replaced by
a stamped build that reports `misterplexd git_rev=<rev>` via `--version`.

## Verify

```bash
cd release_artifacts/ddr-c5382bee-e9f79de2 && md5sum -c MANIFEST.md5
```
