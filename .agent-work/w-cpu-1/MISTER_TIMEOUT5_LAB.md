# LAB ONLY — Main_MiSTer `poll` timeout=5 on Plex

**NOT A PRODUCT CHANGE.** `/media/fat/MiSTer` is upstream Main on the user’s **daily driver**.  
This card is a **reproducible lab experiment** with backup/revert, pre-registered reclaim band, and falsifiers.  
Do **not** ship a patched Main from this reasoning chain alone.

**Agent:** w-cpu · tip branch for daemon work: `w-instr-motion-counter`  
**Upstream:** MiSTer-devel/Main_MiSTer · file **`input.cpp`**  
**Verified line match (master raw, 2026-07-31 fetch):** lines **5596–5617** identical to repo mirror `.agent-work/w-cpu-main-input.cpp`.

**Elastic scavenger:** Main’s CPU is not inelastic demand. **Never** quote `200 − system_busy` as headroom. Spare capacity → H3 fixed-work or H2 `schedstat` wait_frac only.

---

## (a) Upstream site + minimal diff

### Stock (master `input.cpp`)

```c
// input.cpp ≈ L5594–5618  (function input_test, state == 2)
if (state == 2)
{
    int timeout = 0;
    if (is_menu() && video_fb_state()) timeout = 25;

    while (1)
    {
        // ... rumble ...
        int return_value = poll(pool, NUMDEV + 3, timeout);
        if (!return_value) break;
        // ... input devs, inotify, /dev/MiSTer_cmd, LED ...
    }
}
```

`pool[NUMDEV+1]` is **`/dev/MiSTer_cmd`** (open at ~L5140–5144; handler ~L6227–6242: `load_core`, `volume`, …).

### Minimal lab diff (Plex-scoped only — lowest blast radius)

```diff
--- a/input.cpp
+++ b/input.cpp
@@ -5594,7 +5594,18 @@ int input_test(int getchar)
 	if (state == 2)
 	{
 		int timeout = 0;
-		if (is_menu() && video_fb_state()) timeout = 25;
+		if (is_menu() && video_fb_state()) {
+			timeout = 25;
+		} else {
+			/* LAB: yield idle CPU on Plex only. poll() still returns
+			 * immediately when /dev/input/* or /dev/MiSTer_cmd is ready.
+			 * NOT upstream; measure then revert. */
+			const char *cn = user_io_get_core_name();
+			const char *on = user_io_get_core_name(1);
+			if ((cn && !strcasecmp(cn, "Plex")) ||
+			    (on && !strcasecmp(on, "Plex")))
+				timeout = 5; /* milliseconds */
+		}
 
 		while (1)
 		{
```

Requires existing includes (`user_io.h` already pulled via `input.cpp` headers — `user_io_get_core_name` is declared in `user_io.h`). If link fails, `#include "user_io.h"` is already present in stock input.cpp line ~26 area.

**One-line even smaller lab probe** (all cores — higher risk, faster to type):

```diff
-		if (is_menu() && video_fb_state()) timeout = 25;
+		if (is_menu() && video_fb_state()) timeout = 25;
+		else timeout = 5; /* LAB global — revert immediately after measure */
```

Prefer **Plex-scoped** for the daily-driver box so Menu stays stock behaviour.

---

## (b) Build + **instant revert**

### Build (host with MiSTer ARM toolchain)

```sh
set +e
# On a build machine — NOT required to be the MiSTer:
git clone --depth 1 https://github.com/MiSTer-devel/Main_MiSTer.git
cd Main_MiSTer
# apply minimal diff to input.cpp
# Toolchain: arm-none-linux-gnueabihf-gcc (MiSTer docs / release toolchain)
make -j"$(nproc)"
echo "true rc_make=$?"
# Artifact: bin/MiSTer  (see upstream Makefile PRJ=MiSTer BUILDDIR=bin)
ls -la bin/MiSTer
echo "true rc_ls=$?"
```

