# DDR daily-driver promotion runbook

Parent-owned device work only. Agents produce artifacts and commands; they must
**not** SSH to `192.168.1.183`, deploy, cast, or capture HDMI.


## Deploy rc contract (parent 2026-08-01 false-negative)

**Defect hit on daily driver:** post-conditions all PASSED but script returned
`true rc=1` because it sourced missing `boot_hook_policy.sh` **after** success messaging.

**Contract now:**
1. Deps required **before any device I/O** (`daemon_backup_policy.sh`,
   `deploy_misterplexd_lib.sh`; unless `DEPLOY_SKIP_BOOT_HOOK=1` also
   `boot_hook_policy.sh` + `misterplexd_supervise.sh`) — missing → `true rc=2`.
2. Remote live success prints **`REMOTE_LIVE_OK`** (not final).
3. **`DEPLOY_OK` only at absolute end** after live post-conditions + boot-hook + geometry.
   If you see `DEPLOY_OK`, process rc **must** be 0.
4. Both directions: `bash tests/unit/test_deploy_misterplexd.sh`
   (`dir-green-deploy-ok-rc0`, `dir-red-no-deploy-ok`, `miss-dep-rc2`).



## Minimum rollback post-conditions (answer to rd-review)

rd-review open item: *"`deploy_misterplexd.sh` exits 0 on failed deploy; `restore_misterplexd_prev.sh` has no enforced post-conditions."*

**Status on this branch (`fix/rollback-honest`):** both fixed. Deploy: early deps + live `/proc/exe` + terminal `DEPLOY_OK` only. Restore: no `PAIR_ID` → `true rc=10`; with `PAIR_ID` → `rollback_v2.sh` which enforces the HARD set below.

### HARD (any fail ⇒ rollback FAILED, rc ≠ 0)

| ID | Check | Why |
|----|-------|-----|
| **H1** | `n_daemon==1` via `/proc/[0-9]*` + `comm`/`argv0` basename `misterplexd`, then `readlink -f $p/exe` | No pgrep (busybox). No cmdline substring (flock trap). |
| **H2** | live exe md5 == intended daemon pin | Disk path alone is ETXTBSY-class blind. |
| **H3** | loaded core **path** md5 == intended pin (`Plex.rbf` or `Plex_v2.rbf`) | Product vs SPI naming trap. |
| **H4** | `pair_policy_check(core,daemon)==PAIR_OK` | bank1 SPI `0x30040000` vs DDR `0x30080000` — mixed = black/green. |
| **H5** | HTTP `:3005/resources` ∈ {200,204} | Necessary, **not** sufficient alone. |
| **H6** | conf md5 == pre-swap backup (byte-exact) | USER-OWNED; path from cmdline `--conf` only. |
| **H7** | `PRESENT=fpga\|both` (assert, never rewrite) | `fb0` freezes idle (`initPresent` skips `fpga_.open`). |

### SOFT only (record; never sole PASS)

- **S1 `CORENAME=Plex`** — parent proposed as HARD; **disagree**. Every `Plex*.rbf` reports Plex. Useless as pair proof.
- Disk `misterplexd` md5 without live `/proc/exe`.
- `/resources` alone (mixed pair can still answer 200).

### CLAIM (product)

- Viewed pixels. Telemetry never enough.
- On **c5382bee**: `frames_done` packs `bank_vsync_count` (vsync free-run). ARM STALE at `fpga_spi.cpp:1388-1394` stays "live" if swaps freeze. **Do not** claim core health from `frames_done` alone.

Print the set: `./scripts/rbf_swap_preflight.sh min-postcond; echo "true rc=$?"`

## Pre-RBF-swap preflight (before w-fit-1 / next product core)

Deployed product `c5382bee…` has the STALE-blind defect above. **Snapshot before swap; prove rollback against snapshot.**

```bash
cd .worktrees/rollback-honest   # or merge fix/rollback-honest
git rev-parse --short HEAD

# 1) Host plan + banned check (set NEW_RBF when fit lands)
NEW_RBF=/path/to/new_Plex.rbf ./scripts/rbf_swap_preflight.sh plan
echo "true rc=$?"

# 2) Device READ-ONLY snapshot (parent only)
OUT=./build/preflight-$(date -u +%Y%m%dT%H%M%SZ)
PREFLIGHT_EXECUTE=1 OUT=$OUT NEW_RBF=$NEW_RBF   ./scripts/rbf_swap_preflight.sh snapshot
echo "true rc=$?"
# artifacts: snapshot.txt conf_pre.conf conf_pre.md5 pins.env rollback_cmds.sh

# 3) ONE menu deploy discipline
DEPLOY_LOAD=none ./scripts/deploy_plex_core.sh "$NEW_RBF"
DEPLOY_LOAD=menu DEPLOY_SKIP_COPY=1 ./scripts/deploy_plex_core.sh
# never thrash load_core; never kill -9 storms

# 4) If bad — atomic SPI undo (core+daemon+conf)
PAIR_ID=spi-v2-hybrid \
  ROLLBACK_DAEMON=${ROLLBACK_DAEMON:-artifacts/daemon-pins/misterplexd.50f4eb92} \
  PAIR_CONF_RESTORE_FILE=$OUT/conf_pre.conf \
  PAIR_IDLE_PNG=/path/to/idle.png \
  scripts/rollback_v2.sh restore
echo "true rc=$?"

# 5) Score rollback vs snapshot HARD set
PREFLIGHT_EXECUTE=1 SNAP=$OUT \
  EXPECT_DAEMON_MD5=<spi_or_bak_pin> \
  EXPECT_CORE_MD5=dfebf2bfd08dd70b473b587dd7e81848 \
  ./scripts/rbf_swap_preflight.sh verify-rollback
echo "true rc=$?"
```

Host both-direction unit (no device):
`bash tests/unit/test_rbf_swap_preflight.sh` — green mock ⇒ rc0; red n_daemon/http/conf/PRESENT ⇒ rc9.

## RBF rollback before next fit

Product: `/media/fat/_Utility/Plex.rbf` (`c5382bee…`). Prove rollback on host first:

```bash
PAIR_ID=spi-v2-hybrid bash scripts/rollback_v2.sh plan; echo "true rc=$?"
# Parent execute when needed — ONE menu bounce, conf PAIR_CONF_RESTORE_FILE byte-exact:
PAIR_ID=spi-v2-hybrid ROLLBACK_DAEMON=artifacts/daemon-pins/misterplexd.50f4eb92   PAIR_CONF_RESTORE_FILE=./misterplex.conf.userbak PAIR_IDLE_PNG=/path/idle.png   scripts/rollback_v2.sh restore
```

`restore_misterplexd_prev.sh` without `PAIR_ID` → `true rc=10`.

## Deploy / restore fail-loud (rd-review 2026-08-01)

Main-tree defects (do **not** use `scripts/` from pre-fix main):
- `deploy_misterplexd.sh` rebuilt/stripped, installed v1 root, no live `/proc/exe` md5,
  could print success without post-conditions.
- `restore_misterplexd_prev.sh` restored daemon only, **zero** post-conditions (B8).

**This branch:**
- Deploy fails non-zero on: copy/stage fail, disk md5≠host, live `/proc/PID/exe` md5≠host,
  `n_daemon≠1`, HTTP `:3005/resources`≠200, conf md5 mutated (USER-OWNED).
