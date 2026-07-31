# DDR daily-driver promotion runbook

Parent-owned device work only. Agents produce artifacts and commands; they must
**not** SSH to `192.168.1.183`, deploy, cast, or capture HDMI.

## Why this document exists

The FPGA DDR path renders correct colour/geometry on silicon (240p + native 480p):

| Piece | md5 | Role |
|-------|-----|------|
| RBF | `c5382bee73cecdee8220b811e529c297` | product DDR scanout (**not** do-not-ship) |
| daemon | `edc3a46b9d1c6b86337deb90f896eb0f` (w-geom `7554d6b2`) | primary ARM companion |
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
| **ddr-c5382bee** (PRIMARY) | c5382bee → `Plex.rbf` | edc3a46b9d1c… | **0x30080000** | DDR keys only (never rewrite user `DECODE`) |
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

**Pair = ONE unit:** core `c5382bee` + daemon `edc3a46b` + conf
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
# expect: artifacts/daemon-pins/misterplexd.edc3a46b  = edc3a46b9d1c6b86337deb90f896eb0f
# expect: artifacts/daemon-pins/misterplexd.50f4eb92  = 50f4eb925de10e29172999a565c87684
md5sum artifacts/daemon-pins/misterplexd.edc3a46b
# abort unless full md5 == edc3a46b9d1c6b86337deb90f896eb0f
scripts/pair_ship_policy.sh find-daemon edc3a46b9d1c6b86337deb90f896eb0f   # true rc=0
```

**Abort:** `true rc≠0` or md5 ≠ `edc3a46b9d1c6b86337deb90f896eb0f`.

### 1) Plan dry-run (no device)

```bash
RBF=/home/flynnsbit/Projects/MisterPlex/.agent-work/w-fit/leftedge3-proj/remote_out/w-fit-leftedge3/Plex.rbf
DAE=artifacts/daemon-pins/misterplexd.edc3a46b
md5sum "$RBF"   # expect c5382bee73cecdee8220b811e529c297
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

```bash
# Host has /dev/video0 free; device already on coherent DDR pair + v2 boot hook.
scripts/promotion_gate_check.sh verify-live
echo "true rc=$?"
# expect: auto-capture via hdmi_capture_idle.sh (warm-up baked in)
# expect: OK product-core / OK v2-rollback-core / OK n_daemon=1
# expect: OK live-exe-md5 edc3a46b… / OK boot-hook / PAIR_OK bank1=0x30080000
# expect: OK class=idle_envelope  (NOT grabber_not_ready_exhausted)
# expect: PROMOTE_GATES_OK
# expect: true rc=0
# judge pixels yourself: amber chevron on dark grey — gate cannot replace eyes
# ABORT if true rc≠0 OR pixels wrong
```

Optional explicit capture (same helper the gate uses):

```bash
scripts/hdmi_capture_idle.sh build/pair-visual/idle.png
echo "true rc=$?"   # expect 0
PAIR_IDLE_PNG=$PWD/build/pair-visual/idle.png \
  scripts/promotion_gate_check.sh verify-live
echo "true rc=$?"
```

```bash
# Playback (240p or 480p burst dir — motion instrument already skips warm-up frames):
PROMOTE_MOTION_CAPTURE_DIR=/path/to/png-burst \
  scripts/promotion_gate_check.sh verify-live
echo "true rc=$?"
# expect motion instrument: VERDICT=MOTION_OK true rc=0 → gate true rc=0
# HARD FAIL: rc=1 FREEZE, rc=2 COLOR_FAIL, rc=77 UNSCORED → gate true rc=8
```

**Honesty:** until w-fit-1 core-identity register exists, on-disk RBF md5 +
`/tmp/CORENAME=Plex` cannot prove the *running* bitstream. **Viewed pixels
are the claim.** `video_regression.sh` still cannot see mixed DDR-daemon+SPI-core
as broken (w-lint/w-fit-1); do not treat it as promotion safety alone.

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
| ddr-c5382bee-e9f79de2 | c5382bee | e9f79de2 | ddr keys | hist |
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

## Power-cycle rehearsal (parent; daily driver)

A hook-execution rehearsal is necessary but not sufficient — a real cold boot
is the complete proof. Recoverability over SSH is required.

### Pre-flight (before reboot)

```bash
# On lab host — capture undo artifacts
ssh root@$MISTER_HOST 'md5sum /media/fat/_Utility/Plex.rbf /media/fat/_Utility/Plex_v2.rbf \
  /media/fat/misterplex_v2/bin/misterplexd \
  /media/fat/misterplex_v2/bin/misterplexd_supervise.sh; \
  grep -n misterplex /media/fat/linux/_user-startup.sh; \
  cp -a /media/fat/linux/_user-startup.sh /media/fat/linux/_user-startup.sh.bak.pre-reboot'
# PASS: single line with misterplex_v2/bin/misterplexd_supervise.sh
# PASS: daemon md5 edc3a46b9d1c… ; Plex_v2 still dfebf2bf
# ABORT if hook has misterplex/bin (v1) or multiple supervise lines
```

### Hook-only rehearsal (no reboot) — parent already did this once

