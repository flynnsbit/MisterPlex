# FAB PLAYING parent capture contract (pre-registered)

**Lane:** w-osd · tip family `9b28290b`+  
**Product claim this scores:** PMS **960×540** baseline → ARM decode+copy →
**fabric upscale** to a native **1280×720** raster on glass.  
**Honesty label:** this is **720p output**, not 720p source.

Parent owns every device step. Numbers below are **before** any glass photo.
Idle cyan contracts remain binding for the idle milestone; this card is the
**PLAYING** milestone and does **not** require `CYAN_PX`.

**Related:**  
- Idle: `docs/fab-idle-parent-capture-contract.md`  
- Chrome demo: `docs/fab-chrome-parent-capture-contract.md`  
- Post-fit + ARM-out: `docs/fab-idle-postfit-gate.md`  
- Geometry: `docs/chrome-idle-geometry-contract.md` §9  
- Pair scorer: `scripts/hdmi_score_pair.sh`

---

## 0. Binding control (do not re-derive)

Parent glass, core `d1b24e0c`, `video_mode=0`, ARM idle (2026-08-03):

```
MEAN=14.4  STD=24.4  ORANGE_PX=12889  CYAN_PX=0  ACTIVE=923x717  rc=0
```

| Discriminator | Control value | PLAYING product must |
|---------------|---------------|----------------------|
| **ACTIVE** | **923×717** (480p-class letterbox in 720p beam) | **Grow** toward full 1280-class |
| **CYAN_PX** | 0 | Stay **≈0** (idle plane off) |
| **ORANGE_PX** | 12889 (chevron) | **Drop** vs control (real video ≠ amber logo) |
| **MEAN** | 14.4 (dark idle) | **Rise** into content band (not black) |

Any scorer that GREENS the control frame as PLAYING PASS is **broken**.

---

## 1. What is under test (and what is not)

| Layer | Resolution | Who |
|-------|------------|-----|
| Coded / bank | 960×540 | ARM decode + copy (measured 34.50 ms) |
| HDMI beam | 1280×720 (`video_mode=0`) | w-clock / MiSTer.ini |
| Upscale | 960×540 → 1280×720 | **w-scaler** (load-bearing) |
| Chrome HUD | HDMI space only | w-osd PLXC / optional `PLEX_FAB_CHROME` |

**Not required for PLAYING PASS:**

- `PLEX_FAB_IDLE` — must be **OFF** (else idle steals the raster)
- `CYAN_PX≥2000` — that is the **idle** signature
- Magenta L-brackets — only if this fit also enables `PLEX_FAB_CHROME` (orthogonal demo)

**Required platform knobs:**

| Knob | Value |
|------|--------|
| `video_mode` | **0** (same beam as control) |
| `PLEX_FAB_IDLE` | **undefined / OFF** |
| Cast | real 960×540 (or measured proxy) **moving** content |
| Grabber | `scripts/hdmi_capture_idle.sh` only (never bare 1-frame ffmpeg) |

---

## 2. Exact commands (copy/paste)

Paths under `docs/agent-evidence/` so artifacts stay in-repo (not `/tmp`).

```bash
EV=docs/agent-evidence
mkdir -p "$EV"

# --- P0  Negative: control must stay RED vs this contract ---
# Load d1b24e0c (or any macros-OFF idle). video_mode=0. Daemon idle OK.
scripts/hdmi_capture_idle.sh $EV/play-neg-control.png
# Expect class CONTROL (table §4). Must NOT meet PLAYING PASS.

# --- P1  PLAYING dual snap (geometry + real-video motion) ---
# Integration RBF with fabric present/scale path. Cast 960×540 moving title.
# FAB_IDLE off. Prefer HUD hidden or minimal for clean ACTIVE (optional).
scripts/hdmi_capture_idle.sh $EV/play-t0.png
sleep 1
scripts/hdmi_capture_idle.sh $EV/play-t1.png
scripts/hdmi_score_pair.sh $EV/play-t0.png $EV/play-t1.png
# Prints ACTIVE_*, DIFF_*, ORANGE_*, CYAN_*, VERDICT=...

# --- P2  Freeze arm (last-frame present without ARM writers) ---
ssh root@${MISTER_HOST:-192.168.1.183} 'pidof misterplexd'   # note PID
ssh root@${MISTER_HOST:-192.168.1.183} 'kill <PID>'          # PID only — killall banned
sleep 2
scripts/hdmi_capture_idle.sh $EV/play-nodaemon-t0.png
sleep 1
scripts/hdmi_capture_idle.sh $EV/play-nodaemon-t1.png
scripts/hdmi_score_pair.sh $EV/play-nodaemon-t0.png $EV/play-nodaemon-t1.png
# Expect: ACTIVE still large; DIFF≈static (frozen last bank frame). Not black.

# --- P3  Optional chrome plane (separate claim) ---
# Only if this RBF has PLEX_FAB_CHROME=1 (not the default product fit).
# Expect MAGENTA_PX≥1500, CYAN≈0 — see fab-chrome-parent-capture-contract.md
```

