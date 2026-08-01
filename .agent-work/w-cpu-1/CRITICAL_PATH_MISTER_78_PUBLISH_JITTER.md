# CRITICAL PATH — MiSTer 78% → publish jitter (w-cpu T1–T4)

**Agent:** w-cpu · **no device touch** · parent runs every command  
**Authoritative CPU split (parent, 50.127 s, exe-resolved):**

| exe | %onecpu |
|---|---:|
| `/media/fat/MiSTer` | **78.0** |
| ffmpeg | 60.5 |
| misterplexd | 24.3 |
| accounted | 162.8 |
| system busy | **173.1 / 200 (86.6%)** |

**Optimise for:** publish-path **latency jitter** (w-geom `publish_interval`), **not** frame loss.  
**Withdrawn (do not build on):** ERROR 18 (1.54% glass loss), ERROR 19 (0.070% skip), ERROR 17 (fps 23.976).  
**Headroom:** never quote `200−busy`. Inelastic ≈ ffmpeg+daemon = **84.8**. Main = elastic scavenger.

---

## T1 — What is MiSTer doing at 78%? (quoted source)

Upstream **still** matches our mirror (fetched `MiSTer-devel/Main_MiSTer` master, 2026-08-01):

### 1. Entire Main pinned to CPU1

```c
// main.cpp (upstream L47–48; mirror .agent-work/w-cpu-main-main.cpp)
CPU_SET(1, &set);
sched_setaffinity(0, sizeof(set), &set);
// comment in tree: core #0 is HW IRQ handler; pin reduces idle latency 6-7x
```

### 2. Outer lap has **no sleep**

```c
// scheduler.cpp co_poll (mirror .agent-work/w-cpu-main-scheduler.cpp)
for (;;) {
    user_io_poll();
    frame_timer();
    input_poll(0);   // only place that can block
    video_poll();
    scheduler_yield(); // libco switch — NOT nanosleep
}
```

(non-scheduler build: `while(1){ user_io_poll(); frame_timer(); input_poll(0); HandleUI(); OsdUpdate(); }`)

### 3. `input_poll` uses **timeout-free `poll`** except Menu∧FB

```c
// input.cpp upstream L5596–5617 (mirror same lines)
int timeout = 0;
if (is_menu() && video_fb_state()) timeout = 25; // ms ONLY
// ...
int return_value = poll(pool, NUMDEV + 3, timeout);
if (!return_value) break;  // timeout=0 → immediate return when idle → spin
```

`pool` = `/dev/input/*` + inotify + **`/dev/MiSTer_cmd`** + LED sysfs.  
**Not** in the poll set: our DDR frame store, doorbell, or status word.

### 4. Secondary work on non-Menu cores (same inner loop)

```c
if (cfg.rumble && !is_menu()) {
    // per-device spi_uio_cmd(UIO_GET_RUMBLE) every lap
}
```

SPI rumble poll adds **work** on Plex; it does **not** replace the timeout=0 mechanism. Class: timeout-free poll busy-wait / **elastic scavenger on CPU1**.

### Live proof still required (source ≠ device profile)

| ID | Prediction | PASS | FAIL |
|---|---|---|---|
| T1-S | `strace -c` top = `poll`/`ppoll` | ≥40% of sampled syscall time | other top → quote it |
| T1-R | high run, low runqueue wait | `wait_frac` ≤5% over 20 s | high wait → blocked, not spinning |
| T1-A | affinity CPU1 only | `Cpus_allowed_list: 1` | multi-CPU list |
| T1-W | `/proc/pid/wchan` often `0` or poll path | majority running/poll | long uninterruptible block |

**Commands:** §PARENT below (same as C1 card; do not stop Main).

---

## T2 — Is it OUR fault? (highest-value A/B)

### Source verdict (mechanism)

| Claim | Evidence |
|---|---|
| Stock on any non-Menu+FB core | **Yes** — only Menu∧FB gets timeout=25. Plex → timeout=0. |
| Our DDR publishes wake Main’s poll | **No source path** — DDR/F1 not in `pool`. |
| Continuous 78% = MiSTer_cmd hammer | **Unlikely as primary** — continuous scavenger % matches timeout=0 even with idle fds; cmd would be event spikes. Prove with strace event rate if disputed. |
| We “elevate” Main vs idle | **Prior parent numbers contradict elevation:** idle Main **100%**, 240p **83%**, 480p **78%** — scavenger **yields** under load, does not climb. |

