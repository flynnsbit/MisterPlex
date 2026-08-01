# PARENT CARD — C1–C4 MiSTer 48% vs 480p HDMI frame loss

**Agent:** w-cpu · no device touch  
**Host tools already in tree:** `tools/arm_cpu_sample.py`, `tools/schedstat_sample.py`, `tools/starvation_480p_verdict.py`, `tools/score_mister_contention.py` (this turn)  
**Source mirror:** `.agent-work/w-cpu-main-input.cpp` L5596–5617, `scheduler.cpp` co_poll  

**Corrections carried:** ERROR 17 discarded; 117 ms “device defect” discarded (parent capture argv).  
**Do not quote** `200−busy` as headroom.  
**true rc:** always `cmd; echo "true rc=$?"` (never through a pipe).

---

## C1 — What is `/media/fat/MiSTer` doing at ~48%? (prove it)

### Source (already quoted — not a guess)

```c
// input.cpp ~L5596–5617  (.agent-work/w-cpu-main-input.cpp)
int timeout = 0;
if (is_menu() && video_fb_state()) timeout = 25;  // ms — ONLY Menu+FB
int return_value = poll(pool, NUMDEV + 3, timeout);
// timeout=0 ⇒ idle poll returns immediately ⇒ scheduler_co_poll spins on CPU1
```

```c
// main.cpp — Main pinned to CPU1
CPU_SET(1, &set);
sched_setaffinity(0, sizeof(set), &set);
```

```c
// scheduler.cpp — outer lap: no nanosleep; yield is libco switch only
user_io_poll(); frame_timer(); input_poll(0); video_poll(); scheduler_yield();
```

**Mechanism class (source-backed):** timeout-free `poll` busy-wait / elastic scavenger on **CPU1**, not “real decode work”.  
**Device profile still required** to prove the **live** binary is in that path (not a different Main build).

### PRE_REG before any sample

| ID | Prediction | PASS band | FAIL / miss |
|---|---|---|---|
| C1-S | `strace -c` top syscall by time is `poll` (or `ppoll`) | poll ≥ 40% of sampled syscall time | top is something else → quote it; mechanism open |
| C1-R | MiSTer `run_pct_wall` high, `wait_frac` **low** | wait_frac ≤ 5%, run_pct_wall ≥ 30% in play window | high wait_frac → Main is blocked, not spinning |
| C1-A | Main affinity is CPU1 only | `Cpus_allowed_list` is `1` | multi-CPU → quote list |
| C1-I vs C1-P | Idle Main %onecpu **≥** play Main %onecpu | idle ≥ play − 5 pts | play ≫ idle → elevated by *our* load (unexpected for pure scavenger) |

### Commands (copy-paste; read-mostly; do not leave Main stopped)

**Resolve PIDs by exe only (ERROR 14 — never cmdline substring):**

```sh
# --- resolve ---
M_PID=""; D_PID=""
for d in /proc/[0-9]*; do
  exe=$(readlink -f "$d/exe" 2>/dev/null) || continue
  exe=${exe% (deleted)}
  base=$(basename "$exe")
  case "$base" in
    MiSTer|mister) M_PID=${d#/proc/} ;;
    misterplexd) D_PID=${d#/proc/} ;;
  esac
done
echo "M_PID=${M_PID:-NO-DATA} D_PID=${D_PID:-NO-DATA}"
# affinity / policy (C1-A)
if [ -n "$M_PID" ]; then
  echo "--- MiSTer status ---"
  grep -E '^(Name|State|PPid|Cpus_allowed_list|Cpus_allowed):' /proc/$M_PID/status
  # sched policy: field 41 policy, 18 rt_priority in /proc/pid/stat (Linux)
  awk '{print "stat_policy_field41=" $41 " rt_prio_field18=" $18 " nice_field19=" $19}' /proc/$M_PID/stat
fi
if [ -n "$D_PID" ]; then
  echo "--- misterplexd status ---"
  grep -E '^(Name|State|Cpus_allowed_list):' /proc/$D_PID/status
  awk '{print "stat_policy_field41=" $41 " rt_prio_field18=" $18 " nice_field19=" $19}' /proc/$D_PID/stat
fi
echo "true rc=$?"
```

**Syscall profile (C1-S) — 10 s attach; Main keeps running:**