---

## 3. Pre-registered PASS (all must hold on P1)

| Metric | PASS | vs control | Why |
|--------|------|------------|-----|
| **ACTIVE_W** | **≥ 1100** | control **923** | Geometry: fabric fills toward 1280-class |
| **ACTIVE_H** | **≥ 680** | control **717** is tall letterbox; width is the weak axis — **both** gates | H alone can false-green a pillar box |
| **ACTIVE area** | **≥ 1100×680 = 748000** | control 923×717≈661k | Area must grow, not just reshape |
| **CYAN_PX** | **≤ 200** | control 0 | Idle plane must be off during PLAYING claim |
| **ORANGE_PX** | **≤ 4000** | control **12889** | Rejects “still showing idle chevron” as PLAYING |
| **MEAN** | **20 .. 160** | control 14.4 | Content band; not black, not clipped white field |
| **STD** | **≥ 18** | control 24.4 | Structured picture (weak alone — pair with DIFF) |
| **DIFF_PX** (t0→t1, 1 s) | **≥ 8000** | static ≈0..few hundred JPEG | **Real video** vs static test / frozen pattern |
| **DIFF_MEAN** | **≥ 1.5** | static ~0 | Luma change backup if DIFF_PX noisy |

**FULL PASS** = every row GREEN on **P1**, and **P2** does not go black
(`MEAN` still in band, `ACTIVE` still ≥ gates).  
P2 is allowed to fail DIFF (freeze is expected after `kill <PID>`).

### Soft unknowns (recal once, publish both arms)

- Grabber scales 1280×720 into 1920×1080 — ACTIVE may top out below 1280×720.
  Gates **1100×680** are deliberately below full raster; if first good fabric run
  lands ACTIVE=1050×700, publish numbers and hold GREEN until one agreed recal.
- `DIFF_PX≥8000` is pre-reg for **moving** content over **1 s**. Static title cards
  will RED DIFF by design — cast a motion scene (BBB chase, not a still poster).
- JPEG slop can invent a few hundred DIFF_PX; threshold is 10× above that class.

---

## 4. Partial-failure taxonomy (one capture → diagnostic class)

Score **P1** (and P2 when noted). Pick the **first matching** row top-down.

| ID | Name | Measurable signature | Meaning |
|----|------|----------------------|---------|
| **A** | **FABRIC_PLAY_OK** | ACTIVE_W≥1100 ∧ ACTIVE_H≥680 ∧ area≥748k ∧ CYAN≤200 ∧ ORANGE≤4000 ∧ MEAN 20..160 ∧ DIFF_PX≥8000 ∧ P2 not black | Product claim holds on glass |
| **B1** | **ONE_SHOT_THEN_DEAD** | P1 meets ACTIVE+MEAN once; later snap or P2: **MEAN≈0 STD≈0** or ACTIVE=0×0 | Presented one frame then present path died (bank/ freerun) |
| **B2** | **STATIC_FULL_RASTER** | ACTIVE gates PASS, CYAN≤200, ORANGE≤4000, but **DIFF_PX&lt;8000** and DIFF_MEAN&lt;1.5 on moving cast | Geometry OK; **not** live video — frozen bank, bars, or still pattern. Distinct from idle (orange low). |
| **B3** | **PHASE_STUCK_IDLE** | CYAN≥2000 ∧ ORANGE≥500 ∧ DIFF low (or chevron-only motion) | Idle plane on; **not** a PLAYING result (use idle contract) |
| **C1** | **ARM_LETTERBOX_SCALE** | Video-like MEAN/STD/DIFF, but **ACTIVE_W≤950** or area≤ control·1.05 (~694k) ∧ CYAN≤200 | Beam is 720p but content still **control-class letterbox** — fabric upscale **not** filling; ARM/480p path still winning |
| **C2** | **ARM_OVERLAY_BAKE** | ACTIVE may PASS; **MAGENTA≈0** with visible HUD text; after `kill <PID>` HUD **remains burned into** the frozen frame; logs show bake not `plane=1 skip` | ARM still compositing pixels into the bank. Fabric chrome/PLXC skip path not live. |
| **C3** | **DUAL_PAINTER** | CYAN or MAGENTA fabric sig **and** control-class ORANGE chevron counts, or HUD doubles | Both ARM and fabric painting; not a clean plane cutover |
| **D1** | **CYAN_WRONG_STATE** | CYAN≥2000 during a cast that should be PLAYING | `PLEX_FAB_IDLE` on or `has_frame` forced 0 — idle stole PLAYING |
| **D2** | **UPSCALE_GEOMETRY_FAIL** | CYAN≤200, content present (MEAN/STD OK), ACTIVE **stuck ≈923×717** (±3%) | Fabric/idle off but **upscale window wrong** (scaler/geom/PLXG). Colour OK, geometry fail. |
| **D3** | **PILLAR_OR_WINDOW** | ACTIVE_H≥680 but ACTIVE_W≪1100 (or ACTIVE_X span shows fat side gutters) while MEAN OK | Partial scale / wrong display window — not full 1280 fill |
| **E** | **E_NOSIGNAL** | `STD<0.5` ∧ `ACTIVE=0×0` (mean may be 0 **or** ~7) | Hung SoC / no-signal — **not** a product class. Measured wedge: MEAN=7 STD=0 ACTIVE=0×0 |
| **E0** | **UNKNOWN_GRABBER** | `hdmi_capture_idle` rc=1, or `hdmi_score_pair.sh --grabber-not-ready` (**exit 3**) | Grabber busy/absent — **never** fabric PASS or FAIL |
| **F** | **CONTROL_FALSE_GREEN** | held `ctrl720_arm.png` meets **A** | **Scorer bug** — stop, fix gates |
| **CONTROL** | **CONTROL_ARM_IDLE** | ACTIVE≈923×717, ORANGE≫4000, CYAN=0, DIFF=0 | Binding NEG; not C1 (C1 is video-like letterbox) |

