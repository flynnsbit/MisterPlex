# PARENT-RUN — MiSTer spin evidence + reclaim decision

**Agent does not touch the device.** You run every command.  
**Artifact pair:** stamp every result with live RBF md5 + daemon md5 (sampler does this).  
**Headroom ban:** never `200 − accounted`. Main is elastic. Use H1 (= ffmpeg+daemon),  
`sampler` fixed windows, and/or `/proc/<pid>/schedstat` Δrun_delay for *our* PIDs.

---

## 0. What source already proves (mechanism class)

Upstream `MiSTer-devel/Main_MiSTer` master (raw fetch matched mirror):

| Location | Fact |
|----------|------|
| `main.cpp` | `CPU_SET(1)`; `scheduler_run()` or `while(1)` |
| `scheduler.cpp` `scheduler_co_poll` | `user_io_poll(); frame_timer(); input_poll(0); video_poll();` then **cothread yield only** (no nanosleep) |
| `input.cpp` ~L5596–5617 | `timeout = 0`; **only** `if (is_menu() && video_fb_state()) timeout = 25`; then `poll(pool, NUMDEV+3, timeout)` |
| `input.cpp` pool | `/dev/input/*` + inotify + **`/dev/MiSTer_cmd`** + LED sysfs — **not** Plex DDR |

**Mechanism class (source): timer/input `poll` with timeout=0**, which *causes* the loop (including SPI in `user_io_poll`) to run full-tilt.  
It is **not** a dedicated “spin forever on one SPI register” lock — but SPI **is** hammered as cargo of the tight loop.

| Remedy class | Fits? |
|--------------|-------|
| Add/extend `poll` timeout (duty-cycle) | **Yes — primary** |
| SIGSTOP whole Main (SUSPEND) | Yes — nuclear; kills F12/cmd |
| “Stop DDR doorbell” on our side | **No** — pool has no DDR fd |

**Menu at 83–100% idle (your measure):** source gives Menu **sleep only if** `video_fb_state()`.  
If Menu idle is still ~100%, either FB is off, or stacks will show work *outside* blocking poll.  
**Do not assert which without §1 samples.** PRE_REG below covers both.

---

## 1. Evidence pack — what is it spinning on? (you run)

### 1.0 Resolve MiSTer PID (exe only — never name/cmdline)

```sh
M_PID=""; M_EXE=""
for d in /proc/[0-9]*; do
  exe=$(readlink -f "$d/exe" 2>/dev/null) || continue
  b=$(basename "${exe% (deleted)}")
  case "$b" in
    MiSTer|mister) M_PID=${d#/proc/}; M_EXE=$exe ;;
  esac
done
echo "M_PID=${M_PID:-NO-DATA} M_EXE=${M_EXE:-NO-DATA}"
# CORENAME (Menu vs Plex)
echo -n "CORENAME="; cat /media/fat/config/CORENAME 2>/dev/null || cat /tmp/CORENAME 2>/dev/null || echo NO-DATA
echo "true rc=$?"
```

### 1.1 wchan + stack sample (idle, established session)

**PRE_REG (publish miss if wrong):**
- If timeout=0 busy-poll dominates: **≥15/20** samples show kernel poll path  
  (`poll_schedule_timeout` / `do_sys_poll` / `SyS_poll` / `sys_poll`) **and** wchan often `poll_schedule_timeout` or `0`/`poll_schedule`.
- If pure userspace SPI spin with no poll: stacks in fpga/spi paths **without** poll — **different remedy**.
- Menu∧FB with timeout=25: more time in interruptible sleep; MiSTer %onecpu should be **≪ 50** if sleep works.

```sh
# requires M_PID from 1.0
i=0
while [ "$i" -lt 20 ]; do
  echo "=== sample $i $(date +%s%3N) ==="
  echo -n "wchan="; cat /proc/$M_PID/wchan 2>/dev/null; echo
  echo -n "state="; awk '{print $3}' /proc/$M_PID/stat 2>/dev/null; echo
  tr '\0' '\n' < /proc/$M_PID/stack 2>/dev/null | head -12
  i=$((i+1))
  sleep 0.05
done
echo "true rc=$?"
```

### 1.2 schedstat (Main + daemon) — saturation without `200−busy`

