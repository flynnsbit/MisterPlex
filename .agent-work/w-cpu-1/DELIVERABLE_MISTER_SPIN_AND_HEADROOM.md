# DELIVERABLE — MiSTer spin RCA + honest headroom

**Branch tip:** see `status.txt`  
**ERROR 17 (parent):** fps=24/1 vs 23.976 defect **FALSE**. Lab fixtures are 24.000;
rational is per-asset. **Nothing product-side was changed for that false defect.**
`hdmi_motion_instrument.py` default `src_fps=23.976` is a **hardcoded constant**, not a
measurement. Lane: do not re-open fps filter “fixes”.

**Scope:** source quotes + host tools. Parent runs all device commands. No Main product ship
without lab protocol (`MISTER_TIMEOUT5_LAB.md`).

---

## 1. What `/media/fat/MiSTer` spins ON (quoted)

Upstream: MiSTer-devel/Main_MiSTer. Mirror: `.agent-work/w-cpu-main-*.cpp`.

### Outer loop — no sleep, cothread yield only

```c
// scheduler.cpp — scheduler_co_poll
for (;;) {
    scheduler_wait_fpga_ready();
    user_io_poll();   // may early-return for non-8bit cores; still called every lap
    frame_timer();
    input_poll(0);    // <-- sole sleep opportunity
    video_poll();
    scheduler_yield(); // libco switch — NOT nanosleep
}
// scheduler_run: for (;;) scheduler_schedule();  // alternate co_poll / co_ui forever
```

### Sole sleep site — default timeout = 0

```c
// input.cpp ~L5596–5617  (mirror .agent-work/w-cpu-main-input.cpp)
if (state == 2)
{
    int timeout = 0;
    if (is_menu() && video_fb_state()) timeout = 25;  // ms — ONLY Menu+framebuffer

    while (1)
    {
        /* optional rumble SPI when !is_menu() */
        int return_value = poll(pool, NUMDEV + 3, timeout);
        if (!return_value) break;  // timeout=0 → immediate return when fds idle
        /* drain ready fds */
    }
}
```

**Mechanism (evidence-backed):** with `timeout=0`, idle `poll` returns immediately →
`scheduler_co_poll` re-enters → full userspace lap on **CPU1** (affinity pin in main.cpp) →
**83–100 %onecpu** with nothing to do. Stock already proves non-zero timeout works:
Menu **and** `video_fb_state()` → 25 ms.

**Not “SPI-only”:** SPI appears in `user_io_poll` / rumble paths, but the **always-on**
burn is the **timeout-free poll + yield** lap. For many cores `user_io_poll` early-returns
(`core_type` not 8BIT/SHARPMZ) — spin still remains via `input_poll`’s `poll(...,0)`.

### What `pool` watches (wake sources if timeout > 0)

```c
// input.cpp
#define CMD_FIFO "/dev/MiSTer_cmd"
pool[0..NUMDEV-1]  // /dev/input/*
pool[NUMDEV]       // inotify hotplug
pool[NUMDEV+1]     // open(CMD_FIFO)  → load_core, volume, ...
pool[NUMDEV+2]     // LED sysfs
```

So a non-zero timeout **still wakes immediately** on controller input and on
`echo load_core ... > /dev/MiSTer_cmd`.

**Not Plex-induced:** parent measured same class burn on stock Menu.

---

## 2. Targeted alternatives to whole-process SIGSTOP

| approach | From source | Keeps F12 / MiSTer_cmd? | Notes |
|----------|-------------|-------------------------|-------|
| **`poll` timeout > 0** (e.g. 5 ms), Plex-scoped or cfg | **Yes** — same site as Menu+FB 25 ms | **Yes** — pool includes cmd + input | Requires **patched Main** binary. Lab-only until measured. Card: `MISTER_TIMEOUT5_LAB.md` |
| Stock INI/conf for poll timeout | **None found** in mirrored sources | — | — |
| `nice` / affinity only | Does not stop busy-poll | Yes | Weak; scavenger still runs |
| **`SUSPEND_MAIN_DURING_PLAY=1`** | misterplexd SIGSTOP | **No** while `T` | Parent-proven reclaim 68.1%→22.4% dual busy; default OFF correctly |
| misterplexd-only product fix | **No** — loop is inside Main | — | — |