**Our fault class:** we **coexist** with a stock full-core scavenger on a dual A9 while also running ffmpeg+daemon. We did **not** invent `timeout=0`. Whether that coexistence **causes publish jitter** is T2/T3 **measurement**, not assumed.

### PRE_REG before A/B (publish this before running)

| Arm | Label | Expected Main %onecpu | Interpretation if true |
|---|---|---:|---|
| A | Plex core, **no cast**, daemon **stopped** | **70–100** | stock scavenger; not daemon-induced |
| B | Plex core, **480p play** (current load) | **60–85** (parent had 78) | scavenger still large under play |
| C | optional: Menu core + FB if available | **≤35** if timeout=25 path live | proves Menu+FB timeout branch |
| Δ | B − A | **≤ 0 ±15 pts** | play does **not** elevate Main; if B ≫ A+20 → open “our load elevates Main” |

**PASS for “not our spin”:** Arm A already ≥70 with daemon gone.  
**FAIL / open “we elevate”:** Arm B ≥ Arm A + 20 **and** strace shows non-poll work dominant.

### Exact device commands (busybox; exe-resolved; conf untouched)

Copy whole block. Artifacts under `/media/fat/misterplex/lab_t2_*` (user lab dir — parent-owned). **Do not** leave Main SIGSTOP’d. **Do not** rewrite user conf.

