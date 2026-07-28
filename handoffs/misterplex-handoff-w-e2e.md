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