- Host re-asserts `deploy_assert_postconditions` from captured `POST_*` lines.
- `restore_misterplexd_prev.sh` requires `PAIR_ID` and execs `rollback_v2.sh restore`
  (atomic core+daemon+conf+boot). Without `PAIR_ID` → `true rc=10` refuse.

Red-before-green: `tests/unit/test_deploy_misterplexd.sh`, `tests/unit/test_rollback_honest.sh`.

## Measurement claims — do NOT flip daily driver

### Fleet 2026-08-01 — vertical 240-row ceiling (ESTABLISHED FACT)

Parent-run on hardware, pre-registered, 5/5 predictions hit. Codec **out of loop**
(`push_frame --ddr --pattern` → product `FpgaSpi::publishDdrFrame`) on RBF **`c5382bee`**:

| pattern | mean | std | note |
|---------|-----:|----:|------|
| mid_grey CONTROL | 137.0 | 0.00 | path sound |
| even_black | 7.0 | 0.00 | solid BLACK |
| even_white | 255.0 | 0.00 | solid WHITE |
| odd_black | 255.0 | 0.00 | solid WHITE **INVERTED** |
| odd_white | 7.0 | 0.00 | solid BLACK **INVERTED** |

**`std=0.00` is the result:** no stripes — odd store rows are **entirely absent**.
`store_y = py*2` fetches even rows only → **50.0% of rows never reach display**.

**Scope limit:** proves **vertical** ceiling only. Horizontal 529-of-640 is **arithmetic
only** (`clk_sys=20 MHz`; 20e6/60/524=636&lt;640) — **not** pixel-proven here.

**After w-geom T7 (unique rows 240→480):** re-run **identical** card; solid-field
collapse **must break**. That is the glass proof. This card is the **"before" bank**.

**Daily promote:** `rbf_policy_daily_promote_ready c5382bee` → **`true rc=11`**
(`DAILY_PROMOTE_READY=NO`). `promote_ddr_daily.sh stage|activate` hard-refuses unless
`PROMOTE_ALLOW_KNOWN_DEFECTS=1` (parent+user only). Lab RBF deploy still allowed
(not on banned list) — **do not confuse lab OK with daily ready**.

### SAFETY — frames_done / STALE (affects user **today** on c5382bee)

`fpga_spi.cpp:1388-1394` proves mailbox liveness via `frames_done` advances.
On `c5382bee`, that field is a **vsync counter** (`bank_vsync_count`) — advances
even if bank swaps freeze → frozen picture reported healthy; `[STALE]` never fires.
Plausible root of original playback-freeze class. **Rollback path must stay proven
before any new RBF** (see preflight).

### Retractions (STOP building on these)

| Claim | Status |
|-------|--------|
| "22 skips / 1.54% frame loss" | **ERROR 18 WITHDRAWN** (30 fps capture, zero sampling margin) |
| "1 skip / 0.070%" | **ERROR 19 WITHDRAWN** (min hold = one refresh; 60 fps negative margin) |
| `p_ge50 = 14.5%` | **UNSCORED**, not a MISS (σ≫mean; raw log gone — re-measure) |
| "Two independent instruments agree" (`p_ge50` + `acf lag1`) | **WITHDRAWN** — two stats of **one** series; preemption manufactures both |
| `drops=0` as display claim | **VOID** — ARM-supply only; `unaccounted` is `residual` printed twice; `residual≡publish_misses`; **no ledger field observes the FPGA** |
| Any metric from PLXD `frames_done` on c5382bee | **VOID** until new RBF lands |
| Defensible prior bound | Frame loss was **bounded, not measured**; vertical defect now **measured on glass** |
| Judder | Still a separate measured presentation defect; not a promote PASS |

### Standing rule (fleet) — field names

**Publish no field name without its derivation in the same breath.**
Pattern of four: `frames_done` / `presents` / `HISTORICAL FAULT` / `unaccounted` —
names that do not match derivation.

**Pre-retraction check (mandatory):** (1) name the artifact the finding was about
and the artifact the retraction evidence came from — if they differ, retraction is
**INVALID**; (2) device behaviour claims retract only on device-derived evidence;
(3) a comment saying "fixed" is a claim — cite commit **and** live artifact.

### ARM CPU% (required on every soak report)

User rule: report ARM CPU% with every soak. Reference split (of 200% onecpu):
**86.6%** total — MiSTer 78.0, ffmpeg 60.5, misterplexd 24.3.
Promotion checks must stay light on-device (no heavy probes).

### Conf safety (USER-OWNED — assert, never rewrite)

**Current live (parent restored after raster lab 2026-08-01):** conf md5
**`20d31046…`** byte-identical to pre-lab backup; reads **`DECODE=320x240`**
(user-owned; do not "correct" to 624x480). Daemon pid 7585, live exe prefix
**`7c991e47`**, `n_daemon=1`, `:3005/resources` OK, `CORENAME=Plex`.

Prior lab conf class `7f06132f…` (`DECODE=624x480`, …) may return; **always**
resolve path from `/proc/PID/cmdline --conf` and md5 the live file.

| Key | Rule |
|-----|------|
| conf file | Back up + restore **byte-exactly**. Never normalise to a "validated default". |
| `PRESENT` | Must be **`fpga` or `both`**. `PRESENT=fb0` is **wrong**: `initPresent()` skips `fpga_.open()` → DDR frame store never repainted → idle freezes. Deploy asserts this (does not rewrite). |
| `IDLE_SCREEN` | Promotion captures want **`logo`** (static Plex logo). Screensaver contaminates test captures (user). Assert via `DEPLOY_ASSERT_IDLE_LOGO=1` on promote; never silent rewrite. |
| `DECODE` | User-owned. Snapshot pre-swap; restore byte-exact. Never force 624x480. |

### RBF mechanical refuse

`scripts/deploy_plex_core.sh` calls `rbf_policy_check_md5` and **refuses** banned/do-not-ship:
banned `{8832824e,75da8bb1,4d6ee356,4deaf6cc,dabdaeb0}` + do-not-ship `{9eb1431a,ff2e3ca3,f0d3a385,2890baac}`.
`DEPLOY_LOAD=none|menu`; ONE menu bounce only; never thrash `load_core`.
`bootcore=lastcore` is **user-authorised for testing** (do not flip without user).

**Daily vs lab:** `c5382bee` is **not banned** (lab experiments / before-bank OK) but
`rbf_policy_daily_promote_ready` → rc=11 until vertical fix glass-proven.

### Live daemon pin (parent 2026-08-01 post-raster restore)

`/proc/<pid>/exe` md5 prefix **`7c991e47`** (full via `readlink -f` on device).
Prior pins still accepted for pair matrix: `36b89bcb`, `3883f5ab`, `edc3a46b`,
`e9f79de2`, `b981fd20`. Verify live exe — never disk alone.

## Probe capture (V2_MD5 `set +e` glue)

Parent: `got=dfebf2bf…81848set +e`. Cause: `$(frag1)$(frag2)` strips trailing
newlines. Fix: **one** remote heredoc (`promotion_gate_check.sh dump-remote-live`
to audit). Shape assert rejects contaminated digests — never fuzzy-trim.

## OPEN conditions (do not mark closed)

