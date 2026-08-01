# TOP PRIORITY — seriality of decode → DDR push (holds Quartus exclusive)

**Lead:** Dropped offload ranking. Question: is playback **serially** stuck on one
thread while a core idles? Source: ffmpeg | pipe | misterplexd single-thread
read→present; pipe **designed** for multi-frame decoupling (`raw_video_pipe.hpp`).
Seriality is **not** proven by 40.190 constructed sum vs 89.8% occupancy. Parent
runs §1–§3; agent does not touch device. O_SYNC is not the 10.4 ms culprit
(7.378 vs 7.199).

---

## 0. Source model (mechanism candidates — not yet measured truth)

| Fact | Citation |
|------|----------|
| Separate processes | `spawnFfmpeg` → child; parent `threadMain` reads `vpipe[0]` |
| **One** consumer thread, **one** `frame` buffer | `std::vector<uint8_t> frame(frameBytes)` then loop read→present |
| Loop order (serial **inside** daemon) | full-frame `read` → chroma/pad → pace wait → `publishDdrFrame` (`presentMu_`) |
| Intentional **inter-process** decoupling | `raw_video_pipe.hpp`: default pipe **2 MiB ≈ 4.7×449280**; comment: default 64 KiB ≈ 0.15 frames **backpressures decoder** on publish spike |
| `F_SETPIPE_SZ` + mandatory `F_GETPIPE_SZ` | `applyRawVideoPipeSize`; failure keeps kernel default |
| Dual bank on FPGA | write bank ≠ display bank possible via PLXD; ARM still one publish at a time |
| O_SYNC ≠ smoking gun | archive 7.378 vs 7.199 ms `measured` |

**Implication:**  
- **Intra-daemon:** always serial (cannot memcpy two frames at once on that thread).  
- **ffmpeg ∥ daemon:** **can** pipeline if pipe holds ≥1–2 frames and ffmpeg is not blocked on a full pipe.  
- **If pipe is still ~64 KiB or always full/empty:** behaves **as if serial** end-to-end.

Daemon-only fixes if serial-by-coupling: ensure pipe size; deepen buffer; async present thread + 2-deep frame queue (bigger change); reduce `prep_wait` blocking.

---

## 1. Seriality — PRE_REGISTER falsifiers FIRST

### Definitions

- **S-serial (bad for margin story):** end-to-end frame path does not overlap decode CPU with present CPU in a useful way; one side blocks the other almost every frame.  
- **S-pipeline (falsifies “must be serial”):** ffmpeg produces into pipe while daemon presents; both burn CPU in the same wall window; pipe absorbs present spikes.

### Falsifiers (state up front)

| ID | Observation | Verdict |
|----|-------------|---------|
| **F1** | In a steady 480p cast window, **both** ffmpeg and misterplexd show **>15 %onecpu** (exe-resolved) in the **same** window, **and** pipe actual size ≥ 2× frame_bytes | **S-pipeline** — seriality as *system* explanation for “110% free yet missing tick” is **FALSIFIED** |
| **F2** | Same window: one of {ffmpeg, daemon} **NO-DATA or <5 %onecpu** while the other is hot, **or** pipe actual ≤ 1× frame_bytes with frequent ffmpeg stall | **S-serial / coupled** — consistent with serial bottleneck |
| **F3** | During intervals where `ddr_total_us_p` is high (e.g. >8 ms), ffmpeg **utime still advances** at similar rate (task stat Δutime) | **overlap** → pipeline |
| **F4** | During those same high-`ddr_total` intervals, ffmpeg **utime flat** and/or `nvcsw` spikes / state `D`/`S` on write | **backpressure** → effective serial |
| **F5** | `read_eagain_x100_f` high **and** `ddr_total` low → daemon waiting on decode (decode-bound, not present-serial) | **not** “present serialises decode”; opposite |
| **F6** | `read_eagain` low, `ddr_prep_wait` or `ddr_total` high, pipe full | present/ready path serialises |

**Occupancy 89.8% with free core does NOT prove pipeline** (Main elastic + multi-thread ffmpeg).  
**Constructed 40.190 does NOT prove serial** (isolated probes).  
Only F1–F6 on **one live cast** settle it.

### PRE_REG numeric bands (480p steady, 20–30 s)

| Metric | S-pipeline band | S-serial band |
|--------|-----------------|---------------|
| ffmpeg %onecpu | ≥ 40 | any, but see daemon |
| misterplexd %onecpu | ≥ 12 | ≥ 12 while ffmpeg < 10 **or** opposite |
| pipe_actual / frame_bytes | **≥ 2.0** | **< 1.5** |
| overlap_score* | ≥ 0.5 | < 0.25 |

\*overlap_score: fraction of 1 s sub-windows where **both** procs have Δutime>0 (see §1.1).

---

## 1.1 Parent commands — seriality pack

