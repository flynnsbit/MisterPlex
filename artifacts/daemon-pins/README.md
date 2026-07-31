# Daemon pin artifacts (matched pairs) — **gitignored binaries**

Decision (2026-07-31): **do not commit** the ~MB ARM ELFs. Keep this README
tracked; fetch pins onto the host with the script below. Rollback/promote
**refuse** (`true rc=10`) rather than half-apply when a pin is missing.

| File (gitignored) | md5 | Pair |
|-------------------|-----|------|
| `misterplexd.edc3a46b` | `edc3a46b…` (full after fetch) | **PRIMARY** `ddr-c5382bee` + conf `DDR_YUV_FORCE_SCALE=1` `FFMPEG_SWS_FLAGS=fast_bilinear` |
| `misterplexd.e9f79de2` | `e9f79de217982aff44207664fdb945c5` | hist `ddr-c5382bee-e9f79de2` (pre-480p) |
| `misterplexd.50f4eb92` | `50f4eb925de10e29172999a565c87684` | `spi-v2-hybrid` (SPI core `dfebf2bf`) |

## Fetch (parent only — agents must not SSH)

```bash
# Primary DDR live + SPI + hist from the MiSTer (live /proc/exe preferred)
scripts/fetch_daemon_pins.sh both
# true rc=0 when host md5 matches

scripts/fetch_daemon_pins.sh ddr        # edc3a46b PRIMARY (live process)
scripts/fetch_daemon_pins.sh hist       # e9f79de2
scripts/fetch_daemon_pins.sh spi        # 50f4eb92
```

Manual equivalent:

```bash
mkdir -p artifacts/daemon-pins
# example paths parent already used:
#   /media/fat/misterplex_v2/bin/misterplexd.bak.pre-plxd  -> 50f4eb92
#   live /media/fat/misterplex_v2/bin/misterplexd          -> e9f79de2 (when DDR is live)
sshpass -p "${MISTER_PASS:-1}" scp -o StrictHostKeyChecking=no \
  root@${MISTER_HOST:-192.168.1.183}:/media/fat/misterplex_v2/bin/misterplexd.bak.pre-plxd \
  artifacts/daemon-pins/misterplexd.50f4eb92
md5sum artifacts/daemon-pins/misterplexd.50f4eb92
# expect: 50f4eb925de10e29172999a565c87684
```

Verify:

```bash
scripts/pair_ship_policy.sh find-daemon 50f4eb92
scripts/pair_ship_policy.sh find-daemon e9f79de2
# FOUND ... true rc=0
```

## Why not git

- ~30MB static ARM ELFs per pin; bloats clone for every worker.
- Pins are **lab-measured** artifacts; device is source of truth after a good soak.
- `deploy_misterplexd.sh` also writes on-device `misterplexd.<prefix8>.bak` so a
  future fetch can recover without git history.

## Atomic rollback without a pin

```text
REFUSE ATOMIC_ROLLBACK ... Device left UNTOUCHED.
  run: scripts/fetch_daemon_pins.sh spi   # or ddr
```