| ID | Condition | Status |
|----|-----------|--------|
| **P1** | **Real power-cycle / cold boot** of daily driver | **OPEN** — hook execution rehearsed; kernel boot path **not** exercised. Parent will not reboot without asking user. |
| P2 | Live `verify-live` on worktree HEAD (not `961dc724`) against device | Parent-owned; glue fix is host-proven |
| P3 | Running-bitstream ID beyond PLXS magic+seq | Partial — PLXS+seq required; CORENAME useless; file md5 = disk only |
| P4 | HDMI A/V offset bimodality (~117 ms SESSION-LATCHED device defect) | **OPEN / out of promote scope** — not closable by pair md5/PLXS/pixels gates; see below |
| P5 | Daemon pin file `5996385a` in `artifacts/daemon-pins/` on host | Optional; full md5 constant is in policy |

**P1 is NOT closed. BLOCKED ON USER APPROVAL** — parent will not power-cycle the daily driver without explicit user consent. Hook rehearsal ≠ kernel cold boot. Runbook step + post-conditions are ready; execution waits on the user.


## Cold-boot survival (P1) — blocked on user approval

**Do not execute without explicit user approval.** Daily driver at 192.168.1.183.

When authorised, parent runs (agents never SSH):

```bash
# 0) Pre-capture (evidence baseline)
#    n_daemon, live exe md5, conf md5, CORE product md5, /resources, HDMI idle frame

# 1) Power cycle the DE10-Nano (physical or authorised PDU) — NOT ssh reboot unless user says so

# 2) Wait for network + Main (~150s)

# 3) Post-conditions (all required; any fail = P1 FAIL):
#    - n_daemon == 1  (enumerate /proc, readlink -f exe basename misterplexd; not cmdline/flock)
#    - md5sum "$(readlink -f /proc/$PID/exe)" == expected pair daemon pin
#    - product core md5 on disk == pair core pin (c5382bee…) OR intentional SPI undo
#    - conf md5 == pre-cycle backup (USER-OWNED byte-exact)
#    - PRESENT=fpga|both ; IDLE_SCREEN as user left it (prefer logo)
#    - curl -s -o /dev/null -w '%{http_code}' http://$HOST:3005/resources  → 200
#    - boot hook: exactly one misterplexd_supervise for live root; decoy inert
#    - VIEWED pixels: idle logo/playback OK (not green/black freeze)
#    - ARM CPU% snapshot during soak (user-required)
```

Host helper (no device mutate): `PAIR_ID=ddr-c5382bee scripts/power_cycle_pair_rehearsal.sh plan`

## Why this document exists

The FPGA DDR path renders correct colour/geometry on silicon (240p + native 480p):

| Piece | md5 | Role |
|-------|-----|------|
| RBF | `c5382bee73cecdee8220b811e529c297` | product DDR scanout (**not** do-not-ship) |
| daemon | `3883f5ab8744e070e7b0820c6b9b4376` (rollbacks: edc3a46b, 5996385a, b981fd20, e9f79de2) | primary ARM companion |
| conf | `DDR_YUV_FORCE_SCALE=1` + `FFMPEG_SWS_FLAGS=fast_bilinear` | pair half (480p correctness) |
| hist daemon | `e9f79de217982aff44207664fdb945c5` | previous DDR pin (on-device `.bak`) |

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

## B8 — atomic pair only (power-cycle honesty)

`scripts/restore_misterplexd_prev.sh` is **DISABLED** (`true rc=10`). It restored
daemon-only and left core/geometry mismatched (SPI bank1 `0x30040000` vs DDR
`0x30080000` → black/green screen; HTTP still 200).

| Pair id | core | daemon | bank1 | conf |
|---------|------|--------|-------|------|
| **ddr-c5382bee** (PRIMARY) | c5382bee → `Plex.rbf` | 3883f5ab8744… | **0x30080000** | DDR keys only (never rewrite user `DECODE`) |
| spi-v2-hybrid (undo) | dfebf2bf → `Plex_v2.rbf` | 50f4eb92 | **0x30040000** | strip DDR keys |

**bank1 for shipping DDR pair is `0x30080000`.** The FPGA DDR frame store in
`c5382bee` is synthesis-fixed at **624×480** bank geometry; bank1 is therefore
`0x30080000` regardless of the live conf `DECODE=` value (user-owned; 320x240
or 624x480). SPI `frame_store` daily is the other geometry (`0x30040000`). Mixing
them is the black/green-screen class. Conf promote/rollback must **back up and
restore faithfully** — only pair keys `DDR_YUV_FORCE_SCALE` / `FFMPEG_SWS_FLAGS`
are enforced; never silently normalise `DECODE`.

`n_daemon` is counted only when `basename(readlink -f /proc/PID/exe)==misterplexd`
(not cmdline — `flock` embeds the path and lied as ERROR 14).

Running bitstream identity is **UNVERIFIED** until w-fit-1 PLXC @ DOORBELL+0x130.
`/tmp/CORENAME=Plex` for every Plex*.rbf. Coordinate with w-lint: video_regression
must report that, not GREEN on mixed pairs.

Dry-run power-cycle table (no device):

```bash
PAIR_ID=ddr-c5382bee scripts/rollback_v2.sh plan
# expect: POWER-CYCLE states A–E, true rc=0
```

## Numbered parent runbook (exact commands)

**Pair = ONE unit:** core `c5382bee` + daemon `3883f5ab` + conf
`DDR_YUV_FORCE_SCALE=1` `FFMPEG_SWS_FLAGS=fast_bilinear`. Half-state
(DDR daemon + SPI core, or binaries without conf) = black/green screen that
can still return `/resources` 200. **Abort on any non-zero `true rc=`.**

Device is already often on this pair ad-hoc — promotion makes it *reversible*
and conf-complete, not a wild install.

### 0) Fetch pins (host; once)

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/rollback-honest   # or main
scripts/fetch_daemon_pins.sh both
# expect: true rc=0
# expect: artifacts/daemon-pins/misterplexd.3883f5ab = 3883f5ab8744e070e7b0820c6b9b4376
# expect: artifacts/daemon-pins/misterplexd.edc3a46b  = edc3a46b9d1c6b86337deb90f896eb0f (rollback)
# expect: artifacts/daemon-pins/misterplexd.50f4eb92  = 50f4eb925de10e29172999a565c87684 (SPI)
md5sum artifacts/daemon-pins/misterplexd.3883f5ab
# abort unless full md5 == 3883f5ab8744e070e7b0820c6b9b4376
scripts/pair_ship_policy.sh find-daemon 3883f5ab8744e070e7b0820c6b9b4376   # true rc=0
```

**Abort:** `true rc≠0` or md5 ≠ `3883f5ab8744e070e7b0820c6b9b4376`.

### 1) Plan dry-run (no device)

```bash
RBF=/home/flynnsbit/Projects/MisterPlex/.agent-work/w-fit/leftedge3-proj/remote_out/w-fit-leftedge3/Plex.rbf
DAE=artifacts/daemon-pins/misterplexd.3883f5ab
md5sum "$RBF"   # expect c5382bee73cecdee8220b811e529c297
md5sum "$DAE"   # expect 3883f5ab8744e070e7b0820c6b9b4376
PROMOTE_EXECUTE=0 scripts/promote_ddr_daily.sh plan "$RBF" "$DAE"
# expect: PROMOTE_POLICY_LOCAL_OK  true rc=0
# expect: PAIR_OK id=ddr-c5382bee
```

**Abort:** policy refuse, banned prefix, wrong pin.

### 2) Preflight atomic restore path (must be green before mutate)

```bash
PAIR_ID=ddr-c5382bee scripts/rollback_v2.sh preflight
# expect: PREFLIGHT_OK … true rc=0
# (daemon pin present on host or already on disk)
```

**Abort:** `true rc=10` (missing pin — device untouched; fetch and retry).

### 3) Snapshot SPI undo path (optional but recommended)

Confirm `Plex_v2.rbf` still `dfebf2bf` and SPI pin available:

```bash
# on device (parent SSH):
md5sum /media/fat/_Utility/Plex_v2.rbf
# expect dfebf2bfd08dd70b473b587dd7e81848
```

### 4) Activate promote (device; ONE path only)

**Do not use** untrusted `deploy_misterplexd` rebuild paths. Prefer atomic pair
restore of the already-verified live pair (conf+daemon+core), or promote script:

```bash
# A) If device already coherent DDR (common): re-assert pair + conf only
PAIR_ID=ddr-c5382bee PAIR_IDLE_PNG=/path/idle.png \
  scripts/rollback_v2.sh restore
