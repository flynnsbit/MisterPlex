# video_regression — running bitstream identity (ITEM 2)

**Lane:** w-lint gate-integrity  
**Branch tip:** see `git rev-parse --short=8 HEAD` on `w-lint-gate-integrity`  
**Rule 0:** host mutation rcs only; parent owns device.

## Verdict (plain)

**No software path today can name the RBF content hash that is *running* in the
FPGA.** `/tmp/CORENAME` and `/tmp/RBFNAME` are always `Plex`. On-disk
`md5sum …/Plex*.rbf` is the SD file, not the fabric. PLXK/PLXS/PLXD are
family/liveness (residue can fake magic). Bank1 peeks (`0x30040000` /
`0x30080000`) are forensic geometry, not identity.

**Therefore verify must not return promote-green without an explicit identity
proof.** That is implemented:

| Outcome | `GATE_RESULT` | true rc | `PROMOTE_OK` |
|---|---|---:|---:|
| Mixed SPI↔DDR pair | `FAIL` | **1** | 0 |
| Coherent pair, no PLXC/VIDREG | `CORE_IDENTITY_UNVERIFIED` | **2** | 0 |
| Coherent + PLXC magic or `VIDREG_CORE_ID=ddr\|spi` | `FULL_PASS` | **0** | 1 |
| Unregistered daemon pin | `FAIL` | **1** | 0 |
| Dead daemon / no claim / stale claim | `FAIL` | **1** | 0 |

Scanners must key **`GATE_RESULT=` / `PROMOTE_OK=` / `true rc=`** — never mid-script
`OK` lines. Banner: `FABRIC_IDENTITY_AUTHORITY=none_until_PLXC`.

## What closed the "mixed black screen passes GREEN" hole

1. **Running-core claim** after `RBFNAME` mtime advances (`plexctl` /
   `video_regression` load path) — missing/stale → FAIL.
2. **(core,daemon) pair family table** — SPI pins must not mix with DDR pins.
3. **Refuse FULL_PASS** when `GATE_CORE_IDENTITY=UNVERIFIED` → **rc=2**, not 0.
4. Daemon liveness via `/proc/PID/exe` `*misterplexd*` (deleted-tolerant) + HTTP.

Host proof: `tests/unit/test_video_regression_liveness.sh` (mutation suite).

## Durable fix (next exclusive fit — coordinate w-fit-1)

PLXC @ doorbell+`0x130` (`mailbox_abi_spec.hpp` `kPlxcOffset` / magic `0x504C5843`).
Design: `docs/core-running-bitstream-identity.md`. Until that RBF ships, rc=2 is
the honest promotion block for fabric content identity.

## Daemon pin (do not weaken)

| Role | Prefix | Note |
|---|---|---|
| CURRENT (artifacts/validated-pair) | `865d4c8a` | w-geom breadcrumb |
| PREV CURRENT DDR | `edc3a46b` | rollback |
| PREV hybrid SPI | `50f4eb92` | SPI undo only |
| Live (parent 2026-08-01) | **`9ce2c2d1`** | **NOT pinned** → verify must FAIL until w-promote runs `pair_pin_update.sh` with full md5 + provenance |

```bash
# Parent after validating live binary (do NOT hand-weaken video_regression):
scripts/pair_pin_update.sh \
  --core-md5 c5382bee73cecdee8220b811e529c297 \
  --daemon-md5 <full 32 from /proc/PID/exe> \
  --note "live 9ce2c2d1 parent-validated YYYY-MM-DD"
```

## Parent device commands (pre-registered expectations)

```bash
# Host mutation suite (no device):
cd .worktrees/w-lint   # or branch tip
bash tests/unit/test_video_regression_liveness.sh; echo "true rc=$?"
# expect: true rc=0

# Live verify (parent only — this lane does not SSH):
scripts/video_regression.sh verify; echo "true rc=$?"
# expect if live daemon still 9ce2c2d1 unpinned:
#   FAIL daemon-live md5='9ce2…' not in accepted pins
#   GATE_RESULT=FAIL  PROMOTE_OK=0  true rc=1
# expect if pinned + coherent pair + no PLXC:
#   GATE_RESULT=CORE_IDENTITY_UNVERIFIED  PROMOTE_OK=0  true rc=2
# expect FULL_PASS only with VIDREG_CORE_ID=ddr|spi or live PLXC word:
#   GATE_RESULT=FULL_PASS  PROMOTE_OK=1  true rc=0
```

Optional identity inject after parent reads doorbell+0x130:

```bash
VIDREG_CORE_ID=ddr scripts/video_regression.sh verify; echo "true rc=$?"
# expect with coherent DDR pair: true rc=0 FULL_PASS
# expect SPI daemon + VIDREG_CORE_ID=ddr: true rc=1 RED_SPI_DAEMON_DDR_CORE
```

## Soft-skip: live-pms-baseline-profile

`tests/hw/test_pms_baseline_profile.sh` exits **77 SKIP-NOT-PASS** when
`PLEX_BASE` / `PLEX_TOKEN` / `MISTERPLEX_BASELINE_KEY` missing. Outside `make unit`.
`scripts/run_with_skip_summary.py` stamps `GATE_SKIP CRITICAL live-pms-baseline-profile`
and **never** maps 77 → PASS (`GATE_RESULT=SKIP_NOT_PASS`).

**To close honestly (not weaken):** set real lab env:

```bash
export PLEX_BASE=http://<pms>:32400
export PLEX_TOKEN=<token>
export MISTERPLEX_BASELINE_KEY=<ratingKey or path key used by pms_baseline_probe>
make "$PWD/build/pms_baseline_probe"   # absolute make target
tests/hw/test_pms_baseline_profile.sh; echo "true rc=$?"
# expect true rc=0 only when delivered H.264 matches Baseline profile
```

Missing key must stay **coverage gap / CRITICAL skip**, never synthetic green.
