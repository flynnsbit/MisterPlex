# A false pass from my own gate, on real hardware

Branch `w-osd-o5`. Device `192.168.1.183`, RBF md5 `fb4bad849ad2db782a5004ce5a3471ce`.
All three logs are captured runs, not reconstructions.

## What happened

After the MiSTer was power-cycled it came back on the **MENU** core, with `misterplexd`
running. In that state `tests/hw/test_idle_screen_pixel_rca.sh` returned:

```
IDLE_RCA_VERDICT=PRESENTED_CLEAN
IDLE_RCA_RESULT=PASS
```

exit code **0**. There was no Plex fabric loaded at all. The card graded the MiSTer menu
screen, whose left edges are naturally clean, and called it a healthy Plex idle screen.

This is the same class of defect `w-audit` counted 24 of in this repo, and it was in the
gate I wrote to catch other people's versions of it.

## Why it passed

Three things lined up, and each of them looked like evidence:

1. **`PLXK` was valid.** The card required `PLXK_LO == 0x504C584B` at the derived doorbell
   and treated that as "the core is there". But `PLXK` is the **ARM→FPGA** doorbell: it is
   written by `misterplexd`. It proves the daemon is alive. It says nothing about what is
   loaded in the fabric. The FPGA-published mailboxes in the same probe,
   `PLXD` and `PLXF`, were both `0x00000000` — printed on the `DEVICE` line of
   `01_old_card_false_pass_on_menu.log`, right there in the output, and unchecked.

2. **The "is anything drawn" check saw a picture.** DDR keeps its contents across a warm
   boot, so the previous core's frame bytes (`0x2D2D2D2D` luma) were still sitting in both
   banks. The bank sample could not tell "the producer wrote this" from "nobody has
   overwritten this yet".

3. **The pixels were clean, and they were the wrong pixels.** `left_edge_spread=0`,
   `picture_rows=720`. A perfect score, for the menu.

`swap_pending=0`, `free_mask=0`, `debug_state=0x00` and `underrun=0` are all visible in
that log too. A frame store that has never run reads as a frame store with nothing wrong.

## The fix

`check` order in the card is now: derived-doorbell `PLXK` → **FPGA-published `PLXD`/`PLXF`
magics** → **bank vsync counter must advance** → drawn → presented → pixels. The two new
gates are the only ones in the probe that a core-less device cannot fake:

* magics: `PLXD_LO == 0x504C5844` and `PLXF_LO == 0x504C5846`, written by the fabric.
* liveness: `PLXD[31:16]` (bank vsync, ~66/s) must move across a one-second resample,
  because a core held in reset publishes its magics once and then freezes, and a frozen
  core in front of a static screen still grades CLEAN.

Both exit **77 UNSCORED**, never a verdict. `02_fixed_card_unscored.log` is the fixed card
on a device with no Plex fabric: rc=77.

While fixing this I found a second hole in the same file. `probe L`, the new liveness
resample, had no fixture, so `tests/unit/test_idle_screen_rca_logic.sh` — which advertises
"does NOT contact a MiSTer" — silently SSH'd to the real device for that one probe and
passed because of whatever it found. Fixture mode is now all-or-nothing: if
`IDLE_RCA_PROBE_A` is set and any other probe fixture is missing, the card refuses rather
than falling back to the device.

Three unit cases now cover this: `no_plex_fabric`, `scanout_frozen`, `fixture_mode_partial`.

## The measurement that still stands

`03_fixed_card_live_plex_core.log` is the fixed card against a **loaded, scanning-out Plex
core**, on a freshly power-cycled device with a freshly started daemon:

```
SCANOUT_LIVENESS vsync=7015 -> 7180
MAILBOX disp_bank=0 swap_pending=0 free_mask=2 underrun=65296 debug_state=0x96
IDLE_INTEGRITY verdict=RAGGED_LEFT left_edge_p5=84 left_edge_median=128 left_edge_p95=136 spread=52
IDLE_RCA_VERDICT=PRESENTED_CORRUPT
```

`p5=84`, `p95=136`, underrun saturated at `0xFF10` — the same numbers as the pre-wedge
measurement in `../idle_rca_fb4bad84/`. The per-scanline DDR read underrun survives a power
cycle and a fresh daemon, so it is a property of the RBF and not of accumulated runtime
state. It still needs an RBF fix.

## What this does not prove

The pixel evidence here is about left-edge integrity only. It does not identify which
picture is on screen, does not check colours, and does not prove RBF provenance
(`scripts/rbf_provenance.py` owns that, and still hard-fails on `fb4bad84`).

One caveat recorded honestly: before the `03_` run I had written a `PLXK` doorbell word and
a few luma/chroma words into DDR by hand, while I still believed the device was on MENU.
That produced an intermediate `DRAWN_NOT_PRESENTED` reading which I discarded as confounded
rather than reporting. `03_` was taken after restarting `misterplexd`, so the frame in DDR
and the doorbell sequence are the daemon's, not mine — but the bank sample offsets are ones
I had touched, so treat the "drawn" step of that specific run as weaker than the pixel step.
