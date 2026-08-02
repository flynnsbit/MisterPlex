# S3 LEAD falsifier — parent run card (no grabber required)

## Claim under test

rd-review **S3**: steady-state `av_drift_ms` is **not** lipsync accuracy. It sits
near `−AV_PRESENT_LEAD_MS` **by construction**.

### Code (quoted)

`host/libmisterplex/av_clock.hpp` — `avDecide`:

```cpp
if (driftMs + leadMs < 0)
    return AvAction::Hold;
```

Comment at the same site:

> avDecide HOLDs while drift + lead < 0, so in steady state the *observed*
> av_drift_ms sits in approximately **[-lead, drop)** BY CONSTRUCTION. That band
> is a readout of AV_PRESENT_LEAD_MS, not an independent lipsync accuracy.

Telemetry also stamps `av_drift_role=servo_error_not_lipsync`.

Default LEAD = **40** (`presentLeadMs_`). Env override:
`MISTERPLEX_AV_PRESENT_LEAD_MS` (preferred; conf untouched).

---

## Pre-registered predictions (publish hit/miss)

| ID | LEAD | P_MEDIAN `av_drift_ms` (S3) | Falsifies S3 if… |
|----|-----:|----------------------------:|------------------|
| **P20** | 20 | **[−22, −12]** | median stays in **[−45, −15]** (old “healthy” cluster) |
| **P40** | 40 | **[−42, −28]** | median leaves envelope **[−45, −15]** without tracking −40 |
| **P80** | 80 | **[−82, −60]** | median still ~[−40,−21] |

### Pairwise Δ under S3 (median_B − median_A)

| Pair | ΔLEAD | **P_Δ** |
|------|------:|--------:|
| 40 → 20 | −20 | **[+12, +28]** ms (band moves **up** toward 0) |
| 40 → 80 | +40 | **[−55, −25]** ms (band moves **down**) |

### Decision

| Observation | Verdict | Meaning |
|-------------|---------|---------|
| All three medians in S3 P_MEDIAN **and** pairwise Δ in P_Δ | **S3_CONFIRMED** rc=0 | Stop quoting drift as health/lipsync |
| All three medians stuck in **[−45, −15]** across LEAD | **S3_FALSIFIED** rc=2 | Open-loop quantity (still not HDMI lipsync) |
| Multi-`session_epoch` / banner≠env / n&lt;5 samples | **UNSCORED** rc=77 | Do not invent |

**What confirms “drift is just the setpoint”:** P20/P40/P80 all hit their bands
and Δ(40→20) ∈ [+12,+28].

**What falsifies it:** changing LEAD does **not** move the band (H_REAL cluster).

---

## Exact parent commands (agent does not run these)

No HDMI required. Prefer **direct-play** fixture (not transcoder-starved).
One `session_epoch` per arm. Capture `true rc=$?` **directly**.