# sequence: stop → daemon if needed → conf ddr keys → ONE menu → Plex.rbf → start → verify+visual
# expect: PAIR_RESTORE_OK id=ddr-c5382bee  true rc=0

# B) Formal promote from host artifacts:
PROMOTE_EXECUTE=1 scripts/promote_ddr_daily.sh activate "$RBF" "$DAE"
# then apply conf (if activate does not yet push conf, restore does):
PAIR_ID=ddr-c5382bee scripts/rollback_v2.sh restore
```

**Abort mid-flight:** any install/load `true rc≠0` — do **not** load core if
daemon/conf half failed. Run SPI rollback (step 7).

### 5) Telemetry verify (necessary, not sufficient)

```bash
scripts/promotion_gate_check.sh verify-live
# without visual → expect true rc=8 VISUAL_REQUIRED (correct fail-closed)
# Probe capture: md5 fields must be exactly 32 hex. A value like
#   V2_MD5=<32hex>set +e
# is SHAPE FAIL (rc=3) — never fuzzy-trimmed. Fixed by gate_join_remote_parts
# (bash $(...) strips trailing newlines and used to glue the next script line).
```

On device, parent should also see:

```text
n_daemon=1
md5sum $(readlink -f /proc/<pid>/exe)   # edc3a46b…
grep -E 'DDR_YUV_FORCE_SCALE|FFMPEG_SWS_FLAGS' $(... --conf path...)
# DDR_YUV_FORCE_SCALE=1
# FFMPEG_SWS_FLAGS=fast_bilinear
# PAIR_OK … bank1=0x30080000   (DDR synth-fixed 624×480; not DECODE-dependent)
```

### 6) Visual / motion verify (claim success ONLY here)

Visual **always runs** even if an earlier check failed (aggregate; never
"skip visual — prior failed").

**Grabber warm-up is owned by the gate** (parent 2026-07-31): MacroSilicon
`/dev/video0` emits ~11–15 uniform junk frames. A bare
`ffmpeg -frames:v 1` produced `mean_rgb=7,7,7 std=0` and a **false RED**
while the device was showing a correct chevron. The blessed helper is
`scripts/hdmi_capture_idle.sh` (`select=gte(n,20)`). The idle gate classifies
that junk as `GRABBER_NOT_READY` and **retries a warmed capture** before any
device verdict; thresholds are never loosened.

#### Single command (preferred — no warm-up lore)

When `/dev/video0` is free the gate **requires BOTH** positive Plex idle
chevron ID **and** motion (`PROMOTE_MOTION_CAPTURE_DIR` or
`PROMOTE_MOTION_CMD`). Idle-only is incomplete (`PROMOTE_ALLOW_IDLE_ONLY=1`
escape only). Conf keys and PLXS mailbox magic are hard-required.

```bash
# Host has /dev/video0 free; device on coherent DDR pair + real S99user hook.
# Parent: cast a short TREK24 (or feed motion burst dir) so motion can score.
PROMOTE_MOTION_CAPTURE_DIR=/path/to/png-burst \
  scripts/promotion_gate_check.sh verify-live
echo "true rc=$?"
# expect: OK product-core-disk c5382bee… (ON-DISK only) / OK v2-rollback-core …
# expect: OK live-exe-md5 edc3a46b… (from readlink -f /proc/PID/exe)
# expect: OK conf-profile=ddr (DDR_YUV_FORCE_SCALE + FFMPEG_SWS_FLAGS)
# expect: OK PLXS_MAGIC=0x504C5853 + OK PLXS_SEQ advanced (fabric executing)
#          (magic alone can be leftover; seq advance is required by default)
# expect: OK boot-hook-path-from-init USER_SCRIPT=.../user-startup.sh
# expect: OK class=plex_idle_chevron  (MENU/magenta/green → rc=8)
# expect: OK visual-idle+motion (both observed)
# expect: PROMOTE_GATES_OK / true rc=0
# ABORT if true rc≠0 OR viewed pixels wrong
```

Idle-only (incomplete — not a full promote claim):

```bash
PROMOTE_ALLOW_IDLE_ONLY=1 scripts/promotion_gate_check.sh verify-live
echo "true rc=$?"
```

Optional explicit idle capture (same helper the gate uses):

```bash
scripts/hdmi_capture_idle.sh build/pair-visual/idle.png
echo "true rc=$?"   # expect 0
PAIR_IDLE_PNG=$PWD/build/pair-visual/idle.png \
  PROMOTE_MOTION_CAPTURE_DIR=/path/to/png-burst \
  scripts/promotion_gate_check.sh verify-live
echo "true rc=$?"
```

**Honesty:** disk RBF md5 alone cannot prove the *running* bitstream (parent
captured MENU colour bars while gate still saw product md5). Gate now requires
**PLXS** magic at `0x300FF100` (only `ddr_frame_store` publishes) plus positive
idle chevron structure (rejects MENU fixture) plus motion. Still **view the
pixels** — gate cannot replace eyes.

### 7) Atomic SPI rollback (if promote wrong)

```bash
PAIR_ID=spi-v2-hybrid \
  ROLLBACK_DAEMON=artifacts/daemon-pins/misterplexd.50f4eb92 \
  PAIR_IDLE_PNG=/path/idle.png \
  scripts/rollback_v2.sh restore
# expect: strips DDR_YUV_FORCE_SCALE=1, loads Plex_v2.rbf, daemon 50f4eb92
# expect: PAIR_RESTORE_OK  true rc=0
# abort if true rc=10 (missing pin) — device left UNTOUCHED
```

### Host unit evidence (agent-run, no device)

| Test | true rc |
|------|---------|
| `tests/unit/test_rollback_honest.sh` | 0 |
| `tests/unit/test_promotion_gates.sh` | 0 |
| `tests/unit/test_video_regression_liveness.sh` | 0 |

Red-before-green covered: mixed pair rc=3, missing pin rc=10, missing conf rc=3,
missing visual rc=8, motion 77→8.

## Promotion commands (short)

Default is **dry-run**. Nothing touches the device until `PROMOTE_EXECUTE=1`.

```bash
scripts/promote_ddr_daily.sh plan "$RBF" "$DAE"
PROMOTE_EXECUTE=1 scripts/promote_ddr_daily.sh activate "$RBF" "$DAE"
PAIR_ID=ddr-c5382bee PAIR_IDLE_PNG=... scripts/rollback_v2.sh restore
```

### Visual is HARD (not optional soft-skip)

Telemetry alone is insufficient (green screen still returns `/resources` 200).
Unset visual on a would-be-green path → **`true rc=8` VISUAL_REQUIRED**.

**Motion `rc=77` (UNSCORED) is also a HARD FAIL** for promotion claim success —
never treat it as inconclusive-carry-on. Parent measured a broken green burst
that still reported `VERDICT=UNSCORED` while `green_cast_frames>0`. Until
w-instr always maps colour fail → `rc=2`, the gate maps `77 → 8`.

```bash
# Idle static gate (mean + uniformity; reject flat green):
#   good orange chevron: mean ~38.5, structured
#   broken mixed pair:   mean ~128.4, uniform green
PAIR_IDLE_PNG=/path/to/hdmi-idle.png \
  scripts/promotion_gate_check.sh verify-live