```sh
# Prefer strace if present; else report NO-DATA (do not invent).
command -v strace >/dev/null 2>&1 || { echo "NO-DATA strace"; echo "true rc=77"; exit 0; }
# If M_PID empty: NO-DATA
[ -n "$M_PID" ] || { echo "NO-DATA M_PID"; echo "true rc=77"; exit 0; }
# -c summary only; -f follows threads; 10s then detach
strace -c -f -p "$M_PID" 2> /media/fat/misterplex/lab_mister_strace_c.txt &
SP=$!
sleep 10
kill -INT "$SP" 2>/dev/null || true
wait "$SP" 2>/dev/null
echo "--- strace -c ---"
cat /media/fat/misterplex/lab_mister_strace_c.txt
echo "true rc=$?"
```

**If no strace:** stack-sample fallback (weaker):

```sh
[ -n "$M_PID" ] || { echo "NO-DATA"; echo "true rc=77"; exit 0; }
i=0
while [ "$i" -lt 40 ]; do
  echo "=== sample $i ==="
  cat /proc/$M_PID/stack 2>/dev/null || echo "NO-DATA stack"
  cat /proc/$M_PID/wchan 2>/dev/null; echo
  i=$((i+1))
  sleep 0.05
done > /media/fat/misterplex/lab_mister_stack_samples.txt
echo "true rc=$?"
# PASS-ish if many samples show poll_schedule_timeout / do_sys_poll / 0 wchan (running)
```

**Pull artifacts off-device** (`lab_mister_strace_c.txt`, stack file) and quote top lines.  
**Absence of strace = NO-DATA for C1-S**, not proof Main is not in poll.

---

## C4 — Baseline: is 48% “always” or elevated by Plex? (do this before C2 narrative)

### PRE_REG

| ID | Prediction | PASS = NORMAL scavenger | Elevated-by-us band |
|---|---|---|---|
| C4-IDLE | Menu or Plex **idle** (no play, no cast) Main %onecpu | **70–100** | <40 → unexpected (Main sleeping?) |
| C4-PLAY | 480p play Main %onecpu | **30–90** and **≤ idle + 5** | play > idle + 15 → Main doing *more* under our load |
| C4-NOTE | Parent’s 48% play | **compatible with NORMAL** if idle ≥ 48 | only “elevated” if idle ≪ 48 |

**If idle ~80–100 and play ~48: CLOSE suspicion that “Plex elevated Main to 48%”.**  
That is **elastic scavenger yielding CPU to ffmpeg/daemon**, not proof of innocence on frame loss (C2 still required).

### Commands — ONE window method (mandatory)

`P = 100 * dticks / (HZ * dwall)`, HZ=100, fields 14+15 of `/proc/pid/stat`, exe-resolved.

**On device** (busybox-safe; no python required):

```sh
# usage: sample_cpu SECONDS LABEL
# writes one line: LABEL dwall= M= D= F= (NO-DATA if absent)
sample_cpu() {
  sec="$1"; lab="$2"
  # resolve
  M=""; D=""; F=""
  for d in /proc/[0-9]*; do
    exe=$(readlink -f "$d/exe" 2>/dev/null) || continue
    exe=${exe% (deleted)}
    b=$(basename "$exe")
    p=${d#/proc/}
    case "$b" in
      MiSTer|mister) M=$p ;;
      misterplexd) D=$p ;;
      ffmpeg) F=$p ;;  # first match; multi-ffmpeg: note NO-DATA-MULTI if needed
    esac
  done
  ticks() { # $1=pid → utime+stime
    [ -r "/proc/$1/stat" ] || { echo NO-DATA; return; }
    rest=$(sed 's/^[^)]*) //' "/proc/$1/stat")
    set -- $rest
    # fields after comm: 1=state 12=utime 13=stime (1-based in rest → $12 $13)
    echo $(( $12 + $13 ))
  }
  t0=$(date +%s%N 2>/dev/null || date +%s)
  m0=$(ticks "$M"); d0=$(ticks "$D"); f0=$(ticks "$F")
  sleep "$sec"
  t1=$(date +%s%N 2>/dev/null || date +%s)
  m1=$(ticks "$M"); d1=$(ticks "$D"); f1=$(ticks "$F")
  # dwall seconds
  if date +%s%N >/dev/null 2>&1; then
    dwall=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f", (b-a)/1e9}')
  else
    dwall="$sec"
  fi
  pct() { # ticks0 ticks1 dwall → %onecpu or NO-DATA
    a="$1"; b="$2"
    case "$a$b" in *NO-DATA*|NO-DATA*) echo NO-DATA; return;; esac
    awk -v a="$a" -v b="$b" -v w="$dwall" 'BEGIN{
      if(w<=0){print "NO-DATA"; exit}
      dt=b-a; if(dt<0)dt=0
      printf "%.1f", 100.0*dt/(100.0*w)
    }'
  }
  echo "$lab dwall=$dwall Main=$(pct "$m0" "$m1") daemon=$(pct "$d0" "$d1") ffmpeg=$(pct "$f0" "$f1") M_PID=${M:-NO-DATA} D_PID=${D:-NO-DATA} F_PID=${F:-NO-DATA}"
}

echo "=== C4 IDLE (no playback; leave UI alone) ==="
sample_cpu 20 C4_IDLE
echo "true rc=$?"

echo "=== C4 PLAY (start 480p cast first; steady state >30s into play) ==="
sample_cpu 20 C4_PLAY
echo "true rc=$?"
```

