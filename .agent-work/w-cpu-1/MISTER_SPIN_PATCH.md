# `/media/fat/MiSTer` spin — root cause + concrete patch

**Branch tip (daemon work):** `w-instr-motion-counter`  
**Sources cited:** mirrored Main_MiSTer under `.agent-work/w-cpu-main-*.cpp`  
**Framing (load-bearing):** Main is an **elastic scavenger**. Never quote `200 − system_busy` as headroom.

---

## 1. Exact loop (what spins, what it polls)

### Outer

`main.cpp` pins **CPU1**, then `scheduler_run()`:

```c
// .agent-work/w-cpu-main-main.cpp:42-48, 75-77
CPU_SET(1, &set);
sched_setaffinity(0, sizeof(set), &set);
// ...
scheduler_init();
scheduler_run();
```

```c
// .agent-work/w-cpu-main-scheduler.cpp:26-41
static void scheduler_co_poll(void) {
  for (;;) {
    scheduler_wait_fpga_ready();
    user_io_poll();
    frame_timer();
    input_poll(0);
    video_poll();
    scheduler_yield();  // cothread switch only — NO sleep
  }
}
```

`scheduler_schedule` alternates `co_poll` ↔ `co_ui` (`HandleUI` / `OsdUpdate`). **Neither path sleeps** except inside `input_poll`’s `poll()`.

### Inner — the only sleep site

```c
// .agent-work/w-cpu-main-input.cpp:5596-5617
int timeout = 0;
if (is_menu() && video_fb_state()) timeout = 25;  // milliseconds

int return_value = poll(pool, NUMDEV + 3, timeout);
if (!return_value) break;  // timeout → leave inner while, return to scheduler
```

`pool` includes:

| slot | fd | purpose |
|------|-----|---------|
| `0..NUMDEV-1` | `/dev/input/*` | pads/keys/mice |
| `NUMDEV` | inotify watch | device add/remove |
| **`NUMDEV+1`** | **`/dev/MiSTer_cmd`** | **load_core, volume, video_mode, screenshot** |
| `NUMDEV+2` | LED sysfs | disk LED |

```c
// .agent-work/w-cpu-main-input.cpp:4051, 5140-5144, 6227-6242
#define CMD_FIFO "/dev/MiSTer_cmd"
// setup: mkfifo + open O_RDWR|O_NONBLOCK
// on POLLIN:
//   load_core → fpga_load_rbf / xml_load
//   volume / video_mode / screenshot / fb_cmd
```

### Why CPU is ~100% even “idle”

When `timeout == 0` (default for **all non-Menu cores**, and Menu without FB terminal):

1. `poll(..., 0)` is non-blocking.
2. No events → immediate return 0 → `break` out of inner while.
3. Scheduler immediately runs `user_io_poll` again (SPI status / SD poll / buttons) + UI.
4. Tight userspace loop on CPU1 → **~100 %onecpu scavenger**.

Stock already proves a timeout is viable: **Menu + `video_fb_state()` uses 25 ms** so the FB terminal has CPU. That is not theoretical — it is upstream behaviour for one mode only.

### Plex-specific?

**No.** Same binary, same `timeout=0` on Menu (no FB) and Plex. Parent measured both ~100% idle. Not induced by our doorbell/status path.

Under Plex (`CORE_TYPE_8BIT`), `user_io_poll` still runs `user_io_send_buttons`, `check_status_change`, and the generic SD `UIO_GET_SDSTAT` SPI loop every iteration — so each spin lap does real SPI work, then a non-blocking poll. Rate-limiting `input_poll` rate-limits the **whole** `co_poll` body because sleep sits at the end of that body.

---

## 2. Can it take a timeout/yield without breaking OSD / cmd?

### Yes — with the same mechanism Menu+FB already uses

`poll(pool, …, timeout_ms)`:

- **Wakes immediately** when any watched fd is ready (input **or** `MiSTer_cmd`).
- Blocks only when **idle**.
- Worst-case added latency for a cmd that arrives just after sleep starts = **`timeout_ms`** (not “cmd broken”).

OSD/UI: `co_ui` runs when `co_poll` yields. If `input_poll` blocks 5–25 ms, UI refresh rate drops to that order — **already accepted** for Menu+FB at 25 ms.

