# S3 LEAD falsifier — parent run card (no grabber, no conf edit)

## Claim under test

rd-review **S3** (surviving): a **bounded** closed-loop error evidences a closed
loop, **not** correct lipsync. `avDriftMs_` is a real measurement
(`audibleClockMs − frameContentMs`, store ~`media_player.cpp:4143-4152`) and
`leadMs` enters **`avDecide` only** (`av_clock.hpp:269-283`) — not circular
bookkeeping. But **bounded drift still does not prove perceived A/V alignment**.

The crossover that settles whether the band is a **setpoint readout**:

> Change `AV_PRESENT_LEAD_MS` 40 → 20 → 40. Band shifts by about Δlead ⇒ drift
> tracks a real physical relationship (servo tracks lead). Band static in the old
> “healthy” cluster ⇒ **refuted as a lipsync proxy** (and stop quoting it as health).

### Code (quoted)

`host/libmisterplex/av_clock.hpp` — `avDecide`:

```cpp
if (driftMs + leadMs < 0)
    return AvAction::Hold;
```

> avDecide HOLDs while drift + lead < 0, so in steady state the *observed*
> av_drift_ms sits in approximately **[-lead, drop)** BY CONSTRUCTION. That band
> is a readout of AV_PRESENT_LEAD_MS, not an independent lipsync accuracy.

Env override (preferred — **device is daily driver; never edit conf**):

`arm/misterplexd/main.cpp:626-633` — `MISTERPLEX_AV_PRESENT_LEAD_MS` wins; logs
*"conf not modified"*. Banner ~`:668`: `AV_PRESENT_LEAD_MS=env:N`.

Injection path (parent-confirmed):  
`/media/fat/misterplex_v2/bin/misterplexd_supervise.sh` spawns `"$BIN" … &`
**inheriting its environment**, holds `flock -n 9` on
`/tmp/misterplexd_supervise.lock`. Restarting the supervisor **with the var
exported in that shell** injects LEAD without writing any device file.

---

## Pre-registered predictions (publish hit/miss)

Arms: **L40a → L20 → L40b** (return-to-baseline). Within each arm, sample only
one `session_epoch` after banner proof. Multi-restart **between** arms is OK
for LEAD (not for intermittent supply A/B).

| ID | LEAD | P_MEDIAN `av_drift_ms` (steady, n≥8) | Falsifies “setpoint readout” if… |
|----|-----:|-------------------------------------:|----------------------------------|
| **L40a** | 40 | **[−45, −25]** (near −40) | median stuck outside while banner=env:40 |
| **L20** | 20 | **[−28, −10]** (near −20) | median still in **[−45, −25]** (old 40-band) |
| **L40b** | 40 | **[−45, −25]** again | fails to return after L20 |

### Pairwise Δ (median_later − median_earlier)

| Pair | ΔLEAD | **P_Δ** (pre-reg) |
|------|------:|------------------:|
| L40a → L20 | −20 | **[+12, +28]** ms (band moves **up** toward 0) |
| L20 → L40b | +20 | **[−28, −12]** ms (band moves **down**) |

### Decision

| Observation | Verdict | Meaning |
|-------------|---------|---------|
| L20 median moves ~+20 vs L40a **and** L40b returns | **S3_SETPOINT_TRACKED** rc=0 | Drift tracks lead; **not lipsync GT** — stop health quotes |
| All three medians stuck in **[−45, −15]** across LEAD | **S3_STATIC_BAND** rc=2 | Does not track lead; still not HDMI lipsync |
| Banner ≠ env / multi-epoch in arm / n&lt;8 | **UNSCORED** rc=77 | Do not invent |

**What confirms “drift is a lead readout / servo tracks setpoint”:**  
Δ(L40a→L20) in [+12,+28] and L40b returns to L40a band.

**What would be needed for lipsync GT:** glass flash+beep (grabber) — not this test.

**What this does NOT settle:** intermittent supply collapse (within-run only;
do not A/B LEAD arms as supply health).

---

## Exact parent procedure (agent does not run these)

No HDMI. No conf write. Direct-play fixture preferred. Capture `true rc=$?`
**directly** (never through a pipe).

