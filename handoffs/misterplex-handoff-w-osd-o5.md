# Handoff — W-OSD-O5

Branch `w-osd-o5` (worktree `.worktrees/w-osd-o5`), based on `bad31de` (`w-osd-neighbor`).
Commits: `f265abe` build identity, `acba80f` idle RCA, `85e5864` screensaver/OSD_CONTROL.
Everything below is **measured** unless it says assumed.

## Read this first: the device needs a physical power cycle

The MiSTer at `192.168.1.183` is **wedged** and I could not recover it without a human.

* HDMI still carries valid 1280x720 timing, but the picture is uniform level 7 with `std=0`.
* ARP for `192.168.1.183` has been `INCOMPLETE` for over 20 minutes; the network stack is gone.
* It went down during a run that re-asserted the OSD selection **80 times at 0.3 s intervals**
  via `set_status` (UIO/SPI), contending with Main's own status writes. An earlier, gentler run
  (40 × 0.4 s) survived. **Cause is assumed, not proven.**
* `tests/hw/test_osd_screensaver_selects.sh` now caps this at 32 writes, ≥400 ms apart, and
  refuses to run outside those bounds.

State it was left in: `OSD_CONTROL=1` in `/media/fat/misterplex/misterplex.conf`
(original backed up to `misterplex.conf.bak-wosdo5`), daemon healthy, `/media/fat/misterplex/wosd_ruler.yuv`
left on the SD card. All hardware cards return **UNSCORED (77)** while it is down — none of them
can turn an unreachable device into a pass.

## What I confirm from the predecessor

* The `fb0` logo byte values (`26_23_1f_ff` background, `0d_a0_e5_ff` foreground) are still correct.
* `shouldApplyOsdIdle()` really does neutralise a saved OSD word, and the deployed daemon has it.
* The frame-store swap path works.

## What I found is NOT true

* **The idle screen is not black.** On RBF `fb4bad84` the Plex logo renders. The user's black screen
  is explained by the persisted MiSTer status word `0x4000` (idle bits `01` = Black) combined with a
  daemon that predated `shouldApplyOsdIdle()`. Measured: with `OSD_CONTROL=1` the current daemon
  reads persisted `0x6000`, logs `idle=1 (idle unchanged)`, and paints the **logo**.
* **`w-arm-o5`'s assigned mechanism is refuted for the idle case.** "The ARM writes into the bank
  being scanned out" cannot be the cause: the damage is byte-identical with the daemon killed
  (`pidof` = none) and the `PLXK` doorbell sequence frozen across both captures. Give them this
  measurement before they spend a slot on stride candidates.
* **Stride is not the idle defect.** A ruler test frame (rulers every 32 source px) renders with
  correct horizontal and vertical alignment; ruler columns land within ±3 capture px of prediction.
  The 640 / 624 / 618 / `PRESENT_X=11` candidates remain untested for *other* symptoms, but they do
  not explain this one.
* **The `V`-entry build id would have been `nogit` on every remote fit.** `build_rbf_remote.sh`
  rsyncs only `fpga/Plex_MiSTer/` into a Docker slot with no `.git`, so `git rev-parse` inside
  `build_id.tcl` always failed. Confirmed against `remote_out/slot11/compile.log:32`, which emitted
  `BUILD_DATE` only. The predecessor's date+git scheme was real, but it degenerated in exactly the
  environment it was meant to serve.
* **`mailbox_abi_spec.hpp` was pointing at a dead window.** It declares `0x3007F0xx/1xx`, the
  `0x40000`-stride addresses. `present_core.sv` uses the `0x80000` YUV stride, so the live window is
  `0x300FF000`. The stale window still returns correct magics — frozen, from an older core. I lost
  time to this; the header now says so and derives both windows from `doorbellForStride()`.
* **`VALID_BLACK` from `hdmi_capture_classify.py` does not mean "nothing drawn".** The working
  screensaver grades `VALID_BLACK`, because a small moving logo on black has a low mean.
* **`VALID_CONTENT` does not mean the screen is right.** The damaged idle frame grades
  `VALID_CONTENT`. Both traps are why the two new pixel graders exist.

## The three hypotheses, decided

`tests/hw/test_idle_screen_pixel_rca.sh` → **`PRESENTED_CORRUPT`**.

| Hypothesis | Verdict | Evidence |
|---|---|---|
| Nothing drawn | refuted | Both DDR banks hold a real I420 frame (`Y=0x2d`, `U=0x82`, `V=0x7e`) |
| Wrong address/stride | refuted | Ruler frame renders aligned; swap reaches `disp_bank=1` in <1 s |
| Drawn then overwritten | refuted | Identical damage with daemon killed and doorbell frozen |

**Actual mechanism:** a per-scanline DDR read underrun inside the presentation path. Every line loses
a ragged, per-frame-random leading run; picture rows start between capture x=84 and x=136 against a
budget of 8; `PLXF` underrun is saturated at `0xFFFF`. **This needs an RBF change** — `w-fit-o5`'s
slot. Not fixable from the ARM. Not root-caused further: whether it is DDR arbiter bandwidth, the
`LINE_COUNT=8` prefetch depth, or a scanout-start race is **still open**.

Evidence: `tests/fixtures/hw_visual/idle_rca_fb4bad84/`.