```sh
# ===== T2 A/B: MiSTer % with daemon stopped vs 480p play =====
# Method: ONE window per arm, P=100*dticks/(HZ*dwall), HZ=100
# Identity: readlink -f /proc/pid/exe ONLY (never cmdline).
# Capture true rc DIRECTLY after each arm.

LAB=/media/fat/misterplex
HZ=100
WIN=20

resolve_pids() {
  M_PID=""; D_PID=""; F_PIDS=""
  for d in /proc/[0-9]*; do
    exe=$(readlink -f "$d/exe" 2>/dev/null) || continue
    exe=${exe% (deleted)}
    base=$(basename "$exe")
    case "$base" in
      MiSTer|mister) M_PID=${d#/proc/} ;;
      misterplexd)   D_PID=${d#/proc/} ;;
      ffmpeg)
        F_PIDS="${F_PIDS} ${d#/proc/}"
        ;;
    esac
  done
  M_PID=${M_PID:-}
  D_PID=${D_PID:-}
  echo "RESOLVE M_PID=${M_PID:-NO-DATA} D_PID=${D_PID:-NO-DATA} F_PIDS=${F_PIDS:-NO-DATA}"
}

sample_ticks() {
  # args: out_file
  out=$1
  : > "$out"
  for d in /proc/[0-9]*; do
    p=${d#/proc/}
    exe=$(readlink -f "$d/exe" 2>/dev/null) || continue
    exe=${exe% (deleted)}
    [ -r "$d/stat" ] || continue
    raw=$(cat "$d/stat" 2>/dev/null) || continue
    rest=${raw#*) }
    set -- $rest
    # after comm: utime=$12 stime=$13 (1-based fields in rest → $14 $15 of full stat)
    # rest fields: state ppid ... utime is field 12 of rest in Linux proc(5)
    ut=$14; st=$15
    # Actually after ") " the fields are: state=1 ppid=2 ... utime=12 stime=13
    set -- $rest
    ut=$12; st=$13
    ticks=$((ut + st))
    echo "$p $ticks $exe" >> "$out"
  done
  # system busy snapshot
  awk '/^cpu /{print}' /proc/stat >> "$out.cpu"
}

score_window() {
  # args: label a_file b_file wall_s
  label=$1; a=$2; b=$3; wall=$4
  echo "=== ARM $label wall_s=$wall ==="
  # join on pid
  awk -v HZ="$HZ" -v W="$wall" -v L="$label" '
    FNR==NR { t1[$1]=$2; e1[$1]=$3; next }
    {
      if (!($1 in t1)) next
      dt=$2-t1[$1]
      if (dt<0) next
      p=100.0*dt/(HZ*W)
      exe=$3
      base=exe; sub(/^.*\//,"",base)
      printf "  %6.1f  pid=%s  %s\n", p, $1, exe
      sum+=p
      if (base=="MiSTer" || base=="mister") m+=p
      if (base=="misterplexd") d+=p
      if (base=="ffmpeg") f+=p
    }
    END {
      printf "LABEL=%s MAIN=%.1f DAEMON=%.1f FFMPEG=%.1f ACCOUNTED_TOP=%.1f\n", L, m+0, d+0, f+0, sum+0
    }
  ' "$a" "$b"
}

# --- metadata ---
resolve_pids
echo "core_hint=$(cat /sys/devices/system/cpu/online 2>/dev/null)"
if [ -n "$M_PID" ]; then
  grep -E '^(Name|Cpus_allowed_list|State):' /proc/$M_PID/status
  awk '{print "nice="$19" rt_prio="$18" policy_field41="$41}' /proc/$M_PID/stat
fi
if [ -n "$D_PID" ]; then
  grep -E '^(Name|Cpus_allowed_list|State):' /proc/$D_PID/status
  awk '{print "daemon_nice="$19" rt_prio="$18" policy_field41="$41}' /proc/$D_PID/stat
fi

# ========== ARM A: stop playback / stop daemon (parent chooses how) ==========
# PRE: stop cast; stop misterplexd supervisor briefly OR leave idle with no ffmpeg.
# Parent must ensure: no ffmpeg exe; daemon optional stopped.
# SAFE: do NOT kill /media/fat/MiSTer. Do NOT load_core thrash. Restore daemon after.
echo "PRECHECK_A: list ffmpeg/misterplexd (expect ffmpeg NO-DATA if stopped)"
resolve_pids
sample_ticks "$LAB/lab_t2_a0.txt"
: > "$LAB/lab_t2_a0.txt.cpu"
awk '/^cpu /{print}' /proc/stat > "$LAB/lab_t2_a0.txt.cpu"
T0=$(date +%s%N)
sleep "$WIN"
T1=$(date +%s%N)
sample_ticks "$LAB/lab_t2_a1.txt"
awk '/^cpu /{print}' /proc/stat > "$LAB/lab_t2_a1.txt.cpu"
# wall seconds (busybox date may lack %N — fallback)
WALL=$(awk -v t0="$T0" -v t1="$T1" 'BEGIN{ if(t1>t0 && t0>1e11) printf "%.3f",(t1-t0)/1e9; else print '"$WIN"' }')
score_window A "$LAB/lab_t2_a0.txt" "$LAB/lab_t2_a1.txt" "$WALL"
echo "ARM_A_done wall=$WALL"
echo "true rc=$?"

# ========== ARM B: 480p continuous play (parent starts cast first) ==========
# PRE: same fixture as 50s split; wait until steady play then:
echo "PRECHECK_B: expect MiSTer+misterplexd+ffmpeg all present"
resolve_pids
sample_ticks "$LAB/lab_t2_b0.txt"
awk '/^cpu /{print}' /proc/stat > "$LAB/lab_t2_b0.txt.cpu"
T0=$(date +%s%N)
sleep "$WIN"
T1=$(date +%s%N)
sample_ticks "$LAB/lab_t2_b1.txt"
awk '/^cpu /{print}' /proc/stat > "$LAB/lab_t2_b1.txt.cpu"
WALL=$(awk -v t0="$T0" -v t1="$T1" 'BEGIN{ if(t1>t0 && t0>1e11) printf "%.3f",(t1-t0)/1e9; else print '"$WIN"' }')
score_window B "$LAB/lab_t2_b0.txt" "$LAB/lab_t2_b1.txt" "$WALL"
echo "ARM_B_done wall=$WALL"
echo "true rc=$?"

# ========== T1-S strace during B (optional, 10s) ==========
resolve_pids
if command -v strace >/dev/null 2>&1 && [ -n "$M_PID" ]; then
  strace -c -f -p "$M_PID" 2>"$LAB/lab_t2_strace.txt" &
  SP=$!
  sleep 10
  kill -INT "$SP" 2>/dev/null || true
  wait "$SP" 2>/dev/null
  echo "--- strace -c head ---"
  head -40 "$LAB/lab_t2_strace.txt"
  echo "true rc=$?"
else
  echo "NO-DATA strace_or_M_PID"
  # stack fallback
  if [ -n "$M_PID" ]; then
    i=0
    : > "$LAB/lab_t2_stack.txt"
    while [ "$i" -lt 30 ]; do
      echo "=== $i ===" >> "$LAB/lab_t2_stack.txt"
      cat /proc/$M_PID/wchan 2>/dev/null >> "$LAB/lab_t2_stack.txt"
      echo >> "$LAB/lab_t2_stack.txt"
      cat /proc/$M_PID/stack 2>/dev/null >> "$LAB/lab_t2_stack.txt"
      i=$((i+1))
      sleep 0.05
    done
    echo "stack_samples=30 path=$LAB/lab_t2_stack.txt"
  fi
  echo "true rc=77"
fi

echo "RESTORE: ensure misterplexd supervisor running; conf untouched; core still Plex"
```

