# RESULT — supersede e6a3fb2f: resolution-preserving bitrate

**Status:** e6a3fb2f **FALSIFIED on hardware (parent)** — DO NOT SHIP `099635f7`.  
**Superseding commit:** `836ad376` + follow-ups  
**Pin path (stable):** `artifacts/daemon-pins/misterplexd.64112648`  
**Binary md5:** `641126485abba45d215f5f0a97f5d49d` (= `836ad376` artifact; re-pin after new commits)  
**Branch:** `w-cpu-suspend-silicon-pin`

### Honest status of 2000

The 2000 floor is now justified by a **measurement**, stronger than commit 216703b ever had:

| request | delivered | N |
|---|---|---|
| 397 | 312×240 | 40 |
| 2000 | 624×480 | 39 |
| 397 (A') | 312×240 | 40 |

Reversible A/B/A'. **PROVISIONAL** as a *minimum* — knee sweep not done; 2000 is safe full-res, not proven minimal. `kPlexResPreserveRefKbps` comment says PROVISIONAL.

## Parent miss published (mine)

| Prediction (e6a3fb2f) | Parent measured | Verdict |
|---|---|---|
| Cap at source 397 is safe anti-inflate | **312x240 delivered** (half of 624x480) | **MISS — ship blocked** |
| `videoDecision` stays transcode | **No TranscodeSession / no encoder** at 397 | **MISS** |
| 2000 is unjustified inflation | **2000 is load-bearing for full-res MDE** | **RETRACTED** with parent |

## 1. Quoted source (as of this supersede)

### validateWeakLadder (decoder contracts; bitrate floors not hard-fail)

```cpp
// plex_resolve.cpp — codec/profile/level/geometry; positive bitrate only
if (weak.h264Profile != "baseline")
    return fail("H.264 profile must be baseline for the current decoder");
if (weak.h264Level > 30)
    return fail("H.264 level must not exceed 3.0 for the current decoder");
// … geometry max …
// Bitrate floors are NOT decoder contracts. … Positive-only below.
if (weak.videoQuality <= 0 || weak.maxVideoBitrateKbps <= 0)
    return fail("videoQuality and maxVideoBitrate must be positive");
```

### Policy (new)

```text
floor(W,H) = ceil(W * H * kPlexResPreserveRefKbps / (refW * refH))
ref = 624×480, refKbps = kPlexResPreserveRefKbps  // PROVISIONAL 2000

select (non-operator):
  base = tier_default
  if LINK_CAP>0: base = min(base, LINK_CAP)
  if floor>base: base = floor   // RAISE — never source-cap
operator WEAK_BITRATE: absolute (lab knee may go below floor)
source_video_kbps: logged only — NOT a cap
```

Constants: `osd_menu.hpp` `kPlexResPreserveRefWidth/Height/Kbps`.

## 2. Redesign rationale

PMS MDE uses `maxVideoBitrate` as a **quality ladder signal**, not a pure upper bound on the source. Requesting ~source rate on a low-bitrate 624×480 asset made MDE pick a **lower resolution rung** (312×240). Selection must be **resolution-preserving** relative to the **decode target geometry**, not source bitrate.

## 3. What I need from the parent knee sweep

Sweep points: **397 / 600 / 800 / 1200 / 2000** (and any extras).

Per arm, please capture:

| Field | Why |
|---|---|
| `maxVideoBitrate` requested | independent variable |
| `measured=` WxH from daemon (ffmpeg banner) | delivered geometry — pass/fail |
| PMS `-maxrate` / presence of TranscodeSession | encoder path |
| N samples (≥30 if possible) | stability |

**Definition of knee K:** lowest request where **delivered W×H ≥ 624×480** (or ≥ decode target) on **≥95%** of samples, with immediate neighbors reproduced.

Then set:
```text
kPlexResPreserveRefKbps = K   // at ref 624×480
```
Host test already uses `resolutionPreservingMinBitrateKbps(624,480)` — lowering ref kbps auto-scales floors for other geometries.

**Also useful (optional):** same sweep at 320×240 target to check scale law `ceil(W*H*K/(624*480))`.

## 4. Red-before-green (host only — no device claims)

```text
RED  (e6a3fb2f source-cap path re-injected for proof):
  FAIL bad.kbps >= floor
  FAIL bad.kbps != 397
  FAIL vsLink.kbps >= floor
  true rc=1

GREEN (resolution-preserving):
  PASS resolution-preserving bitrate floor @ 624x480 floor=2000
  test_resolve: OK
  true rc=0
```

Commands:
```bash
make build/test_resolve   # or g++ … -o build/test_resolve …
./build/test_resolve; echo "true rc=$?"
```

## 5. make unit / supervisor gate RCA

### Classification: **(ii) pre-existing test design bug + (iii) race**, not a bitrate-commit regression

| Evidence | Value |
|---|---|
| Test file content tip vs `aa80df0f^` (13d3c191) | **identical** (`git diff` empty) |
| Standalone script @ parent | **`true rc=1`** `FAIL expected T got S` |
| Standalone script @ tip (before fix) | **`true rc=1`** same |
| Wired into `make unit` | **`aa80df0f`** (SUSPEND commit) — was not in Makefile at parent |
| Bitrate commits touch this test? | **No** |

**Mechanism (quoted):** supervise used `wait "$DAEMON_PID"` but daemon is the **parent’s** child → `wait: pid is not a child` → resume runs **immediately**. Race: STOP Main → resume finds `T` → CONT → assertion reads **`S`**. Assertion itself is correct; waiter arming/order was wrong.

**Fix (not weakened):** STOP Main **first** and assert `T`; poll `kill -0` until daemon gone (no foreign `wait`); then resume. Assertion still requires `T` before kill -9 and non-`T` + `RESUME_MAIN` after.

| After fix | |
|---|---|
| 5/5 runs | **`true rc=0`** each |

## 5b. Knee table host test

`tests/unit/test_resolve.cpp` — measured rows (397→312x240, 2000→624x480); placeholders 600/800/1200 as `measured=false` (NO-DATA). Calibrate: one-line `kPlexResPreserveRefKbps=K` + fill table rows.

## 6. Could NOT verify (host agent)

- Any on-device delivered geometry after this binary  
- True knee K (parent sweep in progress)  
- Whether provisional refKbps=2000 is higher than necessary  
- PMS MDE internal ladder thresholds  

## 7. PRE_REG for parent when deploying `64112648…`

| Check | Expect |
|---|---|
| rk36, no WEAK_BITRATE | `requested_max≥2000` (provisional floor), `measured=624x480` |
| log | no `clamped_to_source`; may see `res_preserve_floor` |
| WEAK_BITRATE=397 | still allowed (operator); expect half-res — lab only |

**Do not deploy 099635f7 / e6a3fb2f.**
