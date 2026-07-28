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

### 2. `misterplexd` WAS DOWN for part of this shift — check it before you probe
At **14:38–14:39** two independent oracles said it was absent (process grep
count 0; **no listener on port 3005**). At **14:56** it is definitively back:
```
pid 3823  /media/fat/misterplex/bin/misterplexd --port 3005 --pms http://192.168.1.41:32400
netstat -lnt -> :3005 listening
```
So it went down across the ~14:16 reboot and was restarted later. **Assert the
daemon state immediately before and after your poke-probe** — a probe that
straddles a daemon restart is not the experiment you think you ran.

**Two silent probe traps** that nearly made me report this wrong, both worth
knowing fleet-wide:
- `ps w | grep -i "misterplex\|Main"` returns **empty even when the process
  exists** — busybox grep does not treat `\|` as BRE alternation, so the whole
  pattern is matched literally.
- Nested double quotes inside a single-quoted `ssh '...'` command terminate the
  outer string early and silently change what grep receives; this handed me a
  bogus `daemon=1`, which I retracted rather than reported.

Reliable form: pipe a script file to `ssh 'bash -s'` — see
`artifacts/e2e-o5/daemon_probe.sh`.

### 3. The chevron survives the painter being gone entirely
The capture above was taken **with the daemon dead**, and it is identical to
both daemon-alive captures: same 14928 px, same bbox. So the chevron on screen
is **not** proof that your mailbox-zeroing worked — it persists with no ARM
painter running at all.

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

---

# ADDENDUM — 15:50. STEP 2 is UNSCORED, and the device is parked on MENU

## Your network report was 2.5 h stale; the device is fine

Your timestamps are 12:07–12:47. Measured at **15:08**:
```
ping   3/3 received, 0% loss      arp  192.168.1.183 REACHABLE lladdr 90:de:80:17:19:63
ssh    OK                         misterplexd pid 3823, port 3005 listening
```
RTT is 32–224 ms with mdev 86 ms on `wlp89s0` — **WiFi**. That jitter is the
likely source of the transient dropouts both of us have seen, including the one
that made me REFUSE a capture at 14:20.

## `3b1e8435` IS ALREADY DEPLOYED — and Plex is not loaded

My provenance guard refused a capture at 15:09 because the resident md5 had
changed under me:
```
REFUSE: resident RBF md5 3b1e8435 != expected fb4bad84; screen state is UNSCORED
```
Since **15:18 the device has been sitting on `CORENAME=MENU`** — verified every
20–25 s for 27 minutes, `uptime` climbing 3742 → 5324 s, `md5=3b1e8435` the
whole time. **The menu bounce never returned to Plex.** `3b1e8435` is resident
on disk but is *not the running core*.

## The one Plex-loaded capture of `3b1e8435` is UNSCORED — do not read it as black

At 15:10, with `corename=Plex rbf_md5=3b1e8435`, my gate said
`BLACK_SIGNAL mean_luma=6.23` and returned **rc=1 FAIL, blamed on the core**.

**That verdict was wrong and I have fixed the instrument.** 87.54% of those
pixels were exactly **RGB(7,7,7)** — the MS2109's no-lock filler. The receiver
had not re-locked after the core load.

| capture | exact RGB(7,7,7) |
|---|---|
| fb4bad84 Plex (daemon dead / alive) | 0.01% / 0.01% |
| MENU core | 0.00% |
| **3b1e8435 at 15:10** | **87.54%** |

~8000x apart. Six minutes later the same device showed real content
(mean 27.2, 617 distinct colours) — so it was a transient, not a black screen.

**Root cause of the misgrade:** filler value 7 is *below* the black threshold
(8.0), and `classify_signal` tests luma before flatness, so a fully unlocked
capture returns `BLACK_SIGNAL`. `score_idle_screen.py` then attributed black to
the core because the **host was pingable** — but network reachability says
nothing about HDMI lock. Fixed in `f3299eb`: filler dominance is now measured
first and returns `NO_SIGNAL` → REFUSE. Two existing tests had encoded the bug
by using `RGB(7,7,7)` as their "black screen" fixture; fixtures corrected.

**So STEP 2 remains genuinely UNSCORED.** I have no valid measurement of what
`3b1e8435` paints, because it has not been the running core while locked.

## Rig is healthy and waiting

Last capture, provenance-locked to the running core:
```
PROVENANCE: corename='MENU' rbf_md5=3b1e8435 uptime=5397s
Scope: 10 scored frames (warmup dropped 3)
SIGNAL_STATE: CONTENT_PRESENT  mean_luma=26.16  spatial_std=33.73
PLEX_CHEVRON: ABSENT — 0 Plex-orange px
LEFT_EDGE_ARTIFACT: clean — ratio 2.0x
PASS
```
Capture path end-to-end healthy. Note MENU now correctly reports chevron
**ABSENT**; before `76909af` this same screen class scored `PRESENT`.

**Load Plex and say the word — I will have a scored answer within ~90 s.**
Allow ~60 s after the core load before trusting any capture: HDMI re-lock takes
several seconds and the gate will now REFUSE rather than mis-grade during it.

---

# ADDENDUM 16:05 — STEP 2 IS SCORED. `3b1e8435` CAPTURED, PROVENANCE-LOCKED.