```sh
# fields: sum_exec_runtime(ns)  runqueue_wait(ns)  #timeslices
# Derive HZ (busybox getconf CLK_TCK is EMPTY on this box):
HZ=$(awk -v t0="$(awk '/^cpu /{s=0;for(i=2;i<=NF;i++)s+=$i;print s;exit}' /proc/stat)" \
  -v w0="$(date +%s%N)" -v n="$(cat /sys/devices/system/cpu/online | awk -F'[-,]' '{print NF}')" '
  BEGIN{ n=(n<1)?2:n }
' 2>/dev/null)
# Portable HZ probe (2s):
T0=$(awk '/^cpu /{s=0;for(i=2;i<=NF;i++)s+=$i; print s; exit}' /proc/stat)
W0=$(date +%s%N)
sleep 2
T1=$(awk '/^cpu /{s=0;for(i=2;i<=NF;i++)s+=$i; print s; exit}' /proc/stat)
W1=$(date +%s%N)
# NCPU from online
NCPU=$(cat /sys/devices/system/cpu/online)
case "$NCPU" in *-*) a=${NCPU%-*}; b=${NCPU#*-}; NCPU=$((b-a+1));; *,*) NCPU=$(echo "$NCPU"|awk -F, '{print NF}');; *) NCPU=1;; esac
# HZ ≈ Δjiffies / (Δwall_s * NCPU)  — parent method
python3 - <<PY || busybox awk "BEGIN{print int(($T1-$T0)/((($W1-$W0)/1e9)*$NCPU))}"
t0,t1,w0,w1,n=$T0,$T1,$W0,$W1,$NCPU
print(round((t1-t0)/(((w1-w0)/1e9)*n)))
PY

# schedstat snapshot helper
snap_sched() {
  p=$1; tag=$2
  if [ ! -r /proc/$p/schedstat ]; then echo "$tag NO-DATA"; return; fi
  read ex wait sl < /proc/$p/schedstat
  echo "$tag pid=$p exec_ns=$ex runq_wait_ns=$wait slices=$sl"
}
# daemon by exe
D_PID=""
for d in /proc/[0-9]*; do
  exe=$(readlink -f "$d/exe" 2>/dev/null) || continue
  [ "$(basename "${exe% (deleted)}")" = "misterplexd" ] || continue
  case "$exe" in *misterplex_v2*) D_PID=${d#/proc/}; break;; *) D_PID=${d#/proc/};; esac
done
snap_sched "$M_PID" MAIN0
snap_sched "${D_PID:-}" DAEMON0
sleep 10
snap_sched "$M_PID" MAIN1
snap_sched "${D_PID:-}" DAEMON1
echo "true rc=$?"
# Score: Δrunq_wait_ns / 1e7 ≈ ms waited in 10s window (order-of). 
# PRE_REG idle: Main Δexec huge, Δrunq_wait small (it runs, rarely waits).
# PRE_REG under 480p cast: daemon Δrunq_wait rises if Main scavenges the core.
```

### 1.3 CPU% window (sampler — preferred)

Copy `tools/arm_cpu_soak.sh` to device if needed:

```sh
RBF_PATH=/media/fat/_Utility/Plex.rbf \
LOG=/media/fat/misterplex_v2/misterplexd.log \
sh /media/fat/misterplex_v2/arm_cpu_soak.sh 20
echo "true rc=$?"
```

**PRE_REG (stock Main, Plex loaded, idle cast-not-running):**  
`MiSTer` ∈ **[90, 100]** %onecpu (your baseline 99.8–100).  
**Miss if** MiSTer ≤ 50 at idle with Plex loaded → spin hypothesis weakened for *this* binary.

**PRE_REG (480p play):** MiSTer ∈ **[70, 90]** (your 76.4); H1 ≈ ffmpeg+daemon ~86.

**Absence:** print `NO-DATA`, never 0.0. Gate window on daemon `wall_s` advancing if scoring play.

### 1.4 Optional strace top syscall (if strace present; short)

```sh
# 3s only — do not leave attached
timeout 3 strace -p "$M_PID" -c 2>&1 | tail -20
echo "true rc=$?"
# PRE_REG: poll dominates %time if timeout=0 path
```

---

## 2. Reclaim options — recommendation

### 2.1 Already measured (yours)

| Lever | Result | Side effect |
|-------|--------|-------------|
| `SUSPEND_MAIN_DURING_PLAY` | **−45.7** dual-busy (68.1→22.4); drops 3→0; HDMI/DDR OK | F12/OSD/`MiSTer_cmd`/`load_core`/Main input **dead** while `T`; Plex stop via :3005 OK; kill−9 covered by supervisor CONT |
| Product HEAD | **No session SUSPEND conf** | Only SPI critical-section micro-SIGSTOP + `resumeStrandedMain()` |

**Default OFF is correct** for daily driver.

### 2.2 Narrower intervention (preferred if §1 confirms poll)

**Duty-cycle the input `poll`**, keep process running:

