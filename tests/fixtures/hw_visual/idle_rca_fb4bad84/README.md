# Idle-screen RCA evidence — RBF md5 `fb4bad849ad2db782a5004ce5a3471ce`

Captured 2026-07-28 by `tests/hw/test_idle_screen_pixel_rca.sh` against the
MiSTer at `192.168.1.183`, core `Plex`, daemon idle (no playback), conf
`PRESENT=fpga DECODE=624x480 OSD_CONTROL=0`.

| File | What it is |
|------|------------|
| `probe_a.txt` | Raw doorbell-derived mailbox and DDR bank samples read with `devmem` |
| `frame_a.png`, `frame_b.png` | Consecutive HDMI captures, `/dev/video0` MJPEG 1280x720 |
| `integrity.json` | `scripts/idle_frame_integrity.py` grade of `frame_b` against `frame_a` |

Verdict: **`PRESENTED_CORRUPT`**.

Measured, not inferred:

* Both DDR banks hold a real I420 idle frame (`Y=0x2d`, `U=0x82`, `V=0x7e`), so
  the frame **is** drawn.
* `PLXD` reports `disp_bank=0 swap_pending=0 free_mask=0b10`, so the store **is**
  swapping; the frame **is** presented.
* `PLXK` sequence `0x200097D5` is identical in both samples, so the ARM rang no
  doorbell and wrote no bank while these frames were on screen. The ARM is **not**
  overwriting the scanned-out bank in this configuration.
* Picture rows begin between capture x=84 and x=136 (budget 8), and 17% of the
  left region changes between the two frames. Each scanline loses a different
  leading run.
* `PLXF` underrun is saturated at `0xFFFF`.

The damage therefore originates inside the FPGA presentation path — a per-line
DDR read underrun — and cannot be fixed from the ARM side. Fixing it needs an
RBF change, which is `w-fit-o5`'s exclusive slot.

Note for anyone reusing these frames: `scripts/hdmi_capture_classify.py` grades
both of them `VALID_CONTENT`. "The capture worked" and "the screen is wrong" are
simultaneously true here, which is exactly why the left-edge grader exists.
