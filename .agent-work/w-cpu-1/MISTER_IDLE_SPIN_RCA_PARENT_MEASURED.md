# MiSTer idle spin RCA — parent 240p/480p CPU table (w-cpu)

**Artifact pair for parent table (parent-stated):** RBF `8fdf440f`, daemon `7c991e47`.  
**Ceiling:** dual A9 = **200 %onecpu**. Method: exe-resolved, HZ from `/proc/stat` (parent).  
**This document:** host/source analysis only — no device claims beyond parent-quoted numbers.

---

## 0. Parent measurement (accepted as given)

| arm | ffmpeg | misterplexd | our code | `/media/fat/MiSTer` | accounted |
|-----|--------|-------------|----------|---------------------|-----------|
| idle | absent | 1.0 | **1.0** | **99.8** | 102.2 |
| 240p (320×240 delivered) | 39.2 | 22.1 | **61.3** | 86.8 | 150.3 |
| 480p (624×480 delivered) | 64.2 | 21.9 | **86.1** | 76.4 | 164.6 |

**Elastic scavenger pattern (from the table, not a guess):**  
idle Main **99.8** → under load **86.8 / 76.4** while our inelastic work rises. Main shrinks when others grow.  
**Do not** compute headroom as `200 − accounted` (adds inelastic to elastic).  
**Inelastic product work** = ffmpeg + misterplexd only:

| arm | H1 = ff+daemon | Main (elastic) |
|-----|----------------|----------------|
| idle | 1.0 (daemon only; ff=NO-DATA) | 99.8 |
| 240p | **61.3** | 86.8 |
| 480p | **86.1** | 76.4 |

---

## 1. Root cause — quoted Main_MiSTer source (PROVEN)

Fetched **2026-08-01** from `MiSTer-devel/Main_MiSTer` master raw; matches in-repo mirror  
`.agent-work/w-cpu-main-*.cpp`.

### 1.1 Pin to CPU1 + endless scheduler

`main.cpp` (upstream master):

```cpp
// Always pin main worker process to core #1 as core #0 is the
// hardware interrupt handler in Linux.  This reduces idle latency
// in the main loop by about 6-7x.
cpu_set_t set;
CPU_ZERO(&set);
CPU_SET(1, &set);
sched_setaffinity(0, sizeof(set), &set);
// ...
#ifdef USE_SCHEDULER
	scheduler_init();
	scheduler_run();
#else
	while (1) {
		user_io_poll();
		frame_timer();
		input_poll(0);
		HandleUI();
		OsdUpdate();
	}
#endif
```

### 1.2 Scheduler poll co-thread — no sleep of its own

`scheduler.cpp`:

```cpp
static void scheduler_co_poll(void)
{
	for (;;)
	{
		scheduler_wait_fpga_ready();
		{
			user_io_poll();
			frame_timer();
			input_poll(0);   // sole place that can block
			video_poll();
		}
		scheduler_yield();   // cothread switch only — not a nanosleep
	}
}
```

### 1.3 `input_poll`: **timeout-free `poll` except Menu∧FB** — HYPOTHESIS PROVED

`input.cpp` (upstream line numbers from raw fetch; mirror L5596–5617):

```cpp
if (state == 2)
{
	int timeout = 0;
	if (is_menu() && video_fb_state()) timeout = 25;  // ms ONLY

	while (1)
	{
		// ... rumble SPI ...
		int return_value = poll(pool, NUMDEV + 3, timeout);
		if (!return_value) break;
		// ... drain /dev/input/*, /dev/MiSTer_cmd, etc. ...
	}
}
```

| Condition | `timeout` | Behaviour |
|-----------|-----------|-----------|
| **Plex core loaded** (not Menu) | **0** | `poll(..., 0)` returns immediately → busy spin |
| Menu core **and** framebuffer on | **25** | blocks up to 25 ms when idle → sleeps |
| Menu, FB off | **0** | same spin as any non-Menu core |