## "The screensaver still dont work" — cause and fix

`MediaPlayer::startOsdPoll()` returns before starting its thread when `osdControl_` is false. With
`OSD_CONTROL=0` the OSD word is never read, so **every** live menu item — Idle screen, Video delay,
A/V resync, Audio clock trim, Content resolution — silently does nothing. Nothing logs an error.

Measured, same OSD selection (Screensaver), only the conf line differing:

| `OSD_CONTROL` | Daemon log | Bright-centroid travel |
|---|---|---|
| `0` | only `idle screen painted (mode=0)` | **0.0 px** (STATIC) |
| `1` | `OSD word=0x8000 … idle=2` → `idle screen painted (mode=2)` | **518.2 px** (MOVING) |

Evidence: `tests/fixtures/hw_visual/screensaver_osd_control/`. `misterplexd` now warns at startup
when `OSD_CONTROL=0`, naming what it disables. The shipped default in `package_release.sh` is
already `1`; the device conf was a leftover manual workaround for a problem that is now fixed in
code.

**Caveat I could not close:** Main owns the OSD word and restores its shadow within about a second,
so `set_status` injection is transient. I proved the daemon applies the change and the picture
animates, but I did **not** prove the selection sticks when made from a real keyboard through Main's
OSD menu. `tests/hw/osd_keys.py` is the sanctioned path for that; it is still not copied to the
device, and blind `down`-counting risks landing on `Reset`. That is the next piece of work here.

## Build identity — what changed and what `w-fit-o5` must do

* `scripts/gen_build_stamp.py` runs on the build host **before** the rsync and writes
  `fpga/Plex_MiSTer/build_id_stamp.txt` with `BUILD_ID = DATE-GIT-SRC`. `SRC` is a sha256 over
  exactly the fit inputs (mirroring the rsync excludes), so the id changes when the fitted sources
  change and cannot be forgotten.
* `build_id.tcl` prefers the stamp and warns loudly when it is absent.
* `build_rbf_remote.sh` **refuses to fit (exit 4)** if the id would contain `nogit`.
* After the fit it records md5/sha256 → `BUILD_ID` into `fpga/Plex_MiSTer/rbf_provenance.jsonl`.
  `scripts/rbf_provenance.py resolve` maps a device's RBF back to its source and **hard-fails on an
  unknown md5** — which correctly reds the resident `fb4bad84` today.
* Git identity is only accepted when `git rev-parse --show-toplevel` equals the directory asked
  about, so a build slot nested under an unrelated checkout cannot inherit its commit.
  `tests/unit/test_build_identity.sh` caught that bug in my own tool while it was being written.

**Action required: the next fit must go through the updated `build_rbf_remote.sh`.** Without it the
RBF is stamped `nogit` and the OSD build id is worthless.

Honest limits: the Tcl is checked **structurally only** — there is no `tclsh` in this lab, and the
gate's Scope line says so. A true self-hash of the bitstream is circular; the split is source
identity in the fabric, artifact md5 in the ledger.

## Gates added, and their reds

| Gate | Red it ships with |
|---|---|
| `tests/unit/test_build_identity.sh` | editing a fitted file must change `SRC`; a tree with no git identity of its own must be refused; an unknown or edited RBF must fail to resolve; a `BUILD_ID` mismatch must fail |
| `tests/unit/test_idle_screen_rca_logic.sh` | all five verdicts plus UNSCORED driven from fixtures; the same damaged pixels must change verdict when the doorbell advances; the single PASS branch must stop passing when the grader's budget is tightened |
| `tests/unit/test_screensaver_osd_control.sh` | the real `OSD_CONTROL=0` captures must read STATIC and the `OSD_CONTROL=1` captures MOVING; the static set must be *proved* to boil frame-to-frame, so the case against a difference-based gate is measured |
| `scripts/idle_frame_integrity.py --self-test` | clean / ragged / black must be separated; a clean frame must score exactly zero spread |
| `scripts/idle_motion_probe.py --self-test` | static-with-boiling-edge must read STATIC; uniform frames must read NO_CONTENT, not STATIC |

`tests/hw/test_idle_screen_pixel_rca.sh` currently **FAILS** on hardware, honestly:
`IDLE_RCA_VERDICT=PRESENTED_CORRUPT`. It should stay red until the presentation path is fixed.

## Not done / handing on

1. **Neighbour-context wiring** — owned by `w-decode-o5`. I did not touch it.
2. **The per-line underrun** needs an RBF fix. Prepare and prove in simulation; the fit is
   `w-fit-o5`'s exclusive slot. `LINE_COUNT=8`, the DDR arbiter, and the scanout-start race are the
   three candidates; none has been eliminated.
3. **OSD menu navigation with `osd_keys.py`** — copy it to the device and reach "Idle screen"
   (10th selectable item) without overshooting into `Reset`. Verify by reading `PLXS` after each
   step rather than counting blind.
4. **The device must be power-cycled** before any of this can be re-measured.
5. `mailbox_abi_spec.hpp`'s "SINGLE SOURCE OF TRUTH" banner is now accurate only because I added the
   YUV window; `tests/unit/test_rtl_invariants.py` still checks the `0x3007F` defaults only. Someone
   should extend it to assert the instantiated window too.
