# Backlog score audit — 2026-07-29

**Live artifact under audit (user box, READ-ONLY):**

| Item | Value |
|------|-------|
| Host | `192.168.1.183` |
| CORENAME | `Plex` |
| RBF md5 | `41adb98c7a630b541091c22ce291be68` (release v0.3.0) |
| Daemon md5 | `06c5735a2f85114688f0ff2ac36e4fd4` |
| Conf (file + adopted) | `DECODE=320x240` `PRESENT=fb0` `STREAM=0` `OSD_CONTROL=0` |
| Capture | **absent** (`/dev/video*` none, `uvcvideo` not loaded) |
| Quartus | held elsewhere — no fit this audit |

**Challenged headline:** parent hourly **78.4%** programme completion.

---

## Pre-registered prediction (before full classification)

Written first: `.copilot-session/backlog-score-audit-prereg-20260729.md`

| Cat | Predicted N | Actual N (scored goals) | Hit? |
|-----|------------:|------------------------:|:----:|
| (a) defect metric / similarity as completion | 3 | **4** | miss +1 |
| (b) frozen — checks cannot run now | 8 | **11** | miss +3 |
| (c) 480p/other-RBF inherited; ≠ live `41adb98c` | 10 | **14** | miss +4 |
| (d) self-agree / instrument agrees with itself | 5 | **7** | miss +2 |
| clean | 12 | **13** | miss +1 |
| Corrected programme % | **58–65%** | **see dual denominator below** | partial |

**Prediction held on direction (drop), missed on magnitude of contamination and on needing two denominators.**

---

## Method

1. Inventory every backlog goal that carries DONE / PARTIAL / GREEN / numeric % / gate checkbox weight.
2. Classify into (a)(b)(c)(d)/clean — a goal may sit in more than one bucket; primary tag is the strongest defect.
3. Rebuild programme % with **explicit weights** and **two denominators** (the 78.4 figure mixed them).
4. Evidence-only: device quotes, file cites, no invented PASS.

**Cannot-fail-in-the-direction-that-matters** is the hunt signature (G-IDLE2c equality, UNSCORED rc=0, encoder↔decoder-only mailbox, vacuous geometry invariants).

---

## Live device reconfirm (read-only)

```
CORE=Plex
41adb98c7a630b541091c22ce291be68  /media/fat/_Utility/Plex.rbf
pid=31928
06c5735a2f85114688f0ff2ac36e4fd4  /media/fat/misterplex/bin/misterplexd
PRESENT=fb0
STREAM=0
DECODE=320x240
OSD_CONTROL=0
… decode=320x240 weak=320x240@1000k present=fb0 …
device true rc=0
```

Note: Logo DDR bit-exact proof (`ed806ec5…`) was under an earlier `PRESENT=fpga` boot. **It does not automatically grade the current `PRESENT=fb0` present path.** Counted as clean for *idle paint into DDR when fpga present was active*; present-path for fb0 is a separate surface.

---

## Gate checklist — honest reread

Source: `docs/PHASE_BACKLOG.md` § Gate: all green before “complete”.