**Or host-side** if python3 exists on device / you scp tools:

```sh
# from repo root on device or after scp tools/
python3 tools/arm_cpu_sample.py --seconds 20 --label C4_IDLE -o /media/fat/misterplex/lab_c4_idle.json
echo "true rc=$?"
# during 480p:
python3 tools/arm_cpu_sample.py --seconds 20 --label C4_PLAY -o /media/fat/misterplex/lab_c4_play.json
echo "true rc=$?"
```

---

## C2 — Is Main implicated in 0.70% HDMI loss? (falsifiable)

**Budget:** 24 fps → **41.67 ms/frame**. Signature of deadline miss: **service-time / inter-present tail near or above budget**, and/or **runqueue wait** on the publish path — **not** Main’s own %CPU alone.

### PRE_REG signatures (publish before measure)

| ID | Signature | CONTENTION_CONSISTENT band | CONTENTION_REFUTED band |
|---|---|---|---|
| C2-W | `misterplexd` **agg** `wait_frac` during 480p play (schedstat, thread-sum) | **≥ 10%** OR max busy thread wait_frac **≥ 15%** | **≤ 3%** while HDMI loss still ≥ 0.5% |
| C2-F | `ffmpeg` agg wait_frac (same window) | ≥ 15% (starve decode → under-produce) | ≤ 8% with HDMI loss (loss not CPU-starve of ffmpeg) |
| C2-AB | HDMI loss rate with Main **running** vs Main **SIGSTOP/SUSPEND** during same fixture | loss_B / loss_A **≤ 0.30** (loss drops ≥70% when Main off) | loss_B / loss_A **∈ [0.7, 1.3]** (loss unchanged) |
| C2-P | daemon `publish_misses` over same window as 4/568 loss | publish_misses **≥ 4** (or ≥ loss count) | publish_misses **= 0** while HDMI lost 4 frames → loss **not** counted publish_miss path |
| C2-T | p99 inter-present gap (if instrumented) | p99 **≥ 41.67 ms** | p99 **≤ 42 ms** and max **≤ 50 ms** with loss still present → not simple deadline miss on present cadence |

**Primary falsifier = C2-AB.** Everything else is supporting.

**Important:** HDMI loss invisible to `drops` is already explained in source: `drops` = pacer only; `publishMisses_` separate; frames never produced not counted. C2-P tells whether the 4 losses are publish fails vs earlier in the pipe / scanout.

### C2-W / C2-F commands (play steady-state)

```sh
# On device with tools present, OR run after scp of tools/schedstat_sample.py
python3 tools/schedstat_sample.py --seconds 30 --label C2_PLAY -o /media/fat/misterplex/lab_c2_play_sched.json
echo "true rc=$?"
# Host-side score (after pull):
python3 tools/starvation_480p_verdict.py lab_c2_play_sched.json --fps 24
echo "true rc=$?"
python3 tools/score_mister_contention.py lab_c2_play_sched.json
echo "true rc=$?"
```

### C2-P — daemon counters (same play; pull log)

```sh
# Grep only — absence of publish_misses= lines is "log does not contain", not "misses=0"
grep -E 'publish_misses=| lifetime_publish_misses=|media:.*drops=' /media/fat/misterplex/misterplexd.log | tail -n 40
echo "true rc=$?"
```

### C2-AB — Main off during play (HIGHEST VALUE; careful)

**Risk:** while Main is `T` (SIGSTOP) or `SUSPEND_MAIN_DURING_PLAY=1`: **F12/OSD/`/dev/MiSTer_cmd`/load_core dead**. Plex stop via TCP :3005 still works. **Resume Main before leaving the session.**

**Option A — conf (if already supported on live binary):**

