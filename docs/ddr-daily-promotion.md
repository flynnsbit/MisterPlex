# DDR daily-driver promotion runbook

Parent-owned device work only. Agents produce artifacts and commands; they must
**not** SSH to `192.168.1.183`, deploy, cast, or capture HDMI.

## Why this document exists

The FPGA DDR path first rendered correct colour/geometry on silicon with:

| Piece | md5 | Role |
|-------|-----|------|
| RBF | `c5382bee73cecdee8220b811e529c297` | product DDR scanout |
| daemon | `e9f79de217982aff44207664fdb945c5` | paired ARM companion |

The **previous daily driver** is the v0.2.0 SPI pair (no `ddr_frame_store`):

| Piece | path on device | md5 |
|-------|----------------|-----|
| Core | `/media/fat/_Utility/Plex_v2.rbf` | `dfebf2bfd08dd70b473b587dd7e81848` |
| Daemon | live root usually `/media/fat/misterplex_v2/bin/misterplexd` | hybrid pin `50f4eb92…` or release `7cd10b4d…` |
| Conf | **from** `/proc/<pid>/cmdline` `--conf` | often `…/misterplex_v2/misterplex.conf` |

`/media/fat/misterplex/misterplex.conf` is **not** automatically live. Always
resolve conf from the running process cmdline (or `readlink -f /proc/PID/exe`
root). Reading the wrong conf has already caused operator error.

## File-naming trap (read twice)

| Path | Who writes it | Meaning |
|------|---------------|---------|
| `/media/fat/_Utility/Plex.rbf` | `scripts/deploy_plex_core.sh` | **PRODUCT** core (DDR candidate) |
| `/media/fat/_Utility/Plex_v2.rbf` | manual / release install | **ROLLBACK** SPI daily |
| `/media/fat/_Utility/Plex_v3.rbf` | v3 fallback | not DDR product |

`/tmp/CORENAME` and `/tmp/RBFNAME` both report **`Plex`** for every build.
They cannot tell `Plex.rbf` from `Plex_v2.rbf`. Confirm identity with
**on-device `md5sum` of the path you loaded**, plus HDMI fingerprint if needed.

A/B the wrong file once and you will blame an innocent bitstream.

## Broken tool you must not trust from the host

`scripts/plexctl.sh reload-v2` is **on-device only**. On the lab host it used to
run `[ -f /media/fat/_Utility/Plex_v2.rbf ]` against the **host** filesystem and
print `ERROR no core at …` (parent: rc=4 ×3) while the file existed on the
MiSTer. That is a **false catastrophe**.

Fixed behaviour:

- On host (no `/dev/MiSTer_cmd`): `rc=4` **NOT_ON_DEVICE** / cannot check —
  **not** “missing”.
- Host-side restore: **`scripts/rollback_v2.sh`** (SSH + menu bounce + live
  `/proc/PID/exe` md5 + HTTP).

## Banned / do-not-ship RBFs

Executable policy: `scripts/rbf_ship_policy.sh`.

**Banned thrash (never ship):**
`8832824e`, `75da8bb1`, `4d6ee356`, `4deaf6cc`, `dabdaeb0`

**Do-not-ship:**
`9eb1431a` (freezes silicon), `ff2e3ca3` (HARD_FAIL timing), `f0d3a385`,
`2890baac`

## Deploy safety (unchanged lab rules)

```bash
DEPLOY_LOAD=none|menu ./scripts/deploy_plex_core.sh path/to/Plex.rbf
```

- `none` (default): copy only  
- `menu`: **ONE** Menu → Plex bounce (preferred reload)  
- Never thrash `load_core` / never kill-9 storms  
- Daemon: `./scripts/deploy_misterplexd.sh /path/to/misterplexd`  
  (named artifact; live root from `readlink -f /proc/PID/exe`; disk **and**
  live exe md5; `n_daemon==1`)

## Promotion commands (parent)

Default is **dry-run**. Nothing touches the device until `PROMOTE_EXECUTE=1`.

```bash
# 0) Plan + local pin/policy (no SSH required if artifacts local)
scripts/promote_ddr_daily.sh plan /path/to/c5382bee.rbf /path/to/e9f79de2-misterplexd

# 1) Stage copies only (parent)
PROMOTE_EXECUTE=1 scripts/promote_ddr_daily.sh stage /path/to/RBF /path/to/daemon

# 2) Stage + ONE menu bounce + verify-live gates (parent)
PROMOTE_EXECUTE=1 scripts/promote_ddr_daily.sh activate /path/to/RBF /path/to/daemon

# 3) Re-check anytime
scripts/promote_ddr_daily.sh verify
# or:
scripts/promotion_gate_check.sh verify-live
```

### Visual is HARD (not optional soft-skip)

