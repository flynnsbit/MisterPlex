# Score F1–F6 + next actions (parent artifacts 2026-08-01)

**Lead:** F1 **HIT** — seriality **falsified**. ffmpeg~70 + daemon~27 concurrent every
1s window (n=19 both=19). **Do not hold Quartus for overlap 10.4 ms.** Exclusive
release **agreed**. E2E @24 fps meets tick (24–25 f/s, drops0) — **consistent with**
FEED +1.476@24, **does not test** −0.190@25. Next: 30 fps decisive cast; timeout=5
pack; inventory resumed wall-ms + pipeline-known.

**Artifact pair (parent):** RBF `8fdf440f`, daemon `9ce2c2d1` (tip `bc3d3484`),
conf `7f06132f`, `fast_bilinear`, `DDR_YUV_FORCE_SCALE=1`, rk/metadata/27.

---

## 1. F1–F6 score (your data)

| ID | Result | Reading |
|----|--------|---------|
| **F1** | **SATISFIED** | both hot every window; sum ~97/200; **S-pipeline** |
| **F2** | **MISS** (good) | ff_only=0 dm_only=0 |
| **F3** | **Supported at 1s** | both dutime>0 always while cast plays (implies overlap at ≥1s) |
| **F4** | **Not supported** | no window with daemon-only / ffmpeg flat |
| **F5/F6** | **NO-DATA** | need present_profile read_eagain / ddr_* |

**Fine-grained alternation caveat:** Valid. 1s bins cannot rule out ping-pong inside
the second. **Does it matter now?** Low: E2E already meets 24 fps tick with free core;
even perfect micro-seriality inside 1s would not unlock a “free 10.4 ms” programme when
the consumer already presents 24/s. Optional finer probe only if you chase residual
judder attribution — not to re-open exclusive-for-overlap.

**Optional finer instrument (only if you want):**

```sh
# 200 × 50ms samples (10s). PRE_REG pipeline: ≥70% bins both Δutime>0
# Same pid resolve by exe as before.
i=0; both=0; n=0
while [ "$i" -lt 200 ]; do
  du0=$(awk '{i=index($0,") ");r=substr($0,i+2);split(r,a,/ /);print a[12]+0}' /proc/$D_PID/stat)
  fu0=$(awk '{i=index($0,") ");r=substr($0,i+2);split(r,a,/ /);print a[12]+0}' /proc/$F_PID/stat)
  sleep 0.05
  du1=$(awk '{i=index($0,") ");r=substr($0,i+2);split(r,a,/ /);print a[12]+0}' /proc/$D_PID/stat)
  fu1=$(awk '{i=index($0,") ");r=substr($0,i+2);split(r,a,/ /);print a[12]+0}' /proc/$F_PID/stat)
  dd=$((du1-du0)); ff=$((fu1-fu0)); n=$((n+1))
  [ "$dd" -gt 0 ] && [ "$ff" -gt 0 ] && both=$((both+1))
  i=$((i+1))
done
echo "overlap_50ms both=$both n=$n score=$(awk -v b=$both -v n=$n 'BEGIN{printf "%.2f", b/n}')"
echo "true rc=$?"
```

**I do not read F1 differently.** Overlap prize for exclusive is **closed**.

---

## 2. E2E vs margin table (careful wording)

| Evidence | Says |
|----------|------|
| supply_bucket 24–25 frames & presents / ~1s, drops0, gap±0.1 | **Current build meets ~24 fps tick** `measured` parent |
| FEED +1.476 ms @24 | **Same direction** — clean 24 fps run is what the table predicts |
| FEED −0.190 @25 / −6.857 @30 | **Untested on current build** — not contradicted, not confirmed |

**Do not say** “margin table is wrong.” **Do say** “24 fps E2E green is table-consistent; 25/30 remain open.”

---

## 3. Decisive 30 fps test (margin + fps-forcing)

### PRE_REG (publish misses)