Cross-check: upstream `Makefile` sets `BASE = arm-none-linux-gnueabihf`, `PRJ = MiSTer`, `BUILDDIR = bin`.

### Deploy to device (parent only) — **backup first**

```sh
set +e
MISTER_HOST="${MISTER_HOST:-192.168.1.183}"
# 1) Backup stock while box is healthy
ssh root@${MISTER_HOST} 'cp -a /media/fat/MiSTer /media/fat/MiSTer.stock.labbak && \
  ls -la /media/fat/MiSTer /media/fat/MiSTer.stock.labbak && \
  md5sum /media/fat/MiSTer /media/fat/MiSTer.stock.labbak'
echo "true rc_bak=$?"

# 2) Copy lab binary (keep name MiSTer)
scp bin/MiSTer root@${MISTER_HOST}:/media/fat/MiSTer.lab_timeout5
ssh root@${MISTER_HOST} 'cp -a /media/fat/MiSTer.lab_timeout5 /media/fat/MiSTer && sync'
echo "true rc_deploy=$?"

# 3) Restart Main only (init paths vary; prefer graceful)
# Resolve by exe — match *MiSTer* basename; never cmdline.
ssh root@${MISTER_HOST} 'sh -s' <<'EOS'
set +e
pid=""
for p in /proc/[0-9]*; do
  e=$(readlink -f "$p/exe" 2>/dev/null) || continue
  e=${e% (deleted)}
  case "$e" in */MiSTer) pid=${p#/proc/}; break;; esac
done
echo "old_pid=$pid"
if [ -n "$pid" ]; then kill "$pid"; echo "true rc_kill=$?"; else echo "true rc_kill=1"; fi
# user-startup / init usually respawns MiSTer; wait
sleep 2
pid2=""
for p in /proc/[0-9]*; do
  e=$(readlink -f "$p/exe" 2>/dev/null) || continue
  e=${e% (deleted)}
  case "$e" in */MiSTer) pid2=${p#/proc/}; break;; esac
done
echo "new_pid=$pid2"
readlink -f /proc/$pid2/exe 2>/dev/null
md5sum /media/fat/MiSTer
echo "true rc_respawn=$?"
EOS
```

### REVERT — three tiers (memorize before experiment)

| tier | when | action |
|------|------|--------|
| **R0 instant soft** | SSH still works | `cp -a /media/fat/MiSTer.stock.labbak /media/fat/MiSTer && sync` then `kill` Main pid (exe-resolved); wait respawn |
| **R1 hard power** | UI dead but SSH works | R0 then `reboot` |
| **R2 offline SD** | no network / hard lock | Power off → mount SD on PC → restore `MiSTer.stock.labbak` → `MiSTer` → reinsert |

**R0 one-liner (parent keeps this in scrollback before any kill):**

```sh
set +e
ssh root@${MISTER_HOST:-192.168.1.183} 'cp -a /media/fat/MiSTer.stock.labbak /media/fat/MiSTer && sync && \
  for p in /proc/[0-9]*; do e=$(readlink -f "$p/exe" 2>/dev/null) || continue; e=${e% (deleted)}; \
  case "$e" in */MiSTer) kill "${p#/proc/}"; echo killed=${p#/proc/}; break;; esac; done; sleep 2; \
  md5sum /media/fat/MiSTer /media/fat/MiSTer.stock.labbak; echo true rc_revert=$?'
echo "true rc_ssh_revert=$?"
```

**Lab rule:** no second experiment until R0 verified (md5 stock == live MiSTer).

---

## (c) Pre-registered reclaim prediction (judge me on silicon)

Method: `P = 100 * dticks / (HZ * dwall)`, HZ=100, one window ≥5 s, pid by `readlink` exe (`*MiSTer` / realpath), **absence = NO-DATA**.

Baseline (parent-measured, this project): idle Main **83–100 %onecpu** (Menu and Plex).