```diff
# lab patch: .agent-work/w-cpu-1/patches/main_mister_input_timeout5_plex.patch
int timeout = 0;
if (is_menu() && video_fb_state()) timeout = 25;
else if (core is Plex) timeout = 5;  /* ms — poll still wakes on input/cmd */
```

| | timeout=5 (Plex-scoped) | SUSPEND session |
|--|-------------------------|-----------------|
| Reclaim | **Most of idle core** (sleep in poll); under play Main stops full-core scavenge | −45.7 pts proven |
| F12/OSD/cmd | **Live** (poll wakes) | **Dead** while `T` |
| Daily-driver risk | Lab Main binary swap; revert = restore stock Main | Must never leave Main stuck `T` |
| Default | After A/B green | **OFF** forever unless UX accepts dead F12 |

**Ship posture:**  
1. Run §1 on stock → confirm poll stacks.  
2. Deploy **lab-only** Main with timeout=5 (not upstream merge until measured).  
3. A/B §3.  
4. Keep SUSPEND as **opt-in nuclear**, not default.

If §1 shows SPI-only stacks **without** poll: timeout patch may still help (loop rate) but also audit `user_io_poll` call frequency — still not SUSPEND-first.

### 2.3 PRE_REG for timeout=5 Main A/B (same RBF+daemon md5)

| Metric | PASS band | KILL (not the spin / bad patch) |
|--------|-----------|----------------------------------|
| Idle MiSTer %onecpu (Plex, no cast) | **≤ 15** | ≥ 80 |
| 480p MiSTer %onecpu | **≤ 25** | ≥ 60 |
| H1 480p (ff+daemon) | within **±5** of stock ~86 | large H1 regression |
| F12 opens OSD during 480p | **must** | fail → abandon |
| `/dev/MiSTer_cmd` echo load still works | **must** | fail → abandon |
| drops / glass (your score) | equal-or-better vs stock | worse → investigate |

Publish every miss.

### 2.4 What NOT to do

- Do not compute headroom as `200 − accounted` / `200 − SYSTEM_BUSY`.  
- Do not default SUSPEND on.  
- Do not pkill/killall; only `kill <PID>` if you ever stop a lab process.  
- Do not match cmdline for misterplexd (flock trap).  
- Do not use bare `$12` in shell for stat fields — awk after `)`.  
- Do not trust `getconf CLK_TCK` (empty) — derive HZ as you already do.

---

## 3. timeout=5 A/B procedure (parent-owned binary swap)

Only after you have a **lab** Main binary with the patch (not this agent deploying):

```sh
# A) stock Main — idle 20s + 480p 30s CPU soak (your sampler)
# B) replace Main with timeout5 lab build, reboot or supervised restart of Main ONLY
#    (daily-driver: keep stock binary backup; restore path documented before swap)
# C) repeat soaks; F12 smoke; cmd smoke
# D) restore stock Main before leaving the box
```

Backup/restore is **your** ops call — agent does not script Main replacement onto the daily driver without your explicit deploy step.

Existing long-form:  
`.agent-work/w-cpu-1/MISTER_TIMEOUT5_PARENT_AB.md`  
`.agent-work/w-cpu-1/MISTER_IDLE_SPIN_RCA_PARENT_MEASURED.md`

---

## 4. Fixed-work alternative to “headroom”

When you need “is the publisher starved?” without elastic math:

```sh
# During 480p cast — daemon runqueue wait (exe-resolved D_PID from §1.2)
read e0 w0 s0 < /proc/$D_PID/schedstat
sleep 30
read e1 w1 s1 < /proc/$D_PID/schedstat
echo "daemon_runq_wait_ms_30s $(( (w1-w0)/1000000 )) exec_ms $(( (e1-e0)/1000000 ))"
echo "true rc=$?"
```

**PRE_REG:** if Main is the preemption source, timeout=5 or SUSPEND **lowers** `daemon_runq_wait_ms_30s` vs stock under same cast.  
If wait already ~0 on stock, Main CPU% is cosmetic for publish jitter (still reclaimable for other loads).

---

## 5. One-page verdict

| Question | Answer |
|----------|--------|
| What is it? | Stock Main loop: **`poll(...,0)`** on input/cmd pool except Menu∧FB (`timeout=25`); SPI runs every iteration as cargo |
| Our fault via DDR? | **No** (source: pool has no DDR) |
| Recoverable? | **Yes** — up to ~full core idle |
| Best lever | **`poll` timeout=5 while Plex** (keep F12); measure first |
| SUSPEND | Proven −45.7; **default OFF**; opt-in only |
| Headroom | **H1 + schedstat wait**, never `200−accounted` |

**Next action for you:** run §1.0–1.3 on idle Plex, paste wchan/stack majority + one soak line.  
Then we score timeout=5 vs stock against §2.3 bands.