| Gate row | Backlog mark | Honest live grade | Primary cat | Why |
|----------|--------------|-------------------|-------------|-----|
| Product present / tear-free | [x] DONE `1441d409` | **PASS for v0.3.0 surface** (G-VID1 fixed pre-tag; eyes-on; pin `41adb98c`) | clean / mild (c) | Cite is wrong RBF id but property holds on shipped artifact |
| Product A/V cast | [x] DONE fpga/STREAM=0 | **PARTIAL on live box** | (c) | Live is `PRESENT=fb0` not milestone `fpga`; playback not re-proven this boot |
| `make unit` | [x] GREEN C-unit28 | **HOST-only; concurrent-fit fragile** | clean* | Grades tree, not live RBF. *See unit gate note below |
| HW residual hard | [~] PENDING `94bbfe43` | **Does not grade live core** | (b)(c) | User core is `41adb98c`; residual track is other RBFs; cannot thrash user box |
| FBAR visual | [x] DONE on `ec21e133`… | **UNSCOREABLE now** | (b)(c) | Hour-21: no capture device; FBAR=NO_CAPTURE. Checkbox still [x] |
| Full-width VGA | [ ] FAIL 0.605 | **N/A on 320 product** / FAIL on 480 line | (a)(c) | span=0.605 is a **defect width ratio**, not completion; irrelevant to 320 user box |
| DDR F1 ≥30 fps | [~] historical | **Unsubstantiated for current HEAD silicon; live v0.3.0 unmeasured this boot** | (b)(c) | B-ddr7 was `ec21e133` |
| `make package` | [x] embeds `94bbfe43` | **Wrong artifact for user ship** | (c) | User ship pin is `release_artifacts/v0.3.0` / `41adb98c` |
| misterplexd soak | [x] D-soak* | **Historical other core** | (c) | Not re-run on `41adb98c`/`06c5735a` |
| Safe deploy | [x] H-deploy-rcsum6 | **Process OK; last deploy was residual RBF not user pin** | mild (c) | Deploy script improvements still valid |

Naive gate fill **7/10 = 70%** or with halves **8/10 = 80%** — this is a plausible origin of **~78%** if residual/DDR half-credits were included. **After honest reread of the same 10 rows against the live box: 3.5–4.5 / 10 ≈ 35–45%** if the denominator is “gate grades live user artifact”; **~55%** if product present + unit + package-pin + deploy-process kept and cast/soak half-credited.

---

## Category (a) — defect / similarity metrics worn as progress

| ID | Number | What it actually is | Was read as | Honest |
|----|--------|---------------------|-------------|--------|
| **G-IDLE2c** | **93.1%** | Middle-band pixel identity to screensaver = **torn LastFrame fingerprint** | screensaver/idle completion | **0% mode quality**; goal open |
| **G-IDLE2** | was 100% → 65% → **~55%** | One-mode proof inflated multi-mode | multi-mode DONE | **≤40% device / ~55% overall** on `41adb98c` |
| **P3-WIDE span** | **0.605 (60.5%)** | Pillar content width / DE width = **FAIL geometry** | sometimes “how wide we got” progress | **FAIL open** (480 line only) |
| **FBAR 7.0/82.9/94.4** | triple soft scores | Soft visual instrument on **non-user** RBFs | “FBAR DONE” product green | Soft ≠ product; **now NO_CAPTURE** |

*No additional “93%-class” completion impostors found beyond idle.* WIDE/FBAR are labeled FAIL/soft in prose but still inflate gate checkboxes when [x]’d.

---

## Category (b) — scores frozen (checks cannot run in this environment)

| Goal / claim | Why frozen now |
|--------------|----------------|
| FBAR / HW visual golden (current product) | No `/dev/video*`, no uvcvideo |
| G-OSD2 OSD PNG eyes | Capture path |
| G-IDLE / G-IDLE2a/2b glass | Capture path + cannot flip OSD on user box |
| G-AV2/3/6/7/11 absolute HDMI ms | Capture + grabber skew instrument |
| G-OSD5 arrow navigation | uinput arrows don’t register |
| HW residual hard on residual RBFs | Would require reload off user core |
| WIDE Fix-3 silicon | Needs fit + deploy + capture |
| P5-CRT physical matrix | No CRT session |
| P5-ETH | No eth lab path |
| Natural EOF soak reconfirm | Must not disturb user playback session |
| Live `PRESENT=fb0` pixel path vs DDR Logo | Would need present-path probe without reload; fb0 ≠ FPGA DDR banks |

Any backlog **[x]** whose only evidence is one of the above is **frozen at a historical value**, not currently re-derivable.

---

## Category (c) — inherited from 480p / other RBF; does not grade live `41adb98c`