| condition | metric | **predicted band** | notes |
|-----------|--------|--------------------|-------|
| Plex core, **idle**, timeout=5 | Main %onecpu | **8–30** | Reclaim **~55–90 points** from ~100. Floor >0: `user_io_poll` SPI still runs ~200 Hz. |
| Plex core, **idle**, timeout=5 | reclaim points | **55–90** | If Main stays **>50** → **MISS** (patch ineffective or name mismatch). If Main **<5** → unexpected win; still publish. |
| Plex **240p play** | Main %onecpu | **10–40** | Stock play was ~75–85 elastic; timeout may or may not beat CFS yielding. **Wide band on purpose.** |
| Plex 240p play | H1 ffmpeg+daemon | **0 to −12 points** vs stock play | Contention relief only; **not** a second fast_bilinear. 0 is a hit if Main drops. |
| Menu idle (Plex-scoped patch) | Main %onecpu | **83–100** (unchanged) | Control: patch must be inactive on Menu. If Menu drops → accidental global timeout. |

**Explicit non-predictions (do not score):**  
play-time “got a whole core back”; any `200−busy` headroom; scaling-cost-style point estimates without band.

**Miss policy:** publish predicted band vs measured; if Main idle **>50** on Plex with patch, stop and RCA (core name string? binary not running? still timeout 0?).

---

## (d) Responsiveness falsifiers (“no regression”)

Measure **stock baseline first**, then lab binary, same core state. Fail = ship-blocker for the lab conclusion “safe enough to consider again”.

### D1 — `/dev/MiSTer_cmd` wake latency (primary, scriptable)

`poll` must wake on cmd fd. Bound: **p99 cmd-to-Main-log ≤ max(stock_p99 + 15 ms, 25 ms)**  
(5 ms timeout → theoretical worst sleep remainder 5 ms; allow 15 ms slack for scheduling).

```sh
set +e
# On device; Main logging to console or /var/log if available.
# Prefer: time until /tmp/CORENAME stable after a no-op-ish cmd that Main handles quickly.
# volume unmute does not reload FPGA — good latency probe.
OUT=/media/fat/misterplex/lab_main_timeout
mkdir -p "$OUT"
# Drop a marker file when we write; parent correlates with HDMI/serial if needed.
for i in 1 2 3 4 5 6 7 8 9 10; do
  t0=$(date +%s%N)
  echo "volume unmute" > /dev/MiSTer_cmd
  # Busy-wait: Main touches activity — best effort without serial:
  # readlink CORENAME loop is weak for volume; use dmesg/journal if Main stdout not available.
  # Minimum bar: write succeeds and system still accepts a second cmd 50ms later.
  echo "volume unmute" > /dev/MiSTer_cmd
  t1=$(date +%s%N)
  echo "i=$i write_pair_ns=$((t1-t0))"
  sleep 0.05
done
echo "true rc_cmd_flood=$?"
# HARD fail if write blocks > 100ms wall (FIFO full / Main dead):
python3 - <<'PY'
import time, os
t0=time.time()
os.system('echo "volume unmute" > /dev/MiSTer_cmd')
dt=(time.time()-t0)*1000
print(f"single_write_wall_ms={dt:.2f}")
print("FAIL_WRITE_BLOCKED" if dt>100 else "WRITE_OK")
print("true rc_write_probe=0")
PY
```

**load_core latency (functional, not FPGA program time):**

```sh
set +e
# ONLY if parent accepts a core reload. Prefer Menu→Plex once per arm.
# t_cmd = write load_core; t_name = first time /tmp/CORENAME reads Plex (or target).
# FAIL if (t_name - t_cmd) > stock_same_measure + 500ms  (name adopt; NOT full config time)
# FAIL hard if CORENAME never changes within 15s (cmd not serviced — Main dead/stopped).
echo "true rc_load_core_measure_placeholder=0"
```

Numbers to record:

| check | stock | lab | fail if |
|-------|-------|-----|---------|
| single `volume` write wall ms | — | — | **>100 ms** (blocked FIFO) |
| 10× write pair | — | — | any hang; box needs R0 |
| load_core → CORENAME adopt | T_s | T_l | **T_l > T_s + 0.5 s** or no adopt ≤15 s |
| Main still exe-alive after 60 s idle | yes | yes | pid gone / no respawn |

### D2 — OSD open latency (HDMI, parent capture)

Parent: from F12 (or OSD button) to first frame with OSD opaque panel.

| | fail if |
|--|---------|
| lab p50 − stock p50 | **> 50 ms** |
| lab p95 | **> stock p95 + 80 ms** |
| lab absolute p95 (if no stock) | **> 200 ms** wall key→visible |

(5 ms poll sleep cannot add 200 ms alone; larger deltas ⇒ different bug / stuck SPI.)

### D3 — Controller / key path

| check | fail if |
|-------|---------|
| Menu navigation still moves selection | no motion for 1 s held d-pad |
| During Plex, mapped key still reaches daemon/input path you already use | zero events for 1 s while holding |
| Optional: time key-down to on-screen reaction | lab p50 > stock p50 **+ 40 ms** |

### D4 — Auto-load ordering still holds

With lab Main **running** (not SUSPEND):

1. `resumeStrandedMain` / confirm Main not `T`  
2. `load_core` Plex  
3. play  

**FAIL** if load_core ignored while Main running (would mean cmd fd not in poll set — regression).  
SUSPEND remains **lab-only** and **out of scope** for this timeout experiment.

---

## Measure card — Main %onecpu (before/after)

```sh
set +e
python3 - <<'PY'
import os, time
HZ = os.sysconf(os.sysconf_names.get("SC_CLK_TCK", "SC_CLK_TCK")) if False else 100
# prefer libc
try:
    HZ = os.sysconf("SC_CLK_TCK")
except Exception:
    HZ = 100

def exe_of(pid):
    try:
        p = os.readlink(f"/proc/{pid}/exe")
    except OSError:
        return None
    if p.endswith(" (deleted)"):
        p = p[: -len(" (deleted)")]
    return p

def find_mister():
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        e = exe_of(int(name))
        if e and e.rstrip("/").endswith("/MiSTer") or (e and os.path.basename(e) == "MiSTer"):
            return int(name), e
    return None, None

def ticks(pid):
    with open(f"/proc/{pid}/stat") as f:
        raw = f.read()
    rp = raw.rfind(")")
    rest = raw[rp+2:].split()
    return int(rest[11]) + int(rest[12])  # utime+stime fields 14+15 → idx 11+12 after )

pid, ex = find_mister()
print("pid", pid, "exe", ex)
if not pid:
    print("NO_DATA")
    print("true rc_sample=0")
    raise SystemExit(0)
t0 = time.time(); k0 = ticks(pid)
time.sleep(5.0)
t1 = time.time(); k1 = ticks(pid)
P = 100.0 * (k1 - k0) / (HZ * (t1 - t0))
print(f"mister_pct_onecpu={P:.2f} dwall={t1-t0:.4f} HZ={HZ}")
print("true rc_sample=0")
PY
echo "true rc_py=$?"
```

Also run `tools/arm_cpu_sample.py` (H1 + per-core) and `tools/fixed_work_probe.py` for spare capacity — **not** `200−busy`.

**Exe match note:** during deploy, `readlink` may show `.../misterplexd (deleted)` — strip suffix; classify with **`misterplexd` substring on basename**, never `*/misterplexd` exact tail-only glob that drops `(deleted)`.

---

## Go / no-go after lab

| result | action |
|--------|--------|
| Idle Plex Main in **8–30** band, falsifiers green | Document as **LAB_OK**; product decision separate (fork maintenance cost) |
| Main idle **>50** | **LAB_FAIL** effectiveness; do not discuss ship |
| Any D1–D3 fail | **LAB_FAIL** safety; R0 immediately |
| Menu idle changed with Plex-scoped patch | **LAB_FAIL** scope; RCA name match |

**Product ship of patched Main is out of scope of this card.**
