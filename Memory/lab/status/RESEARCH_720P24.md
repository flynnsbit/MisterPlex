# Research: unique 1280×720 @ 24 fps + Track B 720p HDMI

**Date:** 2026-08-16 (restamp 00:58Z)  
**For:** any later harness / session picking up unique24 or Track B  
**Tree:** `/home/shawn/Projects/MisterPlex-wt-480p-lessons` branch `lessons/true480-720p24`  
**Do not use dirty `main`** (`/home/shawn/Projects/MisterPlex`) as the 720p product tree.

unique24 (coded **1280×720** and both meters ≥23.9) is **FAIL**.  
Track B (coded **960×540**, HDMI 720p via `ascal`) is **clean glass**, produce **~28**, last-line hw **23.68** (best). Soft-skip ≠ PASS. Do not invent 23.9.

---

## 1. Gate and leftover (living)

**unique24 PASS** only if **all** of:

- coded **1280×720**
- `pfps` ≥ 23.9 **and** `hw_fps` ≥ 23.9
- `drops` = 0, `presented` > 0
- `MAGIC_F` `0x504C5846` at doorbell **+0x118** (not +0x110)

**Track B PASS** (user grant, not unique24): HDMI 1280×720 via `ascal`; coded **960×540**; clean glass; audio in sync; `presented` > 0; `drops` = 0; MAGIC_F @ +0x118. Produce ≥23 is the rate target. `hw_fps` ~18–20 is **not** a Track B fail.

| Item | Living value | Evidence |
|---|---|---|
| Lab `/media/fat/Plex.rbf` | **`620c27ec`** Track B 960×540 | md5 `620c27ec75eaa2d60e7dae66dd4e8154`. User: chevron looks good. |
| **BEST last-line (960)** | **27.9 / 23.68** | ARM **`e7106b72`** ahead 48 paced. **Named pair:** RBF `620c27ec` + that daemon. 64 paced **WASH 23.42**. |
| Fair memcpy (no ahead) | **24.3 / 20.42** | `/tmp/pfps-720p24-620c-fair.txt`. Late incremental **~23.92**. First 4 s are the hole. |
| Glass (L58, I SAW) | orange chevron + movie | `/tmp/misterplex-eyes/user-ok-f1.jpg` OSD **18.19 kHz 24.0 Hz** / **74.25 MHz 60.0 Hz**. Movie `/tmp/misterplex-eyes/620c-fair-f2.jpg`. |
| ARM living | **`e7106b72`** | 16:9 + inproc 4/3 + `warmup_ahead` 48 paced. |
| ARM 16:9 only | `3a3fcf22` | prefix960 + idle 16:9; memcpy path. |
| Aspect | **16:9 HDMI** | User: 720p is 16:9, HDMI display. Host `defaultSourceAspectForBank` 16:9 on 1280/960. FPGA default 16:9 for `PRESENT_BEAM_960` / `PLEX_PRESENT_720P_L4` (next fit; **not** in this RBF). true480 stays 4:3. |
| ac95 true720p now | **`ac95f8c8`** on product | ahead720 n=48 **31.0 / 22.75** `/tmp/pfps-720p24-ac95-ahead48.txt`. n=36 was 30.6/22.32. Was 19.79 without ahead. unique24 FAIL. |
| Named Track B pair | RBF **`620c27ec`** + daemon **`e7106b72`** (48 paced) / **`cd73f1db`** (same + 1280 ahead) | KEEP RBF `Plex.rbf.KEEP_620c27ec`. KEEP daemon `build/arm/misterplexd.KEEP_cd73f1db_ahead48`. Last-line **23.68 ≠ 23.9**. |
| `2bbe6755` RDYWIN | sidecar KEEP only | glass-HURT; CLOSED as unique24 closer **27.9 / 19.86**. Do not replay. |
| First `620c` Track B | **HOST invalid** | STICK=1 INPROC=0 presented=1 **15.3 / 14.78** `/tmp/pfps-720p24-620c-trackb.txt`. Green idle = 1280-into-960. |
| 480p utility bak | **`07f54d9f`** UNTOUCHED | `/media/fat/_Utility/Plex.true480.07f54d9f.rbf` |
| HDMI INI | `video_mode` **74250** (720p60) | HDMI24 closed (hurt). `vga_scaler=1`. |
| Host | `192.168.1.183` pass `1` | identity MiSTerPlex / :3005 |
| Clip | `/media/fat/misterplex/clips/real720p_1500k_av.mp4` | 1280×720 CBP CAVLC 24/1 ~1500 kb/s. Inproc 960 point-samples 4/3. |
| Farm HDMI | **node-worker1** `/dev/video0` | MacroSilicon `534d:2109` MJPEG 1280×720. First frame often `e74e3559` FALSE-BLACK. L58: look yourself. |
| Farm Quartus | node-worker1 mux `PATH=/tmp/misterplex-sshbin` | one exclusive |
| `SKIP_RESTORE` | YES | do not bounce 480p unless asked |
| Exclusive | **FREE** | `FIT_GO=NO`. U6 **NAME=NONE**. |

