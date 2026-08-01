# ARM CPU during 480p — measured split RCA (w-cpu)

**Parent measurement (authoritative):** one window 50.127 s, exe-resolved,  
`P=100*dticks/(HZ*dwall)`, HZ=100, continuous 624×480@24, PRESENT=fpga,  
`DDR_YUV_FORCE_SCALE=1`, `FFMPEG_SWS_FLAGS=fast_bilinear`, daemon md5 `36b89bcb`.

| Consumer | %onecpu | Notes |
|---|---:|---|
| `/media/fat/MiSTer` | **78.0** | stock Main — not our binary |
| ffmpeg | **60.5** | SW decode + vf |
| misterplexd | **24.3** | present/publish path |
| **Accounted** | **162.8** | |
| **System busy** | **173.1 / 200** | **86.6% of dual A9** |
| Residual | **10.3** | see §2 |

**Framing (binding):** glass path healthy (~0.07% miss). This is **headroom for FPGA-decode roadmap**, **not** a drop fix. Do not claim CPU work fixes drops.

**Headroom statistic:** never `200−busy` as “free for us”. Main is an **elastic scavenger** (`poll` timeout 0). Honest numbers: inelastic = ffmpeg+daemon = **84.8 %onecpu** this window; residual/kernel separate; Main is reclaimable scavenger not fixed demand.

---

## 1. MiSTer 78% — root cause (quoted source)

### Path (Main_MiSTer; mirror `.agent-work/w-cpu-main-*.cpp`)

```c
// main.cpp — pin entire Main to CPU1
CPU_SET(1, &set);
sched_setaffinity(0, sizeof(set), &set);

// scheduler.cpp — co_poll lap (no nanosleep)
user_io_poll();
frame_timer();
input_poll(0);    // sole blocking opportunity
video_poll();
scheduler_yield(); // libco switch, not sleep

// input.cpp ~L5596–5617
int timeout = 0;
if (is_menu() && video_fb_state()) timeout = 25; // ms — ONLY Menu+FB
int return_value = poll(pool, NUMDEV + 3, timeout);
// timeout==0 → idle poll returns immediately → spin
```

`pool` = `/dev/input/*` + inotify + **`/dev/MiSTer_cmd`** + LED sysfs.

**Class:** timeout-free **`poll(..., 0)` busy-wait / elastic scavenger on CPU1**.  
Not “OSD drawing 78%”. Not software video decode. When fds are idle, Main burns the core; when the system is loaded, it still often shows high % because it runs whenever the runqueue lets it (here 78% of one core).

### Does **our** design provoke it?

| Hypothesis | Evidence |
|---|---|
| Stock on any non-Menu+FB core | **Yes (source):** only Menu∧FB gets timeout=25. Plex is neither → timeout=0. Parent earlier: same class burn on Menu idle. |
| Our DDR frame writes wake Main | **Not via poll pool.** DDR/F1 is FPGA-side; Main’s `poll` set is input/cmd/LED. **No source path** from our doorbell into Main’s poll wake list. |
| We spam `/dev/MiSTer_cmd` | **Would** wake poll immediately; that is event-driven work, not a continuous spin. Continuous 78% with steady play is **not** explained by rare cmd traffic unless something hammers cmd (not claimed without log proof). |
| Rumble SPI every lap when `!is_menu()` | Source runs rumble `spi_uio_cmd` each inner loop iteration for devices with rumble. Extra SPI on non-Menu cores; **secondary** to timeout=0. |
| Plex-specific “makes it worse than Menu” | Parent play 78% vs prior idle class 83–100%: **compatible with scavenger yielding**, not proof we elevated Main. |

**Verdict:** spin is **stock Main behaviour on Plex (non-Menu+FB)**. Our workload **competes for CPU** with it; we did **not** invent the timeout=0 path. Reclaim = non-zero poll timeout (lab patch), or SUSPEND during play (UX cost), not “stop DDR writes”.

**Live proof still parent-owned:** `strace -c -p $M_PID` 10s → top=`poll` (card: `PARENT_C1_C4_MISTER_CONTENTION_CARD.md`).

---

## 2. Unaccounted 10.3 %onecpu (162.8 vs 173.1)

