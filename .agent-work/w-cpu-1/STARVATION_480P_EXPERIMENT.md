# 480p under-production: CPU starvation CONFIRM / REFUTE

**User bug:** frames dropped / A-V feel wrong on 480p.  
**Parent measured:** wall 30.88s @24fps → 741 expected; `frames=713` (under-prod **28**); pacer `drops=7`; HDMI skips ~2.5%.  
**Hypothesis H (parent, not a finding):** ARM CPU-starved; ffmpeg cannot hold 24 fps; Main 83–100%onecpu scavenger implicated.  
**This card:** measurement to **confirm or refute** H.

Elastic scavenger stands: **Main %onecpu alone does not prove starvation.** Only runqueue wait and/or a causal reclaim that lifts vfps does.

---

## 0. Two worlds

| world | ffmpeg when behind | schedstat | if Main SUSPEND |
|-------|--------------------|-----------|-----------------|
| **A — wanted CPU** | RUNNABLE on CFS queue | **high** `dwait` / `agg_wait_frac` | vfps **rises** toward 24 |
| **B — not runnable** | blocked (net/pipe) or self-limited | **low** `dwait` | vfps **unchanged** |

```
/proc/<pid>/task/<tid>/schedstat:
  $1 run_ns   executing
  $2 wait_ns  runnable, waiting for CPU   ← starvation signal
  $3 slices
agg_wait_frac_pct = 100 * sum(dwait) / sum(drun+dwait)  over ALL ffmpeg threads
```

**Leader-only** `/proc/<pid>/schedstat` is insufficient for multi-thread ffmpeg.  
`tools/schedstat_sample.py` emits `ffmpeg_agg` (sum over threads).

DDR `frame_tx ms=4..14` can explain **present** loss, **not** `frames` under-production (713 vs 741). Those ~28 never left the decode/pipe path.

---

## 1. Pre-registered predictions

Steady 480p mid-soak (`wall_s>15`), validity = ffmpeg + misterplexd exe live whole window.  
Absence = **NO-DATA**, never 0.0.

### P1 — schedstat stock (no SUSPEND, no Main patch)

| quantity | if H true | if H false |
|----------|-----------|------------|
| `ffmpeg_agg.agg_wait_frac_pct` | **15–45** | **0–8** |
| `ffmpeg_agg.max_busy_thread_wait_frac_pct` | **20–55** | **0–12** |
| `ffmpeg_agg.sum_wait_pct_wall` | **10–35** | **0–5** |
| `misterplexd_agg.agg_wait_frac_pct` | **8–30** | **0–10** |
| MiSTer wait_frac | **0–5** | **0–5** |

Grey **(8, 15)** on ffmpeg agg_wait_frac → `INCONCLUSIVE`.

### P2 — production (reconfirm)

`under_prod = wall_s * 24 - frames` still **20–40** per ~30s if bug steady.

### P3 — SUSPEND A/B (only if P1 CONSISTENT or grey)

| quantity | if H true | if H false |
|----------|-----------|------------|
| vfps | **23.6–24.1** | still **≤23.2** |
| under_prod / ~30s | **0–12** | still **20–40** |
| ffmpeg agg_wait_frac | **0–10** | stays low |

**Reclaimed frames if H true:** **15–30** of ~28 under-prod per 30s.  
Miss: delta under_prod **&lt;8** after SUSPEND → do not claim CPU fix.

### P4 — Main `timeout=5`

**Product-candidate only after H confirmed** (P1 consistent **and** P3 causal).  
Then `MISTER_TIMEOUT5_LAB.md` full protocol (backup/revert/falsifiers).

### Non-predictions

No single-point “Main steals X ⇒ Y frames”. No `200−busy` headroom.

---

## 2. Parent commands — stock window first

Copy to device: `schedstat_sample.py`, `starvation_480p_verdict.py`, `arm_cpu_sample.py`.

```sh
set +e
OUT=/media/fat/misterplex/headroom_v2
mkdir -p "$OUT"

python3 - <<'PY'
import os
ff=mp=mi=None
for n in os.listdir("/proc"):
    if not n.isdigit():
        continue
    try:
        p=os.readlink("/proc/%s/exe" % n)
    except OSError:
        continue
    if p.endswith(" (deleted)"):
        p=p[:-10]
    b=os.path.basename(p).lower()
    if "ffmpeg" in b: ff=n
    if "misterplexd" in b: mp=n
    if b=="mister": mi=n
print("ffmpeg_pid=%s misterplexd_pid=%s MiSTer_pid=%s" % (ff,mp,mi))
print("VALID" if ff and mp else "INVALID_NO_DATA")
print("true rc_valid=0")
PY
echo "true rc_valid_wrap=$?"

# 480p cast; wait wall_s>15; then:
python3 /media/fat/misterplex/tools/schedstat_sample.py --seconds 20 --label p480_stock \
  -o "$OUT/schedstat_p480_stock.json"
echo "true rc_sched=$?"

python3 /media/fat/misterplex/tools/arm_cpu_sample.py --seconds 8 --label p480_stock \
  -o "$OUT/armcpu_p480_stock.json"
echo "true rc_cpu=$?"

grep -E "media: frames=" /media/fat/misterplex*/logs/*.log 2>/dev/null | tail -3
echo "true rc_grep_frames=$?"
grep -E "present_profile" /media/fat/misterplex*/logs/*.log 2>/dev/null | tail -2
echo "true rc_grep_prof=$?"

# Replace numbers from LIVE media line before trusting:
python3 /media/fat/misterplex/tools/starvation_480p_verdict.py \
  "$OUT/schedstat_p480_stock.json" \
  --vfps 23.0 --wall-s 30.88 --frames 713 --drops 7 --fps 24 --presents 672
echo "true rc_verdict=$?"
```

### present_profile non-CPU hints (`PRESENT_PROFILE=1`)

| signal | points to |
|--------|-----------|
| low ffmpeg wait + low run_pct_wall + low vfps | PMS/network stall (not runnable) |
| high `read_eagain_sleep_us_f`, low ffmpeg wait | pipe empty / producer slow for non-sched reason |
| high `ddr_total_us` / present tails | present loss, **not** frames under-prod |
| high `pacing_wait_us_f` | supply OK; pacer holding |

---

## 3. Decision tree

```
§2 stock
  INVALID_NO_FFMPEG → no conclusion
  STARVATION_CONSISTENT → §4 SUSPEND A/B
      vfps up + under_prod down → H CONFIRMED → timeout=5 product-candidate lab
      vfps flat → H incomplete; keep PMS/reader open
  STARVATION_REFUTED → H false for CFS starve; Main timeout not this bug's fix
  INCONCLUSIVE → 40s window or SUSPEND tie-break
```

---

## 4. SUSPEND causal A/B (lab)

CONT before any `load_core`. Parent verified cmd path when Main runs.

```sh
set +e
# Enable lab SUSPEND during play (known-good path); mid-soak:
python3 /media/fat/misterplex/tools/schedstat_sample.py --seconds 20 --label p480_suspend \
  -o /media/fat/misterplex/headroom_v2/schedstat_p480_suspend.json
echo "true rc_sched_b=$?"
# harvest media line; verdict with NEW vfps/frames/wall
# disable suspend; CONT; optional:
echo "load_core /media/fat/_Utility/Plex.rbf" > /dev/MiSTer_cmd
echo "true rc_cmd=$?"
```

---

## 5. Tools

- `tools/schedstat_sample.py` — `ffmpeg_agg` / `misterplexd_agg` / `mister_agg`
- `tools/starvation_480p_verdict.py` — gates → `VERDICT=`

Agent does not touch hardware.
""")