**Verdict:**  
- **In-tree without Main fork:** only **suspend** (or live with scavenger).  
- **Surgical fix that keeps OSD/cmd:** non-zero `poll` timeout at `input.cpp` L5596–5617.  
- **Not “SPI spin only”** — do not chase SPI disable as the primary fix.

**Auto-load / suspend ordering:** while Main is `T`, `/dev/MiSTer_cmd` is dead. Product cast
auto-load must `CONT` Main **before** `load_core`. SUSPEND stays lab/opt-in on product path.

---

## 3. Honest headroom (replace `166.4/200 ⇒ 33.6`)

**Invalid:** `system_busy` mixes inelastic (ffmpeg, daemon) with **elastic scavenger** (Main
timeout-free poll). `200 − busy` is **never** headroom.

| metric | meaning |
|--------|---------|
| **H1** | Inelastic only: sum `%onecpu` of ffmpeg + misterplexd (exe-resolved) |
| **H2** | `/proc/<pid>/schedstat` **wait_frac** on ffmpeg threads + daemon (`wait_ns/(run+wait)`) |
| **H3** | Fixed-work wall ratio play/idle (`fixed_work_probe.py`) |

### Tools (repo `tools/`)

| script | role |
|--------|------|
| `arm_cpu_sample.py` | P=100\*dticks/(HZ\*dwall); exe identity |
| `headroom_sample.py` | table + ACCOUNTED_SUM |
| `schedstat_sample.py` | H2; `ffmpeg_agg` over threads |
| `fixed_work_probe.py` | H3; `--compare` idle vs play |
| `starvation_480p_verdict.py` | wait_frac gates → VERDICT |

Identity rules: `readlink -f /proc/pid/exe`; strip ` (deleted)`; match `*misterplexd*`
substring on basename — **never** cmdline (`flock` ERROR 14). Absence = **NO-DATA**, not 0.0.

### Parent device one-shot (copy scripts first; either install root)

```sh
set +e
ROOT=/media/fat/misterplex_v2   # or misterplex — match live
OUT=$ROOT/cpu_probe
mkdir -p "$OUT"
# PLAY window: confirm ffmpeg + misterplexd exe exist; wall_s advancing
python3 "$ROOT/tools/arm_cpu_sample.py" --seconds 8 --label play -o "$OUT/h1_play.json"
echo "true rc_h1=$?"
python3 "$ROOT/tools/schedstat_sample.py" --seconds 20 --label play -o "$OUT/h2_play.json"
echo "true rc_h2=$?"
python3 "$ROOT/tools/fixed_work_probe.py" --iters 80000000 --label play -o "$OUT/h3_play.json"
echo "true rc_h3=$?"
# IDLE (no play): same three; then:
python3 "$ROOT/tools/fixed_work_probe.py" --compare "$OUT/h3_idle.json" "$OUT/h3_play.json"
echo "true rc_cmp=$?"
```

**Quote to humans:** H1 inelastic %onecpu + H2 wait_frac + H3 wall ratio. Report Main % as
**elastic scavenger**, separate line. Never residual headroom.

---

## 4. ERROR 17 unwind checklist

| Item | Status |
|------|--------|
| Product fps filter forced 24 against 23.976 | **Never shipped** from that false finding |
| Rational path / `fps=24000/1001` when asset is 23.976 | **Keep** — correct |
| `hdmi_motion_instrument` default 23.976 | Labelled DEFAULT_ASSUMED; not a measurement |
| Startup-drop “duplicate frame” story | **Not used** — drops = pacer residual-lead repay |

---

## 5. Related cards

- `MISTER_TIMEOUT5_LAB.md` — lab Main patch, backup/revert, pre-reg, OSD/cmd latency falsifiers  
- `STARVATION_480P_EXPERIMENT.md` — H2 confirm/refute ffmpeg starve  
- `STARTUP_DROP_VARIANCE_RCA.md` — drop count (not lip-sync; H-DROP rejected)  