# Playback motion (w-instr TREK24 instrument — do not duplicate OCR):
PROMOTE_MOTION_CAPTURE_DIR=/path/to/png-burst \
  scripts/promotion_gate_check.sh verify-live
# → python3 tools/hdmi_motion_instrument.py <dir>
#    rc=0 MOTION_OK only; rc=1 FREEZE / 2 COLOR_FAIL / 77 UNSCORED → claim fail

# Or any command that exits 0 only on viewed-pixel OK:
PROMOTE_VISUAL_CMD='test -f /path/PASS.stamp' \
  scripts/promotion_gate_check.sh verify-live
```

Matched pairs (executable: `scripts/pair_ship_policy.sh list`):

| id | core | daemon | conf | mode |
|----|------|--------|------|------|
| **ddr-c5382bee** | c5382bee | **edc3a46b** | ddr keys | **PRIMARY promote** |
| ddr-c5382bee-509b0c75 | c5382bee | 509b0c75 (stamped ba2ec313) | ddr keys | **default lab ship** |
| ddr-c5382bee-e9f79de2 | c5382bee | e9f79de2 | ddr keys | hist — **480p REGRESS** parent HW 2026-08-02; do not default-ship |
| spi-v2-hybrid | dfebf2bf | 50f4eb92 | strip ddr keys | SPI undo |
| spi-v2-release | dfebf2bf | 7cd10b4d | strip ddr keys | SPI release |

Any unlisted mix is **REFUSE** before device mutation. Conf is part of the pair:
restoring binaries without conf keys (or leaving `DDR_YUV_FORCE_SCALE=1` on SPI)
is a half-state.

### Gate checklist (executable)

| # | Check | How |
|---|--------|-----|
| 1 | Product core md5 | `md5sum /media/fat/_Utility/Plex.rbf` == `c5382bee…` |
| 2 | Rollback core intact | `md5sum …/Plex_v2.rbf` == `dfebf2bf…` |
| 3 | Live daemon md5 | `md5sum $(readlink -f /proc/<pid>/exe)` == `e9f79de2…` — **not** disk alone |
| 4 | Single daemon | `n_daemon==1` |
| 5 | Live conf | `--conf` from `/proc/<pid>/cmdline` |
| 6 | Companion up | `GET :3005/resources` → 200 |
| 7 | Visual / motion | idle PNG or `PROMOTE_MOTION_CAPTURE_DIR`; unset/`rc=77` → **hard rc=8** |

Every script prints `true rc=N` captured **directly** (never through a pipe).

## Daemon pins (gitignored)

Decision: **do not commit** the ~MB ARM ELFs. README tracked; binaries ignored.

```bash
scripts/fetch_daemon_pins.sh both   # parent only
scripts/pair_ship_policy.sh find-daemon e9f79de2   # true rc=0
scripts/pair_ship_policy.sh find-daemon 50f4eb92
```

Missing pin → restore **refuses** with fetch instructions (`true rc=10`), device
untouched. See `artifacts/daemon-pins/README.md`.

## One-step ATOMIC rollback (core + daemon pair)

**Parent HW 2026-07-31 defect:** restoring SPI core `dfebf2bf` while leaving DDR
daemon `e9f79de2` live produced a **solid green screen**. `/resources`=200,
`n_daemon=1`, core md5 OK — every non-visual check passed. Partial rollback is
worse than none.

**Live device is often already on the DDR pair** (ad-hoc testing). Primary
recovery is restore of that pair, not only SPI:

```bash
# PRIMARY — restore last verified-good DDR pair (product Plex.rbf + e9f79de2):
PAIR_ID=ddr-c5382bee PAIR_IDLE_PNG=/path/idle.png \
  scripts/rollback_v2.sh restore

# SECONDARY — SPI hybrid (requires pin 50f4eb92 on host or device .bak):
PAIR_ID=spi-v2-hybrid \
  ROLLBACK_DAEMON=artifacts/daemon-pins/misterplexd.50f4eb92 \
  PAIR_IDLE_PNG=/path/idle.png \
  scripts/rollback_v2.sh restore
```

Sequence (atomic):
1. **preflight** — pair matrix + core pin + daemon artifact available, else exit 10
2. stop daemon
3. install matching daemon if disk pin wrong
4. ONE menu bounce → pair core path (`Plex.rbf` or `Plex_v2.rbf` per PAIR_ID)
5. start bundle
6. verify pair (core + live exe + n_daemon + HTTP + pair matrix)
7. **HARD visual gate** (idle PNG / motion) — unset or motion `rc=77` → rc=8

`deploy_misterplexd.sh` archives outgoing binaries as `misterplexd.<prefix8>.bak`.

## Pre-registered observations (parent HW)

If promotion is correct:

- Product `Plex.rbf` md5 `c5382bee73cecdee8220b811e529c297` (**disk** pin — not executing proof)
- Executing core: PLXS magic `0x504C5853` + **advancing** `mbox_seq` (not CORENAME; not file md5 alone)
- `Plex_v2.rbf` still `dfebf2bf…` (untouched SPI undo)
- Live daemon exe md5 from `readlink -f /proc/PID/exe` equals pair pin; `n_daemon=1`
- Live conf path from `/proc/PID/cmdline --conf` under live root (user-owned bytes)
- `/resources` 200
- **Viewed pixels** (required): idle chevron CC geometry and/or motion instrument
  `MOTION_OK` on warmed HDMI capture — not telemetry
- Rollback restore returns SPI baseline picture without hunting files

### RETRACTED — never promotion/soak PASS criteria

Parent fleet broadcast 2026-07-31 (measured on five same-config 480p runs):

- **`clock=av-lock` and `av_drift_ms` are BLIND to real lip-sync.** Daemon series
  stayed within ~0.8 ms while HDMI offset clusters were ~120 ms apart. `av_drift_ms`
  is the servo reading its own setpoint (`host/libmisterplex/av_clock.hpp`).
- **Do not quote av-lock / av_drift_ms as promote, soak, or pair PASS.**
- Lip-sync (if claimed) is judged only by external pixel+audio:
  `tools/avsync_measure_hdmi.py` — parent-owned; not a soft gate in this package.
- Steady-state drop sawtooth also falsified (startup drops only). Drop totals are
  not a rate-mismatch proof; do not build promote gates on drop slope.

Promotion package success = pair identity + boot coherence + **pixels/motion** +
PLXS execution proof. It does **not** claim calibrated lip-sync.

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

## Power-cycle rehearsal (parent; daily driver)

A hook-execution rehearsal is necessary but not sufficient — a real cold boot
is the complete proof. Recoverability over SSH is required. **SSH to the daily
driver can return rc=255 mid-flight** — every mutating step must be launchable
detached on-device.

### Generated runbook (preferred)

```bash
scripts/power_cycle_pair_rehearsal.sh plan          # full procedure + exact ssh/scp
scripts/power_cycle_pair_rehearsal.sh host-preflight
echo "true rc=$?"   # expect 0 before any reboot
```

On-device check (S99user-derived REAL hook, decoy inert, n_daemon via exe,
conf from cmdline, optional PLXS):

```bash
scp scripts/on_device_pair_boot_check.sh root@$HOST:/media/fat/misterplex_v2/bin/
ssh root@$HOST 'chmod +x /media/fat/misterplex_v2/bin/on_device_pair_boot_check.sh
  nohup /media/fat/misterplex_v2/bin/on_device_pair_boot_check.sh rehearse-hook     >/media/fat/misterplex_v2/boot-check.nohup.out 2>&1 &'