| ID | Prediction |
|----|------------|
| T1 | If FEED full-stack still ~40 ms class: @30 fps expect **drops / supply_gap / d_frames < 30** or publish misses | 
| T2 | If current build much faster (fast_bilinear + tip): may still make 30 — then FEED −6.857 is **stale** (first-order) |
| T3 | Log must show `content fps=30/1` or `30000/1001` **or** explicit UNKNOWN→24 | if forces `fps=24/1` on 30 fps source → **decimation defect** |
| T4 | `cadence_src_fps` / `fps_src=` derivation tags honest |

### Cast what

Prefer a **library item that PMS reports 30 fps** (or 29.97). If none:

```sh
# Host-side generate short CFR 30 fps 624x480 H.264 (parent copies to PMS or file play)
ffmpeg -y -f lavfi -i testsrc2=size=624x480:rate=30 -t 60 -c:v libx264 -pix_fmt yuv420p -b:v 2000k /tmp/30fps_624.mp4
# Play via file URL or inject into library — parent chooses path that hits product play()
```

### Capture (during play)

```sh
# 1) fps provenance
grep -E 'content fps|fps_src=|cadence_src_fps|fps=|vf |DEFAULT_ASSUMED|UNKNOWN' \
  /media/fat/misterplex_v2/misterplexd.log | tail -n 40

# 2) supply buckets 30s
grep 'supply_bucket' /media/fat/misterplex_v2/misterplexd.log | tail -n 40

# 3) present_profile if on
grep present_profile /media/fat/misterplex_v2/misterplexd.log | tail -n 5

# 4) CPU stamp
RBF_PATH=/media/fat/_Utility/Plex.rbf LOG=/media/fat/misterplex_v2/misterplexd.log \
  sh /media/fat/misterplex_v2/arm_cpu_soak.sh 30

# 5) artifact pair
md5sum /media/fat/_Utility/Plex.rbf
# daemon md5 via /proc/pid/exe as usual
echo "true rc=$?"
```

**Pass/fail:**  
- `d_frames` steady ~30 and drops0 → margin table **stale** for tip.  
- `d_frames`~24 with vf `fps=24/1` on 30 source → **fps force defect** (judder class).  
- `d_frames`~24–28 with drops>0 and vf `fps=30/1` → **ARM wall budget** real at 30.

---

## 4. Source fps — does daemon learn it?

| Path | Behavior | tag |
|------|----------|-----|
| `main.cpp` play resolve | `setContentFpsRational(resolved.fpsNum, fpsDen)` from PMS parse | source |
| `fpsNum_>0` | pace + `vf fps=N/D` | source |
| `fpsNum_<=0` | pace **24/1** + log UNKNOWN; **may omit fps filter** if only default used in pace consts — check: vf filter only if fpsNum_>0 | source |
| `fps_src=caller_supplied` in status | means fpsNum_>0 this session | your log |
| `cadence_src_fps=DEFAULT_ASSUMED` | **separate** w-instr env `MISTERPLEX_SRC_FPS` — **not** asset probe | source `media_player.cpp` ~1349 |

Your asset PMS 24p + vf `fps=24/1` + caller_supplied is **consistent with wired 24**, not proof of always-default.  
**Risk remains:** any play path that skips resolve / zero rational → silent 24. **30 fps cast is the proof.**

---

## 5. timeout=5 — patch, rollback, proof, risk

### Patch (lab Main only)

File: `.agent-work/w-cpu-1/patches/main_mister_input_timeout5_plex.patch`  
Applies to Main_MiSTer `input.cpp` ~poll timeout:

```diff
int timeout = 0;
if (is_menu() && video_fb_state()) {
    timeout = 25;
} else if (core name is Plex) {
    timeout = 5; /* ms — poll still wakes on input/cmd */
}
```

**Does not ship in misterplexd.** Requires building/replacing `/media/fat/MiSTer`.

### Rollback

