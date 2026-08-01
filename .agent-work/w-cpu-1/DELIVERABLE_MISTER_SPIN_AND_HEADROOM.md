# DELIVERABLE — MiSTer spin RCA + headroom method

**ERROR 17 absorbed:** fps=24/1 vs 23.976 defect **does not exist**. Lab clips are 24.000; rational is per-asset. Lane closed. Do not change fps path.

**Scope:** host/source analysis + scripts. Parent runs device. No product Main binary ship without lab protocol.

---

## 1. WHY `/media/fat/MiSTer` burns ~100 %onecpu

### Quoted loop (Main_MiSTer master `input.cpp` L5594–5618; mirror `.agent-work/w-cpu-main-input.cpp`)

```c
if (state == 2)
{
    int timeout = 0;
    if (is_menu() && video_fb_state()) timeout = 25;  /* ms — ONLY Menu+FB */

    while (1)
    {
        /* ... rumble SPI ... */
        int return_value = poll(pool, NUMDEV + 3, timeout);
        if (!return_value) break;   /* timeout=0 → immediate return when idle */
        /* handles /dev/input/*, inotify, /dev/MiSTer_cmd, LED */
    }
}
```

### Outer driver (no sleep)

```c
/* scheduler.cpp — scheduler_co_poll */
for (;;) {
    user_io_poll();   /* SPI status / SD / buttons — every lap */
    frame_timer();
    input_poll(0);    /* above poll; only sleep site when timeout>0 */
    video_poll();
    scheduler_yield(); /* cothread switch ONLY — not a nanosleep */
}
```

```c
/* main.cpp — pin CPU1 */
CPU_SET(1, &set);
sched_setaffinity(0, sizeof(set), &set);
```

**Mechanism:** default `poll(..., timeout=0)` is non-blocking. Idle → immediate return → scheduler immediately re-enters `user_io_poll` + SPI. Tight userspace lap on CPU1 → **83–100 %onecpu** even with nothing to do.

**Not Plex-induced:** same on stock Menu (parent measured). Only exception in stock: Menu **and** `video_fb_state()` → `timeout=25`.

**What it polls:** input devices, hotplug inotify, **`/dev/MiSTer_cmd`** (`load_core`, volume, …), LED sysfs — all in `pool`.

---

## 2. Can it idle WITHOUT suspension?

| approach | works? | cost |
|----------|--------|------|
| **Non-zero `poll` timeout** (e.g. 5 ms) when core is Plex or via cfg | **Yes, by construction** — same as Menu+FB. `poll` still wakes **immediately** on input or `MiSTer_cmd`. | Needs **patched Main binary** (not our repo). Daily-driver risk. Lab card: `MISTER_TIMEOUT5_LAB.md` |
| Conf/INI stock knob for poll timeout | **None found** in mirrored sources | — |
| `nice` / affinity alone | Does not stop the spin | weak |
| **`SUSPEND_MAIN_DURING_PLAY=1`** | **Proven reclaim** 68.1%→22.4% dual busy; HDMI/DDR OK while `T` | F12/OSD/`MiSTer_cmd`/`load_core` **dead** until CONT. Default OFF correctly. |
| Product misterplexd-only fix | **No** — spin is inside Main | — |

**Verdict:**  
- **Without replacing Main:** only **suspension** (or living with the scavenger) is available in-tree.  
- **With a lab/patched Main:** `timeout=5` (Plex-scoped) is the targeted fix; keeps OSD/cmd alive; see lab protocol for backup/revert/falsifiers.  
- **Do not** treat suspension as “the only physics possible” — stock already proves timeout works for Menu+FB — but **shipping a Main fork is a product decision**, not a misterplexd commit.

**Elastic scavenger:** under load Main often falls ~100→75–85. That is **not** free headroom for inelastic work until H2/H3 say so. **Never quote `200 − system_busy` as headroom.**

---

## 3. Headroom method replacement

| bad | good |
|-----|------|
| `166.4/200 ⇒ 33.6 headroom` | **H1** inelastic only: ffmpeg + misterplexd `%onecpu` |
| mixing Main into “used” | **H2** `schedstat` wait_frac on ffmpeg/daemon threads |
| | **H3** fixed-work wall ratio idle vs play |

### Scripts (repo `tools/`, parent copies to device — either root)

| script | purpose |
|--------|---------|
| `tools/arm_cpu_sample.py` | per-core + per-exe `%onecpu`; H1; strips `(deleted)` |
| `tools/headroom_sample.py` | full table + ACCOUNTED_SUM vs system busy |
| `tools/schedstat_sample.py` | H2 runqueue wait; **`ffmpeg_agg` over all threads** |
| `tools/fixed_work_probe.py` | H3 fixed iters wall; `--compare` idle vs play |
| `tools/starvation_480p_verdict.py` | apply wait_frac gates → VERDICT= |

Identity: `readlink /proc/pid/exe` only; `misterplexd` **substring** on basename (survives `misterplexd (deleted)`). Never cmdline.

### Parent one-shot (device)

```sh
set +e
OUT=/media/fat/misterplex_v2/headroom   # or misterplex/ — match live root
mkdir -p "$OUT"
# validity: ffmpeg + misterplexd exe present; playback live (wall_s advancing)
python3 /media/fat/misterplex_v2/bin/../tools/arm_cpu_sample.py --seconds 8 --label play -o "$OUT/h1.json"
echo "true rc_h1=$?"
python3 .../schedstat_sample.py --seconds 20 --label play -o "$OUT/h2.json"
echo "true rc_h2=$?"
python3 .../fixed_work_probe.py --iters 80000000 --label play -o "$OUT/h3_play.json"
echo "true rc_h3=$?"
# idle earlier: fixed_work_probe --label idle -o h3_idle.json
python3 .../fixed_work_probe.py --compare "$OUT/h3_idle.json" "$OUT/h3_play.json"
echo "true rc_cmp=$?"
```

**Quote to user:** H1 inelastic + H2 wait_frac + H3 ratio. Report Main % separately as **elastic**. Never residual headroom.

---

## 4. Related cards (same dir)

- `MISTER_TIMEOUT5_LAB.md` — lab-only Main patch, revert, pre-reg bands, falsifiers  
- `STARVATION_480P_EXPERIMENT.md` — confirm/refute ffmpeg CFS starve for 480p under-prod  
- `MISTER_SPIN_PATCH.md` — earlier patch notes  

---

## 5. ERROR 17

Closed. No fps filter change.