### Parent one-liners

```
A        = fabric works (geometry + live video + present survives ARM-out freeze)
B1       = one frame then died (t0 picture, t1 nosignal)
B2       = full-looking raster but static (not scaling *live* video)
B3       = idle plane (cyan)
C1       = ARM/480p letterbox still (ACTIVE control-class, video-like)
C2       = ARM still feeding overlay pixels into the bank
D1       = cyan/idle on during playing claim
D2       = upscale wrong (ACTIVE stuck 923×717)
D3       = pillar / partial window
E        = no-signal / hung device (STD≈0 ACTIVE=0×0) — not product
E0       = UNKNOWN_GRABBER (capture rc=1) — not product; score exit 3
CONTROL  = ARM idle letterbox NEG (ctrl720) — must not score A
```

---

## 5. How A differs from “static test pattern”

| | Live 960→720 video (**A**) | Static fabric pattern (**B2** / bars) | Idle chevron (**B3**) |
|--|---------------------------|----------------------------------------|------------------------|
| ACTIVE | ≥1100×680 | may also be large | large if FAB_IDLE |
| DIFF 1 s | **high** | **low** | low or chevron-only |
| ORANGE | **low** (≤4000) | low | **high** (≥500, often ≫) |
| CYAN | ≈0 | ≈0 | **≥2000** |
| After kill PID | freeze, still large ACTIVE | freeze or bars remain | **keeps moving** if true fabric idle |

**Decisive pair for product:** **ACTIVE growth** ∧ **DIFF high** ∧ **CYAN≈0** ∧ **ORANGE not chevron-class**.  
ACTIVE alone can be a static 720p test screen. DIFF alone can be a blinking OSD on a letterbox. Both required.

---

## 6. Hierarchy gate still binds

Before trusting glass:

```bash
make post-fit-fab-idle FIT_RPT=$FITDIR/Plex.fit.rpt MAP_RPT=$FITDIR/Plex.map.rpt
# true rc=0 required. Hierarchy FAIL → void glass PLAYING claim.
```

PLAYING does not add new entities beyond present/scale/chrome survival; w-scaler
owns upscale ALMs. If `present_core` / `ddr_frame_store` elided, PLAYING cannot PASS.

---

## 7. Negative tests (must RED)

| ID | Setup | Must score |
|----|-------|------------|
| **N1** | Control `d1b24e0c` idle mode0 | Class **CONTROL_ARM_IDLE** / not A — ACTIVE≈923×717, ORANGE high, CYAN=0 |
| **N2** | FAB_IDLE RBF, no cast | Class **B3** — CYAN≥2000; PLAYING A is RED |
| **N3** | Moving cast but macros-OFF and no fabric scale (480p content path) | Class **C1** or control ACTIVE |
| **N4** | P1 on a **still** title card | Class **B2** (DIFF fail) — proves DIFF gate has teeth |
| **N5** | `hdmi_score_pair.sh` on two copies of control PNG | DIFF≈0, VERDICT not A |

---

## 8. Optional FAB_CHROME during PLAYING