```sh
# BEFORE swap — mandatory
cp -a /media/fat/MiSTer /media/fat/MiSTer.stock-backup
md5sum /media/fat/MiSTer /media/fat/MiSTer.stock-backup

# Install lab binary only after backup md5 recorded
# cp lab_MiSTer /media/fat/MiSTer && sync
# Restart Main via your supervised path (NOT kill -9 without CONT plan)

# ROLLBACK
cp -a /media/fat/MiSTer.stock-backup /media/fat/MiSTer
sync
# restart Main
md5sum /media/fat/MiSTer  # must match backup
echo "true rc=$?"
```

### Prove no input/OSD regression

| Test | PRE_REG |
|------|---------|
| Idle MiSTer %onecpu (Plex loaded) | **≤ 15** (vs ~100 stock) |
| 480p soak MiSTer % | **≤ 25** |
| F12 opens OSD during 480p play | **must** within 1 press |
| Gamepad/keyboard navigate OSD | **must** |
| `echo load_core ... > /dev/MiSTer_cmd` (or your safe cmd) | **must** still work when not suspended |
| Subjective stick latency | no obvious extra lag vs stock (qualitative) |
| H1 ffmpeg+daemon | within ±5 of pre-patch |

```sh
# A/B CPU
RBF_PATH=/media/fat/_Utility/Plex.rbf LOG=... sh arm_cpu_soak.sh 20   # stock then timeout5
# F12 smoke during cast — parent observes OSD
echo "true rc=$?"
```

### Risk case (daily driver)

| Risk | Mitigation |
|------|------------|
| Break all cores’ input if patch not Plex-scoped | Patch **Plex-only**; Menu keeps 0 or 25 |
| Break F12 | A/B must include F12 during play; rollback binary |
| Main fails to start | keep stock backup on FAT; known-good boot path |
| Legal/support: modified framework | **lab flag**; not default user install until soak |
| Doesn’t reclaim under load if not poll-bound | stack samples first optional; CPU% is the score |
| User leaves lab Main installed | checklist: restore stock before session end |

**Recommendation:** lab A/B on non-primary boot if possible; else backup+rollback drill **before** swap; default user image stays stock Main.

---

## 6. Ranked inventory resumed (corrected)

**Settled:** decode∥present **already pipeline** (F1). No “overlap 10.4” RTL/daemon prize.

| Rank | Target | Basis | Action |
|-----:|--------|-------|--------|
| **1** | **Main poll timeout=5** (or opt-in SUSPEND) | occupancy ~full core `measured`; 0 M10K | lab Main A/B §5 |
| **2** | **E2E @30 (and 25) fps** | replace synthetic −0.190/−6.857 | §3 cast |
| **3** | **fps rational honesty** | DEFAULT 24 when unset; force vf | prove on 30 fps; fix if decimates |
| **4** | **present/DDR copy vs fixed** | `ddr_copy_us_p` vs `ddr_total_us_p` one instrument | still sizes w-geom (~5.3 ms copy ESTIMATED native) |
| **5** | **w-geom glass/store** | row ceiling + native bytes | exclusive OK for **glass**, not seriality |
| **6** | Fabric decode | cumulative ~21 ms class after M10K | after w-fit-1 |
| **7** | Overlay plane | w-osd-hires | product UX |
| **—** | Serial overlap 10.4 | **CLOSED** | — |

Wall-ms FEED table remains capacity folklore until §3; 24 fps E2E green is live.

---

## 7. One paragraph for the user-facing story

We measured concurrent ffmpeg and daemon CPU every second during real 480p playback:
they already run together (~70% + ~27%). There is no free 10 ms hiding in “make them
parallel.” At 24 fps the current build presents on time with headroom. Whether 30 fps
still fits, and whether we wrongly force 24 fps on non-24 titles, is the next single
cast. Separately, the MiSTer menu binary still burns a core in a stock busy-poll; a
5 ms poll timeout while Plex is loaded is the largest cheap ARM win left, with F12 kept
working — unlike freezing Main entirely.