**Do not** `deploy_plex_core.sh` for 720p (writes `_Utility/Plex.rbf` 480p bak).  
**Do not** `/bin/fpga` or `load_core` of named `Plex.720p24.*`. Official load: menu → L4 wipe → `/media/fat/Plex.rbf`.  
**Do not** auto-replay `ac95` over living `620c`. `remote_out/slot720p24freddo/Plex.rbf` on disk is still **`2bbe6755`** — play scripts must pass the KEEP path.

`hw_fps` = FPGA `frames_done` / PLXD bank swaps. `pfps` = host presents.

---

## 1b. Track B campaign (2026-08-15 evening) — what actually happened

User chose Track B after `2bbe` looked corrupt. Plan: restore `ac95`, one play of existing 960 silicon, restore `ac95` on HURT.

1. **Phase 0.** `ac95` restored. User: “its clean.” I SAW orange chevron + pillarbox (`ac95-restore-f2.jpg`).
2. **Phase 2 first play — HOST invalid.** `play_slot720p24freddo` defaulted STICK=1 INPROC=0. ffmpeg scale pipe. **15.3 / 14.78**, harvest presented=1. User: “corrupt.” I SAW green torn full-field chevron (`trackb-620c-now2.jpg`). Restored `ac95`.
3. **RCA (not a new RBF).** `620c` is `PRESENT_BEAM_960` FRAME 960×540, 777600 B, Y stride 960. After play, OSD Content 720p + L4 `glassMax` snapped idle to 1280×720 I420 (stride 1280) into that store. FPGA reads 960: 4 lines per 3 host lines (stacked glyphs) and U/V land in the Y plane (`U=V≈45`) → BT.601 full-field **green**. Idle renderer is still amber `(0xE5,0xA0,0x0D)`. **Not** CHEVRON_GREEN_USB.
4. **Host fixes (no Quartus).**
   - `rbfPrefix8IsKnown960Store` — `glassMax` / OSD retarget stay 960 even when Content is 720p and `MPX_BUDGET_960` is unset.
   - Inproc 1280×720 → 960×540 I420 point-sample `dest(x,y)=src(x*4/3,y*4/3)` (no swscale). x86 tests OK.
   - Play script: DECODE=960 / BUDGET_960 forces STICK=0. Official leftover defaults **INPROC=1 STICK=0**.
   - Harvest `presented=` now prefers last-1Hz `hw_presents` (first `presented=1` in the log is startup).