```sh
# === 0) Artifact pair ===
echo -n "rbf_md5="; md5sum /media/fat/_Utility/Plex.rbf 2>/dev/null | awk '{print $1}'; echo
D_PID=""; F_PID=""; D_EXE=""; F_EXE=""
for d in /proc/[0-9]*; do
  e=$(readlink -f "$d/exe" 2>/dev/null) || continue
  b=$(basename "${e% (deleted)}")
  case "$b" in
    misterplexd)
      case "$e" in *misterplex_v2*) D_PID=${d#/proc/}; D_EXE=$e;;
        *) [ -z "$D_PID" ] && D_PID=${d#/proc/} && D_EXE=$e;; esac ;;
    ffmpeg) F_PID=${d#/proc/}; F_EXE=$e ;;
  esac
done
echo "daemon_pid=${D_PID:-NO-DATA} daemon_exe=${D_EXE:-NO-DATA}"
echo "ffmpeg_pid=${F_PID:-NO-DATA} ffmpeg_exe=${F_EXE:-NO-DATA}"
[ -n "$D_PID" ] && md5sum /proc/$D_PID/exe 2>/dev/null
echo "true rc=$?"

# === 1) Pipe capacity (decoupling proof) — needs fd of daemon's read end ===
# From /proc/D_PID/fd: find pipe:[inode] that matches ffmpeg stdout if possible.
# Simpler: grep playback log for pipe size line from applyRawVideoPipeSize:
grep -E 'PIPE|pipe_sz|F_SETPIPE|raw_video_pipe|pipe_bytes' \
  /media/fat/misterplex_v2/misterplexd.log 2>/dev/null | tail -n 20
# If daemon logs actual size at spawn — quote it. Expect ~1048576–2097152 or NO-DATA.
echo "true rc=$?"

# === 2) Overlap: 20 × 1s windows, BOTH must be live (cast running) ===
# PRE_REG: S-pipeline ⇒ ≥10/20 windows both d_ut>0 and f_ut>0
OUT=/media/fat/misterplex_v2/seriality_overlap.txt
: >"$OUT"
i=0
while [ "$i" -lt 20 ]; do
  if [ -z "$D_PID" ] || [ -z "$F_PID" ]; then echo "NO-DATA missing pid"; break; fi
  # awk after ')': utime=field 14 of full stat = a[12], stime=a[13], nvcsw later
  du0=$(awk '{i=index($0,") "); rest=substr($0,i+2); n=split(rest,a,/ /); print a[12]+0}' /proc/$D_PID/stat)
  fu0=$(awk '{i=index($0,") "); rest=substr($0,i+2); n=split(rest,a,/ /); print a[12]+0}' /proc/$F_PID/stat)
  sleep 1
  du1=$(awk '{i=index($0,") "); rest=substr($0,i+2); n=split(rest,a,/ /); print a[12]+0}' /proc/$D_PID/stat)
  fu1=$(awk '{i=index($0,") "); rest=substr($0,i+2); n=split(rest,a,/ /); print a[12]+0}' /proc/$F_PID/stat)
  dd=$((du1-du0)); ff=$((fu1-fu0))
  both=0; [ "$dd" -gt 0 ] && [ "$ff" -gt 0 ] && both=1
  echo "w=$i d_dutime=$dd f_dutime=$ff both=$both" | tee -a "$OUT"
  i=$((i+1))
done
# score:
awk -F= '/both=/{c++; if($NF==1) b++} END{if(c<1)print "overlap NO-DATA"; else printf "overlap_score=%.2f n=%d\n", b/c, c}' "$OUT"
echo "true rc=$?"

# === 3) CPU soak same window (SUPPORT occupancy only — do not rank vs ms/f) ===
RBF_PATH=/media/fat/_Utility/Plex.rbf LOG=/media/fat/misterplex_v2/misterplexd.log \
  sh /media/fat/misterplex_v2/arm_cpu_soak.sh 20
echo "true rc=$?"

# === 4) Optional: per-task nvcsw for daemon main thread during cast ===
# ls /proc/$D_PID/task; sample stat field voluntary_ctxt_switches from status
if [ -n "$D_PID" ]; then
  for t in /proc/$D_PID/task/*; do
    tid=${t##*/}
    echo -n "tid=$tid "
    grep -E 'voluntary_ctxt|nonvoluntary|Name:' "$t/status" 2>/dev/null | tr '\n' ' '
    echo
  done
fi
echo "true rc=$?"
```

**Score:**  
- `overlap_score ≥ 0.5` + pipe ≥ 2 frames → **F1 hit → do NOT hold Quartus for “serial decode∥push”**; present 10.4 still worth geom/DMA but not “free 10.4 by overlap”.  
- `overlap_score < 0.25` or pipe < 1.5 frames → **serial/coupled** → daemon-only pipe/queue fix is top prize.

---

## 2. If serial/coupled — mechanism & daemon-only fix?

