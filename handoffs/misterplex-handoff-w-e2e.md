# MiSTerPlex handoff — W-E2E

## 1. Identity

- **Worker ID:** W-E2E
- **Branch:** `w-e2e-playwright`
- **Worktree:** `/home/flynnsbit/Projects/MisterPlex/.worktrees/w-e2e`
- **Latest commit:** `792bb6a` (feat(capture): OCR-based RBF identity label gate)
- **Parent branch base:** `parent/integ-hour27`

---

## 2. Assignment

Two parallel missions:

**A. Cast/timeline E2E harness** — headless test proving the MiSTer daemon advances playback time as observed by the Plex client.  
**B. HDMI capture instrument** — arm the MS2109 USB capture stick (`/dev/video0`), classify three signal states (no-signal / valid-black / valid-with-content), remove all human-eye exits-77 that can now be scored via capture.

---

## 3. What Is DONE and PROVEN

### A. Cast/Timeline HTTP Gate — GREEN (committed, double-pushed)

**File:** `tests/hw/test_cast_timeline_poll.sh`  
**Make target:** `make cast-timeline-gate`

**What it literally measures:** Issues `/player/playback/playMedia` to daemon, then polls `http://192.168.1.183:3005/player/timeline/poll?commandID=N&wait=1`, asserts `state=playing` AND `time=` strictly increasing across consecutive polls.

**Green evidence (W-CAST fix deployed, binary md5 `f8c3d2799e365ad51f288dfb40c935fa`):**
- 64 polls, 63 reporting `state=playing`
- `time` advanced 0 → 29,074 ms

**Red evidence:** `tests/unit/test_cast_timeline_poll_red.sh` — Python mock server returning `state="paused" time="0"` → gate exits 1. Commit `5defdb2`.

**What it does NOT cover:** Whether Plex Web *browser* can discover the cast target. It cannot — GDK cast discovery requires myPlex.tv cloud auth. I confirmed this by intercepting 133 browser requests (all to PMS, zero to daemon port 3005). Playwright browser harness exits 77 by design (`tests/hw/e2e/test_cast_timeline_playwright.js`).

### B. HDMI Capture Instrument — BUILT, 2-of-3 states proven on hardware

**File:** `scripts/capture_preflight.py`  
**Make target:** `make capture-rig-preflight`

**Device:** MS2109 (534d:2109) on `/dev/video0`. `/dev/video1` is a decoy UVC metadata node — opens fine, advertises zero formats. Logic must reject on format evidence, not on node index.

**Signal classification (CRITICAL ORDER — do not change):**
1. `luma < 8.0` → `BLACK_SIGNAL`
2. `spatial_std < 3.0` → `NO_SIGNAL`
3. `total >= 2 and unique == 1` → `STALE_CAPTURE`
4. else → `CONTENT_PRESENT`

Order matters: RBF `00eebd5e` produces byte-identical MJPEG for black content. Checking STALE before luma incorrectly fires STALE_CAPTURE. Two stable MJPEG encode states for black observed: luma=0.734 (`33ea8bf5`) and luma=7.0 (`2358782e`).

**Live hardware evidence:**
- BLACK_SIGNAL: confirmed at luma=0.73 and luma=7.0 (RBF `00eebd5e`, daemon running livelock)
- STALE: real device frames verified (3 byte-identical grabs from `/dev/video0`)
- NO_SIGNAL: `/dev/video1` decoy (zero formats, classified NO_SIGNAL) — NOTE: this is not a true no-signal proof. True no-signal requires physical HDMI disconnect. Still outstanding.
- CONTENT_PRESENT: confirmed at luma=36.43 (new RBF `fb4bad84`, daemon not running)

**Unit tests:** `tests/unit/test_capture_preflight.py` — 9/9 synthetic + edge-case tests. All green.

### C. Left-Edge Artifact Gate — BUILT, red/green proven

**File:** `scripts/grade_left_edge.py`, wrapper `tests/hw/test_left_edge_clip.sh`  
**Make target:** `make left-edge-clip-gate`

**Artifact measured:** 24-px black prefix at left edge (cols 0-23 = luma 0, col 24 = luma 45 matching DDR grey=44). Display col 24 → source col ~11.7 at 2.051× scale. Matches `PRESENT_X=11` in `VISUAL_COMPARE_BOX`.

**Confirmed:** Left-edge clip at col 24 **persists in new RBF `fb4bad84`** (July 28, 2026 observation).

**Red proof:** `grade_left_edge.py` on `build/logo-capture/frame_0010.jpg` → `black_prefix=24 > threshold 4` → exit 1.  
**Green proof:** synthetic clean frame → `first_bright_col=0` → exit 0.

### D. OCR-Based RBF Label Gate — BUILT, not yet validated on real rendering

**File:** `scripts/grade_rbf_label.py`  
**Make target:** `make rbf-label-check`

Awaiting W-OSD to implement the label in misterplexd and supply rendering coordinates. OCR tested: NotoSansMono-Black ≥28pt + tesseract `--psm 7` → exact match on synthetic. Red/green evidence in commit `792bb6a`.

### E. Capture Lock — IMPLEMENTED

**Location:** `tests/hw/hw_gate_common.sh` `capture_lock_acquire()` / `capture_lock_release()`  
**Lock file:** `build/video0.lock` (flock on fd 9)  
**Convention:** All scripts opening `/dev/video0` must `source hw_gate_common.sh` and call `capture_lock_acquire` before V4L2 open. EXIT trap auto-releases.

**CRITICAL KNOWN ISSUE WITH W-OSD:** `scripts/hdmi_capture_classify.py` (in worktree `w-osd-neighbor`) uses `build/hdmi_capture.lock` — a **different file**. Concurrent access IS NOT excluded. I reported this to W-OSD with the one-line fix (`DEFAULT_LOCK = ROOT / "build" / "video0.lock"`). Status: W-OSD acknowledged but fix not confirmed merged. **Successor must verify this before running any concurrent capture gates.**

### F. `detect` Subcommand and Auto-Detection

`scripts/capture_preflight.py detect` → prints `/dev/video0`, exit 0; exit 77 if no capture node. Used by `test_f3_visual_golden.sh`, `run_menu_matrix.sh`, `check_edges.py`, `hw_visual_compare.py` to replace stale hardcoded `/dev/video4`.

---

## 4. What Is IN PROGRESS

**The immediate next task: before/after capture for W-ARM commit `3798793`.**

Parent directive: "W-ARM has a candidate fix `3798793` (PLXD display-bank fallback) that needs automated HDMI capture through W-E2E to confirm. That is a concrete, high-value first target."

**However W-ARM's own handoff (`handoffs/misterplex-handoff-w-arm.md`) supersedes this:**
> "The idle-logo left-edge artifact has been determined RTL-side, not ARM-side, by measurement: both live DDR banks match the product-rendered idle payload byte-for-byte, 449280/449280 bytes each. `3798793` remains a correct defensive fix for playback, not the cause or cure of the idle artifact."

So `3798793` before/after capture will likely show identical frames (both correct for the IDLE_SCREEN=logo case) but is still worth running to verify and close the loop.

**Exact next steps:**
1. Confirm `misterplexd` is running (last known state: NOT running as of 11:23 Jul 28)
2. `make capture-rig-preflight` → confirm signal state before any deploy
3. After parent integrates `3798793` and deploys a new RBF with working decode: run `make capture-rig-preflight` → this is the first automated evidence of a decoded picture
4. Run `make left-edge-clip-gate` on new RBF — left-edge clip at col 24 likely persists (display path RTL, not ARM)

**W-OSD RBF label gate** — waiting for W-OSD to: (a) fix `build/hdmi_capture.lock` → `build/video0.lock`, (b) implement the label in misterplexd, (c) tell me the rendering coords for `--region`.

---

## 5. What I TRIED THAT DID NOT WORK (high-value section)

### Playwright Browser Cast Discovery — fundamentally broken, not retry-able

Exhausted all Plex Web cast button selectors. Root cause: GDK (Google Cast SDK) device registry lookup uses `myPlex.tv` cloud token, not local PMS token. Browser authenticates locally fine (133 requests to PMS), but cast target discovery requires a cloud round-trip. Local PMS `X-Plex-Token` cannot substitute. There is no way to make Plex Web contact the daemon using only local credentials. The HTTP gate (`test_cast_timeline_poll.sh`) is the correct instrument for this.

### STALE-before-luma ordering bug (FIXED, but the mistake is instructive)

First classification ordering: check STALE first, then luma. RBF `00eebd5e` produces byte-identical MJPEG frames for stable black content. STALE check fired (unique==1) before luma check, so BLACK_SIGNAL was incorrectly classified as STALE_CAPTURE. Fix: luma < 8.0 first. The synthetic `stale` test case was also wrong (used solid-colour frame → spatial_std=0 → would hit NO_SIGNAL branch). Both fixed in commit `e7f5c0a`.

### Single-frame STALE false positive (FIXED)

`classify_signal([one_frame])` with a single frame always returned STALE_CAPTURE because `unique==1` trivially for any 1-element list. Fix: `if total >= 2` guard. Commit `b0b2db9`.

### `fuser` PID parsing (FIXED)

