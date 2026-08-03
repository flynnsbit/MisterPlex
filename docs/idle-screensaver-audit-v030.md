# Idle / screensaver audit — live v0.3.0 (2026-07-29)

**Scope:** what can be verified about the idle/screensaver path **without** HDMI
capture, without reloading the core, and without restarting the daemon.  
**Device under test:** `CORENAME=Plex`, RBF md5 `41adb98c7a630b541091c22ce291be68`,
daemon md5 `06c5735a2f85114688f0ff2ac36e4fd4`, PID stable.  
**Source SoT for this product:** tag `v0.3.0` / `cacd87176cbc2017c6ef2673eef84717dd673009`
(320×240 RGB565 ARM present). HEAD 480p/YUV idle evidence does **not** transfer.

Related session prereg: `.copilot-session/idle-audit-prereg-20260729.md`.

---

## Pre-registered prediction (before verification)

| Class | Predicted | Actual after audit |
|-------|----------:|-------------------:|
| Sound checks | 6 | **8** |
| Vacuous / weak | 4 | **3** |
| Unscoreable w/o eyes/capture/play | 5 | **6** |

**Prediction held on direction, missed counts** (under-counted sound because
live DDR logo match was not assumed; under-counted unscoreable because conf
still advertises 480p play path). Publishing the miss is intentional.

Expected honest goal score before measuring: **40–55%** (not 93%).  
After measuring: **48%** (see Rescore).

---

## Important: what “93%” is not

In `docs/PHASE_BACKLOG.md` G-IDLE2c, **93.1%** is a **bug metric**:

> middle band is **93.1%** pixel-identical to `screensaver_poststop`

That number means “LastFrame retained stale screensaver pixels,” **not**
“idle/screensaver goal is 93% complete.” Treating 93% as a completion score is
exactly the class of error this fleet exists to catch.

Separately, G-IDLE2 already records that the multi-mode goal was once scored
**100% on one mode** and corrected to **65%**. Even 65% rested on 480p-line
hardware captures that **do not describe** the live `41adb98c` 320×240 core.

---

## Boundary: provable vs eyes-only

### A. Provable without capture (host / RTL / read-only device)

| # | Claim | Method | Result | Class |
|---|--------|--------|--------|-------|
| A1 | Idle bit map `O[15:14]` → Logo/Black/SS/LastFrame | `test_osd_menu` @ tag | PASS | Sound |
| A2 | Black fill is exact zeros (RGB24) | unit + **black mutant** paints `0x10` → **230400 FAILs, rc=1** | PASS (can fail) | Sound |
| A3 | Logo has FG+BG only, FG>0 | unit | PASS | Sound |
| A4 | LastFrame is a no-op (buffer unchanged) | unit + **LF mutant** that paints → **rc=1** | PASS (can fail) | Sound |
| A5 | `idleDrift` stays in `[0,span]` and reverses | unit | PASS | Sound |
| A6 | Screensaver FG stays inside margin | unit (all phases step 7) | PASS | Sound |
| A7 | Screensaver **position changes** with phase | extra host check (not in v0.3.0 unit) | `SS_MOVED=1`, bbox `8,80..63,159` → `120,152..175,231`, `diff_bytes=7680`, rc=0 | Sound (host) |
| A8 | Live DDR bank0/1 hold **exact** Logo RGB565 | read-only `/dev/mem` dump vs host renderer | md5 **`ed806ec51e6f191a02efa71c4697eb65`** all three; `cmp` rc=0; unique=2 colors `0x1904`×75520 + `0xe501`×1280 | Sound (device) |
| A9 | Live core CONF_STR exposes Idle screen menu | `set_status --confstr` | `O[15:14],Idle screen,Plex logo,Black,Screensaver,Last frame;` present; F1 still `RGB565 frame (320x240)` | Sound |
| A10 | Daemon started idle paint Logo | live log | `IDLE_SCREEN=logo(default)`; `media: idle screen painted (mode=0)`; `has_frame=1` | Sound (telemetry) |
| A11 | `paintIdle` geometry is hard `320×240` at tag | source | yes — conf `DECODE=624x480` does **not** resize idle paint on v0.3.0 | Sound (code) |

### B. Vacuous / weak (cannot fail in the direction that matters)

| # | Claim / check | Why weak |
|---|---------------|----------|
| B1 | v0.3.0 unit “screensaver” loop | Proves **margin only**, never asserts phase N ≠ phase M. A frozen non-moving chevron still PASSes. |
| B2 | G-IDLE2c-style `poststop == paused_reference` (historical) | Equality of two copies of the same tear cannot prove correctness (backlog already says this). |
| B3 | Log line `idle screen painted` alone | Proves the daemon *attempted* a path; without DDR/golden compare it cannot distinguish logo from black-bug. **Elevated to sound only because A8 matched golden.** |

### C. Unscoreable right now (need eyes, capture, mode switch, or playback)

