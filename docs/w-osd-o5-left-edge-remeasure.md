# W-OSD-O5 — re-measuring the two left-edge analyses with one instrument

`w-fit-o5` (handoff §30, commit `43f864a`) asked in its §4 that someone re-measure both
left-edge analyses with a single instrument before assuming they describe the same defect.
This is that re-measurement. Everything below is **measured** unless labelled otherwise.

Instrument: Rec.601 luma, `Y < 12` = near-black, drawn-overlay pixels masked out.

## 1. The two images

| file | when | build | size |
|---|---|---|---|
| `build/left-edge-artifact/artifact_annotated.png` | 11:01 | `00eebd5e` | 1280x720 |
| `artifacts/e2e-o5/screen_now.png` | 12:09 | `fb4bad84` | 1280x720 |

Both live in `.worktrees/w-e2e/`. Same geometry, so "different capture geometry" is
excluded as the explanation for the differing signatures.

## 2. The old image contains no video content at all

```
overall near-black      97.8 %        mean luma 1.5
picture area rows 280..719:
    non-overlay content pixels = 0
    max luma                   = 76.245
```

`76.245` is exactly `255 * 0.299` — the luma of **pure red**. So in the entire lower
two-thirds of the frame the only non-zero pixels are the red annotation line.

Sampling whole rows well below the annotation band:

```
row 350 / 450 / 550 / 650
cols 0, 10, 20, 23, 26, 30, 60, 100, 300, 640  ->  luma 0 at every one
```

All remaining non-overlay content is rows `7..270`, in short runs starting at column 6
(106, 49, 68, 59, 97, 56 px per row) — that is the analysis tool's own text header,
not video.

## 3. There is no 24-column clip

The annotation reads:

```
Cols 0-23: BLACK | Col 24: luma=45 (DDR expected: 44)
Red line = first bright col (24px)  Expected: col 0
```

Measured on that same file:

```
col      22    23    24    25    26    27    28
mean luma 2.2   2.6  77.1  77.1   5.2   4.2   3.2
```

Columns 24–25 carry the red marker in **716 of 720 rows** (1432 px total). Their luma
is the marker's own. The four rows at column 24 *not* covered by the marker read
`226` at columns 23, 24, 25, 26 and 30 alike — a horizontal white rule from the
annotation chrome, uniform across columns, not a transition.

Immediately right of the marker the picture is black again (luma 3–5), and it stays
black to column 1279.

**Therefore the "first bright column at 24" is the marker the annotation drew, and the
"24-column clip" is not present in the image cited for it.** The old capture is a black
screen — which is consistent with the long-standing `IDLE_SCREEN=black` defect, and is
not an edge-clip defect.

## 4. What survives, and what is withdrawn

**Survives — the DDR source is clean.** `ddr_source_annotated.png` (624x480) measures
mean luma 47.9, `0.0 %` near-black, uniform luma 44 from column 2 to the right edge.
Caveat stated rather than buried: columns 0–1 read luma 149 and are themselves a drawn
marker, so this file is *also* an annotated image and my reading of it is made through
someone else's overlay. The uniform luma-44 field is unambiguous, but no raw DDR dump
was available to confirm it.

**Withdrawn — the "24 columns" quantity and everything derived from it.** `w-fit-o5`'s §3
lead (line-buffer fill latency; 24 px x 16 bit = 48 bytes near a DDR burst boundary)
rests entirely on the number 24, and 24 is the annotation's marker position. Nobody
should spend time hunting a constant 24-column pipeline offset on this evidence.

**Unchanged in direction, stronger in grounds — the fabric scanout redirection.** The
correct reading of the 11:01 pair is *DDR held valid pixels and the display showed
nothing at all*. That still points at the readback/scanout path rather than the ARM
painter, and on a blunter fact than a 24-column offset.

**§4's discrepancy is resolved.** The old analysis is not "a clean 24-column clip, 100 %
black" and the new frame "a ragged 70 % band"; the old image is a ~100 % black frame with
no left-edge signature to compare at all. The two are not two measurements of one defect.

**Not comparable from raw data.** No raw 11:01 capture exists anywhere in the tree — only
the annotated PNG. The old analysis therefore **cannot** be re-measured from a raw frame,
and its numeric claims cannot be reproduced.

## 5. The classifier false-green this exposed (fixed here)

`scripts/hdmi_capture_classify.py` is the fleet's three-state
`NO_SIGNAL` / `VALID_BLACK` / `VALID_CONTENT` instrument. Fed the annotated black frame:

```
HDMI_CAPTURE_RESULT class=VALID_CONTENT reason=valid-frame-nonblack-structure
  mean=1.363204 std=10.964682 dark_fraction=0.979927 nonblack_fraction=0.007388
rc=0
```

**It scored a frame whose picture area is luma 0 at every pixel as `VALID_CONTENT`.**
Mechanism: `dark_fraction=0.9799` misses the `> 0.985` VALID_BLACK test by `0.0051`, and
`std=10.96` clears the flat-frame test — the annotation supplies ~2 % bright pixels, which
is all it takes. This is the parent's *"capture succeeded" and "the screen is black" are
simultaneously true* trap, defeated not by a subtle case but by drawing on the image.

Fix: `detect_drawn_overlay()` refuses to score a frame carrying an exactly-saturated
primary in a long straight run, returning `class=UNSCORED_ANNOTATED` and **rc=2 (unseen)**
rather than a verdict. On the real file it names the culprit:

```
class=UNSCORED_ANNOTATED reason=drawn-overlay-column:24 overlay_run=449 overlay_pixels=1432
rc=2
```

Red/green pair:

| run | rc | meaning |
|---|---|---|
| `--allow-annotated --expect content` | 0 | trap reproduced — guard is load-bearing |
| `--expect content` | 2 | refused, not scored |

`screen_now.png` still classifies `VALID_CONTENT` rc=0, so the guard does not fire on real
captures.

**Declared scope limit.** The guard keys on exactly-saturated primaries in long straight
runs. Two synthetic goldens carry deliberate marker columns and would be refused
(`plex_visual_640x480_golden.png` at column 11 = `PRESENT_X`, and
`reload_determinism/plex_bytes_in4_stale_screen.png` at column 1). Both are consumed by
`hw_visual_compare.py`, never by this classifier, so no existing gate regresses — verified
by `make unit` rc=0. It does not claim to detect every derived image.

## 6. Generalisation

This is the same family the parent named (vacuous controls, gates that exit 0 without
running, reachability through `decode_stub`, byte-value checks blind to stride) with a new
member worth naming:

> **An instrument that draws on its input can then measure its own drawing.**

The marker was placed at column 24 by the analysis, and column 24 was then reported as the
finding. Nothing in the pipeline distinguished the tool's output from the world's input.
The mechanical defence is the one applied here: a scorer must refuse a frame that carries
evidence of having been drawn on, rather than score it confidently.