Telemetry alone is insufficient (green screen still returns `/resources` 200).
Unset visual on a would-be-green path → **`true rc=8` VISUAL_REQUIRED**.

```bash
# Idle static gate (orange chevron mean ~38.5 vs green mean ~128):
PAIR_IDLE_PNG=/path/to/hdmi-idle.png \
  scripts/promotion_gate_check.sh verify-live

# Or w-instr TREK24 playback counter (do not duplicate that OCR path):
PROMOTE_MOTION_CMD='<w-instr trek24 motion command>' \
  scripts/promotion_gate_check.sh verify-live

# Or any command that exits 0 only on viewed-pixel OK:
PROMOTE_VISUAL_CMD='test -f /path/PASS.stamp' \
  scripts/promotion_gate_check.sh verify-live
```

Matched pairs (executable: `scripts/pair_ship_policy.sh list`):

| id | core | daemon | mode |
|----|------|--------|------|
| spi-v2-hybrid | dfebf2bf | 50f4eb92 | spi |
| spi-v2-release | dfebf2bf | 7cd10b4d | spi |
| ddr-c5382bee | c5382bee | e9f79de2 | ddr |

Any unlisted mix is **REFUSE** before device mutation.

### Gate checklist (executable)

| # | Check | How |
|---|--------|-----|
| 1 | Product core md5 | `md5sum /media/fat/_Utility/Plex.rbf` == `c5382bee…` |
| 2 | Rollback core intact | `md5sum …/Plex_v2.rbf` == `dfebf2bf…` |
| 3 | Live daemon md5 | `md5sum $(readlink -f /proc/<pid>/exe)` == `e9f79de2…` — **not** disk alone |
| 4 | Single daemon | `n_daemon==1` |
| 5 | Live conf | `--conf` from `/proc/<pid>/cmdline` |
| 6 | Companion up | `GET :3005/resources` → 200 |
| 7 | Motion | counter-verified HDMI (w-bw); unset = 77 incomplete |

Every script prints `true rc=N` captured **directly** (never through a pipe).

## One-step ATOMIC rollback (core + daemon pair)

**Parent HW 2026-07-31 defect:** restoring SPI core `dfebf2bf` while leaving DDR
daemon `e9f79de2` live produced a **solid green screen**. `/resources`=200,
`n_daemon=1`, core md5 OK — every non-visual check passed. Partial rollback is
worse than none.

```bash
# Requires SPI daemon artifact (host or on-device .bak). Without it: REFUSE rc=10,
# device untouched.
ROLLBACK_DAEMON=/path/to/misterplexd-50f4eb92 \
  PROMOTE_EXECUTE=1 scripts/rollback_v2.sh restore

# Or restore the DDR pair itself (last verified-good):
PAIR_ID=ddr-c5382bee PAIR_IDLE_PNG=/path/idle.png \
  scripts/rollback_v2.sh restore
```

Sequence (atomic):
1. **preflight** — pair matrix + core pin + daemon artifact available, else exit 10
2. stop daemon
3. install matching daemon if disk pin wrong
4. ONE menu bounce → pair core path
5. start bundle
6. verify pair (core + live exe + n_daemon + HTTP + pair matrix)
7. **HARD visual gate** (idle PNG / w-instr motion) — unset = rc=8

Place pins at `artifacts/daemon-pins/misterplexd.50f4eb92` (see README there).
`deploy_misterplexd.sh` archives outgoing binaries as `misterplexd.<prefix8>.bak`.

## Pre-registered observations (parent HW)

If promotion is correct:

- Product `Plex.rbf` md5 `c5382bee73cecdee8220b811e529c297`
- `Plex_v2.rbf` still `dfebf2bf…` (untouched)
- Live daemon exe md5 `e9f79de217982aff44207664fdb945c5`, `n_daemon=1`
- Live conf path matches the root of that exe (often `misterplex_v2`)
- `/resources` 200; cast playback `vfps≈23.5–23.7`, `clock=av-lock`
- Viewed pixels: crisp text, correct colour, correct letterbox, no shear/green cast
- Rollback restore returns SPI baseline picture without hunting files

If wrong core path was loaded: md5 of `Plex.rbf` may match while HDMI still
shows the old SPI bitstream (or vice versa) — trust path md5 **and** pixels.

## Related scripts

| Script | Role |
|--------|------|
| `scripts/rbf_ship_policy.sh` | banned / do-not-ship / path trap |
| `scripts/promotion_gate_check.sh` | executable gates |
| `scripts/promote_ddr_daily.sh` | plan/stage/activate/verify/rollback |
| `scripts/rollback_v2.sh` | host-side honest V2 restore |
| `scripts/deploy_plex_core.sh` | RBF copy + optional ONE menu bounce |
| `scripts/deploy_misterplexd.sh` | named daemon → live root + live exe md5 |
| `scripts/plexctl.sh` | on-device only bundle control |