# later:
ssh root@$HOST 'cat /media/fat/misterplex_v2/boot-check-report.txt
  echo true rc=$(cat /media/fat/misterplex_v2/boot-check-report.txt.rc)'
```

**PASS rehearse/postboot:** `n_daemon=1`, live md5 `edc3a46b…`, conf under
`misterplex_v2` from cmdline `--conf`, REAL hook **exactly one**
`misterplex_v2` supervise line, decoy `_user-startup.sh` **inert**,
`/resources` 200, PLXS magic when `devmem` present.

**Host visual (warm-up owned by helper — never bare `-frames:v 1`):**

```bash
scripts/hdmi_capture_idle.sh build/pair-visual/idle.png
echo "true rc=$?"
PAIR_IDLE_PNG=$PWD/build/pair-visual/idle.png PAIR_VISUAL_NO_RECAPTURE=1 \
  scripts/pair_visual_gate.sh idle
echo "true rc=$?"   # expect OK class=plex_idle_chevron
```

### IMMEDIATE ROLLBACK if postboot FAIL (SSH alive)

```bash
# 1) stop daemons via /proc/exe (not cmdline substring)
# 2) restore REAL hook + conf from pre-reboot snapshot (byte-faithful)
# 3) atomic pair:
PAIR_ID=ddr-c5382bee \
  PAIR_CONF_RESTORE_FILE=build/conf-restore/misterplex.conf.bak \
  PAIR_IDLE_PNG=build/pair-visual/idle.png \
  scripts/rollback_v2.sh restore
echo "true rc=$?"
# SPI undo:
# PAIR_ID=spi-v2-hybrid ROLLBACK_DAEMON=artifacts/daemon-pins/misterplexd.50f4eb92 \
#   PAIR_IDLE_PNG=... scripts/rollback_v2.sh restore
```

`scripts/restore_misterplexd_prev.sh` remains **DISABLED** (`true rc=10`) —
half-restore of daemon without core is an unpaired black screen
(bank1 `0x30040000` vs `0x30080000`).

If SSH is dead: serial/SD — restore `user-startup.sh` bak (path from S99user),
conf bak, and menu-load `Plex_v2.rbf` if needed.

### Gate that would have caught the session-long defect

```bash
# Path MUST come from S99user (not the _user-startup.sh decoy).
# FAILS when REAL hook root != live daemon root
# Red: archived v1 hook body  Green: current v2 hook body
scripts/promotion_gate_check.sh verify-live
echo "true rc=$?"
```

## Same-family audit (unstated preconditions)

| Precondition | Was | Now |
|--------------|-----|-----|
| Probe md5 capture pure 32 hex | human/SSH quoting lore | `gate_join_remote_parts` + shape assert |
| HDMI idle frame usable | human must know `-frames:v 1` is wrong | `hdmi_capture_idle.sh` warm-up + `GRABBER_NOT_READY` retry |
| Motion burst not cold | easy to feed 1 junk frame | `hdmi_motion_instrument.py` DEFAULT_WARMUP_SKIP=15 already |
| `/dev/video0` exclusive | busy → mysterious fail | helper runs `fuser` and fails with holders |
| Visual optional / idle-only | auto-idle hid motion; MENU passed luma band | dual idle+motion; `plex_idle_chevron` positive ID; MENU fixture rc=8 |
| Conf keys REQUIRE | soft NOTE when unset | hard FAIL (`PROMOTE_REQUIRE_CONF_KEYS=1` default) |
| Executing bitstream | disk RBF md5 only | PLXS magic `0x504C5853` at `0x300FF100` |
| Conf path | assume misterplex/ | resolve from `/proc/pid/cmdline --conf` |
| n_daemon | cmdline substring | `/proc/pid/exe` basename only |


## P0 — boot hook path is derived from S99user (2026-07-31)

MiSTer init `/etc/init.d/S99user` sets `USER_SCRIPT="/media/fat/linux/user-startup.sh"`.
The underscore file `_user-startup.sh` is a **decoy** — not executed. The gate once
returned `BOOT_HOOK_OK` against the decoy while the real file still had v1 supervise
(stale `54f1d916`). Nearly stranded the daily driver on reboot.

**Policy**
1. Resolve path from `USER_SCRIPT=` in S99user only. Missing/unparseable → hard FAIL (no guess).
2. Decoy `_user-startup.sh` must be **inert** (zero misterplexd autostart lines).
3. Promote/rollback install writes the REAL path and strips the decoy.

**Parent live check after reboot**
```bash
# On device or via ssh — observe what init actually names:
grep -E '^[[:space:]]*USER_SCRIPT=' /etc/init.d/S99user
REAL=$(sed -n 's/^[[:space:]]*USER_SCRIPT=//p' /etc/init.d/S99user | tail -1 | tr -d '"')
echo "REAL=$REAL"
grep -n misterplex "$REAL" || true
echo "--- decoy (must be inert) ---"
REAL=$(sed -n 's/^[[:space:]]*USER_SCRIPT=//p' /etc/init.d/S99user | tail -1 | tr -d '"')
grep -n misterplex "$REAL" || echo DECOY_INERT

