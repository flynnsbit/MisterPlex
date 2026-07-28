# W-OSD handoff — MiSTerPlex

## 1. Identity

- Worker ID: W-OSD
- Branch: `w-osd-neighbor`
- Worktree: `/home/flynnsbit/Projects/MisterPlex/.worktrees/w-osd-neighbor`
- Latest implementation commit: `4bd03780615e982fb525a048d04d19226eab3624 feat(osd): show build identity in idle`
- Handoff commit: this file is committed on top of that implementation commit; use `git log -1` for the containing commit SHA (self-referential SHA cannot be embedded before commit).
- Secure state before handoff:
  - `git push origin w-osd-neighbor` twice: `push1_rc=0 push2_rc=0`
  - `git status --short`: clean (no output)

## 2. Assignment

I started as W-OSD investigating the user-visible idle/screensaver Plex-logo black screen. That split proved the logo renderer/fb0 path was healthy and the `PRESENT=fpga` failure matched W-SWAP's bank-release livelock. I was then reassigned to build full-frame reconstructed-neighbour context for H.264 intra prediction, wire it to the consumer, and prove product reachability. After the human-observer ban, I converted my idle-logo hardware gate to use USB-HDMI scoring. My final task before handoff was to add a visible build/RBF identity so the user and gates can tell which RBF is actually running.

## 3. What is DONE and PROVEN

### Idle/screensaver black-screen split

Measured, not assumed:

- `PRESENT=fb0` readback matched two expected idle logo byte values:
  - background: `26_23_1f_ff`
  - foreground: `0d_a0_e5_ff`
- `PRESENT=fpga` then showed the frame-store livelock signature:
  - `free_bank_mask=0`
  - `swap_pending=1`
  - earlier card also recorded `hi=0x94FB0008`, `frames_done=38139`
  - daemon log contained `[STALL] sendDdrFrame: PLXD bank-release timeout ... swap_pending=1`
- With HDMI capture scoring added, the resident known-bad RBF produced:
  - `FB0_PROXY=PASS`
  - PLXD `free_bank_mask=0 swap_pending=1`
  - HDMI classifier `VALID_BLACK mean=7 std=0`
  - final result `IDLE_SPLIT_RESULT=FAIL reason=hdmi-valid-black`, `rc=1`

Important limit: the fb0 readback only proved two sampled byte values. It did **not** cover line stride, shear, whole-frame geometry, or HDMI presentation. The user's later gray-background/jagged-left-lines report remains compatible with a pitch/stride bug; W-ARM owns that RCA.

### Reconstructed-neighbour context

Implemented and committed before the build-id work:

- Full-width PRE-deblock reconstructed-neighbour storage for measured coded frame `624x480` = `39x30` = `1170` MBs, no partial MBs.
- Stores/exports:
  - luma top row `39*16`
  - luma left column `16`
  - luma above-left
  - luma above-right needed for 4x4 modes
  - chroma U/V top/left/top-left storage
  - semantic availability flags for picture/slice edges
- Adapter outputs agreed with W-DECODE:
  - `mb_avail_left`
  - `mb_avail_top`
  - `mb_avail_topright`
  - `mb_avail_topleft`
  - `nb_top[0:15]`
  - `nb_left[0:15]`
  - `nb_topleft`
  - `nb_topright[0:3]`
- MB0 external neighbours correctly unavailable; 128 fallback is legitimate only there and at real unavailable edges.
- Right picture edge above-right is unavailable per H.264 Table 6-3.
- `first_mb_in_slice` added so availability is semantic, not merely storage-valid; neighbours across slice boundaries are unavailable.

Validation/evidence already run earlier:

- `python3 tests/unit/test_h264_intra_nb_ctx_verilator.py`
  - prints `Scope:` first
  - green result: PASS with `checks=252`, denominator `1170` MBs (`39x30`)
  - covers interior, left edge, top edge, right-edge above-right unavailable, last MB, and slice-boundary masking
- Red checks:
  - `H264_INTRA_NB_CTX_FAULT_STUB_NEIGHBORS` forces neighbours back to 128 and fails
  - `H264_INTRA_NB_CTX_FAULT_SWAP_CHROMA_UV` swaps chroma U/V and fails
  - `H264_INTRA_NB_CTX_FAULT_EDGE_AVAILABLE` reports edge neighbours available and fails

Reachability before the new topology ruling:

- W-GATE script result for `h264_intra_nb_ctx` under the old `DECODE_REAL_INTRA=1` stream_path branch:
  - default: `DEFAULT_OFF_DEFINE_REACHABLE_MODULE h264_intra_nb_ctx defines=DECODE_REAL_INTRA=1`
  - with `--define DECODE_REAL_INTRA=1 --list-reachable`, `h264_intra_nb_ctx`, `h264_decode_top`, `h264_intra4x4_pred`, and `h264_intra16x16_pred` were reachable together
- This is now architecturally superseded: the context must feed `h264_decode_top` as a sub-engine inside `h264_decode_core`, not as a mutually exclusive `stream_path` alternative.

### HDMI/capture scoring for idle-logo gate

Implemented:

- `scripts/hdmi_capture_classify.py`
  - uses `/dev/video0` by default
  - MS2109 expected mode: MJPG only, `1280x720@60`
  - classifies `NO_SIGNAL`, `VALID_BLACK`, `VALID_CONTENT`
  - uses project-local `build/` lock, not `/tmp`
- `tests/unit/test_hdmi_capture_classify.py`
  - synthetic content/black/no-signal unit coverage
  - red-check: black is not content; no-signal is not content
- `tests/hw/test_idle_present_split.sh`
  - now scores HDMI automatically and no longer asks human eyes

Known hardware fact: `/dev/video1` enumerates but has zero formats and is a decoy. It is useful as a red/no-signal operand. Do not use raw YUYV; the device advertises MJPG only.

### RBF/build identity

Commit: `4bd03780615e982fb525a048d04d19226eab3624 feat(osd): show build identity in idle`

Done:

