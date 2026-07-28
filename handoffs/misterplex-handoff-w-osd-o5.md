# Handoff — W-OSD-O5

Branch `w-osd-o5` (worktree `.worktrees/w-osd-o5`), based on `bad31de` (`w-osd-neighbor`).
Commits: `f265abe` build identity, `acba80f` idle RCA, `85e5864` screensaver/OSD_CONTROL,
`2bdc6be` docs, `713a0ac` instantiated-mailbox-window gate, `0b74a76` idle RCA false-pass fix,
`63604b2` screensaver card fixes + live green.
Everything below is **measured** unless it says assumed.

## Read this first: the device was power-cycled and everything was re-measured

The MiSTer at `192.168.1.183` **wedged** mid-session and needed a physical power cycle. It has
since had one, and every conclusion below was re-measured afterwards on the recovered device.

What wedged it: a run that re-asserted the OSD selection **80 times at 0.3 s intervals** via
`set_status` (UIO/SPI), contending with Main's own status writes. An earlier, gentler run
(40 x 0.4 s) survived. **Cause is assumed, not proven.**
`tests/hw/test_osd_screensaver_selects.sh` now caps this at 32 writes, >=400 ms apart, and
refuses to run outside those bounds.

State the device is in now: `OSD_CONTROL=1` in `/media/fat/misterplex/misterplex.conf`
(backups `misterplex.conf.bak-wosdo5`, `misterplex.conf.bak-wosdo5-red`), `misterplexd` running,
`/media/fat/misterplex/wosd_ruler.yuv` left on the SD card. Other workers were loading and
unloading cores during my last measurements, so the core present at any moment varied.

## The headline, re-measured after the power cycle

**The screensaver works.** `tests/hw/test_osd_screensaver_selects.sh` returns **rc=0** with the
bright centroid travelling **49.4px** across four captures and turning — a bouncing logo.
Evidence: `tests/fixtures/hw_visual/screensaver_live_green/`.

**The idle screen is still corrupt, for a reason no ARM change can fix.**
`tests/hw/test_idle_screen_pixel_rca.sh` returns `PRESENTED_CORRUPT` with picture rows starting
between capture x=84 and x=136 against a budget of 8, and `PLXF` underrun saturated at `0xFF10`.
These are the **same numbers** as before the power cycle, on a fresh boot with a fresh daemon, so
the per-scanline DDR read underrun is a property of the RBF and not of accumulated runtime state.

## Two of my own gates were wrong, and the device caught both

Both were found by running against real hardware, not by review. Both are committed with the
captured logs that show the wrong answer.

**The idle RCA card returned PASS on a MiSTer with no Plex core loaded.** After the power cycle the
device came back on the MENU core with `misterplexd` running, and the card graded the menu screen
`PRESENTED_CLEAN`, rc=0. Three things lined up: it required `PLXK`, which is the **ARM to FPGA**
doorbell written by the daemon and therefore present with no core at all; DDR keeps its contents
across a warm boot, so the previous core's frame bytes made the "is anything drawn" sample look
like a picture; and the menu's left edges really are clean. The FPGA-published `PLXD`/`PLXF`
magics were printed on the card's own output line, both `0x00000000`, and nothing checked them.
Fixed by requiring the fabric-written magics **and** an advancing `PLXD` bank vsync counter — the
counter separately, because a core held in reset publishes its magics once and then freezes.
Evidence: `tests/fixtures/hw_visual/idle_rca_false_pass_menu/`.

Fixing that exposed a second hole in the same file: the new liveness resample had no fixture hook,
so `tests/unit/test_idle_screen_rca_logic.sh`, which advertises "does NOT contact a MiSTer",
silently SSH'd to the real device for that one probe. Fixture mode is now all-or-nothing.

**The screensaver card reported "the daemon did not react to the OSD word" about a daemon that was
applying every word correctly**, and named `startOsdPoll()` as the place to look. Three defects:
the hold loop was a backgrounded child of an `ssh` command and was torn down when the session
closed, while the card checked `ssh`'s exit status and got 0; the log window was established by
appending a marker to a file the daemon holds open at its own write offset, so the marker was
stranded and the window was empty; and the log path was hardcoded. Then the evidence order was
wrong as well — an empty log overrode a measured 30.8px of centroid travel. The OSD word read back
out of `PLXS` and the pixels on the wire are measurements; the daemon log is lossy corroboration,
because the daemon logs on *change*. Motion is decided first now.
Evidence: `tests/fixtures/hw_visual/screensaver_live_green/`.

Both classes are the same mistake in different clothes: **something that is alive for its own
reasons was accepted as evidence that the thing under test is alive.** `PLXK` proves the daemon.
`ssh` exit 0 proves `ssh`. A clean left edge proves whatever core is loaded.

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

## Closed after the first draft of this handoff

Item 5 below was on the open list; it is now done, because it is the gate that would have caught
the trap that cost me the most time.

`tests/unit/test_rtl_invariants.py` gained `check_instantiated_mailbox_window()`. The two
pre-existing gates in that file are individually strong and jointly blind: `check_mailboxes()`
proves the RTL derives every mailbox from `DOORBELL_PHYS + offset`, and
`check_ddr_frame_layout_contract()` proves the host and RTL layout headers agree constant for
constant. Both are satisfied by *any* self-consistent pair of numbers, so neither can tell you the
doorbell is the one the instantiated frame store actually uses. The new check asserts the three
things that pin the live window: every doorbell in the layout header equals
`PHYS_BASE + 2*stride - 0x1000`; `present_core.sv` instantiates one consistent stride/doorbell
family; and `mailbox_abi_spec.hpp` names the instantiated address in text while saying that its own
`0x3007F` default block is not it.

Three red-checks in `tests/unit/test_rtl_invariants.sh`, each injected so that every pre-existing
gate stays satisfied — otherwise the red would be someone else's gate firing, not mine:

| Fault | Injection | Message |
|---|---|---|
| Doorbell does not follow its stride | `0x300FF000` → `0x3007F000` in **both** layout headers at once | `not where a two-bank YUV420P frame store puts it` |
| Mixed layout families | `present_core.sv` keeps the YUV stride, wired to `DDR_FRAME_RGB565_DOORBELL_PHYS` | `must instantiate ddr_frame_store with one consistent layout family` |
| Host spec aimed at the stale window | `kYuv420pDoorbellAddr` → `0x3007F000` | `would probe an address the fabric never writes` |

Each red-check greps for its own message, so a fault that trips an earlier gate does not count as a
pass. `bash tests/unit/test_rtl_invariants.sh` rc=0 with all three firing.

While writing it I found my own earlier comment in `mailbox_abi_spec.hpp` was wrong: I had called
the `0x3007F` block "the RGB565 stride". It is not. RGB565 ships a `0xC0000` stride whose doorbell
is `0x3017F000`. `0x40000` belongs to no current layout family at all — it is `ddram_frame_rd`'s
bare module default. The corrected comment says so, because "it's the RGB565 window" would have
sent the next reader to probe `0x3017F000` and find the same class of frozen garbage.

5. ~~`mailbox_abi_spec.hpp`'s "SINGLE SOURCE OF TRUTH" banner is now accurate only because I added
   the YUV window; `tests/unit/test_rtl_invariants.py` still checks the `0x3007F` defaults only.~~
   Done, see above.