| Mechanism | How it serialises | Daemon-only fix? |
|-----------|-------------------|------------------|
| **Pipe 64 KiB** (F_SETPIPE_SZ failed / conf 0) | publish blocks → pipe full → ffmpeg write blocks | **Yes:** conf `RAW_VIDEO_PIPE_BYTES`, raise `pipe-max-size`, verify log actual≥2×frame |
| **Single-thread read→present** | no second frame in flight on ARM consumer | **Partial:** 2-deep queue + present worker thread (daemon-only, non-trivial) |
| **Pacer sleep after present before next read** | reduces decode into pipe | **Yes:** pace on publish schedule without starving read (careful A/V) |
| **PLXD/prep_wait / bank_reuse usleep** | long hold with pipe filling | **Partial:** don’t sleep on hot path when PLXD free; fix ready handshake |
| **presentMu_ vs OSD** | brief exclusion | small |
| **Synchronous doorbell wait for busy** | first-kick / status poll | reduce wait; don’t block full frame time |
| **O_SYNC** | ruled out as main term (0.18 ms) | no |

**Most valuable cheap outcome:** prove pipe actual size; if < 2 frames, fix pipe **before any RTL**.  
**Second:** if pipe OK but F4 (ffmpeg stalls on high ddr_total), add **2-frame ARM queue** so read continues during `publishDdrFrame`.

---

## 3. Present bucket: copy vs fixed — ONE instrument

**Do not** mix `ddr_write_bench` with FEED product mean for a “measured” fixed term.  
**Do:** `present_profile` on live cast:

```
fixed_us ≈ ddr_total_us_p - ddr_copy_us_p
# or accounted: prep+flush+doorbell+post_wait
copy_us  = ddr_copy_us_p
```

Document §1.3 indicative: copy 7.378 @449280; 1.846 @320×240; fixed ~3.03 **mixed instruments — ESTIMATED only**.

### PRE_REG (one cast, PROFILE on)

| ID | Prediction |
|----|------------|
| P1 | `ddr_copy_us_p` ∈ 6000–9000 at 449280 B |
| P2 | `ddr_total_us_p - ddr_copy_us_p` ∈ 1500–5000 (fixed class) |
| P3 | `ddr_copy_us_p / ddr_total_us_p` ∈ 0.55–0.85 |
| Kill | copy/total < 0.4 → fixed/wait dominated (geom bytes won’t buy 5.5 ms) |

```sh
# Turn on present profile (conf key parent-verified), restart daemon if needed, cast 480p.
grep -E 'present_profile|ddr_copy_us_p|ddr_total_us_p|ddr_prep_wait' \
  /media/fat/misterplex_v2/misterplexd.log | tail -n 30
echo "true rc=$?"
# Report means from steady lines only. Stamp rbf+daemon md5.
```

Native geom **ESTIMATED** copy save ≈ 7.2×(1−115200/449280)≈**5.35 ms** on copy term only; fixed remains — **~2.1× on copy, not 3.9× on whole 10.41**.

---

## 4. E2E frame time on **current** build (replaces −0.190 synthetic)

**−0.190 ms is NOT current evidence** (constructed sum, 1412 kb/s, tip `da8c38eb`, pre-fast_bilinear).

### PRE_REG

| ID | Meaning |
|----|---------|
| E1 | steady median publish interval ∈ 38–45 ms at 24 fps content → **making 24** |
| E2 | median ∈ 33–37 ms with 25 fps content request → **making 25** |
| E3 | p95 interval > 1.5× median → jitter problem ≠ mean budget |
| E4 | mean `ddr_total_us_p/1000 + read_us_f/1000` ≪ interval → wait/pace dominates wall |

```sh
# A) present_profile steady averages (read_us_f, pacing_wait_us_f, ddr_total_us_p)
# B) publish interval ledger if enabled (trimmed p_ge50_steady — not raw σ=500)
# C) wall: count presents over 30s from log wall_ms advancing
#    e2e_ms_f ≈ 30000 / Δpresents   (only if presents are real presents — not void PLXD)
# Prefer daemon PROFILE + publish timestamps over constructed FEED sum.

# 30s soak + profile scrape
RBF_PATH=/media/fat/_Utility/Plex.rbf LOG=/media/fat/misterplex_v2/misterplexd.log \
  sh /media/fat/misterplex_v2/arm_cpu_soak.sh 30
echo "true rc=$?"
```

**First-order result either way:** e2e ms/f on tip with `fast_bilinear` + artifact pair.

---

## 5. How this decides the exclusive slot

| Seriality result | Exclusive Quartus? |
|------------------|--------------------|
| **F1 pipeline** + e2e already has margin @25 | **Do not** spend fit for “overlap 10.4”; geom/RTL on glass/quality only |
| **F1 pipeline** + e2e still over budget | Fit still for **bytes/DMA/decode**, not serial overlap |
| **F2/F4 serial/coupled** + pipe small | **Daemon-only pipe/queue first** — **hold RTL** |
| **F2** + pipe large + prep_wait huge | Daemon ready-path / PLXD — maybe small RTL, not scaler-first |

---

## 6. Deliverable checklist for parent return

1. rbf_md5 + daemon_md5  
2. pipe actual (log or F_GETPIPE_SZ)  
3. overlap_score + 20-line dump  
4. one `arm_cpu` soak line  
5. present_profile line with `ddr_copy_us_p` + `ddr_total_us_p`  
6. e2e interval or presents/30s  

Agent scores F1–F6 and P1–P3; recommends daemon-only vs release exclusive.