```bash
HOST=${MISTER_HOST:-192.168.1.183}
WT=/home/flynnsbit/Projects/MisterPlex/.worktrees/w-avsync-lane   # or main checkout on tip
cd "$WT"

# --- Arm helper: set LEAD via env, restart daemon YOUR way, cast, capture ---
# Banner MUST show: AV_PRESENT_LEAD_MS=env:N   (not a stale conf value)

run_arm () {
  local LEAD="$1"
  local OUT="$WT/.agent-work/w-avsync/s3_L${LEAD}_$(date +%Y%m%dT%H%M%S)"
  mkdir -p "$OUT"
  echo "OUT=$OUT LEAD=$LEAD" | tee "$OUT/meta.txt"

  # 1) On device: export MISTERPLEX_AV_PRESENT_LEAD_MS=$LEAD and restart misterplexd
  #    Parent owns supervisor path. Then verify banner:
  # ssh root@$HOST 'grep -E "AV_PRESENT_LEAD_MS=" LOG | tail -3'
  # expect: AV_PRESENT_LEAD_MS=env:20|40|80

  # 2) Cast DIRECT-PLAY content (rk of healthy 480p blip / RK6-class is fine;
  #    S3 does not need flash markers). Wait until playing ~30–60 s.

  # 3) Continuity latch (multi-epoch → UNSCORED)
  bash tools/avsync_capture_session_epoch.sh | tee "$OUT/epoch.txt"
  echo "epoch true rc=$?"

  # 4) Daemon slice — use the LIVE log root (v2 before v1). Line-mark optional.
  #    Pull only this arm's window (after restart).
  ssh root@$HOST 'grep -E "av_drift_ms=|av_servo_setpoint|session_epoch=|process_epoch=|AV_PRESENT_LEAD|supply_ratio=" \
    /media/fat/misterplex_v2/misterplexd.log /media/fat/misterplex/misterplexd.log 2>/dev/null \
    | tail -n 500' >"$OUT/daemon_tail.txt"
  echo "pull true rc=$?"

  # 5) Quick median (never pipe the score rc)
  python3 - <<PY
import re, statistics
from pathlib import Path
t = Path("$OUT/daemon_tail.txt").read_text(errors="replace")
v = [float(x) for x in re.findall(r"\\bav_drift_ms=(-?[0-9.]+)", t)]
epochs = sorted(set(re.findall(r"session_epoch=(\\S+)", t)))
print("n", len(v), "median", statistics.median(v) if v else "NO-DATA",
      "min", min(v) if v else "NO-DATA", "max", max(v) if v else "NO-DATA",
      "session_epochs", epochs, "src=measured")
if len(epochs) > 1:
    print("WARN multi session_epoch — arm UNSCORED")
PY
  echo "$OUT"
}

# Run three arms (restart + cast between each):
#   run_arm 40
#   run_arm 20
#   run_arm 80
# Record OUT40 OUT20 OUT80 paths from meta.
```

### Score (after all three arms)

```bash
python3 tools/avsync_score_lead_s3.py \
  --arm 20:$OUT20/daemon_tail.txt \
  --arm 40:$OUT40/daemon_tail.txt \
  --arm 80:$OUT80/daemon_tail.txt
echo "s3_score true rc=$?"
# S3_CONFIRMED → 0
# S3_FALSIFIED / mixed → 2
# missing/short → 77
```

### Host red-before-green for the scorer (no device)

```bash
cd "$WT"
python3 - <<'PY'
from pathlib import Path
import tempfile, subprocess, sys
# Synthetic S3-shaped arms
td = Path(tempfile.mkdtemp(prefix="s3synth_"))
def write(lead, med, n=20):
    p = td / f"L{lead}.txt"
    # tight cluster around med
    lines = [f"media: av_drift_ms={med} session_epoch=1.1 process_epoch=1\n"] * n
    p.write_text("".join(lines))
    return p
p20, p40, p80 = write(20, -18), write(40, -35), write(80, -72)
r = subprocess.run(
    [sys.executable, "tools/avsync_score_lead_s3.py",
     f"--arm=20:{p20}", f"--arm=40:{p40}", f"--arm=80:{p80}"],
)
print(f"synth_S3 true rc={r.returncode}")  # expect 0
# H_REAL stuck cluster
p20b, p40b, p80b = write(20, -30), write(40, -32), write(80, -28)
r2 = subprocess.run(
    [sys.executable, "tools/avsync_score_lead_s3.py",
     f"--arm=20:{p20b}", f"--arm=40:{p40b}", f"--arm=80:{p80b}"],
)
print(f"synth_H_REAL true rc={r2.returncode}")  # expect 2
PY
```

---

## What replaces drift if S3_CONFIRMED

| Metric | Role |
|--------|------|
| `supply_ratio` + `starve_locus` | starvation / transport |
| closed ledger residual (w-instr `daemon_media_ledger.py`) | frames−presents−drops |
| HDMI flash↔beep (when grabber lives) | lipsync GT only |
| **Not** `av_drift_ms` / old `clock=av-lock` | void as accuracy |

---

## Pre-reg for tonight’s parent arms (fill after run)

| Arm | banner LEAD | n | median | in P_MEDIAN? | hit/miss |
|----:|------------:|--:|-------:|:------------:|:--------:|
| 20 | env:20 | | | | |
| 40 | env:40 | | | | |
| 80 | env:80 | | | | |
| Δ40→20 | | | | ∈[+12,+28]? | |