`fuser /dev/video0` returns `"180999m"` (trailing `m` = memory-mapped). `.split()` gives `["180999m"]`, `int("180999m")` raises ValueError. Fix: `re.findall(r'\b(\d+)', raw)`. OBS (PID 180999) was holding the device and had to be killed before capture could proceed.

### OCR normalization destroying RBF prefix (FIXED in `grade_rbf_label.py`)

First version of `_extract_md5_prefix` applied `_OCR_NORMALIZE` (which included `B→8`) to the entire OCR string. This turned `RBF` into `R8F`, breaking the regex. Fix: use `R[B8]F` prefix regex; apply normalization only to the captured hex group, not the full string. Remove `B→8` from normalization table entirely (`b` is a valid hex digit).

### `/dev/video1` decoy trap (AVOIDED by design)

`/dev/video1` is a UVC metadata/audio node that `open()`s successfully and returns no frames. `v4l2-ctl --list-formats-ext` shows zero formats. Node rejection must be on format evidence (`is_capture=false when formats==[]`), not on node index or open success. This is implemented in `find_capture_nodes()` / `probe_node_formats()`.

### NO_SIGNAL from decoy ≠ true no-signal proof

Using `/dev/video1` as the "no-signal" red-check gives `NO_SIGNAL` classification (zero spatial std because zero-frame capture). This verifies the code path but does NOT prove the rig handles the physical case of no HDMI input. True no-signal requires physically disconnecting the HDMI cable from the capture stick. Still outstanding.

---

## 6. Gates I Own — How to Run, Current State, How to Make Fail

### `make cast-timeline-gate`
- **File:** `tests/hw/test_cast_timeline_poll.sh`
- **Current state:** GREEN (W-CAST fix deployed)
- **How to make fail:** Stop misterplexd on MiSTer → gate exits 1 (daemon unreachable) or 77 (connection refused depending on timing). Or revert W-CAST's fix → `state=paused` → exits 1. Mock: `CAST_FAIL_INJECT=1 bash tests/unit/test_cast_timeline_poll_red.sh` → exit 1.
- **Dependencies:** MiSTer at 192.168.1.183, PMS at 192.168.1.41:32400, credentials in `$HOME/.config/misterplex/misterplex.conf`.

### `make capture-rig-preflight`
- **File:** `tests/hw/test_capture_preflight.sh` → `scripts/capture_preflight.py`
- **Current state:** BLACK_SIGNAL exit 1 with `00eebd5e`; CONTENT_PRESENT exit 0 with `fb4bad84` + no daemon (intermittent, luma=36.43 avg over 5 frames)
- **How to make fail:** Point at `/dev/video1` (`HDMI_DEV=/dev/video1`) → NO_SIGNAL exit 1. Disconnect HDMI cable → NO_SIGNAL exit 1. Put FPGA in black-screen mode → BLACK_SIGNAL exit 1.
- **Unit tests:** `python3 tests/unit/test_capture_preflight.py` → 9/9 green (no hardware needed).

### `make left-edge-clip-gate`
- **File:** `tests/hw/test_left_edge_clip.sh` → `scripts/grade_left_edge.py`
- **Current state:** RED (black_prefix=24 on resident RBF)
- **How to make fail:** Pass any frame where col 0-23 are black → `black_prefix > 4` → exit 1. The artifact frame `build/logo-capture/frame_0010.jpg` reliably fails. Green requires a clean frame (col 0 bright).
- **How to make green:** Deploy a fixed RTL that starts scan-out at source col 0.