**Working hypothesis "timeout-free SPI/input poll": PROVED for any non-(Menu∧FB) core, including Plex.**  
It is **stock Main design**, not a Plex DDR doorbell reaction. Pool is input fds + cmd + hotplug — not our DDR mailbox.

**Why idle is 99.8 with daemon alive:** Plex core is loaded (parent CORENAME context); `is_menu()` is false → `timeout=0` forever. Daemon at 1.0 does not drive the spin.

**Why load drops Main 99.8→76–87:** same busy loop competes for CPU1/time; inelastic work preempts it — classic elastic scavenger, not "Main got more efficient."

---

## 2. 240p vs 480p sub-linear cost — verify from **our** source

Parent: 480p = **1.40×** our CPU for **3.90×** pixels; daemon flat 22.1 vs 21.9.

### 2.1 DDR bank bytes fixed at coded size

```text
yuv420pFrameBytesWH(624,480) = 624*480*3/2 = 449280
yuv420pFrameBytesWH(320,240) = 115200   # delivery only — not the bank write size
```

Product path presents into the **coded** store (624×480). Both tiers push **449280 B/frame** on the DDR path when decode target is 624×480 — matches parent "DDR push is 449280 at both tiers" and **flat daemon**.

### 2.2 Scale only when delivery ≠ coded

`host/libmisterplex/ffmpeg_vf.hpp` `buildFfmpegVideoFilter`:

- `SkipIdentity` + verified source WxH == coded → `identity_skip=1`, **no** scale/pad  
- else → `buildScalePadCentered` / crop path → `scale_applied=1` (`arm_rescale=1` in GEOM log)

| Tier | delivered | vs coded 624×480 | expected vf |
|------|-----------|------------------|-------------|
| 480p | 624×480 verified | match | `identity_skip=1`, zero ARM resample |
| 240p | 320×240 | mismatch | scale→pad (e.g. 618:480 + pad 624:480), `arm_rescale=1` |

**ffmpeg 39.2 → 64.2** is decode cost + (240p only) swscale; **not** 4× because 480p skips resample.  
**Daemon flat** is predicted by equal bank write size, not by pixel count of the *source*.

Source-side verification only — parent already measured the CPU table.

---

## 3. What is recoverable?

### 3.1 Options (ranked)

| Rank | Mitigation | Expected reclaim | Cost / risk | Ship? |
|------|------------|------------------|-------------|-------|
| **1** | **Main `poll` timeout when core=Plex** (lab patch: `timeout=5` ms) | Most of idle ~100 %onecpu → order-of Menu+FB sleep behaviour; under play, Main stops scavenging a full core | F12/OSD/`MiSTer_cmd` **stay live**; poll still returns immediately on fd ready | **Best product fix** — lab Main binary or upstream PR; **measure before default** |
| **2** | **`SUSPEND_MAIN_DURING_PLAY=1`** (SIGSTOP Main for play session) | Parent historical **−45.7** dual-busy points; drops 3→0 on that lineage | While `T`: **F12/OSD/`/dev/MiSTer_cmd`/load_core dead**. Plex TCP stop still works → user not stuck in cast | **Opt-in only**, default **OFF**. **Not on product HEAD** as session conf today — HEAD only micro-SIGSTOP for SPI CS + `resumeStrandedMain()` watchdog (`fpga_spi.cpp`) |
| **3** | nice/affinity on daemon vs Main | Unknown without measure | Daily-driver risk if Main starves on CPU0 IRQs | Measure-only until proven |
| **4** | Do nothing on Main; shrink ffmpeg only | Leaves 76–100 Main elastic load manufacturing preemption noise | Safe | Insufficient alone for judder confound |

### 3.2 Recommendation (crisp)

1. **Do not default-on session SUSPEND** on the daily driver. Keep OFF. Document as **lab/opt-in** if re-ported to HEAD (must hold stop across play, block watchdog CONT during play, atexit/CONT mandatory).  
2. **Prefer targeted `poll` timeout (5 ms) while CORENAME=Plex** — recovers the scavenger **without** killing OSD/cmd. Lab patch:  
   `.agent-work/w-cpu-1/patches/main_mister_input_timeout5_plex.patch`  