5. **ac95 movie reconfirm (23:25Z).** KEEP path (must not copy living `remote_out/Plex.rbf` = 2bbe). **27.9 / 19.79** presented=420. I SAW movie (`ac95-movie-f2.jpg`). SAME_CLASS as U1 28.0/19.51.
6. **Phase 2 fair retry (23:28Z).** `620c` + ARM `1cf961c5` then **`3a3fcf22`**. STICK=0 INPROC=1 DECODE=960. **pfps=24.3 hw=20.42** drops=0 F@118. last-1Hz `hw_presents=293` (harvest printed presented=1 — **lie**). I SAW movie advancing (`620c-fair-f1.jpg` / `f2.jpg`, c=5 then c=6). Post-play idle **orange** 960 chevron (`620c-idle-f1.jpg`, `user-ok-f1.jpg`). User: “that version looks good on the chevron.”
7. **16:9.** User: 720p on HDMI is 16:9. Host publishes 16:9 at idle for 1280/960 banks (`defaultSourceAspectForBank`). PLXJ ACK 16:9. FPGA `Plex.sv` default 16:9 for next 720p fit only.
8. **P5_960_DDR_INGEST HURT (00:43Z).** Decode into uncached HPS DDR: `present_pipeline=2slot_ddr_ingest` `read_us` **~67 ms** (was ~15). **12.6 / 10.23**, I SAW **black+OSD** (`ingest-f1.jpg`). Reverted. `/tmp/pfps-720p24-620c-ingest.txt`.
9. **warmup_ahead (00:50–00:58Z).** Decode N I420 frames into **cached heap**, then `sendYuv420pFrameDdr` BestEffort. Blast 36 → **28.4 / 22.01**. Pace 36 wait_swap → **27.7 / 23.45**. Pace **48** → **27.9 / 23.68**. `warmup_ahead n=48 sent=48`. Scheduler deleted (it was RCA-only for ~52 min).

**Track B produce PASS. Track B glass PASS. Last-line hw 23.68 ≠ 23.9.** unique24 FAIL. Do not restore `ac95` over `620c` unless glass HURT.

---

## 2. Why unique24 @ coded 1280×720 is blocked

### 2.1 The A9 can decode 24. Play produce is now 28.

| Condition | Rate | ms/frame | What is on |
|---|---:|---:|---|
| Isolated ffmpeg → `/dev/null` (daemon stopped) | **32.31** | 30.95 | nothing of ours; **1.78 cores** |
| Live Plex core + ffmpeg → `/dev/null` | **~24** | ~42 | FPGA present + ascal HDMI 720p60 |
| Product play pre-U1 (pipe + memcpy) | **~16** | **~53** pipe fill | everything |
| **U1 inproc 1280** (ac95) | **28.0** | **25.4** | libav into 2-slot ring; produce **PASS** |
| **Track B inproc 960** (620c fair) | **24.3** | ~41 | 777600 B/frame; produce **PASS** for Track B |

Isolated bench: `/tmp/misterplex-agent-W-meas.txt`. Clip is Constrained Baseline CAVLC, 1280×720, 24/1, ~1.5 Mbps.

**FPGA H.264 is not required to *compute* 24 fps of this clip.** Isolated ARM already does 32. U1 closed the pipe produce hole at 1280. Track B produce is 24.3 at 960.

### 2.2 Pipe profile (historical; pre-U1)

Pre-U1 leftover `ac95`, `PRESENT_PROFILE=1` (`/tmp/pfps-720p24-ac95-profile.txt`):

| Stage | µs/frame | Meaning |
|---|---:|---|
| `read_us_f` | **53275** | fill one 1.38 MB I420 from ffmpeg `pipe:1` |
| `slot_wait_us_f` | 9138 | produce waiting for a free ring slot |
| `present_wait_us_p` | **38277** | present **idle** waiting for the next pipe frame |
| `send_us_p` | 15926 | doorbell + memcpy path |
| `copy_us_p` | 12319 | uncached memcpy into `PHYS_BASE` `0x30180000` |

U1 inproc closed that produce hole (`read_us` **25355**, pfps **28.0**). unique24 still **FAIL** on `hw_fps`.

### 2.3 What the extra ~11–22 ms is *not*

Closed on silicon (same clip, live Plex, honest scores):

