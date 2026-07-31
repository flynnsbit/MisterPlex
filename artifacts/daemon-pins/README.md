# Daemon pin artifacts (matched pairs)

Promotion/rollback is **atomic over (core, daemon) pairs**. Mixing is a
silently dead display:

| Pair | Core md5 | Daemon md5 | Notes |
|------|----------|------------|-------|
| spi-v2-hybrid | `dfebf2bf…` | `50f4eb92…` | SPI daily / rollback |
| spi-v2-release | `dfebf2bf…` | `7cd10b4d…` | pristine v0.2.0 |
| ddr-c5382bee | `c5382bee…` | `e9f79de2…` | DDR product (viewed OK) |

## Required files for SPI rollback

Place the SPI daemon binary here so `scripts/rollback_v2.sh` can install it:

```text
artifacts/daemon-pins/misterplexd.50f4eb92
# optional:
artifacts/daemon-pins/misterplexd.7cd10b4d
```

Or pass explicitly:

```bash
ROLLBACK_DAEMON=/path/to/misterplexd-50f4eb92 \
  PROMOTE_EXECUTE=1 scripts/rollback_v2.sh restore
```

Without a matching daemon artifact (host **or** content-addressed on-device
backup from `deploy_misterplexd.sh`), rollback **refuses to touch the device**.
Restoring the SPI core alone while a DDR daemon stays live produces a solid
green screen that still returns `/resources` 200.

## On-device backups

`deploy_misterplexd.sh` archives the outgoing binary as:

```text
$ROOT/bin/misterplexd.<prefix8>.bak
```

Rollback searches those before demanding a host file.
