# PARENT A/B — Main `poll` timeout=5 (LAB ONLY)

**Agent:** w-cpu · branch `w-avsync-hdmi-measure`  
**Applyable patch:** `.agent-work/w-cpu-1/patches/main_mister_input_timeout5_plex.patch`  
```sh
cd Main_MiSTer && patch -p1 < /path/to/main_mister_input_timeout5_plex.patch
```

**ERROR 17:** absorbed — no fps work; fixtures are 24.000; discard any “duplicate frame
every 41.7s” story. Nothing product was built on that false defect.

**117 ms A/V clusters (parent SESSION-LATCHED):** real device defect; daemon-blind;
instrument exonerated. This Main-timeout lab does **not** claim to fix lip-sync clusters.
It only targets elastic Main CPU spin. Do not use `av_drift_ms` as success for this lab.

**NOT A PRODUCT SHIP.** Daily-driver Main. Lab experiment only until you score reclaim
and latency falsifiers.

**Elastic scavenger:** never quote `200 − system_busy` as headroom. Use H1 inelastic /
H2 schedstat wait_frac / H3 fixed-work only.

---

## 1. Minimal patch (before / after)

**File:** MiSTer-devel/Main_MiSTer `input.cpp` (mirror `.agent-work/w-cpu-main-input.cpp` **L5596–5617**)

### BEFORE (stock)

```c
	if (state == 2)
	{
		int timeout = 0;
		if (is_menu() && video_fb_state()) timeout = 25;

		while (1)
		{
			// ... optional rumble SPI when !is_menu() ...
			int return_value = poll(pool, NUMDEV + 3, timeout);
			if (!return_value) break;
			// pool: /dev/input/*, inotify, /dev/MiSTer_cmd, LED
		}
	}
```

### AFTER (lab — Plex-scoped; preferred)

```c
	if (state == 2)
	{
		int timeout = 0;
		if (is_menu() && video_fb_state()) {
			timeout = 25;
		} else {
			/* LAB ONLY — not upstream. Measure + revert.
			 * poll() still returns immediately when any pool fd is ready
			 * (controllers, /dev/MiSTer_cmd). Idle is the only sleep. */
			const char *cn = user_io_get_core_name();
			const char *on = user_io_get_core_name(1);
			if ((cn && !strcasecmp(cn, "Plex")) ||
			    (on && !strcasecmp(on, "Plex")))
				timeout = 5; /* milliseconds */
		}

		while (1)
		{
			// ... unchanged ...
			int return_value = poll(pool, NUMDEV + 3, timeout);
			if (!return_value) break;
		}
	}
```

**One-line global probe** (faster; hits Menu too — higher risk):

```diff
-		if (is_menu() && video_fb_state()) timeout = 25;
+		if (is_menu() && video_fb_state()) timeout = 25;
+		else timeout = 5; /* LAB global — revert after measure */
```

Prefer **Plex-scoped** on the daily driver.

`pool[NUMDEV+1]` = `/dev/MiSTer_cmd` (input.cpp `CMD_FIFO`, open ~L5143–5144).

---

## 2. PRE-REGISTERED predictions (publish hit/miss)

### Derivation (not a silicon measurement)

- Stock idle: parent measured Main **100.0 %onecpu** with `timeout=0` → loop is
  back-to-back `poll` returns (work per lap = W seconds of CPU).
- With `timeout=T` ms and idle fds, wake rate ≤ `1000/T` Hz.
  CPU ≈ `100 * (W) / (W + T/1000)` %onecpu.
- W is unknown a priori. Bound: Menu+FB already uses **T=25** and is considered
  usable; T=5 is **5×** that wake rate (more CPU than Menu+FB idle path, far less
  than T=0).
- If W were 0.5 ms: T=5 → ~9 %onecpu; if W=2 ms → ~29 %onecpu; if W=0.1 ms → ~2 %.
- **Band, not point** (parent ERROR 15 class: point extrapolations fail).