| Hypothesis | Build / play | Result | Why closed |
|---|---|---|---|
| FPGA line-prefetch fights HPS during decode | `6ffa88e7` stick burst-32 then idle | 15.9 / 12.79; `read_us` **53079** vs 53275 (−0.2 ms) | FPGA present HPS tax is **not** the 11 ms |
| Uncached 12 ms memcpy is the hole | `ac18b5b9` PLXP `copy_us=0` | 15.6 / 12.74 | memcpy is ~19% of the 63 ms wall, not 8 fps |
| Scan ffmpeg’s cached ring (skip memcpy) | same `ac18` | HURT vs ac95 | FPGA DMA on the produce heap |
| HDMI 60 → 24 (ascal quieter) | `112bb` + CEA 30 MHz | **14.5 / 12.31** | **hurt** produce; reverted 74250 |
| `MISTER_SMALL_VBUF` (1 MB ascal vbuf) | `c94f8847` | **TIMING_FAIL** setup −0.080 TNS −0.080 | **DO_NOT_PLAY** |
| Doorbell / mailbox PHYS move | several n* | MAGIC_F at +0x110 historically | 4 KB flags, no pixel overlap |
| `RequireReleased` → BestEffort | `112bb` | 15.7 → **16.2 / 13.37** | +0.5, not 24 |
| Stick occupancy / pagefill / n7–n16 | `c8db` 13.9/12.77; n14 7.23 | sat ~12.8 or worse | 16-bit stick fill vs scan |
| Prefer ffmpeg over present (nice) | ARM `31b95379` on ac95 | 16.0 / 13.48 | same 16 class |
| ffmpeg write tmpfs not pipe | ARM `cbe79a15` shm + `pread` | **15.4 / 12.16** | **HURT**; reverted |
| CATCH ready-window (`P1_SWAP_RDYWIN`) | `2bbe6755` fair L4 | **27.9 / 19.86** vs ac95 **28.0 / 19.51** | **+0.35 hw ≠ 23.9**; SAME_CLASS; closer CLOSED |
| Host `warmup_prefill` n=2 t0_rearm | `2bbe` + `fc2bcd53` | **27.8 / 19.93**; first_1s **10.3/9.4** | SAME_CLASS; 3 s ramp remains; CLOSED |
| Another 960 CATCH exclusive after Phase 2 HURT | — | first 620c HURT was **HOST** | Fair retry on same silicon is glass+produce OK. Cousin exclusive **NAME=NONE**. |

**L46 is stale vs this silicon.** `T_copy_arm` ~15 ms is real but **not** the unique24 wall.

### 2.4 What the unique24 hole *is* (15 s last-line)

Working model (not a FIT grant). Cite `/tmp/misterplex-agent-R-hw.txt` + `/tmp/misterplex-agent-D-u6.txt`.

CATCH is one swap per core vblank. Freddo beam 1312×762 @ 24 MHz ≈ **24.006 Hz**. 960 CEA 1650×758 @ 30 MHz ≈ **23.986 Hz**. HDMI is **74.25 MHz 60 Hz** (`ascal`). OSD 24 Hz ≠ unique24.

| window | ac95 U1 | 2bbe fair L4 | prefill | 620c fair Track B |
|---|---|---|---|---|
| first_1s | ~10.1 / 8.68 | ~9.92 / 8.52 | 10.3 / 9.4 | (not re-binned) |
| first_3s hw | **~11.27** | **~11.13** | ABSENT | — |
| last-line 15 s | **19.51** | **19.86** | **19.93** | **20.42** |
| late ~5 s | **~20.98** | **~22.96** | ABSENT | — |
| unused vs ~24 | **~4.5 Hz** | **~4.1 Hz** | **~4.1 Hz** | ~3.6 Hz |

**VERDICT=BOTH.** First 3 s ~10–11 Hz is **host warmup** (`hw_match=1` — FPGA already takes every kick). Late incremental is **~21–23, not 24** (steady miss ~1–3 Hz). Warmup holds ~68% of unused blanks.

**15 s last-line math:** if first 4 s stay ~10 Hz, even 100% late blanks last-line-ceiling **≈21.07 < 23.9**. Longer play cannot print unique24 while that ramp stays. Harvest loosen (last 5 s / peek / drain) is Phase 5 — **user grant**, not a closer.

**U6 NAME=NONE.** Living CATCH already *is* scored RDYWIN (`pending_ready` KEEP, live `pending_ready_ddr`, no PREP nuke in CATCH window, last-wins `pend2`). Widening pend2 is a RDYWIN cousin. No leftover-class swap site distinct from scored RDYWIN/PREFILL. `FIT_GO=NO`.

---

## 3. Honest scoreboard

1280×720 unless marked. unique24 FAIL on every 1280 row.