Branch `w-e2e-playwright`. Device measured live, not assumed.

## 1. Two corrections to the parent's status

* **The device is NOT offline.** Parent's message cites *"last responding 11:37; now 13:21 -> ping 100% loss"*. Measured by me: up at 15:08, 15:49 (`ping_rc=0`), 16:01, 16:03. Same boot throughout (uptime monotonic 5567 -> 6427 s).
* **The `3b1e8435` deploy has ALREADY HAPPENED.** It is resident now. The re-authorization is for a deploy that is already spent. At 15:49 the device was parked on `CORENAME=MENU`; by 16:01 Plex was loaded and I captured it.

## 2. STEP 2 SCORED — `3b1e8435` = **VALID WITH CONTENT**

Provenance asserted **before and after** grading pixels:
`corename=Plex  md5=3b1e8435  uptime 6280 -> 6427 s (same boot)`

Denominator: **10 scored frames** (12 grabbed, 2 warmup dropped).

```
SIGNAL_STATE: CONTENT_PRESENT  mean_luma=36.37  spatial_std=22.27  unique=10/10
PLEX_CHEVRON: PRESENT  14928 px  bbox [484,239,707,479]
LEFT_EDGE_ARTIFACT: PRESENT  dark 29.7% vs control 0.2%  (ratio 161.0x)
rc=0
```

**Raw numbers vs thresholds, as asked:**

| quantity | measured | threshold | verdict |
|---|---|---|---|
| mean luma | **36.37** | black if < 8.0 | 4.5x above -> not black |
| spatial std | **22.27** | flat if < 3.0 | 7.4x above -> real structure |
| filler frac RGB(7,7,7) | **0.0001** | no-signal if >= 0.50 | HDMI genuinely locked |
| unique frame hashes | **10/10** | stale if 1 | not frozen |

**Answer to `w-fit-o5`'s falsifiable prediction: CONFIRMED, not refuted.** It predicted that if the DDR *write* path is dead but video timing alive, I would see a VALID signal. I see a valid signal with content. So **the board is alive and driving HDMI**, and the earlier network drop was a network-stack/link event, not an FPGA death.

**A free natural red control.** Frame `f1` came back **100% filler RGB(7,7,7), spatial std 0.000** — the unlocked-capture state — and frames 3..12 came back as content, in the same burst, on the same device. That is the exact confusion that made me mis-score this device earlier today, now graded correctly as NO_SIGNAL/warmup rather than "black screen". The filler fix is validated on live hardware, not just synthetic fixtures.

## 3. The A/B the parent actually asked for — and its limits

Direct pixel comparison, `fb4bad84` frames vs `3b1e8435` frames, both provenance-locked at capture time:

```
fb4bad84 : chevron 14905 px  bbox (484,240,705,479)
3b1e8435 : chevron 14905 px  bbox (484,240,705,479)
chevron mask IoU = 1.0000  (14905/14905)   masks bit-identical: True
```

Left-edge dynamics, same oracle, both builds:

| | `fb4bad84` | `3b1e8435` |
|---|---|---|
| verdict | MOVING | **MOVING** |
| artifact temporal std | 5.68 / 5.81 / 6.19 | **5.7048** |
| noise floor (chevron interior) | 0.00 | 0.0573 |
| dark ratio artifact/control | ~171x | **172.8x** |
| pillar edge column | 128 (12/12 frames) | **128 (stable)** |

**Measured conclusion: the SDC change is invisible in the display path.** Two different bitstreams paint a *bit-identical* image and produce a statistically identical moving artifact.

### Applying the parent's own vacuous-control test to my own result

*"Does this comparison actually differ in the thing it claims to test?"*

* **Yes on the input side.** The two bitstreams genuinely differ (md5 verified on the device at capture time), and per `w-fit-o5` their RTL is byte-identical while `Plex.sdc` differs by 38 lines. The independent variable **is** varied. This is not the four-builds-one-SDC mistake.
* **But partially NO on the output side, and this is the limit of my instrument.** I previously measured the chevron as **pixel-identical with `misterplexd` dead and across a reboot**. So the chevron is scanned out of DDR content that survives without a live writer. **The chevron is largely insensitive to the DDR write path the SDC is suspected of breaking**, which makes it a weak probe for that specific question.

**So state my result precisely:** I have exonerated the **video timing and DDR scanout/present path** on both builds — neither is a blank-screen or lost-sync failure. I have **not** discriminated the SDC hypothesis, because the feature I can see does not depend on the path under suspicion. **`w-fit-o5`'s PLXD poke-probe remains the discriminator; my capture cannot substitute for it.**

One datum that does bear on it: the left-edge artifact is **MOVING** on `3b1e8435` (SNR 99.6x above a noise floor taken from the capture itself). Something is changing that memory between frames. What it is not: the ARM daemon, which I showed earlier makes no statistical difference to this artifact.

## 4. `w-fit-o5` — the answer you were blocked on

**`capture done, proceed`.** Grade **VALID WITH CONTENT**, mean luma **36.37** against a black threshold of **8.0**, filler **0.01%** against a no-signal threshold of **50%**. The board is alive and driving HDMI. Nothing perishable is left to protect — `3b1e8435` is already resident and already captured, so you are unblocked.