| quantity | PREDICT (band) | MISS if |
|----------|----------------|---------|
| Main idle %onecpu after patch (Plex core loaded, nothing playing) | **5–30** (center narrative ~12) | still **≥70** (patch ineffective / wrong binary) OR **NO-DATA** (exe missing) |
| Main 240p-play %onecpu | **10–45** (was 83.0) | still **≥70** |
| Δ Main idle (stock − lab) | **+55 to +95 points reclaimed** | reclaim **&lt;30** points |
| Input edge latency add (worst case, quiet bus) | **≤ 5 ms** (one poll period); typical ~0–2.5 ms | sustained **&gt;15 ms** vs stock on same pad test |
| `load_core` via `/dev/MiSTer_cmd` extra latency | **≤ 5 ms** wake + same work | **&gt;100 ms** extra vs stock or **cmd ignored** |
| F12 / OSD | still works on Plex | dead / needs double-press storm |

**Not predicted as headroom:** `200 − system_busy`. After reclaim, report **H1**
(ffmpeg+daemon only), **H2** wait_frac, **H3** fixed-work ratio.

**vs SUSPEND:** if idle Main lands in 5–30 and play Main &lt;45 **and** F12/cmd work,
timeout=5 is **strictly better** than `SUSPEND_MAIN_DURING_PLAY` (reclaim without
killing OSD/cmd). That is the preferred product outcome **only after** lab scores
green — still not auto-ship Main.

---

## 3. Exact A/B commands (parent runs; method mandatory)

### Method (binding)

- ONE window, ONE wall clock  
- `P = 100 * dticks / (HZ * dwall)` · HZ=100 typical  
- Process ID: `readlink -f /proc/<pid>/exe` only — **never** cmdline  
- Strip ` (deleted)`; match basename `*misterplexd*` / `*MiSTer*` / `*ffmpeg*`  
- Absence → **NO-DATA**, never 0.0  
- `cmd; echo "true rc=$?"` direct — never through a pipe alone  

Prefer repo tools copied to device:

```sh
# on device, once:
# scp tools/arm_cpu_sample.py tools/schedstat_sample.py tools/fixed_work_probe.py root@mister:/media/fat/misterplex_v2/tools/
```

### 3A — BACKUP stock (do this first)

```sh
set +e
cp -a /media/fat/MiSTer /media/fat/MiSTer.stock.labbak
ls -la /media/fat/MiSTer /media/fat/MiSTer.stock.labbak
md5sum /media/fat/MiSTer /media/fat/MiSTer.stock.labbak
echo "true rc_bak=$?"
```

### 3B — STOCK baseline (idle, Plex or Menu — label it)

```sh
set +e
OUT=/media/fat/misterplex_v2/cpu_lab
mkdir -p "$OUT"
# Confirm Main exe exists
MAIN_N=0
for p in /proc/[0-9]*; do
  e=$(readlink -f "$p/exe" 2>/dev/null) || continue
  e=${e% (deleted)}
  case "$e" in */MiSTer) MAIN_N=$((MAIN_N+1)); echo "MAIN_PID=${p#/proc/} EXE=$e";; esac
done
echo "MAIN_N=$MAIN_N"
# If MAIN_N=0 → NO-DATA, stop
python3 /media/fat/misterplex_v2/tools/arm_cpu_sample.py --seconds 8 --label stock_idle -o "$OUT/stock_idle_h1.json"
echo "true rc_stock_idle_h1=$?"
python3 /media/fat/misterplex_v2/tools/fixed_work_probe.py --iters 80000000 --label stock_idle -o "$OUT/stock_idle_h3.json"
echo "true rc_stock_idle_h3=$?"
```

### 3C — STOCK play 240p (optional pair)

```sh
set +e
# start 240p cast; confirm ffmpeg + misterplexd by exe; wall_s advancing
python3 /media/fat/misterplex_v2/tools/arm_cpu_sample.py --seconds 8 --label stock_play240 -o "$OUT/stock_play240_h1.json"
echo "true rc_stock_play_h1=$?"
python3 /media/fat/misterplex_v2/tools/schedstat_sample.py --seconds 20 --label stock_play240 -o "$OUT/stock_play240_h2.json"
echo "true rc_stock_play_h2=$?"
```

### 3D — Install lab binary + restart Main

Build on host (toolchain): clone Main_MiSTer, apply AFTER diff, `make`, get `bin/MiSTer`.

