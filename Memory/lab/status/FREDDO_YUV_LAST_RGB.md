# Freddo DVD-core note (user 2026-08-13)

Discord/screenshot from a MiSTer **MPEG2 DVD player** author (Freddo).
Captured because the user asked to keep it as fleet case law. MPEG2 ≠ H.264;
the *shape* still applies.

## What he said (paraphrase)

- Decoder output is not a framebuffer. It is luma/chroma, then macroblocks.
  Reading a “line” is a scatter-gather. That access pattern is what he had
  to optimize.
- Store stays **YUV**; convert to **RGB only on the way out to scan**.
  About half the memory bandwidth. **Did not help performance.** Blit then
  ~200 fps. Neat, not the win.
- Speeding the video path **blew A/V calibration** tuned for the old slow
  system. Fix sync next; then a CRT idle video signal; AC3 stereo only.
- LLM “just figure it out” for ~72 h hit a wall; he had to step in and
  rewrite.

## What we already do (do not re-litigate)

- Product present is **I420 in DDR**, RGB in the FPGA on scan
  (`PLEX_STORE_YUV_PIPE` / `ddr_frame_store`). Not ARM RGB565.
- YUV 1.5 B/px vs RGB565 2 B/px was already in `docs/display-resolution.md`.
- **L46:** 720p wall is `T_copy_arm` (~15 ms uncached I420 memcpy), not
  YUV→RGB. Isolated FFmpeg ~32 fps; presented unique still FAIL.
- **L50 / P3-720P24:** 24 Hz beam ≠ 24 unique fps. His 200 fps blit is the
  same distinction.

## What to use (fleet)

1. **Next gain is gather, not “more YUV.”** Branch B fabric-direct (FPGA
   `clk_ddr` pull, skip ARM memcpy) is our version of his blit. Do not add
   a second RGB convert on ARM. Do not switch the store back to RGB565.
   If scanout moves to the SDRAM stick: **I420 in every bank**, RGB only on
   `clk_pix` out. Triple-buffer does not license RGB565 VRAM.
   Scan **~33 MB/s** during active video; **big FPGA DMAs only in HSYNC+VSYNC
   blank** (not 66 MB/s simultaneous). Our 1312×762 totals are too tight for
   that mux — need fat porches. `PATH_SDRAM_PLUS_DDR.md`.
2. **FPGA H.264 recon must land scan-order I420 (or a tiled store the
   scanner understands).** MB-order planes in DDR will replay his
   “line read is all over the place” tax on `clk_pix`/`clk_ddr`.
3. **After any real present speedup, re-measure A/V.** `AV_RESYNC_DROP_MS=80`
   was the slow-path leftover (unique ~8). `0` → ~15. Do not keep True480
   offsets on a faster blit.
4. **Idle is a timed YUV frame in the same store the beam reads** (CRT
   idle signal). `ebfe4a12` idle paint FAIL is this class, plus **P4-DISPLAY**.
5. **72 h play-loop = his LLM wall.** New data path, not another bitrate/OSD
   knob. Soft-skip ≠ PASS.

Lessons: **L56** (`MisterPlex-wt-480p-lessons/docs/LESSONS.md`).
Backlog: cite from **P3-720P24** / Branch B; do not invent a new exclusive
from this note alone.

No Plex tokens in this file.