**Honest answer:** a `/proc/<pid>/stat` **process** sampler **does not** attribute:

- Hardirq / softirq (often on CPU0; Main is on CPU1)
- Kernel threads (`kworker/*`, `ksoftirqd/*`, mmcqd, etc.) if not walked
- Short-lived processes that die between samples
- Threads of a process if only the group leader is counted incorrectly (this method used whole-process utime+stime — OK for single-thread Main; ffmpeg is multi-thread **included** in one pid’s utime+stime on Linux)
- `nice` / steal / guest in `cpu` line vs sum of processes

**10.3 / 173.1 ≈ 6% of busy** is **within normal** residual for this method on a loaded system.  

**Do not invent:** “it’s the Ethernet driver” / “it’s SPI” without measurement.

**Settling check (parent) — residual breakdown, still no name-guess:**

```sh
# Same window method: sum ALL /proc/[pid] utime+stime deltas (every pid),
# plus read /proc/stat cpu line user+nice+system+irq+softirq deltas.
# Residual_kernelish ≈ system_busy - sum_all_userspace_pids
# If sum_all_pids ≈ system_busy, short-lived was the gap.
# If irq+softirq ≈ 10, that is the gap.
```

Exact script: §6. Until run: **unaccounted = NO-DATA attribution**, magnitude measured.

---

## 3. ffmpeg 60.5% — filter graph (quoted)

### What the daemon builds (`ffmpeg_vf.hpp` + `media_player.cpp`)

```cpp
// media_player.cpp ~2758–2790
forceScale = yuvDdrPresent && ddrYuvForceScale_;  // conf DDR_YUV_FORCE_SCALE=1
vfReq.scale_mode = ffmpegScaleModeForDdrYuvPresent(confScaleMode, forceScale);
// forceScale && SkipIdentity → Always  (yuv420p_chroma_health.hpp:117-121)

// buildFfmpegVideoFilter:
// fps_filter first (e.g. fps=24/1), then scale+pad unless identity_skip
```

**480p product geometry** (`ddr_frame_layout`): coded **624×480**, display **618×480** (crop_right=6) → `hasCrop=true`.

**With FORCE_SCALE=1 (Always), crop path:**

```text
fps=24/1,scale=618:480:flags=fast_bilinear:force_original_aspect_ratio=decrease,pad=624:480:<x>:<y>:color=black
```

(`buildScalePadCropped` in `ffmpeg_vf.hpp`.)

**Pixel format:** `-pix_fmt` on rawvideo output — **not** inside `-vf` (`ffmpeg_vf.hpp` comment L261–262). One convert at encode-to-raw boundary, not a second scale-for-format.

### Redundant?

| Stage | Avoidable? |
|---|---|
| **H.264 SW decode** 624×480@24 | **No** until FPGA decode — dominant cost class |
| **`fps=24/1`** | Cheap; CFR pin; keep |
| **`scale=618:480` + `pad=624:480` under FORCE_SCALE=1** | **Yes, often redundant** when delivery is **verified** 624×480: `SkipIdentity` + `clearYuv420pCropPadding` is the designed path (`identity_skip_crop_pad_clear`). FORCE_SCALE=1 **forces Always**, disabling that skip — **full swscale every frame** even if source already matches coded. |
| **Second independent scale** | **No** — graph is one scale + one pad, not scale twice to arbitrary sizes |
| **fast_bilinear** | Already the cheap sws path (parent: −24.9 %onecpu vs bicubic cluster) |

**Headroom lever (not a drop fix):** after verified delivery, `DDR_YUV_FORCE_SCALE=0` with conf `skip_identity` allows identity_skip and ARM crop clear — **removes per-frame swscale** when source==coded. Risk class is known (unverified identity_skip → pipe desync); only with `delivery_verified=1`. Parent must measure ffmpeg % with force_scale 0 vs 1 on same fixture.

**Not claiming** this recovers most of 60.5% — decode remains. Expect **partial** reclaim of the scale slice only.

---

## 4. DEFECT 1 `substr(0,4)` — tree vs deploy

| Tree | Deployed `36b89bcb` @ `533a4bca` |
|---|---|
| **Fixed** in `5d1dd996`: `fmtFpsRate` → `%.4f`, `wall_ms=`, single media site | **Still broken** — parent needle `ed1fc22f:3536-3537` class |