```sh
set +e
# from host after scp bin/MiSTer → /media/fat/MiSTer.lab_timeout5
cp -a /media/fat/MiSTer.lab_timeout5 /media/fat/MiSTer
sync
md5sum /media/fat/MiSTer /media/fat/MiSTer.stock.labbak /media/fat/MiSTer.lab_timeout5
# Restart Main — prefer your known-safe init path; do NOT kill -9 storm
# Example if supervised by init script:
#   /media/fat/MiSTer &   # only if you know the box's normal start
echo "true rc_install=$?"
```

### 3E — LAB measure (same method as 3B/3C)

```sh
set +e
# same MAIN_N check; must be lab md5
python3 /media/fat/misterplex_v2/tools/arm_cpu_sample.py --seconds 8 --label lab_idle -o "$OUT/lab_idle_h1.json"
echo "true rc_lab_idle_h1=$?"
python3 /media/fat/misterplex_v2/tools/fixed_work_probe.py --iters 80000000 --label lab_idle -o "$OUT/lab_idle_h3.json"
echo "true rc_lab_idle_h3=$?"
python3 /media/fat/misterplex_v2/tools/fixed_work_probe.py --compare "$OUT/stock_idle_h3.json" "$OUT/lab_idle_h3.json"
echo "true rc_h3_cmp=$?"
# play 240p again if scoring play reclaim
python3 /media/fat/misterplex_v2/tools/arm_cpu_sample.py --seconds 8 --label lab_play240 -o "$OUT/lab_play240_h1.json"
echo "true rc_lab_play_h1=$?"
```

### 3F — Latency falsifiers (must pass for “strictly better than SUSPEND”)

```sh
set +e
# 1) F12 OSD open — wall clock by hand or serial; expect responsive
# 2) Controller: button to OSD action
# 3) load_core (Main must be CONT / not suspended):
t0=$(date +%s%3N)
echo "load_core /media/fat/_Utility/Plex.rbf" > /dev/MiSTer_cmd
# wait until CORENAME=Plex or timeout 15s — your existing check
t1=$(date +%s%3N)
echo "load_core_wall_ms=$((t1-t0))"
echo "true rc_cmd=$?"
```

### 3G — INSTANT REVERT

```sh
set +e
cp -a /media/fat/MiSTer.stock.labbak /media/fat/MiSTer
sync
md5sum /media/fat/MiSTer /media/fat/MiSTer.stock.labbak
# restart Main same way as install
echo "true rc_revert=$?"
```

If box is wedged: boot to storage, restore `MiSTer.stock.labbak` → `MiSTer`, power cycle.

---

## 4. Risk statement

| | `timeout=5` lab Main | `SUSPEND_MAIN_DURING_PLAY` |
|--|----------------------|----------------------------|
| Reclaim idle core | **Predicted** large (see §2) | **Measured** −45.7 dual-busy pts class |
| F12 / OSD during play | **Alive** (poll still services input) | **Dead** while `T` |
| `/dev/MiSTer_cmd` / `load_core` | **Alive** (fd in pool) | **Dead** while `T` |
| Auto-load cast path | Compatible | Needs CONT before cmd |
| Daily-driver risk | **Patched Main** — wrong binary bricks UX until revert | In-tree misterplexd flag |
| Blast radius | Plex-scoped preferred; global hits Menu | Play-only |

**If lab hits the reclaim band and latency falsifiers stay green, timeout=5 makes
SUSPEND unnecessary for CPU reclaim and is strictly better for user-facing Main
features.** That still does **not** auto-promote a Main fork to product — you own
that ship gate after measurements.

**Risks if patch wrong:** still 100% CPU (miss); input feel soft (miss &gt;15 ms);
cmd path broken (miss); uncommon core name match fails Plex-scope (NO reclaim on
Plex — check `user_io_get_core_name`).

---

## 5. ERROR 17 discard list

| Built on false 23.976 rate mismatch? | Action |
|--------------------------------------|--------|
| Product fps filter change | **Never shipped** — nothing to unwind |
| Drop-as-duplicate-cleanup story | **Discard** — drops are pacer residual-lead repay / startup only |
| Instrument default 23.976 as “measured” | **Discard** — DEFAULT_ASSUMED only |