### `make rbf-label-check`
- **File:** `scripts/grade_rbf_label.py`
- **Current state:** UNSCORED (W-OSD hasn't implemented the label yet)
- **How to make fail:** `--expected-md5 00000000` against any real frame → exit 1. Blank/no-label frame → exit 1.
- **Green requires:** W-OSD implementing `misterplexd` RBF label rendering with font ≥28pt equivalent in captured frame.

### `make cast-timeline-playwright`
- **File:** `tests/hw/e2e/test_cast_timeline_playwright.js`
- **Current state:** EXIT 77 by design (myPlex.tv auth barrier, permanent)
- **Do not attempt to fix:** The barrier is architectural. Use the HTTP gate instead.

---

## 7. Peer-to-Peer Interface Contracts

### W-E2E → W-OSD: Capture lock protocol
- **Lock file:** `build/video0.lock` (NOT `build/hdmi_capture.lock`)  
- **Acquire:** `capture_lock_acquire` in `hw_gate_common.sh` (source it first)  
- **W-OSD has `hdmi_capture_classify.py` using the wrong lock file** — `build/hdmi_capture.lock`. This MUST be fixed before concurrent operation. One-line fix: `DEFAULT_LOCK = ROOT / "build" / "video0.lock"`.
- **W-OSD also owns `test_idle_present_split.sh`** which calls `hdmi_capture_classify.py`. It needs the lock before the capture call.

### W-E2E → W-OSD: RBF label gate interface
- **Script:** `scripts/grade_rbf_label.py --capture --expected-md5 HEX8`
- **What W-OSD must supply:** `--region x,y,w,h` in 1280×720 HDMI coords (the screen position of the label)
- **Font requirement:** ≥28pt equivalent in captured frame (at fb0→HDMI scaling). NotoSansMono-Black tested; AdwaitaMono unreliable.
- **OCR strategy:** tesseract `--psm 7`, hex whitelist, R[B8]F prefix match, normalization applied to hex group only.

### W-E2E → W-ARM: Capture coordination
- **W-ARM does NOT open `/dev/video0`** (their handoff confirms this)
- **W-ARM requests:** Before/after capture across deploy of `3798793`
- **W-ARM finding:** `3798793` is defensive-correct for playback but NOT the cause/cure of idle artifact (both DDR banks hold identical idle content, overwrite is idempotent)
- **Still needed:** Capture after W-FIT deploys first decode-capable RBF (h264_decode_core wired into stream_path.sv)

### W-E2E → W-CAST: Timeline poll contract
- **Endpoint:** `http://192.168.1.183:3005/player/timeline/poll?commandID=N&wait=1`
- **Assert:** `state=playing` AND `time=` strictly increasing
- **Do NOT assert:** PMS-side timeline POSTs (they produced false green — proved we report progress to PMS, not that client sees progress)
- **W-CAST owns:** State machine fix in `companion.cpp` (commit `f801829` / binary `f8c3d2799e365ad51f288dfb40c935fa`)

### W-E2E → all: Capture device exclusivity
- `/dev/video0` is NOT safely sharable. V4L2 device has single-open semantics in practice.
- Concurrent grabs produce corrupt/torn frames (documented: `tests/fixtures/hw_visual/capture_logs/wcap_*_yuyv422_corrupt.log`).
- One gate opens at a time. flock on `build/video0.lock`.
- W-GATE, W-DEBLOCK, W-OSD (confirmed they will not open the device directly).

---

## 8. Open Risks and Things That May Be Wrong

**Risk 1: W-OSD lock file mismatch is still live.**  
`hdmi_capture_classify.py` uses `build/hdmi_capture.lock`. Until this is fixed, any concurrent run of W-OSD's gate and any of mine will both succeed at lock acquisition and both open `/dev/video0`. This will produce corrupt frames. Status: I reported it, W-OSD acknowledged, fix not confirmed.

**Risk 2: NO_SIGNAL red-proof is incomplete.**  
The decoy `/dev/video1` gives NO_SIGNAL classification. That tests the code path but does not prove the rig handles real hardware no-signal. Physical HDMI disconnect is required. Outstanding — requires parent coordination to do safely.

**Risk 3: CONTENT_PRESENT threshold (luma=8, spatial_std=3) may be too loose.**  
If the FPGA ever renders a very dark but non-black frame (e.g. dim logo, low-brightness idle screen), it might be misclassified as BLACK_SIGNAL. The thresholds were set against the known `00eebd5e` black-screen build. With a working decode RBF, test content could plausibly produce dark frames. Watch for this.

**Risk 4: Left-edge artifact is display-path RTL.**  
The 24-px black prefix is NOT an ARM bug. DDR source has grey from col 0 (confirmed in `build/ddr-analysis/wcast_final_idle_bank0.yuv`). The clip happens in FPGA scan-out. `PRESENT_X=11` in `VISUAL_COMPARE_BOX=11,...` was adjudicated knowing about this clip. Until RTL is fixed, `left-edge-clip-gate` will always be RED. Do not let red become the expected baseline and stop checking.

**Risk 5: RBF changed without notice (`fb4bad84`).**  
The resident RBF changed from `00eebd5e` to `fb4bad84` between my prior session and my current start. `misterplexd` was not running. I do not know who deployed this or when. The new RBF shows intermittent CONTENT_PRESENT (1/5 frames grey at luma=36.1) with no daemon. This may mean W-FIT's decode work is partially visible at idle, or the core's idle screen logic changed.

**Possible error in my own analysis:** I reported CONTENT_PRESENT luma=36.43 average over 5 frames for RBF `fb4bad84`. But 4 of 5 frames were luma=7.0 (BLACK_SIGNAL individually) and only frame 4 had content. The `classify_signal()` averaging logic makes the 5-frame group appear as CONTENT_PRESENT even though 80% of frames are black. This is correct behavior for a flicker/transition state but could mislead a caller expecting stable content. Consider passing `--frames 10` and requiring `unique_frames >= N/2` for a stronger CONTENT_PRESENT claim.

---

## 9. Committed Files

| File | Purpose |
|------|---------|
| `tests/hw/test_cast_timeline_poll.sh` | Cast/timeline HTTP gate (PRIMARY) |
| `tests/unit/test_cast_timeline_poll_red.sh` | Red mutation test with Python mock |
| `tests/hw/e2e/test_cast_timeline_playwright.js` | Browser check (exits 77 by design) |
| `tests/hw/e2e/observe_cast_protocol.js` | Protocol observer |
| `tests/hw/e2e/quick_intercept.js` | Request interceptor |
| `tests/hw/e2e/package.json` | Playwright 1.62.0 dep |
| `scripts/capture_preflight.py` | HDMI capture rig: enumerate, negotiate, classify |
| `tests/hw/test_capture_preflight.sh` | Capture preflight hw gate wrapper |
| `tests/unit/test_capture_preflight.py` | 9-test unit suite (no hardware) |
| `tests/unit/test_capture_preflight.sh` | Rollcall-registered wrapper |
| `scripts/grade_left_edge.py` | Left-edge black-prefix grader |
| `tests/hw/test_left_edge_clip.sh` | Left-edge gate wrapper |
| `scripts/grade_rbf_label.py` | OCR-based RBF identity label gate |
| `tests/hw/hw_gate_common.sh` | +`capture_lock_acquire()`/`capture_lock_release()` |
| `Makefile` | +targets: cast-timeline-gate, capture-rig-preflight, left-edge-clip-gate, rbf-label-check |
| `tests/unit/test_unit_rollcall.py` | +`test_capture_preflight.sh` (86 commands) |
| `build/handoff-w-e2e.md` | Prior (predecessor) handoff — historical |
| `handoffs/misterplex-handoff-w-e2e.md` | **This file** |

---

## 10. Immediate Trigger Conditions for Successor

**When W-FIT deploys h264_decode_core-wired RBF, run immediately:**
```bash
make capture-rig-preflight   # must exit 0 (CONTENT_PRESENT) — first ever automated picture evidence
make left-edge-clip-gate     # re-scores 24-px left-edge clip on new RBF
```

**If `capture-rig-preflight` still exits 1 with BLACK_SIGNAL after that deploy, the decode path is not producing output.** This is the key gate.

**For W-ARM commit `3798793` (bank fallback fix):**
```bash
# Before (daemon running, confirm livelock state):
python3 scripts/capture_preflight.py --frames 10 --out-dir build/arm-before
# After (deploy + daemon restart):
python3 scripts/capture_preflight.py --frames 10 --out-dir build/arm-after
# W-ARM predicts: both will show identical content (idle banks are identical)
# Interesting finding would be: after fix, CONTENT_PRESENT is MORE stable (more non-black frames)
```

**For W-OSD label gate:** Once W-OSD pushes a branch with misterplexd label rendering:
1. Get the `--region x,y,w,h` from them
2. Run `make rbf-label-check`
3. Fix lock file if not yet fixed

**For NO_SIGNAL red-proof:** Physically disconnect HDMI from capture stick, run `make capture-rig-preflight`, expect exit 1 with NO_SIGNAL. Reconnect, confirm VALID returns.

---

## 11. UPDATE — W-FIT deploy coordination (2026-07-28, added by successor)

### devmem crash — CRITICAL LESSON

**Never call `/usr/sbin/devmem 0xFF200000` on the MiSTer.** This reads the LWH2F (Lightweight HPS-to-FPGA) bridge. If the FPGA peripheral at that address is not ready, the AXI bus stalls and hangs the ARM HPS. The network interface goes down, SSH sessions become unresponsive. The MiSTer requires manual power cycle.

This happened during the deploy coordination for W-FIT. The MiSTer was offline for >20 minutes and counting. All subsequent BLACK_SIGNAL captures during that period are **REFUSE_SOURCE_OFFLINE** (the MS2109 outputs flat RGB(7,7,7) = luma 7.0 = sha 2358782e even when the source is powered off — indistinguishable from black-screen RBF output without host probe).

### New tool: `capture_deploy_window.py`

**File:** `scripts/capture_deploy_window.py` (commit `9e40277`, improved in `2a10b5b`)  
**Purpose:** Continuous multi-frame capture across a deploy/bounce transition. Shows per-frame luma/std/state as they arrive.  
**Correct invocation:**
```bash
python3 scripts/capture_deploy_window.py \
  --host 192.168.1.183 \      # mandatory: disambiguates black-RBF vs dead-source
  --duration 120 \
  --interval 3 \
  --out-dir build/deploy-capture
```
WITHOUT `--host`: any BLACK_SIGNAL result is ambiguous — cannot attribute to core or dead source. **Always pass `--host 192.168.1.183`.**

### New tool: `score_idle_screen.py`

**File:** `scripts/score_idle_screen.py` (commit `72f9e4f`)  
**Purpose:** Grades idle/screensaver screen. Detects Plex-orange chevron. Disambiguates black-core vs powered-off source.  
**Correct invocation:**
```bash
python3 scripts/score_idle_screen.py \
  --host 192.168.1.183 \
  --expect-chevron \
  --out-dir build/idle-score
```
Exit 0 = CONTENT_PRESENT + chevron found. Exit 1 = no content / no chevron (core defect). Exit 2 = REFUSE (no signal or source offline — UNSCORED).

### Pre-deploy baseline data (valid, MiSTer was online)

**RBF `fb4bad84` already resident** before W-FIT's planned deploy:
```
Scope: 40 frames / 120s, interval=3s (warmup-discard not in place — some BLACK may be warmup)
MiSTer 192.168.1.183: REACHABLE, misterplexd pid 7518 RUNNING
CONTENT_PRESENT: 2/40  at t=27.1s (sha=871cb502 luma=36.50 std=22.17)
                        and t=69.1s (sha=04e8975a luma=36.50 std=22.16)
BLACK_SIGNAL:    37/40  sha=2358782e luma=7.00 std=0.00
CAPTURE_ERROR:   1/40   (t=66s transient)
black_attribution: source_host_reachable_core_paints_black
```
The 2/40 CONTENT frames at ≈42s separation match W-ARM's documented timed-bank-fallback period. **Livelock IS present in `fb4bad84` as currently loaded.** Either the `||!slot_keep` fix is not in this build, or misterplexd requires a restart after core reload for the fix to take effect.

### Lock path fix (commit `2a10b5b`)

`capture_deploy_window.py` now uses `git rev-parse --git-common-dir`/video0.lock — the same path as `hw_gate_common.sh`. This is shared across all worktrees on this machine. Previous version used a per-worktree path and serialised nothing.

---

## 12. UPDATE — W-E2E-O5 shift (2026-07-28 12:06–13:0x)

**Branch:** `w-e2e-playwright`. Device `/dev/video0` was claimed and held for the whole shift.

### 12.1 The screen WAS scored — the deploy of `fb4bad84` is no longer UNSCORED

| Time | Verdict | Evidence |
|------|---------|----------|
| 12:09 | **VALID SIGNAL WITH CONTENT** — Plex chevron rendering | `artifacts/e2e-o5/screen_now.png` |
| 12:27 | flat black, **but the MiSTer was off the network** | `artifacts/e2e-o5/warmup_flat_frame.png` |

At 12:09 with RBF `fb4bad84` resident the idle screen showed **14928 px of Plex brand
orange RGB(244,163,2) (#E5A00D)**, bbox `484,239..707,479`, centroid `(595,359)`, on a
dark-grey background (median lum 38.7).

**This answers the "one-glance user question" w-osd-o5 left open** ("do you see a Plex
chevron instead of a pure black screen?"). **Measured answer: YES, the chevron renders.**
No human was asked.

### 12.2 Three fleet-wide instrument bugs found and fixed

**(a) MS2109 warmup produced a 33% false BLACK_SIGNAL rate.** `grab_frame` opens ffmpeg
once per frame and each open emits a leading run of flat RGB(7,7,7) frames until the HDMI
receiver locks (10 leading flat frames in a 60-frame burst, 11 in a 20-frame burst,
nondeterministic). At the old default of 3 scored frames, **2 of 6 identical live runs
called a screen with real content BLACK_SIGNAL**, and the emitted note blamed resident RBF
`00eebd5e`. This is a very likely origin of "the screen is black" reports in this project.
Fixed in `e89ddc4`; `tests/unit/test_capture_warmup.py`.

**(b) A powered-off source is INDISTINGUISHABLE from a black core.** With the MiSTer
switched off the capture device **keeps delivering frames** and they are flat RGB(7,7,7) —
byte-identical to a black core. **Mean luma alone can never separate those two causes.**
`scripts/score_idle_screen.py --host` probes the source and returns REFUSE/UNSCORED rather
than a core FAIL. Fixed in `72f9e4f`; `tests/unit/test_idle_screen_score.py`.

**(c) The `/dev/video0` flock serialized nothing.** The lock file was derived from the
worktree root, so each of the ~20 worktrees got its own private lock. Now anchored at
`git rev-parse --git-common-dir` = one real lock per machine. Proven with two genuinely
different worktrees: contender blocked with rc=77. `tests/unit/test_capture_lock_shared.sh`.

### 12.3 Left-edge artifact now has a number (owner: w-arm-o5)

The user-reported "moving jagged black lines on the left edge" is **confirmed and
quantified** on capture:

- **26.86%** dark pixels in cols 84–200 vs **0.19%** in the 300–1200 control = **143.3x**
- present in **59/59** scored frames
- **it moves**: median **7304** pixels change in the band per frame

Reported by `scripts/score_idle_screen.py` as `LEFT_EDGE_ARTIFACT`, never fatal.

### 12.4 Plex Web control — stuck-at-0:00 is OURS, not upstream

`tests/hw/e2e/test_plex_web_player_baseline.js` drives real Plex Web in headless Chromium
against the real server with **no cast target and no MiSTer**:

- `currentTime` **3.590 → 37.677 = 34.087s advance** over 35s, readyState=4, error=null
- server cross-check `/status/sessions` size=1, **viewOffset=28000ms**

**Plex Web, the media and the server are healthy for `/library/metadata/3`.** The
stuck-at-0:00 symptom does **not** reproduce in Plex's own player, so it is a
**MiSTerPlex-side bug** — that closes off an entire branch of investigation for w-cast.

Two blockers had to be solved, both of which otherwise make the UI unscorable:
1. **"Select User" profile picker** — with managed accounts nothing renders until a
   profile is chosen, and a JS `.click()` does not work (React needs a real input event).
   Use a real Playwright click. `PLEX_WEB_USER=shawnhenderson`.
2. **`#!/server/auto/` resolves to a loopback connection** the browser cannot reach
   (`[Connections] All connections to [Loopback] failed`) unless it runs on the PMS host.
   Route through the real `machineIdentifier` from `/identity`.

Note `PLEX_BASE` is **`http://192.168.1.41:32400`**, not the `127.0.0.1` in the task brief —
that URL only works from the PMS box itself.

### 12.5 Blocked / not done

- **The MiSTer went off the network at ~12:27** (`No route to host`, ARP `INCOMPLETE`) and
  had not returned by end of shift. Everything needing hardware is blocked on power-up:
  full cast E2E, re-scoring the screen, and any per-deploy capture request.
- The full cast path (`test_cast_timeline_playwright.js`) correctly exits **77** while the
  daemon is unreachable — that is a skip, **not** a pass.
- `tests/unit/test_no_private_data.sh` was **already red on HEAD** before this shift
  (`handoffs/`, `tests/hw/test_cast_timeline_poll.sh`). Not mine, not fixed; this shift
  added no new hits.

### 12.6 How to re-score the screen the moment the MiSTer is back

```bash
cd .worktrees/w-e2e
python3 scripts/score_idle_screen.py --device /dev/video0 \
  --host 192.168.1.183 --expect-chevron --json-out screen.json
# 0 = content (+chevron)   1 = genuinely black   2 = UNSCORED   77 = no device
```

---

## 13. UPDATE — W-FIT deploy + post-deploy capture (2026-07-28 13:10–13:22)

### 13.1 W-FIT deploy confirmed

W-FIT deployed `fb4bad849ad2db782a5004ce5a3471ce` (frame-store livelock fix) and verified on-device:
- `CORENAME=Plex → MENU → MENU → Plex` — FPGA actually reconfigured (not stale)
- `on-device md5sum /media/fat/_Utility/Plex.rbf = fb4bad849ad2db782a5004ce5a3471ce`

### 13.2 W-FIT register telemetry — CRITICAL finding: fabric writes NOTHING to DDR

After deploy, W-FIT found `0x3007F12C frozen at 0xA086000C, delta = 0`.

W-FIT poked all four mailbox words with `0xDEADBEEF` / `0xA5A5A5A5` and waited 6s each time. ALL FOUR stayed poisoned — the fabric wrote **nothing** to DDR. Both PLXS and PLXD are completely silent. The pre-deploy advancing counter was genuine (fabric-written, confirmed by `host/libmisterplex/mailbox_abi_spec.hpp:120` declaring PLXD `direction="fpga_to_arm"`) but the new build produces zero writes.

**W-FIT's two candidate explanations:**
- **(A) DDR write path dead, video timing alive** → HDMI signal present (black or logo)
- **(B) `clk_ddr`/`reset_ddr` stuck, or video timing dead** → NO_SIGNAL

### 13.3 Post-deploy capture result

**Capture 1 (post-deploy main clip):**
```
Scope: 18 frames, t=0..85s, 90s clip, started 13:11:36
MiSTer host_alive=False (standing routing issue from this host; W-FIT had working SSH)
ALL 18 frames: BLACK_SIGNAL  luma=7.000  std=0.000  sha=7bc7f229  unique_colors=1
delta=0.0 on all frames (byte-identical consecutive frames)
orange_px=0 in all frames
```

**Capture 2 (bounce-probe, 60s at 4fps = 240 frames):**
```
Scope: 240 frames, t=0..60s, 4fps extraction, started 13:18:36
ALL 240 frames: BLACK_SIGNAL  luma=7.000  std=0.000  sha=7bc7f229  unique_colors=1
NO_SIGNAL transitions: 0
CONTENT_PRESENT frames: 0
```

### 13.4 Why these results are AMBIGUOUS (do not skip this section)

All frames are flat RGB(7,7,7) — IDENTICAL to:
1. MiSTer powered off (MS2109 flat noise, documented in section 11)
2. The pre-deploy `00eebd5e` black-screen RBF output
3. A valid-but-black HDMI signal from the new `fb4bad84` (if timing alive but nothing to show)

The `--host 192.168.1.183` probe returns `False` from THIS host due to the standing routing issue — this does NOT mean MiSTer is offline. W-FIT was successfully doing SSH+devmem during the capture window.

**The sha=7bc7f229 is DIFFERENT from prior clips' sha=2358782e**, but this is because the earlier sha was computed over MJPEG-compressed bytes while the current sha is over decoded RGB numpy arrays. These are incomparable. When I extracted a frame from the old clip using the same pipeline, it ALSO gave sha=7bc7f229 — confirming identical content, not a different source.

### 13.5 Bounce-probe discriminator — INCONCLUSIVE (bounce timing unknown)

I started a 60s recording and asked W-FIT to issue a menu bounce during the window. A live FPGA during reconfiguration produces a brief NO_SIGNAL gap in HDMI (I/Os tri-state during bitstream load). If the bounce happened inside 13:18:36–13:19:36 and HDMI was alive, I'd see a BLACK→NO_SIGNAL→BLACK transition.

**No transitions detected in 240 frames.** This is inconclusive because:
1. W-FIT may not have bounced during the 60s window (likely — timing is tight)
2. OR HDMI is dead (option B confirmed by absence of discriminator transition)
3. OR HDMI was already dead-looking before the bounce, so the bounce added no visible change

**OUTSTANDING: W-FIT asked to confirm whether they issued a bounce during 13:18:36–13:19:36.**

### 13.6 Important correction to section 12.1 (12:09 content claim)

Section 12.1 states: "At 12:09 with RBF `fb4bad84` resident — 14928 px Plex-orange detected."

However: W-FIT's register telemetry confirmed that at the start of the current session, the **file** on disk was `fb4bad84` but the **FPGA fabric** was loaded with `00eebd5e`. Since the prior session (12:09) did not explicitly verify what was in fabric (only what was on disk), the 14928-px chevron at 12:09 was likely rendered by `00eebd5e` via timed-bank-fallback — **not** by `fb4bad84`.

This means we have **NO confirmed evidence** that `fb4bad84` outputs displayable content. The 12:09 measurement must be treated as `00eebd5e` evidence.

### 13.7 Summary of what W-FIT's deploy tells us (what we can and cannot claim)

**Can claim:**
- `fb4bad84` FPGA fabric writes NOTHING to the PLXD/PLXS DDR mailboxes (6s+ poison test)
- The livelock fix (`||!slot_keep`) is either not in this build or has no effect on mailbox writes
- There is NO timed-bank-fallback content visible in the post-deploy captures (unlike pre-deploy)

**Cannot claim:**
- Whether HDMI output is alive or dead (signal is flat RGB(7,7,7) = ambiguous)
- Whether `fb4bad84` has the frame-store fix working
- Whether the absence of mailbox writes is a `clk_ddr` issue (option B) or just the DDR write path being broken while video timing is alive (option A)

### 13.8 Recommended next steps (post-deploy)

1. **W-FIT: confirm bounce timing** — Did you bounce during 13:18:36–13:19:36? If not, please issue one bounce and tell me the exact time. I'll start a 30s clip immediately.

2. **Alternative discriminator:** W-FIT can pipe misterplexd's log. If it says `idle screen painted (mode=0)` but the fabric still outputs all-black, that's strong evidence for option B (scanout dead, ARM writes are lost).

3. **If W-FIT confirms bounce AFTER 13:19:36:** I need to start another capture for the discriminator. Standing ready — just say the word.

4. **Post-bounce scoring:** Once I have a capture that spans a bounce, I can determine:
   - NO_SIGNAL seen briefly → HDMI alive → option A (DDR write path dead, timing OK)
   - No NO_SIGNAL ever → HDMI already dead → option B (timing dead or clk_ddr stuck)


## 14. UPDATE — W-E2E-O5: the hardware "decode golden" is an idle screen (2026-07-28)

**Branch `w-e2e-playwright`, commits `0867f21` (gate) and `a4ba3e6` (record correction).**

### 14.1 Finding (MEASURED, not assumed)

`tests/fixtures/hw_visual/plex_real_baseline_320x240_57674f2e_mjpeg720_golden.png`
— the fixture the repo used as its **hardware decode golden** — does **not depict
decoded video**. It is a capture of the **Plex chevron idle screen**.

Method: host-decode the bitstream its own `.provenance.json` names
(`tests/fixtures/p3_host_recon/plex_real_baseline_320x240_1f.264`) with ffmpeg,
then compare.

| | golden | host decode of the declared bitstream |
|---|---|---|
| content | dark background + orange chevron | bright testsrc2 colour bars + timecode |
| overall mean luma | **23.6** | **123** |
| luma std | 20.2 | **65.53** |
| ROI `11,0,160,120` (declared "stable top-left decoded ROI containing MB0") | **9 distinct colours, std 5.35**, mean RGB (13,25,23) | MB0 16×16 std **53.22** |
| correlation (luma NCC) | **−0.0735 — uncorrelated** | — |

### 14.2 Why it matters: the historical green was vacuous

`docs/PHASE_BACKLOG.md` recorded *"Green rollback `57674f2e`: exact ROI pixels
`19200/19200`, MAE `[0,0,0]`, max_abs `0`, `rc=0`"*.
**19200 = 160×120 = the compare_box.** That ROI is flat background in the golden.
So the celebrated green matched **flat background against flat background**. It is
evidence about the display/present path only, and never about decoding.

This is consistent with — and independently corroborates — `w-fit-o5`'s post-fit
proof that deployed `fb4bad84` contains no decoder, and with the project's honest
statement that **zero frames have ever been decoded and displayed**.

### 14.3 The fix: `scripts/prove_decoded_frame.py`

A painter-proof decode oracle. It takes the one position a painter cannot fake:

> a core has decoded only if the screen **agrees with the host decode of the exact
> bitstream that was pushed**.

Verdicts: `0 DECODE_PROVEN` / `1 NOT_DECODED` / `2 REFUSE`.
Flat or absent signal **always REFUSES** — never passes, never fails — because a
black screen carries no evidence about decoding. A degenerate (flat) reference
also REFUSES, since it would otherwise match anything.

Hermetic `--self-test` (no hardware), **9/9**, every green shipped with its red:

```
true-decode-clean             DECODE_PROVEN  ncc  0.9816
true-decode-noisy             DECODE_PROVEN  ncc  0.9855
chevron-idle-golden           NOT_DECODED    ncc -0.0735
live-capture-no-decoder-core  NOT_DECODED    ncc  0.1425
mirrored-reference            NOT_DECODED    ncc -0.8680
block-shuffled-reference      NOT_DECODED    ncc -0.1044
flat-black / flat-grey-painter / degenerate-reference   REFUSE
```

Threshold `0.75` sits in an empty gap between `0.1425` and `0.9816`.
Mutation-verified non-vacuous — 4/4 mutations turn it red:
always-DECODE_PROVEN, no-flat-refusal, threshold=−1, no-degenerate-ref-guard.

Note `plex_visual_640x480_golden.png` is **not** used as a negative: it is the
same testsrc2 content at another resolution and the gate correctly scores it as
agreeing. The structural negatives (mirror, block-shuffle) prove the gate keys on
picture structure rather than colour histogram.

Usage when a decoder-bearing RBF finally lands:
```bash
python3 scripts/prove_decoded_frame.py \
  --reference tests/fixtures/p3_host_recon/plex_real_baseline_320x240_1f.264 \
  --device /dev/video0
```

Registered in `Makefile` and `tests/unit/test_unit_rollcall.py`
(`tests/unit/test_prove_decoded_frame.py`, 15/15). Rollcall now 90 protected commands.

### 14.4 Baseline honesty

`make unit` is **rc=2 with 37 `FAIL` lines both with and without** the new gate
(measured, logs in `artifacts/e2e-o5/`). Pre-existing and unrelated to this work;
failures are in C++ (`test_osd_menu`, `test_last_frame_latch`), RTL DPB/MC seam,
and live-PMS gates.

### 14.5 Hardware still DOWN

`192.168.1.183` unreachable all shift (100% packet loss; ARP INCOMPLETE).
`/dev/video0` free and unclaimed. Live re-score correctly returned **rc=2 REFUSE**:

```
REFUSE: frames are flat black BUT source host is unreachable — a powered-off
MiSTer produces identical flat RGB(7,7,7) frames. Screen state is UNSCORED;
this is NOT evidence of a core defect.
Scope: 8 scored frames, warmup dropped 12
```

That is the host-liveness fix from §12 working live. **No capture request can be
served until the MiSTer returns**; this likely needs a physical power-cycle, which
conflicts with the no-human-in-the-loop directive and should be escalated.

## 15. STEP 1 (parent-authorized capture of the `fb4bad84` failure state) — NO HDMI SIGNAL

**Attempted 2026-07-28 13:33–13:40. Result: cannot capture; there is no signal to capture.**

Parent expected a possible Plex logo on screen after `w-fit-o5` zeroed the stale
magics and the ARM reported `media: idle screen painted (mode=0)`. **Measured
now, there is no HDMI signal at all.**

Three independent probes, all agreeing:

| probe | result |
|---|---|
| `ping -c2 192.168.1.183` | 100% packet loss, rc=1 |
| `ip neigh show 192.168.1.183` | **INCOMPLETE** (no ARP resolution on `wlp89s0`) |
| `ssh root@192.168.1.183` | `No route to host` |

And the decisive pixel evidence that this is **no-signal, not a black core** — the
ambiguity flagged in §12 as unresolvable by luma alone is resolved here by
byte-identity rather than by threshold:

```
stored no-HDMI-lock warmup filler frame : 1 unique colour, RGB(7,7,7)
6/6 frames captured now (warmup_discard=0, nothing dropped):
  every frame 1 unique colour RGB(7,7,7), identical_to_nolock_warmup = True
```

All six frames are **byte-identical** to the known pre-HDMI-lock filler the MS2109
emits when the receiver has not locked. That filler is what the device produces
with **no source attached**. Combined with ARP INCOMPLETE, the conclusion is that
the MiSTer is powered off or physically disconnected from both network and HDMI.

`v4l2-ctl --get-dv-timings` is not available on this device
(`Inappropriate ioctl`) — the MS2109 is a UVC device and exposes no HDMI link
status, so byte-identity against the known filler is the strongest available
link-state oracle. Worth reusing.

**Consequence for the authorized sequence:** STEP 1 cannot produce a capture, and
STEP 2 (the `3b1e8435` A/B deploy) cannot be deployed or scored either, because
the host is unreachable by SSH. **Escalated to parent — this needs a physical
power-cycle, which the no-human-in-the-loop directive cannot cover.**

### 15.1 Bug found and fixed in my own new gate

Exercising the live path exposed that `scripts/prove_decoded_frame.py` called
`cp.grab_n_frames(dev, fmt, size, fps, Path(td), frames)` with `n` and `out_dir`
**transposed** (`AttributeError: 'int' object has no attribute 'mkdir'`). The
hermetic `--self-test` could not see it because it never opens a device.

Fixed, and guarded three ways in `tests/unit/test_prove_decoded_frame.py`
(now 18/18): the real `grab_n_frames` parameter order is asserted, the call is
`inspect.signature(...).bind(...)`-checked, and the source call form is asserted.
Red-proven: re-transposing the arguments turns the gate red on exactly that check.
Live path now verified against hardware — returns `rc=2 REFUSE` cleanly.

## 16. CORRECTION — the STEP 1 capture is the MENU core, not `fb4bad84`

**I got this wrong in commit `1c9ee4e` and am correcting it within the shift.**

I captured content at 13:47–13:48 and attributed the 7-bar gradient pattern to
Plex's own `fpga/Plex_MiSTer/rtl/colorbars.sv`, and derived `has_frame==0` from
`present_core.sv:338`. **That attribution is void.** A provenance check
afterwards showed:

```
CORENAME    = [MENU]          <- NOT Plex
fpga_state  = operating
uptime      = 523s            <- device REBOOTED ~13:44
md5 /media/fat/_Utility/Plex.rbf = fb4bad849ad2db782a5004ce5a3471ce  (on disk only)
misterplexd = running, pid 983 (restarted at boot)
```

The MiSTer **rebooted at ~13:44**, which explains the 12:27–13:44 network
outage (§15) and its sudden return. On reboot it loaded the **Menu core**.
`fb4bad84` is present on the SD card but **is not loaded into the FPGA**.

Therefore:
- The captured colour bars are the **MiSTer Menu core's** output. They are not
  evidence about Plex, `colorbars.sv`, `present_core`, `has_frame`, or the DDR
  frame path. My `has_frame==0` inference is withdrawn.
- The transient state the parent asked me to photograph — the ARM-painted
  `media: idle screen painted (mode=0)` on `fb4bad84` — was **destroyed by the
  reboot**, not by any deploy. It is unrecoverable.
- **STEP 1 is unachievable as specified.** There is no `fb4bad84` screen state
  left to capture.

### 16.1 What the capture legitimately does establish

Genuinely useful, and independent of which core is loaded:

- The **capture rig is healthy and correctly targeted**: `/dev/video0`, MS2109,
  MJPG 1280x720@60, 21/24 frames with content, luma spatial std **max 24.05**
  (threshold 1.0), mean luma up to **27.0** (black threshold 8.0).
- The **three-state gate discriminates correctly on live hardware**: it reported
  NO SIGNAL while the device was down (all frames byte-identical to the no-lock
  filler) and VALID WITH CONTENT once it returned — with no code change.
- The **decode oracle survived a real adversarial case**: the Menu core's
  gradient colour bars superficially resemble the testsrc2 colour-bar reference,
  and `prove_decoded_frame.py` still returned **`ncc 0.1675 NOT_DECODED` (rc=1)**.
  That is a live false-positive test against a painter, passed.

### 16.2 Lesson

Signal state and *provenance* are independent axioms. A capture is only evidence
about a bitstream if the loaded-core identity is checked **at capture time**.
`score_idle_screen.py --host` probes host liveness but does **not** verify
`CORENAME`/loaded RBF; a capture can therefore be perfectly valid and still be
about the wrong core. Any capture gate used for grading a deploy must assert
`CORENAME` and the resident RBF md5 alongside the pixels.

---

## 15. UPDATE — Option A confirmed via bounce-long clip (2026-07-28 13:43–13:47)

**Branch `w-e2e-playwright`, commit `b290bb7`. Evidence in `artifacts/e2e/post-deploy-evidence/`.**

### 15.1 The discriminator fired

180s clip (13:43:50–13:46:50), extracted at 10fps (1800 frames) and confirmed at 60fps native (120 frames around transition):

```
BLACK_SIGNAL:     202/1800 (11.2%)  t=0.0–20.1s
CONTENT_PRESENT: 1598/1800 (88.8%)  t=20.2s–180s
NO_SIGNAL:          0/1800  (0.0%)
```

**Transition at t=20.183s: BLACK → CONTENT, instantaneous (no NO_SIGNAL gap at 60fps).**

This is the definitive answer to W-FIT's A vs B question:
- **Option A CONFIRMED: video timing alive**
- No FPGA reconfiguration occurred (would show NO_SIGNAL)
- Content change was DDR state change, not core reload

### 15.2 What the content is

The content after t=20.2s is a **color test pattern**, NOT:
- The Plex idle screen (orange_px=0–6, threshold 2000)
- Decoded video (prove_decoded_frame: NOT_DECODED ncc=-0.091)

Color breakdown:
- t=20.2s: greyscale only (R=G=B), 256 unique grey levels
- t=50s: pure green (0,255,0), white (255,255,255), magenta (255,0,255)
- t=180s: magenta, green, white, near-pure blue

These are primary/secondary RGB colors at full saturation — consistent with the FPGA's built-in test pattern generator activating in the absence of valid DDR content.

### 15.3 What this means for W-FIT's diagnosis

- `fb4bad84` FPGA: DDR mailbox (PLXD/PLXS) completely silent (confirmed by W-FIT's devmem poison test)
- But HDMI timing is alive: the video output clock and sync are running
- ARM timed-bank-fallback apparently failed to paint the idle screen (no chevron visible)
- The test pattern appearing at t=20.2s is what the FPGA shows when its DDR scanout falls back to built-in generator

**RCA implication:** The `||!slot_keep` fix in the prep allocator may have inadvertently broken the heartbeat/vsync writer in `ddr_frame_store.sv:879-889` (the block gated only by `reset_ddr`). If `clk_ddr` is alive but the `reset_ddr` de-assertion was broken, the heartbeat block won't run, which matches both the dead mailbox writes AND the eventual recovery of the test pattern.

### 15.4 Correction: host_alive=False was routing, not crash

During the 180s clip, `host_alive=True` at analysis time (post-capture ping check). The earlier `host_alive=False` readings were the standing routing issue from this machine, not MiSTer offline. W-FIT had full SSH access throughout.


### 15.5 CORRECTION TO SECTION 15 — Content was Menu core, not fb4bad84

**W-E2E-O5 (commit `fbb5177`) identified that the MiSTer REBOOTED at ~13:44.** The content appearing at t=20.183s in the bounce-long clip was the **Menu core** coming up after reboot, not `fb4bad84`'s display.

Evidence: W-E2E-O5 checked provenance via SSH immediately after their concurrent capture: `CORENAME=[MENU] uptime=523s`. The MiSTer had been offline since ~12:27 (devmem crash) and rebooted at ~13:44, landing on the Menu core.

**Implications:**
- Section 15.1 "Option A CONFIRMED" is WITHDRAWN. The HDMI content was from the Menu core, not fb4bad84.
- My option A inference was wrong because I did not verify CORENAME at capture time.
- `fb4bad84` HDMI output is still UNSCORED.
- The color bars seen are the MiSTer Menu core's startup display.

**Critical lesson: Never claim a bitstream result without asserting CORENAME + RBF md5 at capture time.**

W-E2E-O5's approach is correct: SSH provenance check (`CORENAME` + `md5sum /media/fat/_Utility/Plex.rbf`) must be done BEFORE and AFTER any capture used as evidence about a specific RBF.

**What section 15 captures DO prove (correct claims only):**
- The capture RIG is healthy (correctly transitions NO_SIGNAL → CONTENT when MiSTer returns)
- prove_decoded_frame correctly rejects the Menu core's color bars (ncc=0.1675, NOT_DECODED)
- LEFT_EDGE_ARTIFACT present on Menu core too (215.4× ratio) — may be physical/capture artifact rather than Plex-RTL-specific

**For fb4bad84 scoring:** W-FIT needs to load fb4bad84 via menu bounce to Plex core, confirm CORENAME=Plex, then capture with provenance.


## 17. STEP 1 COMPLETE — `fb4bad84` shows the Plex chevron. VALID WITH CONTENT.

**Provenance-locked capture, 2026-07-28 ~13:57.** This supersedes §15 (no signal)
and §16 (MENU core); both were accurate for their moment.

```
PROVENANCE: corename='Plex' rbf_md5=fb4bad84 uptime=983s
Scope: 8 scored frames from v4l2:/dev/video0 mjpeg 1280x720@60 (warmup dropped 2)
SIGNAL_STATE      : CONTENT_PRESENT   mean_luma=36.43  spatial_std=22.22
PLEX_CHEVRON      : PRESENT  14928 px Plex-orange, centroid (595,359),
                             bbox [484,239,707,479]
LEFT_EDGE_ARTIFACT: PRESENT  28.0% dark in cols[84,200] vs 0.2% control
                             [300,1200]  = 150.5x enrichment
rc=0  PASS
```

**Verdict on the three-state grading: (3) VALID WITH CONTENT.**
Raw discriminator: luma spatial std **22.22** against a content threshold of
**1.0**, and 12/12 saved frames independently at std ~21.05 with orange_px
**14928** (chevron floor 2000). Not black (black threshold mean luma 8.0;
measured 36.43) and not no-signal.

Artifacts: `artifacts/e2e-o5/STEP1_PLEX_fb4bad84_screen.png`,
`step1_plex_f00..f11.png`, `STEP1_plex_fb4bad84.json`.

### 17.1 Answer to W-FIT-O5's falsifiable prediction

> DDR write path dead **but video timing alive** -> VALID signal (black, or the ARM-painted logo)
> `clk_ddr`/`reset_ddr` stuck -> NO SIGNAL

**Prediction CONFIRMED, not refuted.** The signal is valid *and* carries the
ARM-painted Plex logo. The video timing and present path on `fb4bad84` are
**alive**, and the ARM's `media: idle screen painted (mode=0)` **does reach the
display**. The NO-SIGNAL branch is refuted.

Caveat kept deliberately narrow: this proves the **pixel/video clock domain and
the present path** are alive. It says nothing directly about `clk_ddr`, and the
chevron is ARM-painted, so it is **not** evidence that the fabric writes to DDR.
It is fully consistent with w-fit-o5's mailbox result (fabric writes nothing).

### 17.2 Timeline (measured; all three states observed on one shift)

| time | state | evidence |
|---|---|---|
| 12:27–13:44 | **NO SIGNAL** | frames byte-identical to no-lock filler; ARP INCOMPLETE |
| ~13:44 | device **rebooted** | `uptime=523s`, came back on `CORENAME=MENU` |
| ~13:48 | MENU core bars | misattributed to Plex; corrected in §16 |
| ~13:57 | **VALID WITH CONTENT** | `CORENAME=Plex`, `rbf_md5=fb4bad84`, chevron present |

The rig produced all three states in one shift and the gate graded each one
correctly with no code change — including refusing the ambiguous ones.

### 17.3 New guard: provenance is now enforced before pixels

`score_idle_screen.py` gains `--expect-corename` and `--expect-rbf-md5`, which
read `/tmp/CORENAME` and the resident RBF md5 over SSH and **REFUSE (rc=2)
before grading any pixel** when they do not match. This is the durable fix for
the §16 misattribution — it would have caught my error automatically.

Live red/green, both directions, against the real device:
```
--expect-corename MENU  while device on Plex  -> rc=2 REFUSE  (red)
--expect-corename Plex  while device on Plex  -> rc=0 graded  (green)
```

### 17.4 Note on the transient `ABSENT` chevron reading

An earlier run reported `PLEX_CHEVRON: ABSENT` with `mean_luma=82.94`,
`spatial_std=72.31`, `unique=8/8`. That was **not** a detector bug: it was a
correct reading of a different, brighter, animating screen during the core-load
transition. Once stable, the same detector reports 14928 px on 12/12 frames.
Recorded because "gate said absent, logo was there" would otherwise look like a
false negative to the next reader.

## §18 — Chevron detector scored the MiSTer MAIN MENU as "Plex chevron PRESENT"

**Measured false positive on live hardware**, not a hypothetical. With
`CORENAME=MENU` on screen, `score_idle_screen.py` printed `PLEX_CHEVRON:
PRESENT — 8959 px ... bbox [368, 0, 486, 719]` and `PASS`. That bbox is
119x720: a full-height column of orange **menu text**. The detector used
colour + pixel count + centroid and had **no shape constraint**.

| | bbox | aspect | fill |
|---|---|---|---|
| real Plex chevron | 224x241 | 0.929 | 0.277 |
| MENU text column | 119x720 | 0.165 | 0.105 |

Added `CHEVRON_ASPECT_RANGE=(0.40, 2.50)` and `CHEVRON_MIN_FILL=0.18`.
Red/green replayed on **real stored frames** both ways. Mutation testing then
showed my first regression case was **vacuous** — the text column was rejected
on aspect alone, so both fill mutations survived. Added a square-but-sparse
orange block that isolates fill. Now 14/14 mutants killed.

## §19 — `misterplexd` is DEAD, and the screen is unchanged

Device rebooted ~14:16 (uptime 1926s -> 172s), came back on `MENU`, then Plex
was loaded. `misterplexd` **did not restart**:

```
ps w                    -> 95 processes, /media/fat/MiSTer /media/fat/_Utility/Plex.rbf running
                           NO misterplexd
netstat -lnt | grep 3005 -> no listener
```

With **no ARM daemon at all**, provenance-locked capture (`corename=Plex`,
`rbf_md5=fb4bad84`) still shows:

```
SIGNAL_STATE: CONTENT_PRESENT  mean_luma=36.33  spatial_std=22.3  unique=12/12
PLEX_CHEVRON: PRESENT — 14928 px, centroid [595,359], bbox [484,239,707,479]
```

**14928 px and the identical bbox** — the same numbers as the daemon-alive
STEP 1 capture. The chevron does not require a live `misterplexd`.

## §20 — The left-edge artifact MOVES, and killing the ARM daemon does not change it

New instrument `scripts/analyze_left_edge_dynamics.py` (self-test 5/5, gate
`tests/unit/test_left_edge_dynamics.py` 8/8). It takes its **noise floor from
the capture itself** — the temporal std inside the saturated chevron interior —
so motion is measured against a real, per-capture noise estimate.

A first attempt using IoU of the dark mask suggested motion (0.61 vs 1.00) and
was **discarded as unsound**: the artifact sits near the black threshold, so
IoU mostly measures threshold proximity. Density-matched controls could not be
constructed (the control band's luma distribution is discrete). The chevron
noise floor settled it properly.

| | daemon ALIVE (STEP 1) | daemon DEAD |
|---|---|---|
| artifact temporal std | 5.81 | 5.68 |
| capture noise floor | 0.00 | 0.00 |
| dark ratio vs control | 179.0x | 171.0x |
| per-row width variation | 16.84 px | 16.45 px |
| raggedness collapse on averaging | 0.449 | 0.487 |
| pillar edge column | 128 | 128 |
| verdict | MOVING | MOVING |

**~2% difference.** Removing the ARM writer entirely leaves the artifact
statistically unchanged.

**This refutes the stated mechanism for the left-edge artifact** ("ARM writes
into the bank being scanned out", owner `w-arm-o5`) *for this state*: there is
no ARM writer, and the artifact is unchanged in magnitude, raggedness and
motion. The stable pillar edge at **column 128** in 12/12 frames of both
captures points at the present/scanout path, not at an ARM/DDR write race.

Scope limit, stated: this compares two captures of the same resident RBF taken
either side of a reboot. Both are provenance-locked to `corename=Plex`,
`rbf_md5=fb4bad84`. It does not identify what *does* move the pattern.

## §21 — Same-boot control added; artifact still independent of the ARM daemon

`misterplexd` came back mid-shift (pid 3823, listening on 3005), giving a
**same-boot** daemon-alive arm and removing the reboot confound declared in
§20.

| capture | daemon | boot | temporal std | dark ratio | row-width var | pillar edge | verdict |
|---|---|---|---|---|---|---|---|
| STEP 1 (pre-reboot) | ALIVE | 13:44 | 5.81 | 179.0x | 16.84 px | 128 | MOVING |
| 14:41 | **DEAD** | 14:16 | 5.68 | 171.0x | 16.45 px | 128 | MOVING |
| 14:56 | ALIVE | 14:16 | 6.19 | 160.5x | 17.90 px | 128 | MOVING |

The daemon-dead arm sits **between** the two daemon-alive arms on every
statistic. There is no daemon-attributable effect. Chevron is **14928 px with
the identical bbox in all three**.

**Probe-reliability caveat, stated because it nearly misled me.** Two shell
quoting/portability traps hit this measurement:

1. `ps w | grep -i "misterplex\|Main"` returns **empty even when the process
   exists** — busybox grep does not treat `\|` as alternation in BRE, so the
   whole pattern is literal.
2. Nested double quotes inside a single-quoted `ssh '...'` command
   (`"daemon=$(... grep -c "[m]isterplexd")"`) terminate the outer string early
   and silently change what grep receives. This produced a bogus `daemon=1`.

Both failure modes are **silent** and both produce a confident wrong answer.
The reliable form is to pipe a **script file** to `ssh 'bash -s'`
(`artifacts/e2e-o5/daemon_probe.sh`) and read plain counted output. Daemon
absence at 14:38–14:39 was nonetheless corroborated by an independent oracle
(no listener on port 3005), and presence at 14:56 by two (pid + listener).

## §22 — `3b1e8435` scored, and the limit of a logo as a probe

Measured 16:01-16:05, provenance-locked (`corename=Plex md5=3b1e8435`, asserted
before *and* after grading pixels, same boot).

* **VALID WITH CONTENT.** mean_luma 36.37 (black threshold 8.0), spatial_std
  22.27 (flat threshold 3.0), filler_frac 0.0001 (no-signal threshold 0.50),
  10/10 unique frame hashes. Denominator 10 frames of 12 grabbed.
* Frame 1 of the burst was **100% filler RGB(7,7,7)** while frames 3..12 were
  content — a natural red/green control for the filler fix on live hardware.
* **Chevron masks are bit-identical between `fb4bad84` and `3b1e8435`**
  (IoU 1.0000, 14905/14905 px, same bbox). Left-edge artifact MOVING on both,
  temporal std 5.70 vs 5.68-6.19, pillar edge column 128 on both.

**The transferable lesson: an image can be a valid A/B on its inputs and still
be a vacuous probe on its outputs.** The two bitstreams really do differ, and
really do differ *only* in the SDC — the comparison varies its independent
variable, so it is not the parent's four-builds-one-SDC error. But the chevron
is painted from DDR content that persists with `misterplexd` dead and across a
reboot (§19, §21), so it **does not depend on the DDR write path the SDC is
suspected of breaking**. A bit-identical logo therefore exonerates video timing
and scanout, and says nothing about the write path.

Before citing any comparison as evidence, check vacuity at **both** ends:
does the input actually vary the variable, **and** does the output actually
depend on it?

## §23 — `scripts/mutation_check.py`, the mechanical vacuity check

Promoted my one-off harness to a reusable, spec-driven tool so any worker can
prove a gate is non-vacuous. `--self-test` is 6/6 and is registered in the
Makefile and the rollcall.

Its own red proof is built in: the self-test contains a deliberately weak test
that only exercises one branch, and the harness reports `SURVIVED` for it.
Refuses (rc=2) on a red baseline — otherwise every mutation appears "killed"
and the tool reports a confident, meaningless green. Refuses an empty mutation
list and a no-op mutation (`old == new`), both of which are vacuous controls by
construction.

Real use: `artifacts/e2e-o5/mutation_spec_capture_gates.json`, 17 mutations
across `score_idle_screen.py` and `capture_preflight.py` -> **17/17 killed**.
This harness has already caught a real vacuity in my own work: two fill-gate
mutations survived because my regression frame was rejected on *aspect* before
the fill check ran (§18).

## §24 — FABRIC vs FILE: w-e2e's §12.1 correction is right, and here is the mechanism

The outgoing w-e2e warned that "file != fabric" and that the 12:09 content was
probably `00eebd5e` rather than `fb4bad84`. **That warning is correct and it
applied to my own provenance guard.** `--expect-rbf-md5` hashes
`/media/fat/_Utility/Plex.rbf` — the file on the SD card — which is not proof of
what is configured into the fabric.

**Mechanism (measured, `scripts/deploy_plex_core.sh:34,191-194`):**
`DEPLOY_LOAD` defaults to **`none`**, which copies the RBF and deliberately does
*not* call `load_core` ("RBF on SD only; not calling load_core (safest)").
So after a default deploy the file carries the new md5 while the fabric still
runs the previous bitstream and paints every pixel you are about to grade. The
md5 check passes and the capture is attributed to the wrong build.

**Why there is no readback.** No bitstream readback exists on this part, and
there is no fabric-published build ID — I searched the RTL and
`host/libmisterplex/mailbox_abi_spec.hpp`; the mailbox words are DDR, which
survives reconfiguration, so they cannot identify the fabric either.

**The fix is ORDERING.** `/tmp/CORENAME` is rewritten by Main when a core loads,
so mtime of the RBF <= mtime of /tmp/CORENAME proves the load happened after the
file was in place and therefore configured the fabric from those bytes. Added
`--require-fabric-provenance` to `scripts/score_idle_screen.py`; without it the
md5 flag is a file check only, and its `--help` now says so.

Measured on the live device: rbf_mtime=14:56:44, CORENAME mtime=16:00:16,
**delta +3812 s** -> my 16:01 capture of `3b1e8435` is fabric-sound.

**Correction to my own §22.** The `3b1e8435` side of that A/B is now
fabric-proven; the `fb4bad84` side is **file-provenance only** — I never recorded
the load-ordering for those 14:xx captures and cannot reconstruct it. So
"chevron bit-identical between fb4bad84 and 3b1e8435" must be downgraded to
"bit-identical between the fabric running at 14:xx (file said fb4bad84) and the
fabric proven to be 3b1e8435 at 16:01". The display-path exoneration survives;
the build label on one side does not.

## §25 — RGB(7,7,7) is not a black screen, and it is not an ambiguous result

w-e2e reported an 18-frame clip and a 240-frame bounce probe as
`BLACK_SIGNAL, flat RGB(7,7,7), std=0.0`, and called it AMBIGUOUS between
"MiSTer offline" and "valid but black". **It is neither.** RGB(7,7,7) is the
MS2109 capture device's own no-lock filler: it is emitted by the *receiver* when
it is not locked to a source, so it carries no information about the FPGA at all.

Because 7 < the black-luma threshold of 8.0, the old classifier tested luma
before flatness and graded a completely unlocked capture as a black screen —
then blamed the core whenever the host happened to be pingable. Fixed in
`capture_preflight.classify_signal` (filler dominance is tested first).

Verified today on a live frame with exactly that signature
(mean_luma=7.0 spatial_std=0.0, 100% filler): the gate now returns
**rc=2 NO_SIGNAL / UNSCORED**, with a note stating it is not evidence of a black
screen and not evidence of a core defect.

**Consequence for the proposed bounce discriminator:** watching for a NO_SIGNAL
gap during a core bounce cannot work when the capture is *already* unlocked —
there is no locked state to drop out of. The question it was meant to answer is
answered directly instead: this device has since produced CONTENT_PRESENT frames
(mean luma 36.37), so the HDMI output path is alive, not dead.

## §26 — RBF-md5 binding is necessary but NOT sufficient (extends the parent's fleet rule)

The parent has made md5 binding mandatory for every gate that reads a fit
report, on `w-arm-o5`'s evidence that 40 fit reports exist here and 35 describe
builds nobody runs. That rule is right. **It does not go far enough.**

`md5(/media/fat/_Utility/Plex.rbf)` identifies the **file on the SD card**, not
the **fabric**. `scripts/deploy_plex_core.sh:34` defaults to `DEPLOY_LOAD=none`,
which copies the RBF and deliberately does not call `load_core`. After a default
deploy the file carries the new md5 while the previous bitstream is still
configured and painting every pixel. So a gate can be perfectly **BOUND** — the
report matches the file md5, exactly as the rule demands — **and still describe a
build nobody is running.** That is the same failure the binding rule exists to
prevent, moved down one level.

It cannot be closed by readback: no bitstream readback exists on this part, and
there is no fabric-published build ID (mailbox words are DDR, which survives
reconfiguration). So it is closed by **ordering** — `/tmp/CORENAME` is rewritten
when a core loads, so an RBF mtime at or before the CORENAME mtime proves the
load read those bytes.

`scripts/fabric_provenance.py` implements this for any gate, including shell
gates, with one call. Verdicts, only the first of which is a pass:

    BOUND  UNBOUND  UNREACHABLE  MD5_MISMATCH  STALE_FABRIC  ORDER_UNKNOWN

`UNREACHABLE` and `ORDER_UNKNOWN` exist so a missing measurement can never be
laundered into a pass — the parent's "report it as unseen, never as absent".
There is deliberately no exit 1: this tool never reports a product defect, only
whether a claim has a subject.

Measured live: `BOUND`, core loaded **3812 s** after the RBF was written.
Control on the same healthy device with the md5 omitted: `UNBOUND`, rc=2 —
proving UNBOUND is about the claim lacking a subject, not about device health.

**Mutation testing caught a vacuity in this module too**, the second time in one
session. `ordering-comparison-inverted` SURVIVED because the self-test fixtures
pre-set `load_after_write`, so the comparison that computes it was never
executed by any test. Fixed by extracting `compute_load_after_write()` and
testing it directly. Now 14/14 self-test, 8/8 mutations killed.

**Generalisable lesson: a hand-built fixture can silently bypass the very
computation the test claims to cover.** If you construct the derived field
yourself, you are testing your fixture, not the code.

## §27 — Device availability, measured rather than asserted

Reported offline by the parent at 16:48 ("ping 100% loss, ssh rc=255,
independently confirmed"). Measured from this host at the same time:

    16:48:51  ping 3/3, 0% loss, rtt 5.4-31.3 ms
    16:48:51  ssh rc=0, uptime 9145 s (continuous; no reboot since 16:10)
    16:49:31 - 16:53:29  60/60 UP, zero flaps, 4 s interval

Denominator 60. The device is on WiFi with high RTT variance, so single-probe
failures are plausible — but a 60/60 sample rules out a device that is off the
network. This is the third status cycle reporting offline while it was
reachable. **Availability should be reported as a rate with a denominator, not
as a binary**; two workers can otherwise both be honest and contradict each other.

## §28 — CLOSED: option A vs option B. No bounce probe was needed.

W-E2E (original) handed over an open question: is the HDMI output (A) valid but
black with the DDR write path dead, or (B) completely dead with clk_ddr/timing
stuck — and asserted that "only a bounce-during-capture can settle it."

**It is settled, and not by a bounce.** Measured 17:03, fabric-bound:

```
FABRIC_PROVENANCE: BOUND   corename=Plex rbf_md5=3b1e8435 fpga_state=operating
                           load_after_write=True (delta 3812s)
SIGNAL_STATE: CONTENT_PRESENT   mean_luma=36.38  spatial_std=22.25  unique=12/12
PLEX_CHEVRON: PRESENT  14928 px  bbox [484,239,707,479]
LEFT_EDGE_DYNAMICS: MOVING  std 5.8532 vs noise floor 0.0  (SNR 117.1x)
                            pillar edge column 128, stable
```

**Option B is refuted.** Video timing is alive: the receiver holds a 1280x720@60
lock and the fabric renders a structured picture at mean luma 36.38 against a
black threshold of 8.0. A stuck clk_ddr/reset_ddr cannot produce that.

**Option A is what the evidence supports, with one part upgraded.** The present
path is not merely alive, it is actively refilling: the left-edge artifact varies
frame to frame at 117x the capture's own noise floor, and per the parent's
mechanism (`y_valid[fill_idx] <= 1'b1` asserted only at whole-line completion)
that artifact is *produced by* line-buffer refill timing. Refill implies active
**DDR reads**. So:

| path | verdict | evidence |
|---|---|---|
| video timing / HDMI out | **ALIVE** | CONTENT_PRESENT, stable lock, 12/12 unique |
| DDR read / scanout / refill | **ALIVE** | MOVING artifact, SNR 117x; present_core -> ddr_frame_store survive synthesis |
| DDR write (fabric -> DDR) | **NOT ADDRESSED by capture** | w-fit-o5's poke-probe is the oracle |

**Why the bounce probe could never have worked.** It looked for a NO_SIGNAL gap
during a core load, on the reasoning that FPGA I/Os tri-state during
reconfiguration. But the 258 frames that motivated it were flat **RGB(7,7,7)**,
which is the MS2109's own no-lock filler — the capture was *already* unlocked, so
there was no locked state to drop out of. Every frame of that probe would have
read identically whether or not a bounce occurred. The probe was inconclusive by
construction, not by bad luck with the timing window.

That also means the "258 frames all BLACK_SIGNAL" figure should not be carried
forward as evidence about the FPGA: it is 258 frames of an unlocked receiver,
which is UNSCORED. Same measurement, correct verdict, opposite implication.