- Added source/build identity in fabric sidebar `CONF_STR` `V` entry:
  - `sys/build_id.tcl` now generates both `BUILD_DATE` and `BUILD_ID`
  - `BUILD_ID` format: `YYMMDD-<git8>[D]`, where `D` means dirty tree at build time
  - `Plex.sv` uses `` `BUILD_ID `` in the `V` entry
- Added actual deployed-RBF md5 label in daemon idle/logo renderer:
  - new `host/libmisterplex/rbf_identity.hpp`
  - computes short uppercase md5 from `md5sum <path>`
  - default path: `/media/fat/_Utility/Plex.rbf`
  - conf override: `RBF_ID_PATH=...`
  - displayed idle label: `RBF XXXXXXXX`
  - daemon log line: `misterplexd: BUILD_ID_LABEL=RBF XXXXXXXX source=/media/fat/_Utility/Plex.rbf`
- Added glyph rendering in `idle_screen.hpp`; label is rendered for logo/screensaver/last non-black idle modes. `IDLE_SCREEN=black` deliberately remains black.

Honesty/assumption boundary:

- A true final self-md5 in the fabric/sidebar is not achievable honestly without a circular hash: the RBF md5 includes the bits used to display that md5, so embedding it changes the operand. I did **not** fake it.
- The sidebar `BUILD_ID` is a source/build id, not a final artifact md5.
- The idle overlay `RBF XXXXXXXX` is derived from the actual file operand at daemon startup, but after deploy it still needs W-E2E/W-FIT hardware proof that the label is visible on HDMI.

Exact validation after `4bd0378`:

- `make "$PWD/build/test_osd_menu" > build/w-osd-rbfid-test_osd_build.log 2>&1 && build/test_osd_menu > build/w-osd-rbfid-test_osd.log 2>&1`
  - `rc=0`
  - log: `Scope: OSD word decode plus idle renderer, including RBF build-id label pixels`; `test_osd_menu: OK`
- `tests/unit/test_osd_menu_red.sh > build/w-osd-rbfid-red.log 2>&1`
  - `rc=0`
  - includes `RED OK: two different RBF identifiers render different visible labels`
- `make arm-plexd > build/w-osd-rbfid-arm-plexd.log 2>&1`
  - `rc=0`
  - built ARM `misterplexd`, `push_frame`, `set_status`, `input_mailbox_probe`
- `make define-parity > build/w-osd-rbfid-define-parity.log 2>&1`
  - `rc=0`
  - `PASS define parity: Quartus product macros match Verilator/lint; test-only macros are allowlisted`
- `make quartus-sv-subset > build/w-osd-rbfid-quartus-sv-subset.log 2>&1`
  - `rc=0`
  - `STATIC_PASS Quartus SV subset pattern scan: 36 file(s) ... not_a_Quartus_analysis_or_synthesis_PASS`
  - `VERILATOR_ELAB_PASS: no owned RTL elaboration errors`
- `tests/unit/test_confstr_guard.sh > build/w-osd-rbfid-confstr.log 2>&1`
  - `rc=0`
  - red malformed CONF_STR rejected, checked-in CONF_STR green
- `python3 tests/unit/test_unit_rollcall.py > build/w-osd-rbfid-rollcall.log 2>&1`
  - `rc=0`
  - `UNIT_ROLLCALL_OK actual_prereqs=33 expected_prereqs=33 actual_commands=91 protected_commands=88 expected_commands=88 actual_ignored_commands=3 expected_ignored_commands=3`
- `tests/unit/test_no_private_data.sh > build/w-osd-rbfid-no-private-data.log 2>&1`
  - `rc=0`
  - `test_no_private_data: OK`
- `git diff --check > build/w-osd-rbfid-diff-check.log 2>&1`
  - `rc=0`
- `make unit > build/w-osd-rbfid-make-unit.log 2>&1`
  - `rc=0`
  - skip summary had one high skip from an existing live PMS wrapper missing deps red-check, not caused by my changes:
    - `GATE_SKIP_SUMMARY total=1 critical=0 high=1 advisory=0`
    - `reason=OK red-check: live PMS wrapper missing deps return SKIP-NOT-PASS rc=77`

## 4. What is IN PROGRESS

No uncommitted code is in progress. Worktree is clean at `4bd0378` and pushed twice.

Architectural next step created by the latest parent ruling:

- My neighbour context currently exists and was previously wired in the old `stream_path.sv` `DECODE_REAL_INTRA=1` branch to `h264_decode_top`.
- The binding topology now says `h264_decode_core` is the product decoder and `h264_decode_top` is only an intra-MB sub-engine inside that core.
- Therefore the next concrete step is **not** to keep expanding the `DECODE_REAL_INTRA` alternate branch. Instead, integrate `h264_intra_nb_ctx` into/around `h264_decode_core` so its adapter outputs feed the `h264_decode_top` sub-engine when W-DECODE instantiates that sub-engine inside the core.
- I made no RTL edits after that topology ruling; successor should start clean from `4bd0378` and coordinate with W-DECODE before touching `h264_decode_core.sv`.

RBF identity remaining proof:

- The code and unit gates are committed, but hardware visibility is not yet proven on HDMI.
- `tests/hw/test_rbf_identity_label.sh` is registered as a non-capture operand/log comparison card, but a true visual/OCR/pixel proof must be owned by W-E2E after W-FIT deploys the new daemon/RBF. I did not open `/dev/video0`.

## 5. What I TRIED THAT DID NOT WORK

- Human-eye visual gates: originally correct when no capture device existed, now superseded. Any gate asking the user to look is wrong. My idle split was converted to USB-HDMI scoring.
- Treating capture success as visual success: wrong. Resident RBF `00eebd5e` captures successfully while screen is valid black. Gates must distinguish `NO_SIGNAL`, `VALID_BLACK`, and `VALID_CONTENT`.
- `/dev/video1`: opens/enumerates as a V4L2 node but has zero formats. It is a decoy/no-signal red operand, not a capture device.
- Raw YUYV capture: wrong for this MS2109. Device is MJPG only; archived YUYV tearing likely came from attempting unsupported raw modes.
- fb0 byte spot-check as proof of full logo correctness: insufficient. It proved asset/renderer byte values at two sample points only. It cannot catch wrong pitch/stride/shear, which matches the user's jagged-left-lines report.
- Exact final RBF md5 in fabric/sidebar: not honest because of circularity. Embedding a hash changes the hashed artifact. Closest honest split is source/build id in fabric sidebar plus runtime md5 label from actual deployed file.
- Old `DECODE_REAL_INTRA=1` product assumption: now refuted by W-GATE/W-DECODE topology analysis. It made intra modules reachable but deleted MC/DPB/deblock modules, so it cannot decode the measured stream (`343 P / 7 IDR`, real P-frame heavily skipped). Do not extend that alternate branch as the product decoder.
- Unit test green without reachability: not enough. My neighbour context was module-verified before product reachability was checked; that exact pattern has caused multiple false-complete claims in this repo.

## 6. Gates I own

### `tests/unit/test_h264_intra_nb_ctx_verilator.py`

- Run: `python3 tests/unit/test_h264_intra_nb_ctx_verilator.py`
- Current green: rc 0, prints `Scope:` first, `checks=252`, denominator `1170` MBs.
- Literally compares: exact luma/chroma neighbour bytes, MB adapter bytes/availability, edge/right-edge/last-MB/slice-boundary behavior.
- Does not cover: entropy parsing, residual math, deblock, DPB post-deblock refs, MC, HDMI, or product decode correctness.
- Red-checks:
  - `H264_INTRA_NB_CTX_FAULT_STUB_NEIGHBORS=1` -> forces neighbours to 128 -> fails.
  - `H264_INTRA_NB_CTX_FAULT_SWAP_CHROMA_UV=1` -> swaps chroma -> fails.
  - `H264_INTRA_NB_CTX_FAULT_EDGE_AVAILABLE=1` -> reports unavailable edges available -> fails.

### Reachability check for neighbour path

- Script: `scripts/check_rtl_module_instantiations.py`
- Previously used to prove old branch classification:
  - default: `DEFAULT_OFF_DEFINE_REACHABLE_MODULE h264_intra_nb_ctx defines=DECODE_REAL_INTRA=1`
  - `--define DECODE_REAL_INTRA=1 --list-reachable`: `h264_intra_nb_ctx`, `h264_decode_top`, `h264_intra4x4_pred`, `h264_intra16x16_pred` reachable together.
- This must now be rewritten/reinterpreted for the binding topology: the desired proof is product reachability through `h264_decode_core`, not the old `DECODE_REAL_INTRA` alternative.
- Red-check used earlier: remove/misclassify `h264_intra_nb_ctx` and the classifier returns `rc=1`; restore returns green.

### `tests/hw/test_idle_present_split.sh`

- Run only with capture ownership coordinated through W-E2E if it opens `/dev/video0`.
- Current known resident bad-build behavior: returns `rc=1`, not PASS, with HDMI `VALID_BLACK` and PLXD livelock.
- Literally compares:
  - fb0 sampled logo bytes
  - PLXD telemetry
  - HDMI classifier state (`NO_SIGNAL`, `VALID_BLACK`, `VALID_CONTENT`)
- Does not cover: exact full-frame stride/shear, decode correctness, or post-W-SWAP fixed RBF until W-FIT deploys one.
- Red-checks:
  - `FB0_EXPECT_FG=00_00_00_00 tests/hw/test_idle_present_split.sh` fails with `fb0-logo-foreground-mismatch`.
  - `scripts/hdmi_capture_classify.py` expecting content on `/dev/video1` returns `NO_SIGNAL`/nonzero.
  - expecting content on known valid-black capture returns nonzero.

### `scripts/hdmi_capture_classify.py` and `tests/unit/test_hdmi_capture_classify.py`

- Unit run: `python3 tests/unit/test_hdmi_capture_classify.py`
- Current green: rc 0 in earlier validation.
- Literally compares: synthetic frames and capture/file input into `NO_SIGNAL`, `VALID_BLACK`, `VALID_CONTENT` buckets.
- Does not cover: semantic correctness of the video content, OCR, which RBF generated the frame.
- Red-check: black frame expected as content fails; invalid/no-format device expected as content fails.

### `build/test_osd_menu` plus `tests/unit/test_osd_menu_red.sh`

- Build/run:
  - `make "$PWD/build/test_osd_menu"`
  - `build/test_osd_menu`
- Current green: `Scope: OSD word decode plus idle renderer, including RBF build-id label pixels`; `test_osd_menu: OK`.
- Red script: `tests/unit/test_osd_menu_red.sh`
- Current red/green: rc 0; includes existing OSD red-checks and new `RED OK: two different RBF identifiers render different visible labels`.
- New failure macro: `MISTERPLEX_FAULT_RBF_ID_LABEL_CONSTANT` renders every build label as `RBF 00000000`; test catches `idDiff > 0` failure.
- Literally compares: visible idle-label pixels differ for two labels and md5 labels derived from two different local files are `RBF 0CC175B9` and `RBF 92EB5FFE`.
- Does not cover: HDMI visibility, MiSTer sidebar rendering, deployed daemon restart, or file path correctness on the device.

### `tests/hw/test_rbf_identity_label.sh`

- New hardware card, executable, committed.
- Run after deploy/daemon restart: `tests/hw/test_rbf_identity_label.sh`
- Literally compares:
  - `md5sum /media/fat/_Utility/Plex.rbf` on the device
  - `BUILD_ID_LABEL=RBF XXXXXXXX` in `/media/fat/misterplex/misterplexd.log`
- Does not cover: HDMI OCR/sidebar pixels; it is a provenance/log operand check.
- Red-check: `RBF_ID_EXPECT_SHORT=00000000 tests/hw/test_rbf_identity_label.sh` should fail unless the actual md5 short is coincidentally zero.
- Skips: exits 77 through `hw_skip_not_pass` if `sshpass`, md5 read, or log read is unavailable.

### `tests/unit/test_confstr_guard.sh`

- Run: `tests/unit/test_confstr_guard.sh`
- Current green after build-id change: rc 0; malformed CONF_STR red rejected; checked-in CONF_STR green.
- Failure mode: corrupt F-entry comma fields; script catches malformed field counts.

## 7. Interfaces agreed with other workers

### W-DECODE

Agreed adapter shape from `h264_intra_nb_ctx` to intra consumer:

- `mb_avail_left`
- `mb_avail_top`
- `mb_avail_topright`
- `mb_avail_topleft`
- `nb_top[0:15]`
- `nb_left[0:15]`
- `nb_topleft`
- `nb_topright[0:3]`

Semantics:

- PRE-deblock reconstructed samples only.
- Semantic availability, not storage-valid availability.
- MB0 external neighbours false/128.
- Top edge false.
- Left edge false.
- Right picture edge above-right false.
- Slice boundary neighbours false even if bytes exist in storage.
- Consumer falls back to 128/replicate internally when availability is false.
- Under new topology, these ports feed `h264_decode_top` only as an intra-MB sub-engine inside `h264_decode_core`.

Latest W-DECODE state reported to me:

- Current `w-decode-hour27` still hard-wires MB0 external neighbours while focusing all-16 residual/mode feed.
- W-DECODE says next consumer integration should replace constants with my adapter outputs.
- W-DECODE evidence after all-16 residual feed: `DECODE_REAL_INTRA diff 76794/76800`, MB0 RGB565 exact `74/256`, still not bit-exact.

### W-DEBLOCK

Contract:

- Intra prediction reads PRE-deblock neighbour context.
- DPB/reference samples are POST-deblock and become visible only after filtered samples write back plus frame boundary.
- DPB/post-deblock refs must never drive `h264_intra_nb_ctx`.
- W-DEBLOCK planned/owns swapped-tap red-check for this seam.

### W-E2E

- W-E2E owns `/dev/video0`; do not open it concurrently.
- I added capture classification and idle gate logic, but did not grab the device after the ownership rule.
- For RBF identity, W-E2E should own the real HDMI proof (OCR/pixel classification) after W-FIT deploys. My new hardware card only compares md5/log label.

### W-ARM / W-ARM-O5

- I explicitly told W-ARM that my fb0 logo proof was only two byte samples and does not rule out pitch/stride/shear.
- W-ARM owns the gray-background/jagged-left-lines idle artifact RCA. I did not duplicate that work.
- My new `RBF XXXXXXXX` idle label uses the same idle renderer/present path, so any stride issue may affect the label.

### W-GATE

- Reachability must be proven with `check_rtl_module_instantiations.py`, not inferred from unit tests.
- My old neighbour reachability result is honest but under the old default-off topology; successor must update the desired classification to the new `h264_decode_core` product topology.

### RBF identity runtime interface

- On-device conf optional key: `RBF_ID_PATH=/media/fat/_Utility/Plex.rbf`.
- Default if unset: `/media/fat/_Utility/Plex.rbf`.
- Daemon label format: `RBF XXXXXXXX` uppercase short md5.
- Daemon log: `misterplexd: BUILD_ID_LABEL=RBF XXXXXXXX source=<path>`.

## 8. Open risks and anything I believe is wrong

- Biggest risk: my neighbour producer is still wired in the old `stream_path.sv` `DECODE_REAL_INTRA=1` branch from before the architectural ruling. That branch is no longer the product decoder. The next worker must move/reattach the context so it is product-reachable through `h264_decode_core` and its `h264_decode_top` sub-engine.
- `DECODE_REAL_INTRA=1` reachability is no longer a success criterion by itself. It can make intra reachable while deleting MC/DPB/deblock, which cannot decode measured live content (`343 P / 7 IDR`; real P-frame mostly skipped). Any gate that reports that as product PASS is wrong.
- RBF identity is not yet HDMI-proven. The code is unit-proven and log/provenance-carded, but W-E2E must still prove visible pixels after deployment.
- Idle/logo renderer proof remains vulnerable to stride/shear bugs. My two-byte fb0 green must not be quoted as a whole-image PASS.
- `IDLE_SCREEN=black` intentionally suppresses the build-id overlay. If the lab wants identity always visible even in black mode, that is a product decision, but it conflicts with the burn-in-safe exact-black semantics currently tested.
- The hardware `test_rbf_identity_label.sh` reads the daemon log. If the daemon has not restarted since the RBF changed, the log may be stale. The card compares label to current md5, so it should fail rather than pass stale state, but the deploy workflow should restart/repaint before scoring.
- Handoff is committed at `handoffs/misterplex-handoff-w-osd.md` per the corrected parent instruction.