| Claim | Evidence artifact | Live grade |
|-------|-------------------|------------|
| G-IDLE2a Black PROVEN | 480p bank dumps | historical only |
| G-IDLE2b Screensaver PROVEN | 480p time-separated captures | historical only |
| G-IDLE2c LastFrame torn | 480p Y planes | defect on 480 line; v0.3.0 LastFrame is weaker/no-op latch |
| FBAR DONE | `ec21e133`, `8832824e`, … | not `41adb98c` |
| Package DONE embeds `94bbfe43` | residual campaign | not user pin |
| Product present cite `1441d409` | pre-v0.3 tear milestone | property yes, id no |
| P3-3l* FPGA residual / native-I420 greens | host/RTL / other RBFs | not on user ARM-F1 core |
| B-ddr7 DDR F1 60 fps | `ec21e133` | not live |
| Soak D-soak* | other builds | not live pair |
| G-AV* eyes-on / blip | `PRESENT=fpga` era | live `PRESENT=fb0` |
| HW visual GREEN `57674f2e` | rollback instrument (already labeled) | must not grade product decode |
| WIDE pillar work | 624/480 geometry | user is 320×240 |
| Hour-21 residual sticky 0x14 on `00eebd5e` | later FPGA line | not user core |

---

## Category (d) — self-agree / cannot fail the property that matters

| Instance | Mechanism | Status |
|----------|-----------|--------|
| G-IDLE2c `lastframe_poststop == lastframe_paused` | Both sides share tear → equality never exposes defect | open, documented |
| Mailbox encoder↔decoder-only probes | Agreement without external oracle | historical confirmed class |
| Visual card UNSCORED + rc=0 | Exit code green while unscored | historical confirmed class |
| Geometry audit vacuous invariants | Predicted 3 vacuous, found 4 | fixed in tree; class remains a risk |
| `test_unit_rollcall` constant-as-measurement | Printed 30 while 33 real | fixed (`b19ceaa` era) |
| browse/HTTP tests ignoring daemon abort | HTTP 200 while `terminate` | fixed with `assert_clean_exit` |
| HOST_GOLDEN_OK / FBAR soft as product | Host or soft instrument labeled near PASS | backlog prose warns; gate [x] still over-credits FBAR |

---

## Clean (still sound, with scope)

| Item | Scope |
|------|-------|
| v0.3.0 pin `41adb98c` + daemon `06c5735a` live | user product |
| G-VID1 fix pre-tag + eyes-on VGA | 320 present geometry |
| Conf triple corrected `320/fb0/STREAM=0` | live |
| Idle Logo host renderer + unit mutants (black/LastFrame red) | host |
| Idle Logo DDR bit-exact both banks (fpga-present boot) | DDR paint, historical boot |
| G-MAIN* SPI-safe daemon (no Main thrash) | code on live daemon |
| G-STAB1 SIGPIPE fix | code on live daemon |
| G-OSD-UNIT bit layout unit | host |
| G-SEEK unit `universalOffsetSeconds` | host |
| Native-I420 **intra** host scoreboard greens | **FPGA decode programme only** |
| Inter MC measured RED | correctly RED |
| BUILD_OK≠residual PASS discipline in prose | process |
| Release artifact + README hash pin | ship |

---

## Corrected programme percentages

### Why 78.4% was inflated

Most likely construction (reconstructed, not found as a single cell):

- Gate checklist with half-credit on residual/DDR ≈ **75–80%**
- Plus Phase-3 table rows counting BUILD_OK/FBAR/host green as partial product
- Plus idle multi-mode still carrying **65–93** flavour before R3 retraction

That mixes **user-stable ARM product** with **FPGA decode residual/WIDE campaign** and freezes capture-backed [x] marks after the grabber disappeared.

### Denominator 1 — Live user product (what the user is running today)

Equal-ish weights on the surface the user asked for (320×240 ARM + overlay + controls + stable today):

