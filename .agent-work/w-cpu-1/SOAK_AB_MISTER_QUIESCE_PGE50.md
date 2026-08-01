# A/B — Quiesce MiSTer Main vs publish_interval p_ge50

**Baseline (parent-measured, authoritative):**
- SYSTEM_BUSY 169/200 (84.5%), 60 s
- 30 s: MiSTer **90.6**, ffmpeg **69.6**, misterplexd **25.6**
- daemon md5 `7c991e47`, ~5 min 480p cast
- **`p_ge50 = 0.1450`** (MISS vs pre-reg 9–11% late band — high side)
- `acf lag1 = -0.1950` (catch-up)
- RBF `c5382bee…`: **do not score** PLXD `frames_done` / bank_vsync-packed presents/drops

**Evidence rule:** score only `publish_interval` ledger lines + exe-resolved CPU.  
**Agent does not touch device.**

---

## What 90.6 is (source + what still needs device proof)

### Source (upstream Main_MiSTer master — re-fetched; mirror `.agent-work/w-cpu-main-*`)

```c
// main.cpp — pin whole process to CPU1
CPU_SET(1, &set);
sched_setaffinity(0, sizeof(set), &set);

// input.cpp ~5596–5617
int timeout = 0;
if (is_menu() && video_fb_state()) timeout = 25; // ms ONLY Menu+FB
int return_value = poll(pool, NUMDEV + 3, timeout);
// timeout==0 → poll returns immediately when fds idle → spin

// scheduler co_poll: user_io_poll; frame_timer; input_poll(0); video_poll;
// scheduler_yield();  // libco — NOT sleep
```

`pool` = input devices + inotify + `/dev/MiSTer_cmd` + LED. **Not** DDR doorbell.

**Class (source):** timeout-free `poll` **elastic scavenger** on CPU1.  
**Not (source):** H.264 decode, our DDR memcpy, OSD full-frame paint as primary.

### Device proof still required (not assumed from %)

| ID | Check | PASS |
|---|---|---|
| E1 | `strace -c -p $M_PID` 10 s during cast | top syscall time = `poll`/`ppoll` ≥40% |
| E2 | `Cpus_allowed_list` | `1` |
| E3 | schedstat wait_frac | ≤5% (running, not blocked) |

If E1 fails (top ≠ poll) → mechanism **open**; quote the top syscall.

---

## PRE-REGISTER (publish BEFORE running A/B)

**Baseline this card locks:** `p_ge50_base = 0.1450` (parent soak).

| Arm | Action | Predict MAIN %onecpu | Predict `p_ge50` | Predict `acf_lag1` |
|---|---|---|---|---|
| **B0** | Repro: 480p cast, Main running (stock) | 80–95 | **0.12–0.18** (repro 0.145) | negative (catch-up), ∈ [−0.35, −0.05] |
| **B1** | Same cast class, Main **SIGSTOP** for soak window only, then **SIGCONT** | **≤ 2** (or NO-DATA if frozen ticks) | **≤ 0.06** if Main causal | closer to 0 than B0 (less catch-up) |
| **B2** (optional) | Lab Main `poll` timeout=5 Plex-scoped | 15–40 | **≤ 0.08** if causal | milder negative |

### Verdict rules (score after both arms)

| Result | Verdict |
|---|---|
| B1 MAIN≈0 **and** `p_ge50_B1 ≤ 0.06` **and** Δ = p_ge50_B0 − p_ge50_B1 ≥ 0.06 | **MAIN_CAUSAL** — reclaim is product-relevant for judder |
| B1 MAIN≈0 **and** `p_ge50_B1 ≥ 0.12` (within 0.03 of B0) | **MAIN_NOT_CAUSAL** — late publish is ffmpeg/daemon path; stop chasing Main for judder |
| B1 MAIN≈0 **and** `p_ge50_B1 ∈ (0.06, 0.12)` | **MAIN_PARTIAL** — contributes; other tails remain |
| B0 fails repro (`p_ge50_B0 < 0.09`) | **BASELINE_MISS** — do not interpret B1; re-soak |
| Cannot SIGSTOP safely / left stopped | **INVALID** — restore SIGCONT; discard |

**This is the standard:** predictions above are **not results**. Misses will be published.

### Risk (B1 SIGSTOP)

