# Frame accounting close — parent run card (user 480p drop bug)

Host-side only. **Parent runs all hardware.** Agent never SSHes/casts.

## What this settles

| Question | Instrument | Pass look |
|----------|------------|-----------|
| Are frames missing *outside* pacer Drop + counted publish fail? | `residual_unexplained = frames − presents − drops − publish_misses` | `== 0` every valid round |
| Is interval rate ~ content fps (not cumulative vfps artifact)? | `iv_vfps = d_frames/d_wall` from `supply_bucket` or media deltas | median ≥ `0.90 × content_fps` (DEFAULT_ASSUMED floor) |
| Did the soak stay one session? | `session_epoch` / `process_epoch` / `pid` / EXIT markers | single epoch; else **rc=79** |

## What this does **not** settle

- Glass / HDMI pixels / perceived lipsync (need grabber flash↔beep).
- `av_drift_ms` as lipsync GT — locked band is **setpoint readout** (`avDecide` Hold while `drift+lead < 0`). Use LEAD falsifier below.
- `supply_ratio ≈ 1` as health (asymmetric: **&lt;1** is trustworthy starvation; **~1** is not proof). VOID for socket-starved vs consumer-blocked.
- `drops=N` alone as “N frames lost” — counts **pacer skips only** (`droppedFrames_.fetch_add` after Drop).

## Product citations (this tree)

| Counter | Meaning | Tip locus (approx) |
|---------|---------|-------------------|
| `drops` | A/V-pacer Drop only | `media_player.cpp` ~`:4185` |
| `presentCount_` | success-only publish | ~`:3677` |
| `publishMisses_` | publish fail | ~`:3641` |
| resets | play-path `store(0)` | ~`:3010`/`:3011` |
| residual_arm | `frames-presents-drops` | `frame_ledger.hpp` |
| residual_unexplained | arm − `publish_misses` | same + host tool |
| rate print | `fmtFpsRate` `%.6f` | `media_player.cpp` (no `substr(0,4)`) |
| interval truth | `supply_bucket` `d_*` + `iv_vfps` | `supply_bucket.hpp` |

Parent lore citing `:3141` / `:2312` / `substr(0,4)` is **stale for this tip**.

## rc ladder (align w-instr `daemon_media_ledger.py`)

| rc | Verdict |
|----|---------|
| 0 | `LEDGER_OK` |
| 2 | `LEDGER_RESIDUAL` (unexplained ≠ 0) — **user finding** |
| 3 | `FPS_COLLAPSE` (interval short) |
| 4 | both residual + FPS |
| 78 | `INSUFFICIENT_EVIDENCE` |
| 79 | `SESSION_INVALID` |
| 77 | `NO-DATA` — **never a pass** |

---

## Exact commands (parent)

### 0) Host red-before-green (no device)

```bash
WT=/home/flynnsbit/Projects/MisterPlex/.worktrees/w-avsync-lane
cd "$WT"
python3 tools/frame_accounting_close.py --self-test > .agent-work/w-avsync/frame_acct_selftest.txt 2>&1
echo "true rc=$?"
# expect: SELF_TEST_OK and true rc=0

python3 tools/daemon_media_ledger.py --self-test; echo "true rc=$?"
# expect rc=0 (w-instr convention vendor-copied)
```

### 1) Unit (daemon ledger math)

```bash
cd "$WT"
make "$PWD/build/test_frame_ledger" "$PWD/build/test_supply_bucket"
"$PWD/build/test_frame_ledger"; echo "true rc=$?"
"$PWD/build/test_supply_bucket"; echo "true rc=$?"
```

### 2) Live soak score (one session, direct-play 24.000 fixture)

Pull a **single** `session_epoch` window (mark log before cast). Prefer tip binary that emits atomic `frameLedgerTelemetryFragment` + `supply_bucket` with `residual_unexplained` and `iv_vfps`.

```bash
# After parent pull of daemon log for ONE cast window:
LOG=$OUT/daemon_window.txt   # parent path
python3 tools/frame_accounting_close.py \
  --daemon-log "$LOG" \
  --content-fps 24 \
  --content-fps-src caller_supplied \
  | tee "$OUT/frame_accounting_close.txt"
echo "true rc=$?"
```