3. **PRE_REGISTER before parent measures timeout=5 Main binary** (publish misses):

| Metric | PRE_REG band if timeout=5 works | Kill criterion (Main not the spin) |
|--------|--------------------------------|-------------------------------------|
| MiSTer idle %onecpu (Plex loaded, no cast) | **≤ 15** (vs parent 99.8) | Still ≥ 80 |
| MiSTer 480p play %onecpu | **≤ 25** (vs parent 76.4) | Still ≥ 60 |
| H1_inelastic 480p | **unchanged within ±5** vs 86.1 | — |
| F12 opens OSD during play | **must work** | broken → abandon patch |
| `sampler_self` | report measured | — |

4. **Headroom metric forever:** quote **H1_inelastic** and **SYSTEM_BUSY** separately. Never `200 − accounted`. Optional saturation: `/proc/<misterplexd>/schedstat` runqueue wait — not Main %.

### 3.3 SUSPEND vs timeout=5 (tradeoff one-liner)

| | timeout=5 (Plex-scoped) | SUSPEND_MAIN_DURING_PLAY |
|--|-------------------------|---------------------------|
| Reclaim | large (sleep in poll) | parent −45.7 pts historical |
| F12/OSD/cmd during play | **live** | **dead** while `T` |
| Plex stop | works | works (:3005) |
| Default | after A/B green | **OFF** |
| On product HEAD today | patch not shipped | session conf **absent** (SPI micro-stop only) |

**Ship posture:** pursue **timeout=5 lab Main A/B** first; keep SUSPEND as nuclear opt-in only.

---

## 4. Parent commands (device — parent runs)

### 4.1 Confirm wchan/stack = poll (optional, proves on *this* binary)

```sh
# Resolve MiSTer by exe only
M_PID=""
for d in /proc/[0-9]*; do
  exe=$(readlink -f "$d/exe" 2>/dev/null) || continue
  case "$(basename "${exe% (deleted)}")" in MiSTer|mister) M_PID=${d#/proc/};; esac
done
echo "M_PID=${M_PID:-NO-DATA}"
# 20 stack samples (~1s)
i=0; while [ "$i" -lt 20 ]; do
  echo "--- sample $i ---"
  cat /proc/$M_PID/wchan 2>/dev/null; echo
  tr '\0' '\n' < /proc/$M_PID/stack 2>/dev/null | head -8
  i=$((i+1))
  sleep 0.05
done
echo "true rc=$?"
# PRE_REG: majority of samples show poll_schedule_timeout / do_sys_poll / syS_poll
```

### 4.2 timeout=5 A/B (only after lab Main binary deployed — parent-owned)

Use existing card `.agent-work/w-cpu-1/MISTER_TIMEOUT5_PARENT_AB.md` + CPU sampler:

```sh
RBF_PATH=/media/fat/_Utility/Plex.rbf \
LOG=/media/fat/misterplex_v2/misterplexd.log \
sh /media/fat/misterplex_v2/arm_cpu_soak.sh 30
echo "true rc=$?"
```

Compare stock Main vs timeout=5 Main on **same** RBF+daemon md5; score MiSTer %onecpu + F12 smoke — not `200−busy`.

---

## 5. Rule 0 summary

| Claim | Status |
|-------|--------|
| Main spins on `poll(...,0)` when not Menu∧FB | **PROVED** — quoted `input.cpp` + GitHub master |
| Spin is stock Main, not Plex DDR-induced | **PROVED** — pool is input/cmd; timeout gate is `is_menu()&&video_fb_state()` |
| Elastic scavenger | **PROVED** by parent table (99.8→76–87 as H1 rises) |
| 480p sub-linear vs 240p due to identity_skip | **Source-consistent**; parent CPU table matches |
| SUSPEND −45.7 | **Parent historical measure** — not re-measured this turn |
| timeout=5 reclaim magnitude on device | **UNKNOWN until parent A/B** — bands in §3.2 |

**No device was touched by this agent.**