Current tip (`media_player.cpp`):

```cpp
" vfps=" + fmtFpsRate(vfps) +   // %.4f
" pfps=" + fmtFpsRate(pfps) +
" wall_ms=" + std::to_string(wall2) +
```

**Gate tightened:** `tests/unit/test_media_fps_precision.sh` — forbids any `to_string(*fps*).substr`, requires exactly one `vfps=` site using `fmtFpsRate`.

**Parent action:** deploy a binary built from ≥`5d1dd996` (or tip); confirm log shows `vfps=23.9694` style and `wall_ms=`. Until then live telemetry remains non-evidence.

---

## 5. Priority attack order (headroom roadmap)

1. **Main poll timeout lab** (or SUSPEND during play) — reclaim ~full core elastic; largest single chunk (78%).  
2. **FORCE_SCALE=0 when delivery_verified** — cut avoidable swscale; measure Δ ffmpeg %.  
3. **FPGA decode** — attacks the inelastic 60% class.  
4. **misterplexd 24%** — present path; secondary after 1–3.

---

## 6. Parent commands (no agent device touch)

### 6a. Confirm Main spin (C1-S)

See `PARENT_C1_C4_MISTER_CONTENTION_CARD.md` strace block. PRE_REG: top syscall = `poll`.

### 6b. Residual 10.3 — full pid sum + /proc/stat

```sh
# 20s window; busybox-friendly. Writes one summary line.
HZ=100
SEC=20
# snapshot A
awk '/^cpu /{print}' /proc/stat > /media/fat/misterplex/lab_cpu_a.txt
: > /media/fat/misterplex/lab_pids_a.txt
for d in /proc/[0-9]*; do
  p=${d#/proc/}
  [ -r "$d/stat" ] || continue
  rest=$(sed 's/^[^)]*) //' "$d/stat") || continue
  set -- $rest
  # utime=$12 stime=$13 after comm-stripped rest (Linux)
  echo "$p $(( $12 + $13 ))" >> /media/fat/misterplex/lab_pids_a.txt
done
sleep "$SEC"
awk '/^cpu /{print}' /proc/stat > /media/fat/misterplex/lab_cpu_b.txt
: > /media/fat/misterplex/lab_pids_b.txt
for d in /proc/[0-9]*; do
  p=${d#/proc/}
  [ -r "$d/stat" ] || continue
  rest=$(sed 's/^[^)]*) //' "$d/stat") || continue
  set -- $rest
  echo "$p $(( $12 + $13 ))" >> /media/fat/misterplex/lab_pids_b.txt
done
# Host-side or on-box awk: sum delta ticks all pids; parse cpu line
# user nice system idle iowait irq softirq ...
echo "pull lab_cpu_*.txt lab_pids_*.txt; true rc follows snapshot"
echo "true rc=$?"
```

**PRE_REG R1:** `100*sum_all_pid_dticks/(HZ*dwall)` within ~3 pts of process-accounted method.  
**PRE_REG R2:** `(user+nice+system+irq+softirq)` delta from `cpu` line → system busy; `irq+softirq` share of residual.

### 6c. FORCE_SCALE A/B (ffmpeg only; same 480p fixture)

```sh
# PRE_REG: force_scale=0 + delivery_verified=1 → lower ffmpeg %onecpu than force_scale=1
# by a measurable scale slice (not "near zero"). Glass must stay pixel-OK.
# Parent owns conf backup/restore (user-owned conf).
# Sample exe-resolved ffmpeg+Main+daemon 30s each condition; compare.
```

### 6d. After deploy — DEFECT1

```sh
grep -E 'vfps=|wall_ms=' "$LOG" | tail -n 5
# PASS: vfps has ≥4 decimal digits or not equal for 23.9694 vs 23.9111 class; wall_ms= present
echo "true rc=$?"
```

---

## 7. What this does **not** claim

- Does not fix the 0.07% glass miss  
- Does not attribute residual 10.3 without §6b  
- Does not claim FORCE_SCALE=0 is free (desync risk if unverified)  
- Does not claim live md5 `36b89bcb` has fps precision fix  