| Surface | W | Honest | Rationale |
|---------|--:|-------:|-----------|
| Tear-free 320 present | 12 | 11 | G-VID1 closed; pin live; cite RBF id drift −1 |
| ARM cast playback path | 12 | 8 | Code+conf OK; **not re-proven on fb0 this boot**; no eyes |
| Controls / OSD bits | 10 | 7 | Unit+CONF_STR; live `OSD_CONTROL=0`; glass OSD not re-shot |
| Idle multi-mode | 10 | **5.5** | prior honest rescore |
| A/V lipsync product | 10 | 6 | G-AV9 historical eyes-on; fb0 path + no grabber |
| Seek/resume | 6 | 4 | lab blip DONE; not this boot |
| Main/SPI stability | 10 | 9 | shipped in live daemon |
| Conf geometry triple | 8 | 8 | verified live |
| Release pin / known-good RBF | 8 | 8 | `41adb98c` |
| Capture-backed visual gates | 6 | **0** | no hardware — unscoreable, not green |
| Natural EOF | 4 | 0 | G-EOF1 open |
| LastFrame idle quality | 4 | 0 | broken/unproven |

**Sum = 66.5 / 100 → round to 67%.**

**Defensible band: 63–70%.** Prefer reporting **~67% live user product**.

Deltas vs treating the same surface as “~90% shipped stable”:

| Move | Δ pts | Why |
|------|------:|-----|
| Idle 90→55 | −3.5 | R3 already |
| Cast full→partial | −4 | fb0 / no re-prove |
| Capture gates 6→0 | −6 | no grabber; were smuggled via FBAR [x] |
| A/V full→partial | −4 | path/instrument |
| EOF+LastFrame open | −8 | were under-weighted as “idle DONE” |
| OSD glass partial | −3 | |

### Denominator 2 — Full Phase-3 + lab programme (FPGA decode, residual, WIDE, package campaign)

| Bucket | W | Honest fill | Notes |
|--------|--:|------------:|-------|
| Product present/cast (ARM) | 15 | 12 | as above |
| Host unit / goldens | 10 | 9 | tree green when exclusive; ≠ silicon |
| FPGA residual hard product | 15 | 3 | one later sticky on `00eebd5e` historical; live user N/A; campaign mostly HARD_FAIL |
| WIDE full-width | 10 | 1 | FAIL 0.605 open |
| FBAR / HDMI visual product | 10 | 0 | NO_CAPTURE now; old soft on other RBFs |
| Native intra I420 | 8 | 7 | host-evidence green |
| Inter / P-slice product | 10 | 2 | measured RED / partial MC |
| Idle/OSD UX | 8 | 4.5 | ~55% idle + OSD unit |
| Package/soak/deploy process | 7 | 4 | process OK; wrong RBF embedded in campaign packages |
| CRT/eth/deferrals | 7 | 1 | open/blocked |

**Sum = 43.5 / 100 → round to 44%.**

**Defensible band: 40–48%.** Prefer reporting **~44% full programme**.

### Headline replacement for the user

Do **not** keep a single blended **78.4%**.

| Audience | Report |
|----------|--------|
| **User (stable box today)** | **~67%** of the v0.3.0 product surface is evidence-backed on the live triple; remaining gap is multi-mode idle, capture-backed glass, EOF, and fb0 cast re-prove |
| **Internal FPGA programme** | **~44%**; residual/WIDE/capture dominate the hole |
| **What 78.4 was** | Gate-shaped blend that counted frozen FBAR, campaign packages, and half-open residual/DDR as progress on a box that is not running those RBFs |

**Drop from 78.4 → 67 (user) or 44 (full) is the honest measurement.**

---

## Goal-level moves (summary table)