- **During STOP:** F12 / OSD / `/dev/MiSTer_cmd` / input dead.  
- **Mandatory:** `kill -CONT $M_PID` in a `trap` and after soak.  
- **Never** leave STOP on handback. Daily driver.  
- Prefer B2 lab binary if STOP is too scary; B1 is strongest falsifier.

---

## Runnable A/B (copy-paste)

### 0) Resolve Main by exe (never cmdline)

```sh
LAB=/media/fat/misterplex
M_PID=""
for d in /proc/[0-9]*; do
  exe=$(readlink -f "$d/exe" 2>/dev/null) || continue
  exe=${exe% (deleted)}
  b=$(basename "$exe")
  case "$b" in MiSTer|mister) M_PID=${d#/proc/} ;; esac
done
echo "M_PID=${M_PID:-NO-DATA}"
[ -n "$M_PID" ] || { echo "true rc=77"; exit 0; }
grep -E '^(Name|State|Cpus_allowed_list):' /proc/$M_PID/status
echo "true rc=$?"
```

### 1) E1 strace during cast (prove spin class)

```sh
# busybox: awk for /proc/stat — never `read a b c` on cpu line
command -v strace >/dev/null 2>&1 || { echo "NO-DATA strace"; echo "true rc=77"; exit 0; }
strace -c -f -p "$M_PID" 2>$LAB/lab_mister_strace_cast.txt &
SP=$!
sleep 10
kill -INT "$SP" 2>/dev/null || true
wait "$SP" 2>/dev/null
cat $LAB/lab_mister_strace_cast.txt
echo "true rc=$?"
```

### 2) B0 — baseline soak (Main running)

Parent: start same 480p cast class as the 0.145 soak.  
Ensure tip daemon emits `publish_interval` summary (w-geom ledger on successful publish).

During steady play (~60 s+):

```sh
# CPU 30s (or host tools/arm_cpu_sample.py if present on box)
sh /path/to/parent_t2_mister_ab.sh B
# After soak: grep daemon log for publish_interval (NOT PLXD frames_done)
# Example pattern (exact tag may vary — paste full line):
#   publish_interval ... p_ge50=... verdict=...
```

Record: `MAIN_B0`, `p_ge50_B0`, `acf` if printed, daemon md5, RBF id.

### 3) B1 — Main STOP during soak (strongest)

```sh
# PRE: cast playing, same asset, soak_continuity pid stable
M_PID=... # re-resolve
trap 'kill -CONT "$M_PID" 2>/dev/null; echo CONT_sent' EXIT INT TERM

kill -STOP "$M_PID"
echo "STOPPED $(date -Iseconds 2>/dev/null || date)"
# run SAME duration soak as B0; collect publish_interval + CPU
# CPU sample while stopped: Main ticks should barely advance
sh /path/to/parent_t2_mister_ab.sh B

kill -CONT "$M_PID"
trap - EXIT INT TERM
echo "CONTINUED $(date -Iseconds 2>/dev/null || date)"
grep -E '^(Name|State):' /proc/$M_PID/status
echo "true rc=$?"
```

**Handback check:** State = `S` or `R`, not `T`. F12 works.

### 4) What to paste back

```
B0: MAIN=  p_ge50=  acf_lag1=  SYSTEM_BUSY=  publish_interval_line=...
B1: MAIN=  p_ge50=  acf_lag1=  SYSTEM_BUSY=  publish_interval_line=...
strace_top=...
State_after_CONT=...
true rc each step
```

I score MAIN_CAUSAL / NOT / PARTIAL per table. **No PLXD presents/drops/frames_done.**

---

## Headroom numbers (accounting — not “free CPU for ffmpeg”)

| Quantity | Value | Label |
|---|---:|---|
| Main play (parent) | 90.6 | elastic scavenger |
| ffmpeg + daemon | 69.6+25.6 = **95.2** | inelastic |
| system busy | 169/200 | measured |
| If Main → 0 (SIGSTOP) | reclaim **~90 %onecpu** of one core ≈ **45% of machine** | upper bound elastic |
| If Main → 25 (timeout=5 lab) | reclaim **~65 %onecpu** | PREDICTION |

Honest “room for inelastic growth” after full Main quiesce ≈  
`200 − (busy − Main) ≈ 200 − (169 − 90.6) ≈ **121.6 / 200**`  
before new work — **still shared** with IRQ/kernel. Not a promise ffmpeg gets 90 points.

---

## Cost: resolution ceiling fix (w-geom RTL)

