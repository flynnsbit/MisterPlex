# CEA_OSD_24HZ_VIDEO_MODE5 — two HDMI lines, one ascal cmd

**Worker:** H-display · **2026-08-14T19:38Z** · **RCA_OK only.**
**RCA_OK ≠ unique-24 ≠ HDMI PASS ≠ P4-DISPLAY DONE.** Soft-skip ≠ PASS.
**unique24=FAIL.** **FIT_GO=NO.** ZERO play / Quartus / `/bin/fpga` / INI / ssh.

SoT card: `MisterPlex-wt-480p-lessons/Memory/lab/status/CEA_OSD_24HZ_VIDEO_MODE5.md`

RBF **`347bb7ea`** **SKIP_RESTORE**. Bak **KEEP `07f54d9f`**.

## Verdict (short)

Play2 daemon `display raster 480p → video_mode 5` is RASTER-CMD from saved OSD **Display=480p** (`0xa010`). Farm OSD **1280×720 18.19 kHz 24.0 Hz** is CEA **present_core** (1650×758 @ 30 MHz). Second line **640×480 25.18 MHz 59.9 Hz** is **ascal**. FPGA owns the 24 Hz **core** raster; scaler 480p is a **second path**. Do **not** request `video_mode` 8/12/custom 720p24 from host after CEA. unique24 still needs **presented>0** + **F@+0x118**. HDMI scaler is not a reason to loosen F.

Cite SoT card for the full trace.