```bash
HOST=${MISTER_HOST:-192.168.1.183}
WT=/home/flynnsbit/Projects/MisterPlex/.worktrees/w-avsync-lane
cd "$WT"
OUTROOT="$WT/.agent-work/w-avsync/s3_lead_$(date +%Y%m%dT%H%M%S)"
mkdir -p "$OUTROOT"

# For each LEAD in 40,20,40 with tags L40a, L20, L40b:
# 1) Inject via supervise env ONLY (no conf edit). Parent owns stop/start.
#    SUP=/media/fat/misterplex_v2/bin/misterplexd_supervise.sh
#    Stop supervise cleanly (release flock); do NOT kill -9 thrash.
#    export MISTERPLEX_AV_PRESENT_LEAD_MS=$LEAD
#    nohup env MISTERPLEX_AV_PRESENT_LEAD_MS=$LEAD "$SUP" >/tmp/supervise_lead.log 2>&1 &
#
# 2) PROVE banner (main.cpp ~668) — do not assume env took:
#    grep -E 'AV_PRESENT_LEAD_MS=|conf not modified' LOG | tail -5
#    expect: AV_PRESENT_LEAD_MS=env:$LEAD
#
# 3) Cast DIRECT-PLAY ≥30 s steady. One session_epoch per arm.
#    Do NOT use LEAD arms as supply A/B (intermittent ~25%).
#
# 4) Pull arm window:
#    grep -E 'av_drift_ms=|session_epoch=|AV_PRESENT_LEAD' LOG | tail -n 400 \
#      > $OUTROOT/<tag>/daemon_tail.txt
#    echo "pull true rc=$?"
#
# 5) Median n>=8; score pairwise:
#    Δ40a→20 expect [+12,+28]; Δ20→40b expect [-28,-12]
```

### Host score helpers

```bash
# Servo-only 40→20 (LOG_A=L40a, LOG_B=L20):
LOG_A=$OUTROOT/L40a/daemon_tail.txt LOG_B=$OUTROOT/L20/daemon_tail.txt \
  bash tools/avsync_lead_falsifier.sh score_logs
echo "lead_falsifier true rc=$?"
# expect AV_DRIFT_CIRCULAR rc=0 if delta in [+12,+28]

# Synthetic scorer RBG (20/40/80 shaped):
python3 tools/avsync_score_lead_s3.py --help  # then synth arms as in self docs
bash tools/avsync_lead_falsifier.sh card
```

### Host red-before-green for the scorer (no device)

```bash
cd "$WT"
python3 - <<'PY'
from pathlib import Path
import tempfile, subprocess, sys
td = Path(tempfile.mkdtemp(prefix="s3synth_"))
def write(lead, med, n=20):
    p = td / ("L%d_%d.txt" % (lead, med))
    p.write_text("".join(
        "media: av_drift_ms=%d session_epoch=1.1 process_epoch=1\n" % med
        for _ in range(n)))
    return p
p20, p40, p80 = write(20, -18), write(40, -35), write(80, -72)
r = subprocess.run([sys.executable, "tools/avsync_score_lead_s3.py",
     "--arm=20:%s" % p20, "--arm=40:%s" % p40, "--arm=80:%s" % p80])
print("synth_S3 true rc=%d" % r.returncode)  # expect 0
p20b, p40b, p80b = write(20, -30), write(40, -32), write(80, -28)
r2 = subprocess.run([sys.executable, "tools/avsync_score_lead_s3.py",
     "--arm=20:%s" % p20b, "--arm=40:%s" % p40b, "--arm=80:%s" % p80b])
print("synth_STATIC true rc=%d" % r2.returncode)  # expect 2
PY
```

---

## What replaces drift if S3_SETPOINT_TRACKED

| Metric | Role |
|--------|------|
| multi-axis verdict (markers+supply+ledger+servo) | session health; rc=78 if any NO-DATA |
| `supply_ratio` throughput only | **VOID** local-vs-path |
| w-instr recv_q / wchan | local vs path |
| closed ledger residual (w-instr) | frames−presents−drops |
| HDMI flash+beep when grabber lives | lipsync GT only |
| **Not** `av_drift_ms` alone | void as lipsync / weak as “health” |

---

## Pre-reg fill table (parent)

| Arm | banner | n | median | in P_MEDIAN? | hit/miss |
|-----|--------|--:|-------:|:------------:|:--------:|
| L40a | env:40 | | | | |
| L20 | env:20 | | | | |
| L40b | env:40 | | | | |
| Δ40a→20 | | | | in [+12,+28]? | |
| Δ20→40b | | | | in [−28,−12]? | |