| Prefix / play | Path | pfps | hw_fps | presented | Notes |
|---|---|---:|---:|---:|---|
| **`620c` ahead48 paced `e7106b72`** | 960 heap prime 48 + wait_swap | **27.9** | **23.68** | 313 | **BEST last-line.** 3 swaps short of 23.9. `/tmp/pfps-720p24-620c-ahead48.txt` |
| **`620c` ahead36 paced `9167c23d`** | 36 wait_swap | **27.7** | **23.45** | 304 | `/tmp/pfps-720p24-620c-ahead2.txt` |
| **`620c` ahead36 blast `6722ae42`** | 36 BestEffort no wait | **28.4** | **22.01** | 292 | CATCH dropped ~half. `/tmp/pfps-720p24-620c-ahead.txt` |
| **`620c` memcpy revert `3a3fcf22`** | 2slot_cached_ring | **24.2** | **20.05** | 289 | ingest reverted. `/tmp/pfps-720p24-620c-revert.txt` |
| **`620c` DDR ingest `44f24f78`** | 2slot_ddr_ingest | **12.6** | **10.23** | 151 | **HURT black.** read_us ~67 ms. `/tmp/pfps-720p24-620c-ingest.txt` |
| **`620c27ec` fair Track B `1cf961c5`** | 960 inproc 4/3, STICK=0 | **24.3** | **20.42** | **293** (log) | Late ~23.92. First 4 s hole. `/tmp/pfps-720p24-620c-fair.txt` |
| **`ac95` ahead720 n=36 `cd73f1db`** | 1280 heap prime 36 + wait_swap | **30.6** | **22.32** | 289 | True 720p loop start. Was 19.79. `/tmp/pfps-720p24-ac95-ahead720.txt` |
| **`ac95` 23:25Z leftover movie** | 1280 inproc | **27.9** | **19.79** | 420 | SAME_CLASS U1. `/tmp/pfps-720p24-ac95-loop.txt` |
| **`2bbe6755` PREFILL `fc2bcd53`** | warmup_prefill n=2 | **27.8** | **19.93** | 416 | **CLOSED as path**; first_1s 10.3/9.4 |
| **`2bbe6755` RDYWIN fair L4 `97643cb8`** | CATCH live-ready | **27.9** | **19.86** | 419 | **CLOSED as closer**; +0.35 hw ≠ 23.9 |
| **`ac95` + U1 inproc `b06a433c`** | DDR3 + libav + A9 1.2G | **28.0** | **19.51** | 420 | produce PASS; `read_us` 25355 |
| **`ac95f8c8` sidecar** | DDR3 CATCH pre-U1 | **15.9** | **13.05** | 240 | Best pre-U1 720p glass |
| `ac95` profile | PRESENT_PROFILE | 15.9 | 13.57 | 239 | `read_us` 53275 |
| `112bb651` | SWAPVB | 15.7 | 13.38 | 237 | same class |
| `112bb` BestEffort | no PLXD wait | **16.2** | **13.37** | — | best pre-U1 pfps |
| `112bb` HDMI24 | CEA 30 MHz | 14.5 | 12.31 | — | **HURT**; poke 74250 |
| `ac18b5b9` | PLXP cached ring | 15.6 | 12.74 | 236 | `copy_us=0` |
| `6ffa88e7` | stick burst-then-idle | 15.9 | 12.79 | 240 | `read_us` 53079 |
| `c8db61b8` | stick STICK=1 | 13.9 | 12.77 | 210 | stick sat |
| ac95 + nice `31b95379` | ffmpeg nice −5 | 16.0 | 13.48 | 242 | same 16 class |
| ac95 + shm `cbe79a15` | `/dev/shm` + `pread` | 15.4 | 12.16 | 186 | **HURT**; reverted |
| `2bbe` first play | unpinned ARM `52306628` | NONE | NONE | **0** | **INVALID**; glass=true480 |
| **`620c` first Track B** | STICK=1 INPROC=0 pipe | **15.3** | **14.78** | **1** | **HOST invalid** + green 1280-into-960 idle |
| **`620c` historical** | 960 (old host) | 23.0 | 18.29 | — | not a 720p unique24 claim |
| **`69ccec33`** | 960 CATCH | 22.7 | 18.45 | — | **BAN** as unique24 |
| ffmpeg → `/dev/null` | live Plex | **24** | — | — | 480 / 20 s class |
| isolated ffmpeg | daemon stopped | **32.31** | — | — | W-meas |

