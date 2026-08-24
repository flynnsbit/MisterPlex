# F12 Display resolution — fleet fix (user 2026-08-13)

Permanent product requirement. **Do not drop.** Fleet item: `P4-DISPLAY` + `P4-720P-MIX`.

Glass that showed this: **True480 `07f54d9f`**
(`/media/fat/_Utility/Plex.true480.07f54d9f.rbf`, md5 `07f54d9f8f0eda2fe75d9cc314f6de54`).
Not `_Utility/Plex.rbf` (`17dd3b56`).

## P4-DISPLAY — Display must change the MiSTer raster

**User:** Display resolution should change the resolution MiSTer is actually
**displaying**. If it does not, the setting is meaningless.

Today on `07f54d9f`:

- HDMI and VGA stay **640×480** after F12 Display change, save, Reset, and reboot.
- The idle chevron stays a 480p-sized glyph (painted into the 640×480 bank).
- `FRAME_W=640` / `FRAME_H=480` / `PLEX_PRESENT_TRUE_480P=1` are compile-locked.
- F12 Display only changes the host present-bank *request* (`DECODE` / `DISPLAY_RES`).
- It does **not** change `video_mode`, scandoubler, or analog 15 kHz vs 31 kHz.

**Why it matters:** a 240p TV on VGA cannot sync 640×480. With the menu as shipped
you would need a second RBF just to drive that TV. One product core should switch
the real output standard from Display (240p 15 kHz / 480p / later 720p), or the
item must not be offered.

240p ↔ 480p in one RBF is the first real step. 720p is a different pix clock
(sibling `Plex_720p24.qsf`); do not raise product `clk_sys` on `Plex.qsf`.

## P4-720P-MIX — 720p vs content hangs play

**User matrix on the same True480 glass (Mistercast / Plex Web):**

| Content | Display | Play |
|---------|---------|------|
| 240p | 240p | OK |
| 240p | 480p | OK |
| 480p | 480p | OK |
| *any* | 720p while **≠ content** | **FAIL** — waiting/buffering spinner, never starts |
| 720p | 720p | also **FAIL** on first report (Trek + Mistercast spinner) |

Recovery: set **480p/480p** and **F12 Reset**. Then play works again.

This is a **play bug**, not “HDMI did not switch.” Soft-skip ≠ PASS. Do not
call 720p Display supported until a title actually starts.

Traced (W-720p-mix **DESIGN_OK**, still **TODO** / not implemented):
`persistOsdResToConf` writes `DECODE=` **display**; `doPlay` does
`setDecodeSize(displayRes)` then PLXJ ACK at the 1280×720 doorbell
(`0x3047F130`) on true480; 720/720 has no content-size retry; reject
returns without companion `stopped` → Web spinner. PMS ladder is already
content-owned. Named design **MIX-CONTENT-BANK** (UPSCALE-ASCAL, not
refuse-closed): Content owns DECODE/PMS/bank; Display owns raster
(**RASTER-CMD**). Card (product tree):
`MisterPlex-wt-480p-lessons/Memory/lab/status/P4_720P_MIX_DESIGN.md`.

## Fleet rules

- Do **not** treat F12 Display as done because conf upserts `DISPLAY_RES=`.
- Do **not** thrash True480 `07f54d9f` to chase 720p24 unique pfps.
- Evidence: MiSTer reported HDMI/VGA mode **and** a play that starts, not OSD
  word bits alone.
- Case law: `docs/LESSONS.md` **L55** (product tree
  `/home/shawn/Projects/MisterPlex-wt-480p-lessons`).

## 968b828a (2026-08-13, W-display-j)

Live 720p24 QSF still HDMI/VGA **640×480 25.18 MHz 59.9 Hz**. Cause is **ascal `video_mode=6` + `vga_scaler=1`**, not a failed L4 beam. Display OSD persists `DISPLAY_RES` / `setDecodeSize` only; `display_res_sel` is dead on the beam; L4+`FABRIC_NATIVE` compile-locks 1280×720@24 V.info. **P4-DISPLAY stays TODO.** Card: `DISPLAY_RES_STILL_640x480_ON_J.md`. **FIT_GO=NO.**

No Plex tokens in this file.