**Pass look:** `VERDICT=LEDGER_OK rc=0`, `residual_unexplained=0`, `iv_vfps` median ~24, `coverage` axes DATA, one `session_epoch`.

**User-finding look:** `VERDICT=LEDGER_RESIDUAL rc=2` with `residual_unexplained≠0`.

**Respawn look:** `VERDICT=SESSION_INVALID rc=79` — discard soak.

Optional parallel (same log, w-instr closer without interval FPS):

```bash
python3 tools/daemon_media_ledger.py --log "$LOG"; echo "true rc=$?"
```

### 3) LEAD falsifier (av_drift setpoint — no grabber, no conf edit)

**Claim:** steady `av_drift_ms` band is ~`[-lead, drop)` by `avDecide` construction, not lipsync accuracy.

**Injection:** env only — `MISTERPLEX_AV_PRESENT_LEAD_MS` (`main.cpp` ~626–668). Supervise inherits env; **do not edit conf**.

#### Pre-registered predictions

| Arm | LEAD | P_MEDIAN `av_drift_ms` (n≥8 steady) |
|-----|-----:|--------------------------------------|
| L40a | 40 | **[−45, −25]** (near −40) |
| L20  | 20 | **[−28, −10]** (near −20) |
| L40b | 40 | **[−45, −25]** again |

| Pair | ΔLEAD | **P_Δ median** |
|------|------:|---------------:|
| L40a→L20 | −20 | **[+12, +28]** ms |
| L20→L40b | +20 | **[−28, −12]** ms |

| Observation | Verdict |
|-------------|---------|
| Δ tracks ~±20 and L40b returns | **S3_SETPOINT_TRACKED** — stop quoting drift as health/lipsync |
| All medians stuck in old 40-band | **S3_STATIC_BAND** — still not lipsync GT |
| Banner ≠ env / multi-epoch / n&lt;8 | **UNSCORED rc=77** |

```bash
HOST=${MISTER_HOST:-192.168.1.183}
OUTROOT=$WT/.agent-work/w-avsync/s3_lead_$(date +%Y%m%dT%H%M%S)
mkdir -p "$OUTROOT"

# For LEAD in 40, 20, 40  (tags L40a, L20, L40b):
# 1) Stop supervise cleanly (release flock). No kill -9 thrash.
# 2) Start with env ONLY:
#    export MISTERPLEX_AV_PRESENT_LEAD_MS=$LEAD
#    nohup env MISTERPLEX_AV_PRESENT_LEAD_MS=$LEAD \
#      /media/fat/misterplex_v2/bin/misterplexd_supervise.sh \
#      >/tmp/supervise_lead.log 2>&1 &
# 3) PROVE banner (do not assume):
#    grep -E 'AV_PRESENT_LEAD_MS=|conf not modified' LOG | tail -5
#    expect: AV_PRESENT_LEAD_MS=env:$LEAD
# 4) Cast direct-play ≥30 s steady. ONE session_epoch per arm.
#    Do NOT treat LEAD arms as supply A/B (intermittent ~25%).
# 5) Pull av_drift_ms + session_epoch window → $OUTROOT/<tag>/daemon_tail.txt
# 6) Score:
LOG_A=$OUTROOT/L40a/daemon_tail.txt \
LOG_B=$OUTROOT/L20/daemon_tail.txt \
  bash tools/avsync_lead_falsifier.sh score_logs
echo "lead_falsifier true rc=$?"
```

Host synth RBG for scorer (no device): see `docs/AVSYNC_S3_PARENT_RUN.md`.

---

## Pre-registered soak predictions (publish hit/miss)

| Hypothesis | residual_unexplained | iv_vfps | notes |
|------------|---------------------:|--------:|-------|
| H0 healthy closed path | 0 | ~24 | tonight-like RK6 geometry path |
| H1 uninstrumented loss (user bug) | **≠0** | any | **finding** |
| H2 pacer-only | 0 (arm==drops path closed) | may dip | drops rise; unexplained 0 |
| H3 publish fails only | 0 (arm==publish_misses) | any | explained |
| H4 common ffmpeg stall | 0 | **<<24** | FPS_COLLAPSE rc=3; residual may stay 0 |
| H5 mid-soak respawn | n/a | n/a | **rc=79** INVALID |

**Do not** design single-run A/B for intermittent ~25% supply events — within-run only.