Do-not-replay (non-exhaustive): `6ffa88e7`, `ac18b5b9`, `c8db61b8`, HDMI24, `69ccec33` as unique24, first `620c` HOST-invalid play, `8832824e`, `75da8bb1`, `4d6ee356`, `4deaf6cc`, `dabdaeb0`, n20–n28 MAGIC_F@+0x110 family, `07f54d9f` as a 720p claim, **`P1_SWAP_RDYWIN` exclusive cousins**, **`P1_PREFILL` cousins**, **`2bbe` as leftover** (glass-HURT). **`620c` living leftover is not a bitstream BAN.** Do not treat harvest `presented=1` on a 960 play as silicon BAN when last-1Hz `hw_presents` is hundreds.

---

## 4. Architecture (what is actually running)

**Living leftover `620c` (Track B):**

```
clip 1280×720 CBP
    → inproc libav decode 1280
    → point-sample 4/3 → packed I420 960×540 (777600 B)
    → 2-slot ring
    → memcpy PHYS_BASE 0x30180000  (3-bank, stride 0x180000)
doorbell 0x3047F000  (+0x118 MAGIC_F, +0x128 PLXD, +0x130 PLXJ aspect ACK)
    → ddr_frame_store CATCH
    → PRESENT_BEAM_960: sample store at 3/4 onto CEA 1280×720 DE
      (sx=hc*3/4, sy=vc*3/4)  1650×758 @ 30 MHz ≈ 23.986 Hz
    → ascal HDMI 1280×720 74.25 MHz 60 Hz
```

**ac95 sidecar (1280 unique24 leftover-class):**

```
inproc libav → 2-slot ring (1.38 MB × 2)     [U1; produce 28.0]
    → PHYS_BASE 0x30180000
    → ddr_frame_store CATCH (not RDYWIN on this bitstream)
    → Freddo beam 1312×762 @ ~24 MHz ≈ 24.006 Hz
    → ascal HDMI 720p60
```

720p fits: `PRODUCT_NO_STUB=1`, `DDR_FRAME_STORE=1`. `620c` has `PRESENT_BEAM_960=1` `FRAME_W=960`. `ac95` has `PLEX_PRESENT_720P_L4=1` `FRAME_W=1280`. Stick `SDRAM_I420_STORE` off on both.

Wrap `BUILD_OK` is hardcoded NO — ignore. Independent BUILD_OK = `FIT_WRAPPER_RC=0` AND Full Comp 0e AND TNS=0 AND clk_ddr slack≥0 AND farm==local AND prefix unbanned.

---

## 5. Closed experiments (do not reopen)

### FPGA / RBF

- Stick FSM, n7–n16 fill-ratio, pagefill, MemTest-8, burst-then-idle (`6ffa`).
- PLXP scan of ffmpeg System-RAM (`ac18`).
- HDMI24 modeline / L4 emit 24 Hz HDMI.
- Doorbell or mailbox PHYS relocate.
- SWAPVB / CATCH cousins as 24 claims (`112bb` same class).
- 960 CATCH / WAIT_TAG / READY_HOLD **as 720p unique24** (`69cc`, `06cf`, `c2ad` TIMING_FAIL).
- **`P1_SWAP_RDYWIN` (`2bbe6755` fair 27.9/19.86).** SAME_CLASS ac95 U1. **CLOSED as unique24 closer.** Glass-HURT; sidecar KEEP; **not** a 620c replacement.
- **U6 leftover-class swap. NAME=NONE.** No site distinct from scored RDYWIN/PREFILL. 15 s last-line cannot print 23.9 while first 4 s stay ~10.

### Host

- `RequireReleased` vs BestEffort.
- Nice flips / shm-file ingest / pipe size.
- U1 inproc produce (PASS 28.0 at 1280; unique24 still FAIL on hw).
- **`P1_PREFILL` n=2 t0_rearm.** SAME_CLASS. first_1s still ~10. **CLOSED.**
- Treating first `620c` play (STICK=1 / INPROC=0 / green idle) as a 960-silicon BAN. That play is **HOST invalid** (same class as first `2bbe` unpinned ARM).

### Process