# Host gate (single command; auto visual if /dev/video0 free):
scripts/promotion_gate_check.sh verify-live
echo "true rc=$?"
# expect: OK boot-hook-path-from-init USER_SCRIPT=/media/fat/linux/user-startup.sh
# expect: OK boot-hook matches root=... path=/media/fat/linux/user-startup.sh
# expect: OK boot-hook decoy inert
# expect: PROMOTE_GATES_OK  true rc=0
```

### Observation audit (path-trust vs system-consulted)

| Check | Was (trust) | Now (observe) | file |
|-------|-------------|---------------|------|
| Boot hook path | hardcoded `_user-startup.sh` | `USER_SCRIPT` from `/etc/init.d/S99user` | `boot_hook_policy.sh`, `promotion_gate_check.sh`, `rollback_v2.sh`, `deploy_misterplexd.sh` |
| Decoy `_user-startup.sh` | ignored / treated as real | must be inert | same |
| Live daemon binary | on-disk path | `readlink -f /proc/PID/exe` md5 | `pair_live_probe.inc.sh` |
| Live conf | assumed `misterplex.conf` | `/proc/PID/cmdline --conf` | same |
| n_daemon | cmdline substring | exe basename `misterplexd` only | same |
| Product core loaded | `/tmp/CORENAME` / disk md5 | PLXS mailbox magic (+ optional seq advance); MENU frame rejected by chevron ID | `promotion_gate_check.sh`, `pair_visual_gate.sh` |
| Idle identity | luma band; then centroid bounds (20% false RED on screensaver) | CC geometry (dominance/aspect/fill) — **no position** | `pair_visual_gate.sh` |
| HDMI frame | parent `-frames:v 1` recipe | `hdmi_capture_idle.sh` warm-up | `pair_visual_gate.sh` |
| Conf keys | soft NOTE | hard fail closed | `promotion_gate_check.sh` |
| Motion vs idle order | auto-idle elif hid motion | both required when grabber present | `promotion_gate_check.sh` |



## What product-core-disk md5 proves (and does not)

| Claim | True? |
|-------|-------|
| `/media/fat/_Utility/Plex.rbf` bytes match pin | YES — that is all file md5 proves |
| FPGA is executing that bitstream | **NO** — MENU can be loaded while file is correct |
| Execution proof | PLXS `0x504C5853` @ `0x300FF100` **and** advancing `mbox_seq` (default required) |
| Identity on HDMI | `plex_idle_chevron` + motion instrument |

`PROMOTE_REQUIRE_PLXS_SEQ_ADVANCE` defaults to **1**. Stuck seq + valid magic = hung/leftover core class.

## What product-core-disk md5 proves (and does not)

| Claim | True? |
|-------|-------|
| `/media/fat/_Utility/Plex.rbf` bytes match pin | YES — that is all file md5 proves |
| FPGA is executing that bitstream | **NO** — MENU can still be loaded while the file is correct |
| Execution proof | PLXS `0x504C5853` @ `0x300FF100` **and** advancing `mbox_seq` (default required) |
| Identity on HDMI | `plex_idle_chevron` + motion instrument |

`PROMOTE_REQUIRE_PLXS_SEQ_ADVANCE` defaults to **1**. Stuck seq + valid magic =
hung/leftover core class. File md5 is still useful as a pin check on the
rollback/product slots; it is never execution evidence.

## Idle chevron ID is translation-invariant (screensaver)

`IDLE_SCREEN=screensaver` (mode=2) bounces the logo. Centroid bounds caused a
**20% false RED** on healthy frames (cy up to 0.806). Identity is now one
dominant orange connected component with chevron-like `dom_frac`, `aspect`,
and bbox `fill` (~0.28 notched). Position is diagnostic only.

STOPPED transport overlay over the chevron is **accepted** by the idle stage
(logo still present). OSD-absent is a separate concern for w-osd-hires.


## deploy_misterplexd honesty (re-task)

Measured traps encoded in `scripts/deploy_misterplexd.sh`:

1. **Exact artifact only** — `DEPLOY_REBUILD=0` default; host md5 of the named path is what must appear on live `/proc/PID/exe`.
2. **Target root** from live `readlink -f /proc/PID/exe` (and live `--conf`); refuse cross-root when live is v2 and override is v1.
3. **Stop then start** — stop supervisors + daemon by `/proc/PID/comm` + argv0 basename, **not** cmdline substring (flock embeds `misterplexd`).
4. **Install** — scp to `/tmp/misterplexd.deploy.$$`, verify stage md5, `mv -f` onto final path (ETXTBSY-safe). stderr not suppressed.
5. **Post** — `n_daemon==1` via comm/argv0; live exe md5; live `--conf` under target root; `/resources` 200.
6. **Boot hook** — real `USER_SCRIPT` from S99user; decoy `_user-startup.sh` left inert; both v1/v2 paths grepped so dual boot lines fail closed.

Atomic pair promote/rollback remains `scripts/rollback_v2.sh` / `promote_ddr_daily.sh` (core+daemon+user conf+boot). Half-restore `restore_misterplexd_prev.sh` → rc=10.

### V2_MD5 probe glue (never fuzzy-trim)

`$(ssh …)` strips trailing newlines, so a remote `echo V2_MD5=$md5` fused with the next `set +e` produced `…81848set +e` (parent 2026-07-31). Fix: `gate_join_remote_parts` + `gate_assert_md5_shape` (exactly 32 hex). Contaminated values fail closed — do not strip noise.

## Conf restore md5 equality (user-owned)

`rollback_v2.sh apply_pair_conf` always:

1. Computes `CONF_WANT_MD5` of the exact bytes about to install (restore-file = backup; merge-keys = merge output only touching pair keys).
2. Byte-backups the live conf first (`CONF_BAK_MD5`).
3. `mv` installs, then requires `CONF_NEW_MD5 == CONF_WANT_MD5` (`CONF_MD5_MATCH_OK`). Mismatch → hard fail (no silent default rewrite).
4. `PAIR_CONF_RESTORE_FILE` additionally requires equality to the parent-supplied backup md5 (e.g. user conf `7f06132f…` with `DECODE=624x480`).

## V2_MD5 capture (blind-and-RED class)

Fixed by `gate_join_remote_parts` + host-side refuse of `MD5=<32hex>set` in joined remote script + `gate_assert_md5_shape` before equality. Wrong pure 32-hex still fails equality (`FAIL v2-rollback-core`). Contaminated values fail shape — never fuzzy-trim.


## Daemon pin chain (2026-07-31 evening)

| prefix8 | role | full md5 (when known) |
|---------|------|------------------------|
| **5996385a** | **CURRENT** live DDR (w-instr) | `5996385a57c6af142b8e732a39b36a4a` |
| b981fd20 | on-device bak rollback | prefix until pin filed |
| edc3a46b | prior DDR primary | `edc3a46b9d1c6b86337deb90f896eb0f` |
| e9f79de2 | first silicon-correct DDR | `e9f79de217982aff44207664fdb945c5` |
| 50f4eb92 | SPI hybrid undo | `50f4eb925de10e29172999a565c87684` |

`video_regression.sh` and `pair_ship_policy.sh` accept CURRENT + documented
rollbacks only. Unknown md5 → FAIL (mixed-pair catch). Primary pair id
`ddr-c5382bee` resolves daemon to CURRENT.

User conf md5 **`7f06132f`** is USER-OWNED (`misterplex.conf.bak.horigin`) —
restore with `PAIR_CONF_RESTORE_FILE=…` only; never rewrite DECODE/PRESENT/IDLE.

## Deploy trap — rename-before-kill (sibling of ETXTBSY)

Parent-measured failure mode:

```sh
mv $B/misterplexd $B/misterplexd.bak.b981fd20   # BAD if process still live
mv $B/misterplexd.new $B/misterplexd
# kill loop on readlink -f /proc/*/exe matching *misterplexd → MATCHES NOTHING
# because exe path is now …/misterplexd.bak.b981fd20
```

Disk looks correct; old daemon keeps serving. **Required order:**

1. Capture target PIDs (`/proc/PID/comm == misterplexd` or argv0 basename).
2. Stop/kill those PIDs (no `pgrep` — not on busybox MiSTer).
3. Only then stage+`mv` the new binary (or `cp` to `.bak` then replace).
4. Start one daemon; verify `md5sum "$(readlink -f /proc/$NEWPID/exe)"` == host artifact.
5. Assert `n_daemon==1` by the same comm/argv0 rule.

`scripts/deploy_misterplexd.sh` stops before install and uses stage+`mv`.

## Running bitstream (promotion blocker honesty)

- File md5 of `Plex.rbf` = **product-core-disk** only.
- `/tmp/CORENAME` = `Plex` for every build — **not** a bitstream id.
- Executing proof required: **PLXS** magic `0x504C5853` @ bank mailbox + **advancing**
  `mbox_seq` (`PROMOTE_REQUIRE_PLXS_SEQ_ADVANCE=1` default). SPI core + DDR daemon
  is `PAIR_REFUSE` and must not go green.

## Power-cycle evidence checklist (parent; ask user before reboot)

Pre (SSH session stable):

```bash
# on device (or ssh one-liners) — capture true rc DIRECTLY
md5sum /media/fat/_Utility/Plex.rbf /media/fat/_Utility/Plex_v2.rbf
readlink -f /proc/$(…misterplexd pid…)/exe | xargs md5sum
tr '\0' ' ' < /proc/PID/cmdline; echo
n_daemon via comm==misterplexd count
wget -q -O /dev/null -S http://127.0.0.1:3005/resources 2>&1 | head -1
grep USER_SCRIPT= /etc/init.d/S99user
grep misterplex /media/fat/linux/user-startup.sh
# decoy must be inert:
grep -E 'misterplexd' /media/fat/linux/_user-startup.sh || echo DECOY_INERT
md5sum /media/fat/misterplex_v2/misterplex.conf
# conf must still be user bytes (7f06132f…)
devmem 0x300FF100 32; sleep 0.05; devmem 0x300FF100 32   # PLXS + seq change
```

Detached arm (survive SSH drop):

```bash
# host prepares:
scripts/power_cycle_pair_rehearsal.sh plan
# on device: copy on_device_pair_boot_check.sh; run under nohup; then reboot
```

Post (after boot + ~30s):

```bash
# same probes as pre; expect:
#   product core c5382bee, v2 dfebf2bf untouched
#   n_daemon==1, live exe md5 == 5996385a… (or chosen pair pin)
#   conf md5 == pre bak (user-owned)
#   hook exactly one v2 supervise line; decoy inert
#   /resources 200
#   PLXS magic + seq advance
# host:
PAIR_ID=ddr-c5382bee bash scripts/promotion_gate_check.sh verify-live; echo "true rc=$?"
# warmed capture (NOT -frames:v 1 alone):
scripts/hdmi_capture_idle.sh /path/idle.png; echo "true rc=$?"
PAIR_IDLE_PNG=/path/idle.png scripts/pair_visual_gate.sh idle; echo "true rc=$?"
# motion if cast available — MOTION_OK rc=0 only (77=fail)
```

Soft-skip rc=77 is never PASS. Do not quote av-lock/av_drift as soak PASS.

## HDMI A/V ~117 ms bimodality (parent 2026-07-31 — DEVICE CONFIRMED)

**Not a promotion gate. Not closable by this package.**

Parent one-session / three-capture test (thresholds pre-registered before run):

| capture | window | median offset (ms) | n_pairs |
|---------|--------|--------------------:|--------:|
| 1 | ~12–112 s | -293.33 | 99 |
| 2 | ~148–248 s | -296.00 | 99 |
| 3 | ~284–360 s | -292.67 | 74 |

- Within-session spread **3.33 ms** vs between-cluster separation **~117 ms** (~35×).
- Verdict: **SESSION-LATCHED** on the device (instrument multi-input confound ruled out for this design).
- State latched by first flash/beep pair (~1.4 s); stable for whole session.
- Daemon `av_drift_ms` / `clock=av-lock` remain **BLIND** (RETRACTED as promote/soak PASS).
- Common-mode ~25 ms startup transient (first-10 s vs last-60 s) in **both** clusters — short A/V windows are biased.

**Promotion PASS does not claim lip-sync.** Success = pair identity + boot + user conf bytes + PLXS exec + viewed pixels/motion. Closing 117 ms is a separate rig program.

Instrument value labels when referenced from this package:
- `measured` — from device/capture this run
- `caller-supplied` — parent env / pin
- `DEFAULT_ASSUMED` — code default (never present as measurement)


## Daemon deploy order (supervisor-safe, parent 2026-08-01)

Device runs a durable supervisor that races stop-everything-then-start. Required order:

1. **Capture** daemon PIDs (`/proc/PID/comm == misterplexd` or argv0 basename) — **before** any rename
2. **Stage** new bytes → `/tmp/misterplexd.deploy.$$` (exact host artifact; `DEPLOY_REBUILD=0`)
3. **cp** live → `.prev-deploy` / `.bak.<prefix8>` (never `mv` the live name away first)
4. **mv** stage onto live path (OK while old inode still executing)
5. **kill only captured PIDs** — leave supervisor alive
6. **Supervisor restarts** child; wait until live md5 matches host
7. **Verify** `md5sum "$(readlink -f /proc/NEWPID/exe)"` == host; `n_daemon==1`

Never: kill-then-manual-start when supervise is live. Never: md5 disk alone. Never: pgrep. Never: cmdline substring.

Primary pair: core `c5382bee` + daemon `edc3a46b…`. Also accepted: 5996385a, b981fd20, e9f79de2.

## Parent hand-sequence (mechanised — do not improvise)

```
# Host: stage named by measured host md5, ship, verify live exe only
HOST_MD5=$(md5sum build/arm/misterplexd | awk '{print $1}')   # expect 3883f5ab8744e070e7b0820c6b9b4376
HOST_P8=${HOST_MD5:0:8}
DEPLOY_EXPECT_MD5=$HOST_MD5 \
  ./scripts/deploy_misterplexd.sh build/arm/misterplexd
