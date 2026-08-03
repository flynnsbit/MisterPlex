# T4 — Can hold-duration (judder) be scored from one capture frame?

**Verdict: not reliably on this grabber path. Honest negative + weaker multi-frame alternative.**

## What was measured (parent)

958 holds with distribution mean **2.4990** vs theory **2.5014** (rate OK), but
**adjacent holds equal 29.9%** vs ideal **0%** (floor 15.1%). That is **judder /
cadence clustering**, not frame *loss*. Diagnosis required a **per-frame index on
every capture** over thousands of frames.

## Why single-frame “smear encodes hold” fails here

A fast edge whose motion blur width ∝ display hold needs an **integrating**
exposure (camera shutter open across the hold). The lab path is:

  FPGA present → HDMI → MS2109 USB → **discrete MJPEG frames** @ ≤30 fps

Each grabber frame is a sampled still, not a long exposure. There is **no
measured integrating shutter** on this path. Therefore smear width in one PNG is
**not** a calibrated hold-duration channel. Shipping such a fixture would invite
exactly the ERROR-18/19 class mistake: treating an unmeasured sensor model as a
metrology channel.

## What *would* make hold visible with far fewer than 3591 frames

Still multi-frame, but cheap:

1. **Keep per-frame glass ID** (bars+checksum) — non-negotiable for “which source frame”.
2. **Hold-ruler strip (optional):** a vertical ticker that advances 1 px per
   *source* frame along x (phase = n mod W). On capture, the mode of decoded n
   across a short window still gives hold stats; you need O(tens–hundreds) of
   captures, not one, but not 3591 if you only need a cadence histogram.
3. **Phase wedge (optical):** angle ∝ sub-frame phase — still needs an integrating
   sensor to blur; **not** recommended for MS2109.

## Recommendation

Do **not** block on a single-frame judder fixture. Use glass OCR-proof / bar ID
(already shipping) + parent’s hold histogram. Audio work (T1) is the open
half of the user bug; judder is already characterisable with the video ID.