| Goal | Old posture | New posture | Δ |
|------|-------------|-------------|---|
| Screensaver/idle “93%” | completion | **defect fingerprint** | already R3; keep **~55%** |
| G-IDLE2 multi-mode | 65–100% DONE flavour | **≤40% device** on live | −25–60 pts on that goal |
| Gate FBAR [x] | DONE product-adjacent | **UNSCOREABLE** | remove from green numerator |
| Gate package [x] `94bbfe43` | DONE ship | **campaign package ≠ user pin** | split ship pin vs campaign |
| Gate residual [~] | half programme | **0 on user denominator** | −half-credit |
| Gate DDR [~] | half | **0 live / unsubstantiated HEAD** | −half-credit |
| P3-WIDE 0.605 | open FAIL (ok) | keep FAIL; never “60% done” | 0 |
| P3-3l2 native intra GREEN | programme green | **clean for FPGA denom only** | don’t lift user % |
| Inter RED | open | keep | 0 |
| Product present DONE | 100% | **~90%** (right property, wrong cited RBF) | −small |
| A/V cast DONE | 100% | **~65%** on live fb0 | −35 pts on goal |
| G-EOF1 | open | open | 0 |
| make unit GREEN | 100% host | host only; see gate note | 0 user silicon |

---

## `make unit` gate note

Parent baseline request: TRUE rc + `grep -c ': OK'` expect 0 / 70.

Hour-23 backlog correction: **`grep -c ': OK'` is build-state dependent** (golden extract lines 5 vs 6). Prefer unique test names + assertion `^OK` counts.

### Runs this audit (all under concurrent local Quartus)

| Log | TRUE_RC | `: OK` count | Notes |
|-----|--------:|-------------:|-------|
| `make-unit-score-audit.log` | 2 | 64 | Verilator link race without flock |
| `make-unit-score-audit2.log` | 2 | 69 | Exclusive + `ALLOW_LOW_MEMORY=1` → **polluted** `test_resource_preflight` (want rc=3 got 0). Clean re-run of that script alone: **rc=0** |
| `make-unit-score-audit3.log` | 2 | 64 | `make --eval=preflight` **leaked via MAKEFLAGS** into Verilator recursive makes → `0 modules` phantom builds |
| **`make-unit-score-audit4.log`** | **2** | **68** | Exclusive + `skip-preflight.mk` (no MAKEFLAGS eval, no ALLOW override). **Terminal fail:** `test_no_private_data` found lab IP `192.168.1.41` in `tests/unit/test_core_conf_geometry_gate.sh:24` — concurrent-tree RED, not from this audit. unique `: OK` names=46, `^OK`=44 |

**Gate not green this hour.** Do not claim baseline 70/rc=0. Do not treat Verilator `0 modules` under MAKEFLAGS pollution as RTL RED. Do not set `MISTERPLEX_ALLOW_LOW_MEMORY_TESTS=1` for the full suite — it makes the preflight unit fixture lie.

---

## Confidence

| Claim | Confidence |
|-------|------------|
| 78.4 inflated by (b)+(c)+idle (a) | **high** |
| User product ~67% | **medium-high** (weights judgmental; direction robust) |
| Full programme ~44% | **medium** (Phase-3 weighting judgmental; residual/WIDE/capture hole is not) |
| No second 93%-class impostor | **medium-high** |
| fb0 cast quality | **low without play+eyes** — deliberately partial |

---

## What this audit could not determine without hardware / deploy

- Whether `PRESENT=fb0` playback is tear-free and lipsync-clean on the live triple
- Glass appearance of OSD / idle modes on `41adb98c`
- Any FBAR or HDMI golden on current silicon
- Residual sticky behaviour (requires non-user RBF)
- Whether concurrent unit RED is pure race or latent tree break (needs exclusive green reconfirm)

---

## Recommended parent actions (no deploy implied)

1. **Tell the user two numbers**, not 78.4: **~67% stable v0.3 surface / ~44% full FPGA programme**.
2. Annotate gate FBAR [x] → **UNSCOREABLE/NO_CAPTURE** (Hour-21 already proved absence).
3. Split **ship pin `41adb98c`** from **campaign package `94bbfe43`** in P5-PKG row.
4. Keep idle at **~55%**; never restore 93%.
5. Schedule a **device window** later for fb0 cast + optional capture reattach — not while user is on the box.