# true rc=0 required; prints STAGE_MD5, OUTGOING_MD5, ARCHIVED_DAEMON …bak.<out_p8>, live exe md5
```

On-device order encoded in `deploy_misterplexd.sh` (parent 2026-08-01):
1. CAPTURE PIDs (`comm`/`argv0`/`pidof` OK; **never** cmdline substring; **no pgrep**)
2. `scp` → `…/bin/misterplexd.stage.<host_p8>`; **md5 staged first**
3. `cp -p` live → `misterplexd.bak.<measured_outgoing_p8>` **and** `misterplexd.<p8>.bak`
4. `mv` stage → live (not `cp` — ETXTBSY)
5. `kill` **captured** PIDs only; supervisor restarts
6. Verify `md5sum $(readlink -f /proc/NEW/exe)` + `n_daemon==1` + conf from cmdline `--conf`

## Backup naming / retention (decidable rollback)

```bash
# Host: print policy + inventory plan (no device delete)
./scripts/daemon_backup_policy.sh retention-policy
./scripts/daemon_backup_policy.sh inventory-plan
./scripts/daemon_backup_policy.sh name-for 3883f5ab8744e070e7b0820c6b9b4376
```

**Rule:** a path is a rollback pin only if `name_prefix8 == content_md5_prefix8` (VERIFIED_PIN).
MISLABEL / UNVERIFIED must not be used as `ROLLBACK_DAEMON` until re-pinned from measured content.
Agents never delete on device — parent runs inventory and quarantine renames.

User conf (byte-exact, never normalise):
`7f06132f0c00e90b35141bdc0c60ccc9` @ `/media/fat/misterplex_v2/misterplex.conf`
(always resolve conf from `/proc/PID/cmdline --conf`, never guess root).