If the same session enables `PLEX_FAB_CHROME=1` (demo HUD + magenta):

| Extra | PASS add-on |
|-------|-------------|
| MAGENTA_PX | ≥1500 |
| CYAN_PX | ≤200 |
| Bottom panel | visible; underlay still satisfies §3 ACTIVE+DIFF |

Product shipping fit should keep FAB_CHROME **OFF** and use PLXC state-change HUD
when plane live — magenta is a **lab signature**, not the product requirement.

---

## 9. Sim / offline evidence (no device)

```bash
# Pair scorer unit (synthetic PNGs) — true rc must be 0
tests/unit/test_hdmi_score_pair.sh; echo "true rc=$?"

# Chrome cmds: HUD in output 1280×720, not coded 960×540
# (y-range [572,662] on 720p bottom band)
c++ -std=c++17 -O2 -Ihost -I. tests/unit/test_plex_chrome_cmds.cpp \
  -o build/test_plex_chrome_cmds && ./build/test_plex_chrome_cmds
# true rc=0
```

---

## 10. What this contract refuses to claim

- Refresh rate / true 24 Hz CEA — w-clock `clk_pix` (~29.7 MHz); ACTIVE≠fps.
- 720p **source** — bank is 960×540 until DMA/write-combine (w-path).
- ARM millisecond savings — glass taxonomy only; profile separately.
- Soft-skip 77 or hierarchy-only green as PLAYING PASS.

---

## 11. Instrument validation (parent-held real frames)

Scored on build host against frames parent captured on glass. Fixtures checked into
`docs/agent-evidence/` so the unit test does not depend on `/tmp`.

| Frame | Ground truth | Scorer output | OK? |
|-------|--------------|---------------|-----|
| `ctrl720_arm.png` self-pair | ARM idle, mode0: MEAN=14.4 ORANGE=12889 CYAN=0 ACTIVE=923×717 | **`VERDICT=CONTROL_ARM_IDLE`** active_pass=0 | YES — not A, not C1 |
| `wedge_check.png` self-pair | Hung SoC no-signal: MEAN=7.0 STD=0.0 ACTIVE=0×0 | **`VERDICT=E_NOSIGNAL`** | YES — was UNSCORED hole before fix |
| ctrl → wedge pair | picture then dead | **`VERDICT=B1_ONE_SHOT_THEN_DEAD`** | YES |
| `--grabber-not-ready` | capture rc=1 | **`VERDICT=UNKNOWN_GRABBER` exit 3** | YES |

**Hole closed:** first scorer treated only `MEAN==0 && STD==0` as black. Real wedge is
**MEAN=7 STD=0 ACTIVE=0×0**. Rule is now `STD<0.5 ∧ ACTIVE area==0`.

```bash
scripts/hdmi_score_pair.sh docs/agent-evidence/ctrl720_arm.png docs/agent-evidence/ctrl720_arm.png
scripts/hdmi_score_pair.sh docs/agent-evidence/wedge_check.png docs/agent-evidence/wedge_check.png
# grabber fail path:
scripts/hdmi_score_pair.sh --grabber-not-ready; echo "true rc=$?"   # expect 3
tests/unit/test_hdmi_score_pair.sh; echo "true rc=$?"               # expect 0
```

---

## 12. DIFF gate risk (slow / dark scenes) — opinion

**Yes, false B2 is a real risk** on a dark static film hold (credits, night interior)
even when fabric is correctly presenting live decode at 24 Hz. `DIFF_PX≥8000` over 1 s
is a **content-dependent** motion proxy, not a present-path heartbeat.

| Approach | Verdict |
|----------|---------|
| Keep DIFF for the **integration gate cast** | **Do this.** Gate cast must be a **known-motion** scene (BBB chase / high-motion proxy), same discipline as parent’s 720p control stream. Document on the command card. |
| Lower DIFF to “catch dark scenes” | **Reject** as default — collides with JPEG slop and frozen-bank B2. |
| Triple snap, max pairwise DIFF | Minor help; still content-dependent. Optional later. |
| Content-independent fabric beacon | **Best product fix**, separate from this gate: a vsync-phase **1–2 px marker** or existing chrome sig edge toggled in blanking/corner while PLAYING + plane live (idle already has screensaver motion under FAB_IDLE). Not required to land the first fit gate if cast is motion-known. |
| Screensaver motion as PLAYING key | **Wrong state** — that path is idle (`has_frame=0`). Do not enable FAB_IDLE during a PLAYING claim. |

**Contract rule:** PLAYING PASS **A** is only claimed on a **pre-declared motion cast**.
A dark still that scores B2 is **inconclusive for present**, not proof of failure —
re-run on motion content before calling fabric broken. B2 on a motion cast remains FAIL.
