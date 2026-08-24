# P4_HDMI_24_ON_60 — 24 Hz FPGA raster on 720p60 HDMI / ascal mix

**Living 2026-08-14T22:07Z — G-hdmi-card-2207:** one-line pointer → SoT
`/home/shawn/Projects/MisterPlex-wt-480p-lessons/Memory/lab/status/P4_HDMI_24_ON_60.md`.
Living leftover still **NOT 74.25**. 22:07Z confirms **59.9 VGA**
(ss2 **050fd6d1**). CLASS living = **HDMI_24_ON_640x480_60**.
INI **`[MiSTer] video_mode=6` LIVE**. **PHY_PASS=NO.** **HDMI_PASS=NO.**
unique24=**FAIL**. **FIT_GO=NO.** Do **not** fork a class here.

**Historical 2026-08-14T21:56Z — G-p4-card-2156:** one-line pointer → SoT
`/home/shawn/Projects/MisterPlex-wt-480p-lessons/Memory/lab/status/P4_HDMI_24_ON_60.md`.
CLASS living leftover = **HDMI_24_ON_640x480_60** (21:45Z OSD analog
**640×480 25.18/60**). m1 74.25/60 is **historical play leftover**.
**PHY_PASS=NO.** **HDMI_PASS=NO.** unique24=**FAIL**. **FIT_GO=NO.**
**CARD_OK ≠ unique-24 ≠ HDMI PASS ≠ FIT_GO.** Do **not** fork a class here.

**Historical 2026-08-14T21:00Z — H-hdmi-24-m1 (abridged fork; not living):** After **PRODUCT_PLXF_M1 ONE play
CLOSED** RBF **`f02aa88b`** SKIP_RESTORE. Exclusive **FREE**. unique24=**FAIL**
(12.5 / F@118=**NO**; orthogonal). **PHY moved.** Official during-play OSD
I SAW `plxf-m1-ss1.jpg` (19942 B md5 **74851ab9**):
`1280×720  18.19KHz  24.0Hz` over `1280×720  74.25MHz  60.0Hz` — rest **black**.
No movie. No chevron. **NOT** leftover `640×480 25.18MHz 59.9Hz` (md5
**3c7e869f**). Stay-up `plxf-m1-stay.jpg` **e74e3559** MEAN=**7** FALSE-BLACK;
`plxf-m1-stay-ss1.jpg` **14c877c3** MEAN=**0** TRUE-BLACK I SAW black.
74.25/60 = 720p60 ascal, **not** unique 24 Hz. CLASS stays **HDMI_24_ON_60**.
**PHY_PASS=NO.** Picture=**NO.** **P4-DISPLAY** stays **TODO.** **P4-HZ**
stays **DEFER.** OSD text ≠ PHY PASS (**L55**). Do **not** invent unique24
PASS from OSD 24.0Hz. Did **not** write `MiSTer.ini`. Did **not** echo
`/dev/MiSTer_cmd`. Did **not** unpin/re-pin `video_mode=6`. Did **not** play.
Did **not** Quartus. L58: opened official m1 JPEGs only (no new grab).
Cite `/tmp/misterplex-agent-H-hdmi-24-m1.txt` · `/tmp/misterplex-loop-status.txt`.

**Living 2026-08-14T20:44Z — H-hdmi-24 (historical):** Exclusive was **LIVE
`slot720p24plxf` PRODUCT_PLXF_M1**. HDMI leftover then **unchanged**
CLASS=**HDMI_24_ON_60**. Snow ≠ PASS. **PHY_PASS=NO.** Cite
`/tmp/misterplex-agent-H-hdmi-24.txt`.

**Worker:** H-hdmi-mix · **2026-08-14T20:25Z** · **CLASS_OK only.**
**INI unpin closed the VGA pin leftover.** unique24 then **FAIL** (12.8 /
F@118=NO).

SoT card: `MisterPlex-wt-480p-lessons/Memory/lab/status/P4_HDMI_24_ON_60.md`

Cite: `/tmp/misterplex-eyes/plxf-m1-ss1.jpg` ·
`docs/LESSONS.md` **L55** **L58** · lab RBF **`f02aa88b`** CEA 1650×758 pix30 ·
modeline `1280,110,40,220,720,5,5,20,74250` = 720p60 / 74.25 MHz.

## Verdict

**ONE P4 class: HDMI_24_ON_60** — CEA **24 Hz FPGA** beam
(1650×758 @ 30 MHz ≈ 18.19 kHz / 23.986 Hz) mixed onto **720p60** HDMI / ascal
(1650×750 @ 74.25 MHz = 60 Hz). `vsync_adjust=0` `direct_video=0`.

PHY analog line **MOVED** off VGA (I SAW 74.25/60). Picture **black**.
OSD ≠ raster PASS. **PHY_PASS=NO.**

INI `video_mode=6` COMMENTED is a **closed** leftover. 640×480 pin card is
**SUPERSEDED for living leftover**.

**P4-DISPLAY TODO.** **P4-HZ DEFER** (24 Hz HDMI modeline). unique24 **FAIL**
orthogonal. **FIT_GO=NO.** Do not replay **`f02aa88b`** / **`849bc600`**.

No Plex tokens in this file.
