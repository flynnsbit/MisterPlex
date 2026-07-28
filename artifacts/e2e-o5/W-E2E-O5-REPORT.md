# W-E2E-O5 — capture report

Branch `w-e2e-playwright`, commit `0d9e602`. All figures **measured**, not assumed.

---

## STEP 1 — COMPLETE. **W-FIT-O5: CAPTURE DONE, PROCEED.**

The screen is **VALID SIGNAL WITH CONTENT**. Not no-signal, not black.

Provenance-locked at capture time (`corename` + resident RBF md5 read over SSH
**before** any pixel was graded):

```
PROVENANCE: corename='Plex' rbf_md5=fb4bad84 uptime=1396s
Scope: 12 scored frames from v4l2:/dev/video0 (warmup dropped 2)
SIGNAL_STATE:       CONTENT_PRESENT  mean_luma=36.33  spatial_std=22.30  unique=12/12
PLEX_CHEVRON:       PRESENT — 14928 px, centroid [595,359], bbox [484,239,707,479]
LEFT_EDGE_ARTIFACT: PRESENT — dark 30.8% in cols [84,200] vs 0.2% in control [300,1200] (164.5x)
PASS: valid signal with picture content including the Plex chevron
```

**Thresholds and denominator** (measured constants, `capture_preflight.py:59,63`):
`BLACK_SIGNAL` iff `mean_luma < 8.0` — measured **36.33**, i.e. 4.5x above.
`NO_SIGNAL` iff `spatial_std < 3.0` — measured **22.30**, i.e. 7.4x above.
`STALE_CAPTURE` iff all frame hashes identical — measured **12/12 distinct**.
All three negative branches are cleared with margin, so `CONTENT_PRESENT` is
not a default: it is the only surviving classification. Denominator 12 scored
frames of 14 captured (2 warmup dropped). Artifacts:
`artifacts/e2e-o5/plex_nodaemon/`,
`artifacts/e2e-o5/STEP1_PLEX_fb4bad84_screen.png`.

**Your falsifiable prediction is CONFIRMED**: DDR write path dead but video
timing alive → VALID signal. The `clk_ddr`/`reset_ddr`-stuck branch is refuted.
Caveat: this proves the pixel-clock domain and present path only. It is **not**
evidence the fabric writes DDR.

---

## ⚠ THREE THINGS THAT CHANGE YOUR STEP 2

### 1. The device rebooted spontaneously — twice today
`~13:44` and `~14:16` (uptime 1926s → 172s across one measurement pair). It
comes back on **`CORENAME=MENU`**, not Plex. The parent's "device unreachable"
report was this reboot in progress, not a dead device — it is up now.

### 2. `misterplexd` IS NOT RUNNING
It did not restart after the reboot. Two independent oracles:
```
ps w  -> 95 procs, /media/fat/MiSTer /media/fat/_Utility/Plex.rbf present, NO misterplexd
netstat -lnt | grep 3005 -> no listener
```
**Your poke-probe run now would be measuring a system with no ARM daemon.**
That is a different experiment from the one you ran before. Either restart it
first or record the difference — otherwise the A/B against `3b1e8435` is
confounded.

### 3. The capture above was taken with the daemon dead
And it is **identical** to the daemon-alive STEP 1 capture: same 14928 px, same
bbox. So the chevron on screen is **not** proof that your mailbox-zeroing
worked — it survives the painter being gone entirely.

---

## New finding: the left-edge artifact is NOT caused by ARM writes

Instrument: `scripts/analyze_left_edge_dynamics.py` (self-test 5/5, gate 8/8).
Noise floor is taken **from the capture itself** — temporal std inside the
saturated chevron interior.

| capture | daemon | temporal std | dark ratio | row-width var | pillar edge | verdict |
|---|---|---|---|---|---|---|
| STEP 1, pre-reboot | ALIVE | 5.81 | 179.0x | 16.84 px | 128 | MOVING |
| 14:41 | **DEAD** | 5.68 | 171.0x | 16.45 px | 128 | MOVING |
| 14:56, **same boot** | ALIVE | 6.19 | 160.5x | 17.90 px | 128 | MOVING |

The daemon-dead arm sits **between** the two daemon-alive arms on every
statistic. The 14:56 arm shares a boot with the dead arm, so this is no longer
confounded by the reboot. Chevron is **14928 px with the identical bbox in all
three**.

**W-ARM-O5:** the mechanism "ARM writes into the bank being scanned out" is
**refuted for this state**. The artifact moves identically with no ARM process
alive. The pillar edge pinned at **column 128** in 12/12 frames of both
captures points at the present/scanout path.

I discarded an earlier analysis before reporting it: IoU-of-dark-mask gave 0.61
vs 1.00 and looked like proof of motion, but the artifact sits near the black
threshold so IoU largely measures threshold proximity. The chevron noise floor
(0.00) is the sound version, giving SNR 113x/116x.

---

## My own gate was reporting a false PASS — fixed

With `CORENAME=MENU` on screen, `score_idle_screen.py` printed
**`PLEX_CHEVRON: PRESENT ... PASS`**. The bbox was `[368,0,486,719]` — a
full-height column of orange **MiSTer menu text**. Colour + count + centroid
with no shape constraint.

| | bbox | aspect | fill |
|---|---|---|---|
| real chevron | 224x241 | 0.929 | 0.277 |
| MENU text | 119x720 | 0.165 | 0.105 |

Added aspect and fill gates; red/green replayed on real stored frames both
ways. **Anyone who ran this gate before commit `76909af` could have got a green
"Plex chevron present" off the MiSTer main menu.**

---

## A false-green trap others will hit

**`argparse` exits 2 on a usage error, which collides with `EXIT_REFUSE`.**
An early revision of my own test passed `--input` four positional paths;
argparse rejected the command line, exited 2, and the test scored
`"NO_SIGNAL refuses (rc=2)"` as **GREEN** without the gate ever reading a pixel.

Any wrapper that reads `rc=2` as "UNSCORED" may be reading a typo. Check stderr
for `usage:` before trusting a 2.

---

## Evidence standard

- Offline red-proof `tests/unit/test_capture_gate_states.py`: **27/27**, and
  **14/14 mutations of `score_idle_screen.py` killed, 0 survivors**
  (`artifacts/e2e-o5/mutate_gate_states.py`). Two mutations initially
  **survived**, proving my first regression case was vacuous; fixed.
- `tests/unit/test_idle_screen_score.py` rc=0, `test_capture_rig.sh` rc=0,
  rollcall rc=0 (92 protected commands).
- No exit code read through a pipe anywhere; every rc captured by redirecting
  to a file and testing `$?` directly.

`/dev/video0` is claimed by me and otherwise idle — capture requests welcome.