```bash
# stop supervisor+daemon, run hook exactly as boot does, measure
ssh root@$HOST 'bash -s' <<'EOS'
set -e
# stop
for d in /proc/[0-9]*; do
  x=$(readlink -f "$d/exe" 2>/dev/null) || continue
  b=$(basename "$x")
  case "$b" in misterplexd) kill ${d#/proc/} 2>/dev/null || true ;; esac
done
pkill -f misterplexd_supervise.sh 2>/dev/null || true
sleep 1
pre=$(for d in /proc/[0-9]*; do
  x=$(readlink -f "$d/exe" 2>/dev/null) || continue
  [ "$(basename "$x")" = misterplexd ] && echo 1
done | wc -l)
echo pre_hook_n_daemon=$pre
# run hook (same as boot)
bash /media/fat/linux/_user-startup.sh
sleep 5
# count via /proc/exe ONLY
post=0; pid=""; md5=""; cmd=""
for d in /proc/[0-9]*; do
  x=$(readlink -f "$d/exe" 2>/dev/null) || continue
  [ "$(basename "$x")" = misterplexd ] || continue
  post=$((post+1)); pid=${d#/proc/}
  md5=$(md5sum "$d/exe" | awk '{print $1}')
  cmd=$(tr '\0' ' ' </proc/$pid/cmdline)
done
echo post_hook_n_daemon=$post
echo pid=$pid md5=$md5
echo cmdline=$cmd
wget -qO- http://127.0.0.1:3005/resources | head -c 80; echo
EOS
# PASS: pre=0 post=1 md5=edc3a46b… conf=…/misterplex_v2/misterplex.conf resources=200
# FAIL → do NOT reboot; fix hook; SPI atomic undo if needed
```

### Real cold boot

1. Confirm SSH still works after boot (`ssh root@$HOST true; echo true rc=$?`).
2. Immediately:

```bash
ssh root@$HOST 'bash -s' <<'EOS'
set +e
echo "=== hook lines ==="
grep -n misterplex /media/fat/linux/_user-startup.sh
echo "=== n_daemon via exe ==="
n=0
for d in /proc/[0-9]*; do
  x=$(readlink -f "$d/exe" 2>/dev/null) || continue
  [ "$(basename "$x")" = misterplexd ] || continue
  n=$((n+1))
  echo pid=${d#/proc/} md5=$(md5sum "$d/exe" | awk '{print $1}') exe=$x
  echo cmdline=$(tr "\0" " " < "$d/cmdline")
done
echo n_daemon=$n
wget -q -O /dev/null -S http://127.0.0.1:3005/resources 2>&1 | awk "/HTTP\//{print; exit}"
EOS
```

**PASS:** `n_daemon=1`, md5 `edc3a46b9d1c…`, exe under `misterplex_v2`,
`--conf …/misterplex_v2/misterplex.conf`, hook has **exactly one**
`misterplex_v2/bin/misterplexd_supervise.sh` line, `/resources` 200, idle
chevron on HDMI (viewed pixels).

**IMMEDIATE ROLLBACK (SSH):**

```bash
# 1) stop everything
ssh root@$HOST 'pkill -f misterplexd_supervise; pkill -x misterplexd; sleep 1'
# 2) restore hook bak if needed
ssh root@$HOST 'cp -a /media/fat/linux/_user-startup.sh.bak.pre-reboot \
  /media/fat/linux/_user-startup.sh'
# 3) atomic SPI or DDR pair restore from lab host
PAIR_ID=ddr-c5382bee PAIR_IDLE_PNG=… scripts/rollback_v2.sh restore
# or SPI:
PAIR_ID=spi-v2-hybrid ROLLBACK_DAEMON=artifacts/daemon-pins/misterplexd.50f4eb92 \
  PAIR_IDLE_PNG=… scripts/rollback_v2.sh restore
```

If SSH is dead: serial console / physical SD — restore
`_user-startup.sh.bak.*` and `Plex_v2.rbf` boot path manually.

### Gate that would have caught the session-long defect

```bash
# FAILS when hook root != live daemon root
PROMOTE_HOOK_BLOB=<(ssh root@$HOST cat /media/fat/linux/_user-startup.sh) \
  scripts/promotion_gate_check.sh verify-live
# or after pair restore: verify includes boot-hook gate automatically
```

## Same-family audit (unstated preconditions)

| Precondition | Was | Now |
|--------------|-----|-----|
| Probe md5 capture pure 32 hex | human/SSH quoting lore | `gate_join_remote_parts` + shape assert |
| HDMI idle frame usable | human must know `-frames:v 1` is wrong | `hdmi_capture_idle.sh` warm-up + `GRABBER_NOT_READY` retry |
| Motion burst not cold | easy to feed 1 junk frame | `hdmi_motion_instrument.py` DEFAULT_WARMUP_SKIP=15 already |
| `/dev/video0` exclusive | busy → mysterious fail | helper runs `fuser` and fails with holders |
| Visual optional | skip → false green | unset visual → hard rc=8; always-run aggregate |
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
grep -n misterplex /media/fat/linux/_user-startup.sh || echo DECOY_INERT

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
| Product core loaded | `/tmp/CORENAME` / disk md5 | still **UNVERIFIED** bitstream (w-fit-1); visual required | gate honesty |
| HDMI frame | parent `-frames:v 1` recipe | `hdmi_capture_idle.sh` warm-up | `pair_visual_gate.sh` |