| # | Claim | Blocker on this device |
|---|--------|------------------------|
| C1 | HDMI/VGA picture shows logo (scanout) | No `/dev/video*`, no `uvcvideo`; no eyes gate in this session |
| C2 | Screensaver **animates on glass** | Would need live mode=SS + two time-separated captures or eyes |
| C3 | Black mode on device | Not selected (`IDLE_SCREEN` default logo; `OSD_CONTROL=0` so OSD word cannot switch mode) |
| C4 | LastFrame holds last **decoded** frame | v0.3.0 is intentional no-op (no latch). HEAD G-IDLE2c torn-composite is a **later** path; not re-tested here |
| C5 | Stop/EOF → idle replaces video | Needs a real play then stop. Conf has token, but `DECODE=624x480` + `STREAM=1` on a 320×240 core is unsafe to exercise without an explicit play clearance; **not attempted** |
| C6 | OSD menu idle item applies live | `OSD_CONTROL=0` in conf; live apply path off by design on this boot |

---

## Geometry note (high-risk category)

Live conf still says:

```text
PRESENT=fpga
STREAM=1
DECODE=624x480
OSD_CONTROL=0
```

while the loaded core is **320×240 RGB565** (`41adb98c`, CONF_STR F1 line).  

Idle paint at v0.3.0 **hardcodes** 320×240, which is why DDR matched the logo golden despite the conf lie. That is **good luck for idle**, not proof the play path is coherent. Any future idle/play gate that trusts `DECODE=` without checking the core will mis-size banks (the 320 bank1=`0x30040000` vs 480p bank1=`0x30080000` footgun).

HEAD `test_last_frame_latch.cpp` deliberately contrasts 320 playback layout vs `plex480pDdrFrameGeometry()` idle layout — that test is about the **later** latch, absent from tag `cacd871`.

---

## Evidence quotes (commands)

Host unit (tag sources):

```text
test_osd_menu: OK
green true rc=0
mut black true rc=1   # 230400 failure(s) on v == 0
mut lf true rc=1      # LastFrame no-op broken by mutant
reconfirm green true rc=0
SS_MOVED=1  ss_move true rc=0
```

Device read-only:

```text
CORENAME=Plex
41adb98c7a630b541091c22ce291be68  /media/fat/_Utility/Plex.rbf
pid=31137  md5 daemon=06c5735a2f85114688f0ff2ac36e4fd4
bank0 md5=ed806ec51e6f191a02efa71c4697eb65 unique=2 top=[('0x1904', 75520), ('0xe501', 1280)]
bank1 md5=ed806ec51e6f191a02efa71c4697eb65  bank0==bank1 True
cmp bank0 vs expected true rc=0
has_frame=1
O[15:14],Idle screen,Plex logo,Black,Screensaver,Last frame;
NO_VIDEO_DEV / NO_UVC
```

---

## Rescore (honest)

### Live product goal: “idle/screensaver on the v0.3.0 box the user is using”

| Slice | Weight | Earned | Notes |
|-------|-------:|-------:|-------|
| Host renderer correctness (4 modes + drift + bits) | 25 | 22 | SS motion proven host-side; v0.3 unit gap on motion (−3) |
| Live DDR Logo publish both banks | 25 | 25 | bit-exact golden |
| Live menu surface / has_frame telemetry | 10 | 8 | CONF_STR + log + has_frame; OSD apply off (−2) |
| Black / Screensaver / LastFrame **on device** | 20 | 0 | unscoreable this boot |
| Scanout eyes / capture | 10 | 0 | no grabber |
| Stop/EOF → idle transition | 10 | 0 | not run (play path conf mismatch) |
| **Total** | **100** | **55** | — |

**Defensible score: 55%** for “idle path works on live v0.3.0 as deployed.”  

If the previous headline was **93%**, cut it. The only 93% in-tree is the G-IDLE2c **failure** fingerprint.

### Mapping to backlog gates (for the live core)

| Gate | Prior mark | Live v0.3.0 standing |
|------|------------|----------------------|
| G-IDLE | DONE (old PNG eyes) | **PARTIAL** — DDR logo proven; HDMI/stop transition not re-proven on this boot |
| G-IDLE2a Black | DONE on 480p YUV dumps | **HOST-ONLY** for v0.3.0 RGB path; device mode not selected |
| G-IDLE2b Screensaver | DONE on 480p captures | **HOST-ONLY** motion; device still Logo |
| G-IDLE2c LastFrame torn | OPEN on 480p | **N/A to v0.3.0 latch** (no-op design); do not cite as v0.3 PASS or FAIL without a new test |
| G-IDLE2 multi-mode 65% | historical | **≤40% on live boot** (1/4 modes DDR-proven, 0/4 eyes) |

**480p-line DONE marks stay historical.** They must not inflate the score of the core the user is watching today.

---

## What would raise the score (still no Quartus required)

1. Conf hygiene (when parent allows write): `DECODE=320x240`, `STREAM=0` for v0.3 product cast, keep `PRESENT=fpga`.  
2. With clearance: switch `IDLE_SCREEN` black/screensaver **or** `OSD_CONTROL=1` and set menu bits; re-dump DDR (still no HDMI needed for mode proof).  
3. Two DDR dumps 1s apart in Screensaver mode → animation without capture card.  
4. Optional eyes-on one-liner from the user: “amber chevron on dark field?” → closes C1 only.

---

## Bottom line

- **93% is not a completion score.**  
- **Live Logo idle into DDR is real and bit-exact** on `41adb98c` + matching daemon.  
- **Most of the multi-mode / animation / stop-transition story is either host-only or unscoreable** on this boot.  
- Honest goal standing for the user’s box: **~55%**, not 93%.  