**Host-side alternative** (if Python on device or pull `/proc` not needed):  
`python3 tools/arm_cpu_sample.py --seconds 20 --label t2_A|t2_B -o …` with same arm preconditions.

**After A/B:** paste `LABEL=A/B MAIN=…` lines + strace top. I score; you do not need to interpret.

---

## T3 — Headroom → publish jitter (PRE-REGISTERED prediction)

**Instrument (tree):** `host/libmisterplex/publish_interval_ledger.hpp`  
Bands (already committed by w-geom):

| verdict | criterion |
|---|---|
| `ARM_CLEAN` | σ&lt;4 ms, ≥99% in [41.67±8], **P(iv&gt;50 ms)&lt;0.03** |
| `ARM_LATE_MATCH_HOLD45` | **P(iv&gt;50 ms) ∈ [0.09, 0.11]** |
| `ARM_LATE_MILD` | P ∈ (0.03, 0.09) |
| heavy late | P&gt;0.11 or P(iv&gt;83)&gt;0.02 |

### Predictions (label: PREDICTION — not measured)

**Context:** dual A9; Main **pinned CPU1**; IRQ preference CPU0 (Main comment).  
ffmpeg+daemon currently share the machine with a always-runnable scavenger. Parent load: busy **173/200**.

| ID | Change (hypothetical) | Predicted Main % | Predicted effect on publish_interval | Falsifier |
|---|---|---|---|---|
| P1 | Main poll timeout lab **5 ms** on Plex (existing patch) | **15–35** (from 78) | If baseline soak is `ARM_LATE_*`, expect **P(iv&gt;50) drop by ≥0.5×** toward `&lt;0.03` **or** clear move `LATE → MILD/CLEAN` | P(iv&gt;50) unchanged within ±0.02 **and** Main actually fell ≥40 pts → **Main not causal** for jitter |
| P2 | Main **SIGSTOP** only during play (lab) | **~0** | Strongest: if late-publish is CPU1 scavenger, expect **ARM_CLEAN**. | Still `ARM_LATE_*` with Main stopped → **not Main**; look ffmpeg/daemon path |
| P3 | Main stays 78%; only nice daemon −10 | Main ~same | **Weak** improve: P(iv&gt;50) drop **&lt;0.03 absolute** unless daemon was losing CPU to Main on same core | Large improve would surprise (daemon already 24%) |
| P4 | Affinity: daemon+ffmpeg → **CPU0 only**; Main stays CPU1 | Main may rise toward 90–100 on CPU1 | **Ambiguous:** isolates scavenger vs publish path. Predict: if contention was **cross-CPU**, little change; if daemon was on CPU1 fighting Main, **P(iv&gt;50) improves** | Measure both |

**Numeric anchor for parent brief (“if 78→20, what happens?”):**

> **PREDICTION P1:** Reducing Main from **78 → ~20 %onecpu** (Δ ≈ **−58** points of one core) frees roughly **one third of total dual-core capacity** currently burned by the scavenger (58/200 ≈ 29% of machine).  
> **If** w-geom baseline shows `P(iv>50ms) ∈ [0.09,0.11]`, **predict** post-reclaim `P(iv>50ms) ≤ 0.05` (enter MILD/CLEAN), **provided** ffmpeg+daemon inelastic load stays in the same band (±10%onecpu).  
> **If** baseline is already `ARM_CLEAN` (`P<0.03`), Main reclaim is **headroom-only** — do not claim judder fix.  
> **This is a prediction.** Misses will be published.

**Do not claim** Main reclaim fixes glass holds until publish_interval + fabric hold hist both move.