- Harvest mill / cards / PHASE_BACKLOG prepends as a substitute for product work.
- `deploy_plex_core.sh` for 720p.
- Mid-fit RTL. Second Quartus. Named `load_core` of sidecars.
- Auto-play `ac95` over living `620c`.
- Asking the user to look at the TV (L58 — farm HDMI on node-worker1).

---

## 6. Not tried yet (and why)

| # | Idea | Why it might work | Why it might fail | Cost |
|---|---|---|---|---|
| **U1** | In-process libav | **SCORED** 28.0 / 19.51 | unique24 FAIL on hw | DONE produce |
| **U2** | PL330 / ACP / write-combine into `0x30180000` | Removes 12 ms CPU memcpy | `ac18` copy_us=0 still 16 fps pre-U1; produce is already 28 | Host+maybe FPGA |
| **U3** | `MISTER_SMALL_VBUF` | Quieter ascal | **TIMING_FAIL** `c94f8847` **CLOSED** | — |
| **U4** | A9 overclock | Isolated 32 has headroom | U1 already 1.2 GHz | Lab only |
| **U5** | Track B 960 + ascal 720p HDMI | **SCORED** glass OK, produce **24.3**, user chevron OK | unique24 FAIL hw **20.42**. Not coded 1280 | **LIVING product** |
| **U6** | FPGA swap after produce is 24 | hw_fps is the unique24 hole | **NAME=NONE.** RDYWIN+PREFILL SAME_CLASS. 15 s last-line ceiling ~21 if warmup stays | Do not FIT |
| **U7** | FPGA Baseline 720p24 decode | Deletes ARM produce | Months; stub is not a decoder | User grant |
| **U8** | Hybrid FPGA IDCT/MC | Offload some CAVLC | ARM still emits full I420 | Exclusive + host |
| **U13** | Fix first-4s host warmup (not prefill n=2) | Warmup is ~68% of unused blanks | PREFILL already failed first_1s~10. Any cousin is CLOSED. Last-line still needs late≈24 | Host only if **NEW** shape |
| **U14** | Harvest last-N-s / peek (Phase 5) | Late 2bbe ~22.96 | **User grant.** Still ≠ 23.9 unless late is 24. Does not make unique24 true | Policy |
| **U15** | `P5_960_DDR_INGEST` (loop tick noted UNAPPLIED) | Maybe quieter 960 present | Unapplied. Not a unique24 closer. Do not play without parent PLAY_GO | Host |

---

## 7. Recommended next (for the next harness)

1. Read this file + `docs/LESSONS.md` L44–L58. Living leftover is **`620c27ec`**. User confirmed chevron. Do **not** put `ac95` or `2bbe` on product.
2. unique24 is **FAIL** and **structurally blocked** on the 15 s last-line while first 4 s stay ~10 Hz. U6 **NAME=NONE**. `FIT_GO=NO`.
3. Track B v0 is the living product: 960 coded, HDMI 720p60, 16:9, produce 24.3, clean glass. Optional host-only tune (U13/U15) only with a **NEW** name, one play, HDMI during, restore `620c` on HURT.
4. FPGA 16:9 default in `Plex.sv` rides the **next** 720p exclusive — do not FIT only to change default AR (living `620c` already fills 16:9 HDMI).
5. If they want unique24 as written: need **both** a NEW host warmup that actually presents ~24 from t=0 **and** late hw≈24. Neither exists as a named leftover-class design. Do not reopen RDYWIN/PREFILL.
6. FPGA decode (U7) is a new architecture program. Do not promise 24 this week.

### Agent shape

Parent owns FIT_GO / PLAY_GO / leftover. Do **not** claim “next = RDYWIN / PREFILL / ac95 play / 960 CATCH cousin.”

| Phase | Status | Exclusive |
|---|---|---|
| P0 restore ac95 | **DONE** (then superseded by fair 620c) | no |
| P2 first 620c | **HOST invalid** (green 1280-into-960) | no |
| P2 fair 620c | **GLASS OK + produce 24.3** | no |
| P4 new 960 exclusive | **not needed** | no |
| U6 unique24 swap | **NAME=NONE** | no |
| 16:9 HDMI default | **host live**; FPGA default in tree for next fit | no |

---

## 8. Pickup checklist