### Concrete patch (Main_MiSTer `input.cpp`, `input_test` state==2)

**Minimal Plex-scoped (lowest blast radius for a lab daily driver):**

```c
int timeout = 0;
if (is_menu() && video_fb_state()) {
    timeout = 25;
} else {
    /* Yield CPU when the loaded core is Plex. poll() still wakes
     * immediately on /dev/input/* and /dev/MiSTer_cmd. */
    const char *cn = user_io_get_core_name();
    const char *on = user_io_get_core_name(1); /* orig / RBF name */
    if ((cn && !strcasecmp(cn, "Plex")) ||
        (on && !strcasecmp(on, "Plex")))
        timeout = 5; /* ms; start here, measure 1 and 10 too */
}
```

**Upstream-friendlier variant** (if you maintain a fork long-term):

```c
/* cfg.h / mister.ini: input_poll_timeout=0..25  default 0 (stock) */
int timeout = 0;
if (is_menu() && video_fb_state()) timeout = 25;
else if (cfg.input_poll_timeout > 0) timeout = cfg.input_poll_timeout;
```

Then product can set `input_poll_timeout=5` only on the Plex box without hard-coding the name.

### What this is NOT

| Non-fix | Why |
|---------|-----|
| `nice +10` alone | Still spins; steals cache/power; weak reclaim |
| Affinity move off CPU1 | Fights Main’s stated IRQ isolation (`main.cpp` comment) |
| `SUSPEND_MAIN` as the *spin fix* | Stops **cmd** (see §3) — wrong tool for auto-load |

### Expected reclaim (honest)

| claim | status |
|-------|--------|
| Idle Main % drops from ~100 toward low single digits at timeout≥5 | **Hypothesis** — Menu+FB precedent; **must measure** on device |
| Play-time inelastic H1 (ffmpeg+daemon) improves | **Unknown** — scavenger already yields under load; may be small vs SUSPEND’s −45.7 |
| `MiSTer_cmd` still works | **By construction** if Main stays RUNNING and cmd fd stays in `pool` |

**Do not ship a %onecpu number until parent measures** with the patched binary (or a one-line `timeout = 5` lab build).

---

## 3. Interaction with auto-load + `SUSPEND_MAIN_DURING_PLAY`

### Cmd path requires a **running** Main

While Main is `T` (SIGSTOP):

- `poll` does not run → **`/dev/MiSTer_cmd` is not read**
- `echo load_core … > /dev/MiSTer_cmd` sits in the FIFO until CONT
- Our daemon’s `resumeStrandedMain()` will CONT stranded Main ~every 600 ms unless `MainSafeWindow` holds depth — so a long external STOP is unstable on our stack anyway  
  (`arm/misterplexd/fpga_spi.cpp`, `fpga_spi.hpp`)

### Ordering contract for cast auto-load (product)

```
[cast start]
  1. resumeStrandedMain() / ensure Main state != T
  2. write "load_core <Plex.rbf>" to /dev/MiSTer_cmd
  3. wait until core live (CORENAME / health — parent’s existing checks)
  4. start ffmpeg / present
  5. OPTIONAL only after 3: SUSPEND_MAIN during steady play
[cast end / need Menu or reload]
  6. CONT Main BEFORE any MiSTer_cmd
  7. then load_core / volume / etc.
```

### How timeout patch vs SUSPEND interact

| lever | Main state | `MiSTer_cmd` | F12/OSD | CPU reclaim | Cast auto-load |
|-------|------------|--------------|---------|-------------|----------------|
| **poll timeout (this patch)** | RUNNING | **OK** (≤timeout worst-case) | OK (slower refresh) | idle reclaim; play TBD | **Compatible** |
| **SUSPEND during play** | STOPPED | **DEAD until CONT** | DEAD | large (measured) | **Must CONT before load_core**; cannot suspend across load |
| Both | timeout while run; STOP only mid-play after load | OK if order held | OK outside STOP | max reclaim | OK if ordered |

**Recommendation for auto-load product path:**

1. **Ship / lab the Main `timeout=5` (or cfg) patch** as the default spin mitigation — keeps cmd alive for load_core at cast time and at idle on Menu.
2. **Do not default `SUSPEND_MAIN_DURING_PLAY=1`** if cast must load cores or issue cmd during session without a hard CONT protocol.
3. If suspend remains a manual lab lever: gate it behind “core already Plex AND no pending cmd”, and always CONT in the auto-load prelude (daemon already has `resumeStrandedMain` on boot paths).