---

## T4 — Least-risky mitigations (ranked)

| Rank | Mitigation | Expected Main Δ | Risk to daily driver | Revert | When |
|---|---|---|---|---|---|
| **1** | **Lab Main binary: Plex-scoped `poll` timeout=5** (patch `.agent-work/w-cpu-1/patches/main_mister_input_timeout5_plex.patch`) | −40 to −70 %onecpu | **Medium:** input latency +5 ms worst-case; cmd/OSD still wake immediately on fd ready. Wrong binary path could brick UI until stock Main restored. | Copy stock `/media/fat/MiSTer` back from backup **before** test | After T2 confirms scavenger; pair with publish_interval soak |
| **2** | **Daemon publish path `nice -10`** (or `renice` live) — **not** SCHED_FIFO yet | Main unchanged; daemon wins ties vs nice0 | **Low:** Main stays default; UI preserved. May starve background only slightly. | `renice 0` | If T2 shows Main high **and** daemon shares CPU1 |
| **3** | **CPU affinity split:** `taskset -c 0` daemon+ffmpeg; Main already `1` | Main may ↑ on CPU1 | **Medium:** CPU0 hosts IRQs — can **worsen** decode latency. Must A/B publish_interval. | clear affinity / restart | Only as experiment with instant revert |
| **4** | **`FFMPEG_SWS_FLAGS=fast_bilinear` already on**; `DDR_YUV_FORCE_SCALE=0` when delivery_verified | ffmpeg −(scale slice only) | **Low–med:** identity_skip risk if geometry wrong — only with verified delivery | conf flag back to 1 | Secondary; does not remove Main 78 |
| **5** | **SCHED_FIFO on publish thread** | n/a | **High on daily driver:** can starve Main/input if bug; priority inversion; hard to reason under load | restart daemon default | **Defer** until 1–3 measured; never default-on |
| **6** | **SIGSTOP Main during play** | Main → 0 | **Unacceptable for daily use:** kills F12/OSD/cmd. Lab-only falsifier (P2). | `SIGCONT` | Lab C2-style only; restore before handback |

### Hard constraints (binding)

- **Never** leave Main stopped or a lab Main binary without stock backup.  
- **Never** thrash `load_core` / kill −9 storms.  
- **User conf is user-owned** — no normalise-to-pass.  
- **No Quartus.** Core `c5382bee` undisturbed.  
- Mitigation **1** requires parent-built Main from known source + md5 backup of stock.

### Recommended sequence (parent)

1. Run **T2 A/B** + **T1-S** (strace) — 5 minutes.  
2. Run **w-geom publish_interval** soak on current tip (baseline P(iv&gt;50)).  
3. **Only if** baseline is `ARM_LATE_*` **and** T2 shows Main scavenger: lab timeout=5 **or** affinity A/B with pre-registered P1/P4.  
4. Score with same publish_interval bands + CPU sample. Publish hit/miss on P1.

---

## What is already in tree (do not reinvent)

| Artifact | Role |
|---|---|
| `.agent-work/w-cpu-main-input.cpp` L5596–5617 | poll timeout quote |
| `patches/main_mister_input_timeout5_plex.patch` | lab Main reclaim |
| `tools/arm_cpu_sample.py` | exe-resolved %onecpu |
| `tools/schedstat_sample.py` | runqueue wait |
| `tools/score_mister_contention.py` | C2 scorer |
| `host/libmisterplex/publish_interval_ledger.hpp` | judder ARM bands |
| `PARENT_C1_C4_MISTER_CONTENTION_CARD.md` | earlier C1–C4 card |
| `ARM_CPU_480P_MEASURED_RCA.md` | 50 s split RCA |

---

## One-line answers for parent

- **T1:** timeout-free `poll(...,0)` on CPU1 in Main `input.cpp` (upstream confirmed); live proof = strace top=`poll`.  
- **T2:** **Not Plex-induced spin** by source; A/B with daemon stopped is the device closer — expect Main still high.  
- **T3:** PREDICTION: 78→20 ⇒ if late-publish baseline, `P(iv>50)` should fall toward `&lt;0.05`; else Main not causal.  
- **T4:** Safest real reclaim = **Plex-scoped poll timeout=5 lab Main** with stock backup; then nice/affinity; no FIFO yet.