```text
[ ] Lab Plex.rbf == 620c27ec75eaa2d60e7dae66dd4e8154 (living Track B leftover)
[ ] User + parent I SAW orange chevron (user-ok-f1.jpg). Do not restore ac95 over it.
[ ] ac95 sidecar KEEP (not product). 2bbe KEEP only (glass-HURT).
[ ] Utility true480 bak == 07f54d9f UNTOUCHED
[ ] HDMI 74250 (not 24 Hz). Aspect 16:9 on 720p HDMI.
[ ] ARM 3a3fcf22 (prefix960 + inproc 4/3 + idle 16:9). Do not play unpinned ARM.
[ ] unique24 FAIL until both pfps and hw_fps ≥ 23.9 on coded 1280
[ ] Track B produce 24.3 / hw 20.42 / glass OK — not a unique24 claim
[ ] First 620c play 15.3/14.78 is HOST invalid — not a 620c BAN
[ ] Harvest presented=1 on 960 plays: use last-1Hz hw_presents
[ ] P1_SWAP_RDYWIN CLOSED. P1_PREFILL CLOSED. U6 NAME=NONE. FIT_GO=NO
[ ] Worktree: MisterPlex-wt-480p-lessons / lessons/true480-720p24
[ ] Farm HDMI: node-worker1 /dev/video0 MJPEG 1280x720. Discard e74e3559.
[ ] Farm Quartus: PATH=/tmp/misterplex-sshbin. One exclusive.
[ ] No deploy_plex_core.sh, no /bin/fpga, no named sidecar load
[ ] play_slot720p24freddo DEFAULT_RBF is 2bbe — always pass KEEP path
[ ] Closed: 6ffa stick, ac18 PLXP, HDMI24, doorbell PHYS, nice, shm, 960-as-unique24,
    RDYWIN closer, PREFILL path, U6 leftover-class swap
```

## 9. Evidence index

| What | Path |
|---|---|
| Isolated 32.31 fps | `/tmp/misterplex-agent-W-meas.txt` |
| U1 inproc 28.0/19.51 | `/tmp/pfps-720p24-ac95-u1-inproc.txt` |
| ac95 23:25Z movie 27.9/19.79 | `/tmp/pfps-720p24-ac95-loop.txt` |
| **620c fair Track B 24.3/20.42** | `/tmp/pfps-720p24-620c-fair.txt` |
| 620c first play HOST invalid | `/tmp/pfps-720p24-620c-trackb.txt` |
| 2bbe fair L4 27.9/19.86 | `/tmp/pfps-720p24-2bbe6755-l4.txt` |
| 2bbe PREFILL 27.8/19.93 | `/tmp/pfps-720p24-2bbe-prefill.txt` |
| 2bbe first play HOST invalid | `/tmp/pfps-720p24-2bbe6755.txt` (presented=0) |
| U6 NAME=NONE | `/tmp/misterplex-agent-D-u6.txt` |
| first-4s / late hw | `/tmp/misterplex-agent-R-hw.txt` |
| 960 idle RCA (green = stride) | `/tmp/misterplex-agent-R-960idle.txt` |
| HDMI 620c green (invalid play) | `/tmp/misterplex-eyes/trackb-620c-now2.jpg` |
| HDMI ac95 clean idle | `/tmp/misterplex-eyes/ac95-restore-f2.jpg` |
| HDMI ac95 movie | `/tmp/misterplex-eyes/ac95-movie-f2.jpg` |
| HDMI 620c fair movie | `/tmp/misterplex-eyes/620c-fair-f2.jpg` |
| HDMI 620c orange idle (user OK) | `/tmp/misterplex-eyes/user-ok-f1.jpg` |
| Pipe profile 53.3 ms | `/tmp/pfps-720p24-ac95-profile.txt` |
| Historical 960 (not this leftover) | `/tmp/pfps-720p24-69ccec33.txt`, `/tmp/pfps-720p24-620c27ec.txt` |
| Loop status | `/tmp/misterplex-loop-status.txt` |
| L45/L46/L57/L58 | `docs/LESSONS.md` |
| FPGA decode plan | `docs/phase3-decode.md` |
| Durable Memory copy | `~/Projects/MisterPlex/Memory/lab/status/RESEARCH_720P24.md` |