---

## 4. Risk register

| risk | severity | mitigation |
|------|----------|------------|
| SD-heavy cores need sub-ms `user_io_poll` | med if global timeout | **Plex-scoped** timeout first |
| Input latency +5 ms | low for cast UI | start at 5; A/B 1 vs 10 |
| OSD feel “sluggish” | low at 5 ms | 25 ms already stock for Menu+FB |
| Wrong core name string | low | check `/tmp/CORENAME` and RBF name; log once |
| Replacing daily-driver Main | **high** | keep stock binary backup; parent-only deploy; easy revert |
| Expecting play-time −80 points | — | **do not**; measure H1/H3; timeout ≠ SUSPEND |

---

## 5. Parent measure commands (after optional Main lab binary)

**Safety:** backup stock `/media/fat/MiSTer` before replace. Revert = copy backup back + reboot if needed. Agent does not touch device.

```sh
set +e
# --- resolve Main by exe, never cmdline ---
MISTER_PID=""
for p in /proc/[0-9]*; do
  e=$(readlink -f "$p/exe" 2>/dev/null) || continue
  if [ "$e" = "/media/fat/MiSTer" ]; then MISTER_PID=${p#/proc/}; break; fi
done
echo "MISTER_PID=$MISTER_PID"
echo "true rc_resolve=$?"

# Sample %onecpu method (HZ=100), one window
# (or use tools/arm_cpu_sample.py on device)
python3 - <<'PY'
import os, time
HZ=100
pid=None
for name in os.listdir("/proc"):
    if not name.isdigit(): continue
    try:
        if os.readlink(f"/proc/{name}/exe")=="/media/fat/MiSTer":
            pid=int(name); break
    except Exception:
        pass
print("pid", pid)
if not pid:
    print("NO_DATA"); raise SystemExit(0)
def ticks(p):
    with open(f"/proc/{p}/stat") as f: sp=f.read().split()
    return int(sp[13])+int(sp[14])
t0=time.time(); k0=ticks(pid); time.sleep(5.0); t1=time.time(); k1=ticks(pid)
P=100.0*(k1-k0)/(HZ*(t1-t0))
print(f"mister_pct_onecpu={P:.2f} dwall={t1-t0:.3f}")
print("true rc_sample=0")
PY
echo "true rc_py=$?"

# Prove cmd still works with timeout binary (Menu or Plex):
# BEFORE: note core. Write a no-op-ish cmd first if needed.
# echo "volume unmute" > /dev/MiSTer_cmd
# sleep 0.2
# dmesg/log: expect Main prints MiSTer_cmd line; volume path runs
# true rc from write:
echo "volume unmute" > /dev/MiSTer_cmd
echo "true rc_cmd_write=$?"
```

**A/B matrix (parent):**

| arm | Main binary | core | expect (pre-reg qualitative) |
|-----|-------------|------|------------------------------|
| A | stock | Menu idle | Main ~100 |
| B | timeout=5 Plex-scoped | Menu idle | Main ~100 (patch inactive) |
| C | timeout=5 | Plex idle | Main **≪100** if patch works |
| D | timeout=5 | Plex 240p play | H1 ffmpeg+daemon vs stock; Main lower or similar |
| E | stock + SUSPEND play | Plex play | large reclaim; **cmd dead** until CONT |

Use `tools/arm_cpu_sample.py` + `tools/fixed_work_probe.py` for spare capacity — **not** `200−busy`.

---

## 6. Verdict

| question | answer |
|----------|--------|
| Why full core? | Scheduler + `poll(...,0)` busy lap on CPU1; only Menu+FB sleeps |
| Our core induce? | **No** (Menu same) |
| Fix without suspend? | **Yes:** non-zero `poll` timeout; cmd stays in `pool` → auto-load safe |
| Concrete change? | `input.cpp` timeout=5 when core name Plex (or cfg) — §2 |
| SUSPEND vs auto-load? | Suspend **breaks** cmd; timeout does **not**. Prefer timeout for product cast load; suspend only with CONT protocol |
| Recoverable %onecpu | **Measure** — design target is “most of the idle scavenger core”; play-time bonus unknown |