**Defect (quoted):** `present_core.sv:161-164`  
`H_DE=529`, `V_STORE=240` while `FRAME_W/H` macros 640×480 — fetches **240 rows / ~529 cols** of store mapping.

**ARM today already writes full coded bank** (`ddr_frame_layout.hpp`):  
`624×480 yuv420p = 449280 B` every publish (`kPlex480pYuv420pBytes`).

| Component | Δ if scanout fetches full 480 rows | Evidence class |
|---|---|---|
| ARM decode size | **0** — already 624×480 | code |
| ARM memcpy/publish bytes | **0** — full bank already | code |
| ffmpeg scale | **0** unless geometry contract changes | code |
| FPGA DDR **read** bandwidth during scanout | **~2× vertical** | arithmetic from V_STORE 240→480 |
| ARM CPU % from “more rows” | **~0 direct** | inference from byte path; confirm with CPU sample post-RBF |
| Memory-controller contention ARM write vs FPGA read | **UNKNOWN** — could worsen publish tails | measure p_ge50 after ceiling RBF **without** other changes |
| PLXD frames_done | still void on old RBF; new RBF must fix packing separately | parent |

**PRE_REG for ceiling-only RBF (when parent grants fit):**  
- `p_ge50` change ∈ **±0.03** vs same daemon/Main if only scanout mapping changes and ARM path identical.  
- If `p_ge50` **worsens by ≥0.05** → suspect DDR contention; re-measure with Main STOP.

**Do not** attribute ceiling fix as CPU headroom win for ARM inelastic — it is a **correctness/scanout** fix. Possible second-order bus contention only.

---

## Cost: hi-res overlay @ 84.5% busy

Update of `OVERLAY_COST_AND_MISTER.md` against **this** load.

### Host bench (NOT silicon) — measured on build host

| geom | renderYuv420p µs | frac of 41.67 ms | panel frac |
|---|---:|---:|---:|
| 624×480 panel 594×96 (scale1) | **470** | 1.1% | 19% |
| rows×2 panel ~594×192 (scale≥2 floor) | **~940 proj** | ~2.3% | ~38% |
| 1920×1080 panel 1824×216 | **3045** | 7.3% | 19% |

### A9 absolute

**UNKNOWN** — no host→A9 scale. Must use `PRESENT_PROFILE=1` → `overlay_us_*` / `present_us_p99` on device.

### Affordability at SYSTEM_BUSY 169/200

| Scenario | Assessment |
|---|---|
| Overlay **off** (no chrome) | `NEVER_CALLED` — **0** added; safe |
| Burst chrome 3 s, dirty-rect, 624 path scale≥2 | Host says ~2% frame; on A9 at 95% inelastic+scavenger — **risk of present tail >41.7 ms** without Main reclaim |
| Full-screen composite every frame at 800×600 / 640×480 | **Hostile** at current load: order-of-magnitude from 1080 host bench (~7% of budget on fast host) → A9 likely **multiple ms to tens of ms**; can raise `p_ge50` |
| After Main reclaim (if MAIN_CAUSAL) | Overlay becomes **much** more plausible; still gate on `present_us_p99 < 35000` |

### Binding gates before shipping hi-res overlay

1. Prefer **Main reclaim A/B done** first if judder is #1.  
2. `PRESENT_PROFILE=1`, force chrome ≥30 calls.  
3. `present_us_p99 < 35000`, `present_us_max < 41667`.  
4. `publish_interval` `p_ge50` not worse than baseline by **>0.03**.  
5. **Never** gate on PLXD presents/drops/frames_done on `c5382bee`.

### Scale targets user asked (800×600 / 640×480 / 240p)

| Present target | Coded bank today | Overlay note |
|---|---|---|
| 640×480 | 624×480 YUV | match existing bench class |
| 240p | 320×240 class | cheaper panel; scale≥2 glyphs still required if store y-scale 2 |
| 800×600 | **not** current product bank | new geometry + more bytes — cost **unmeasured**; treat as new present path |

---

## Priority order (product)

1. **E1 strace + B0/B1 A/B** (this card) — settles whether 90.6 fixes judder.  
2. If MAIN_CAUSAL → lab timeout=5 or product-safe Main sleep policy.  
3. Ceiling RTL (correctness) — ARM CPU ~flat; watch p_ge50.  
4. Hi-res overlay only after 1–2 and profile gates green.
