# Daemon pin artifacts (matched pairs) — **gitignored binaries**

Decision (2026-07-31): **do not commit** the ~MB ARM ELFs. Keep this README
(+ `PROVENANCE-*.txt`) tracked; fetch/pin binaries onto the host. Rollback/promote
**refuse** (`true rc=10`) rather than half-apply when a pin is missing.

| File (gitignored) | md5 | Pair / role |
|-------------------|-----|-------------|
| `misterplexd.9ce2c2d1` | `9ce2c2d13d1c8712683289043e99002c` | **PRIMARY / CURRENT LIVE** `ddr-8fdf440f-9ce2c2d1` — w-osd-hires chevron, parent glass 2026-08-01 |
| `misterplexd.3883f5ab` | `3883f5ab8744e070e7b0820c6b9b4376` | prior live — accepted DDR rollback |
| `misterplexd.edc3a46b` | `edc3a46b9d1c6b86337deb90f896eb0f` | older DDR primary — accepted rollback |
| `misterplexd.e9f79de2` | `e9f79de217982aff44207664fdb945c5` | hist first silicon-correct DDR |
| `misterplexd.50f4eb92` | `50f4eb925de10e29172999a565c87684` | `spi-v2-hybrid` (SPI core `dfebf2bf`) — SPI undo only |

Provenance (tracked): `PROVENANCE-9ce2c2d1.txt`.

## Pin policy (do not weaken)

1. **Pin the measured bytes** that match device `md5sum $(readlink -f /proc/PID/exe)`.
2. A lane `build/arm/misterplexd` **is acceptable** when that md5 equals live device
   and glass evidence exists. Rollback must restore *those* bytes, not a hopeful rebuild.
3. **Rebuild is optional hygiene**, not a gate. Only promote a rebuild to the pin
   name if `cmp -s rebuild pin` (or identical md5). Timestamp/path noise often
   breaks byte-identity — that is not a reason to drop the measured pin.
4. Never relax a gate md5 compare to “accept any build/”. Unknown md5 stays FAIL.

## Install primary pin from host lane build (no SSH)

```bash
WT=/home/flynnsbit/Projects/MisterPlex/.worktrees/rollback-honest
SRC=/home/flynnsbit/Projects/MisterPlex/.worktrees/w-osd-hires/build/arm/misterplexd
md5sum "$SRC"
# expect: 9ce2c2d13d1c8712683289043e99002c
PIN_NOTE='w-osd-hires glass-verified live' \
  "$WT/scripts/pin_daemon_artifact.sh" "$SRC"
md5sum "$WT/artifacts/daemon-pins/misterplexd.9ce2c2d1"
# expect identical full md5
"$WT/scripts/pair_ship_policy.sh" find-daemon 9ce2c2d13d1c8712683289043e99002c
# FOUND ... true rc=0
```

## Fetch from device (parent only — agents must not SSH)

```bash
scripts/fetch_daemon_pins.sh both
# or live primary only:
scripts/fetch_daemon_pins.sh 9ce2c2d1
# true rc=0 when host md5 matches

# alternate: pin whatever is live right now
scripts/pin_daemon_artifact.sh --from-device-live
```

Verify:

```bash
scripts/pair_ship_policy.sh find-daemon 9ce2c2d1
scripts/pair_ship_policy.sh find-daemon 50f4eb92
# FOUND ... true rc=0
source scripts/rbf_ship_policy.sh
rbf_policy_ddr_daemon_accepted 9ce2c2d1; echo "true rc=$?"   # expect 0
```

## Why not git

- ~13–30MB static ARM ELFs per pin; bloats clone for every worker.
- Pins are **lab-measured** artifacts; device live `/proc/exe` is source of truth.
- `deploy_misterplexd.sh` also writes on-device `misterplexd.<prefix8>.bak` so a
  future fetch can recover without git history.

## Atomic rollback without a pin

```text
REFUSE ATOMIC_ROLLBACK ... Device left UNTOUCHED.
  run: scripts/pin_daemon_artifact.sh <measured-path>
  # or: scripts/fetch_daemon_pins.sh 9ce2c2d1
```