```sh
# ONLY if parent already trusts SUSPEND_MAIN_DURING_PLAY (prior lab: reclaim OK).
# Backup conf first (user-owned — restore byte-exact).
CONF=/media/fat/misterplex/misterplex.conf
cp -a "$CONF" /media/fat/misterplex/misterplex.conf.bak_c2ab
# Do NOT leave modified conf if user did not approve — parent decision.
# Measure loss with SUSPEND=0 and SUSPEND=1 on identical 480p fixture + same instrument.
```

**Option B — temporary SIGSTOP (no conf edit; shorter blast radius):**

```sh
# PRE: 480p playing steady. Record HDMI loss window A (Main running) first.
# Then:
[ -n "$M_PID" ] || { echo "NO-DATA M_PID"; echo "true rc=77"; exit 0; }
kill -STOP "$M_PID"
# verify T
awk '{print "state="$3}' /proc/$M_PID/stat
# run SAME HDMI loss instrument window B
# ALWAYS resume:
kill -CONT "$M_PID"
awk '{print "state_after="$3}' /proc/$M_PID/stat
echo "true rc=$?"
```

**PRE_REG numeric example (parent fills measured):**

```
loss_A = 4/568 = 0.704%   (Main running)   # already measured class
loss_B = ?                 (Main STOPPED)
ratio  = loss_B/loss_A
  ratio ≤ 0.30  → CONTENTION_IMPLICATED (Main CPU causally linked to loss)
  ratio ∈ [0.7, 1.3] → CONTENTION_ELIMINATED (loss independent of Main spin)
  else grey → longer window / more reps
```

Also capture schedstat **during B** (Main STOPPED): expect MiSTer run_pct ≈ 0 or NO-DATA; misterplexd wait_frac should drop if C2-W was high.

---

## C3 — Cheap mitigations (**only if C2-AB or C2-W hits CONSISTENT**)

| Mitigation | Expected reclaim | Risk to daily driver | Ship? |
|---|---|---|---|
| **A. `poll` timeout=5 on Plex only** (lab patch already written) | Main idle/play → low tens %onecpu; input latency +≤5 ms PRE_REG | Low if scoped; still wakes on fds | Lab first (`MISTER_TIMEOUT5_PARENT_AB.md`) |
| **B. `SUSPEND_MAIN_DURING_PLAY=1`** | ~full core during play (parent prior −45.7 pts) | **F12/OSD/cmd dead while playing** | Default stays 0 until UX OK |
| **C. nice −5 / SCHED_FIFO on misterplexd only** | May cut wait_frac if C2-W high | Can starve Main input if too aggressive; **do not RT-prio Main off** | Lab only; measure input lag |
| **D. Affinity: pin ffmpeg+daemon to CPU0** (Main already CPU1) | Reduce cross-cpu fight | If already true, no-op; if daemon on both CPUs, pinning may help or hurt | Measure Cpus_allowed first |
| **E. nice +10 on Main** | Main still runs, less aggressive scavenger | Slightly slower OSD/input under load | Safer than STOP |

**Do not:** kill Main permanently; RT-prio Main below daemon without recovery plan; leave Main in `T` after lab.

**If C2 REFUTED:** do **not** ship A–E for frame-loss reasons. Main spin remains a **headroom** issue only (timeout=5 still optional for CPU budget).

---

## Scoring pulled artifacts (host)

```sh
# After scp lab_c2_play_sched.json (and optional lab_c2_stop_sched.json):
python3 tools/score_mister_contention.py lab_c2_play_sched.json \
  --loss-a-pct 0.70 \
  --loss-b-pct 0.00   # if C2-AB done; omit if not
echo "true rc=$?"
```

Exit codes: `0` scored (including REFUTED/IMPLICATED/INCONCLUSIVE), `77` NO-DATA, `2` bad input.

---

## What would settle “unknown” without guessing

| Unknown | Settling check |
|---|---|
| Live Main in poll(0)? | C1-S strace −c top=poll |
| 48% normal? | C4 idle vs play |
| Causes HDMI loss? | **C2-AB** loss ratio + C2-W wait_frac |
| Loss = publish_miss? | C2-P publish_misses vs 4 HDMI gaps |
| Binary has timeout patch? | `strings` / md5 Main vs stock; or C1-S still poll-dominated |

---

## Rule 0 summary for the report-back

- Quote strace top line / schedstat numbers / loss_A loss_B — or say **NO-DATA**.  
- Do **not** write “contention caused 0.70%” unless C2-AB (or strong C2-W+C2-T) hits band.  
- Do **not** write “Main is innocent” unless C2-AB refutes.  
- Soft-skip 77 ≠ pass.
