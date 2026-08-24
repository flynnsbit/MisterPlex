# Farm HDMI eyes-on — test glass yourself

**User 2026-08-14 (standing).** Also **L58**.

Do **not** ask the user to look at the TV. After every play or deploy,
SSH to **node-worker1**, grab a frame, pull it back, and read it yourself.

SoT card: `MisterPlex-wt-480p-lessons/Memory/lab/status/FARM_HDMI_EYES.md`

| | |
|--|--|
| Host | `node-worker1` |
| Dongle | MacroSilicon `534d:2109` UVC |
| Device | `/dev/video0` (metadata `/dev/video1`) |
| Recipe | MJPEG `1280x720` via ffmpeg; **not** YUYV |
| Artifacts | `/tmp/misterplex-eyes/<tag>.jpg` |

USB grab ≠ CRT. Eyes-on ≠ unique-24.

**Living 2026-08-15 (05:44Z c073b546):** Pointer/pin only. SoT `MisterPlex-wt-480p-lessons/Memory/lab/status/FARM_HDMI_EYES.md`. Official `c073b546-ss1.jpg` **`dadf9a4a`** / ss2 **`0722cc80`**. I SAW **green-tint chevron** + OSD **1280×720 12.12 kHz 16.0 Hz** over **74.25/60**. CLASS=**CHEVRON_GREEN_USB**. unique24=**FAIL** cite `/tmp/pfps-720p24-c073b546.txt` pfps=**23.3** hw_fps=**14.78** F@118=**YES**. **OSD 16 Hz ≠ unique-24**. **Chevron ≠ unique-24**. EYES_OK ≠ unique-24. Cite `/tmp/misterplex-agent-E-eyes-0544.txt`.

**Living 2026-08-14 INI-unpin (E-eyes-snow):** Farm `ini-unpin-720p-ss1.jpg` is **green snow** (not 640×480 OSD `3c7e869f`). First/warm siblings black. **PHY_PASS=NO.** Snow ≠ unique-24. P4-DISPLAY **TODO**. Cite `/tmp/misterplex-agent-E-eyes-snow.txt`.
**Living 2026-08-14 (m1 CLOSED):** Official `/tmp/misterplex-eyes/plxf-m1-ss1.jpg` I SAW **1280×720 18.19 kHz 24.0 Hz** over **1280×720 74.25 MHz 60.0 Hz** rest **black**. **PHY_PASS=NO**. **HDMI_24_ON_60**. Parent stay-up `plxf-m1-stay-ss1.jpg` md5 **`14c877c3`** **TRUE-BLACK**. USB ≠ CRT. Eyes-on ≠ unique-24. OSD 24 Hz ≠ unique-24. OSD 74.25/60 ≠ unique-24. Cite `/tmp/misterplex-agent-E-eyes-m1.txt` · `/tmp/misterplex-agent-P-plxf-m1-play.txt`.
**Living 2026-08-14 (21:14 idle):** Official play eyes stay `plxf-m1-ss1.jpg` **HDMI_24_ON_60** **PHY_PASS=NO**. Parent idle this tick `parent-idle-2114-ss1.jpg` md5 **`e74e3559`** **FALSE-BLACK** first-frame · sibling `parent-idle-2114-ss1b.jpg` md5 **`21febc10`** **BLACK** no OSD (I opened both: **black**, no OSD). Card did **not** say Next=RCA (no RCA pin to replace). USB ≠ CRT. Eyes-on ≠ unique-24. OSD 24 Hz ≠ unique-24. Cite `/tmp/misterplex-loop-status.txt` · `/tmp/misterplex-agent-E-eyes-m1.txt`.
**Living 2026-08-14 (21:26 idle):** Pointer/pin only. SoT `MisterPlex-wt-480p-lessons/Memory/lab/status/FARM_HDMI_EYES.md` + `docs/LESSONS.md` **L58**. Official `plxf-m1-ss1.jpg` md5 **`74851ab9` KEPT** **HDMI_24_ON_60** **PHY_PASS=NO**. Parent 21:26Z `parent-idle-2126.jpg` **`e74e3559`** FALSE-BLACK MEAN=**7** · ss1/ss2 **`14c877c3`** TRUE-BLACK MEAN=**0** (I opened: **black**, no OSD). FPGA **NOW=NGPC**. TRUE-BLACK on NGPC ≠ Plex FAIL restamp. Last Plex SPI **21:16Z** CLASS=**HAS_FRAME_0_SCAN_BLACK**. unique24=**FAIL**. **HDMI_PASS=NO**. **FIT_GO=NO**. Cite `/tmp/misterplex-agent-L-lessons-2126.txt` · `/tmp/misterplex-loop-status.txt`.
**Living 2026-08-14 (21:45Z idle):** Pointer/pin only. SoT `MisterPlex-wt-480p-lessons/Memory/lab/status/FARM_HDMI_EYES.md` + `docs/LESSONS.md` **L58**. Lab **NOW CORE=Plex `f02aa88b`** has_frame=**1** CLASS=**HAS_FRAME_1_CHEVRON_VISIBLE**. **21:26Z TRUE-BLACK on NGPC SUPERSEDED** for living glass. I opened `plex-hasframe-ss1.jpg` **`3fbeee5a` KEPT** orange chevron + OSD 24 Hz over **640×480 25.18/60**; `parent-idle-2143.jpg` **`e74e3559`** FALSE-BLACK MEAN=**7**; ss1 **`6ff568ec`** MEAN=**39.6** dark scan no OSD; ss2 **`48071d5f`** MEAN=**26.4** I SAW orange chevron + same OSD. Glass idle **PASS**. **Chevron ≠ unique-24**. **OSD 24 Hz ≠ unique-24**. unique24=**FAIL**. **HDMI_PASS=NO**. **PHY_PASS=NO** leftover **HDMI_24_ON_640x480_60**. **FIT_GO=NO**. Cite `/tmp/misterplex-agent-L-lessons-2143.txt` · `/tmp/misterplex-loop-status.txt`.
**Living 2026-08-14 (21:56Z):** Pointer/pin only. leftover **HDMI_24_ON_640x480_60**; no new grab this tick. Living eyes remain ss2 **`48071d5f`**. USB JPEG 1280×720 ≠ PHY PASS. Cite `/tmp/misterplex-agent-L-lessons-2156.txt` · SoT `docs/LESSONS.md` **L55/L58**.
**Living 2026-08-14 (22:07Z idle):** Pointer/pin only. SoT `MisterPlex-wt-480p-lessons/Memory/lab/status/FARM_HDMI_EYES.md` + `docs/LESSONS.md` **L58**. Parent grab `parent-idle-2207.jpg` **`e74e3559`** FALSE-BLACK · ss1 **`c101fd45`** green snow RIGHT · ss2 **`050fd6d1`** orange chevron + OSD 24 Hz over **640×480 25.18/59.9**. Living analog **NOW 59.9**. CLASS=**HAS_FRAME_1_CHEVRON_VISIBLE**. **HDMI_24_ON_640x480_60**. USB JPEG 1280×720 ≠ PHY PASS. unique24=**FAIL**. **HDMI_PASS=NO**. **PHY_PASS=NO**. **FIT_GO=NO**. Cite `/tmp/misterplex-agent-L-lessons-2207.txt` · SoT `docs/LESSONS.md` **L55/L58**.
**Living 2026-08-14 (22:19Z idle):** Pointer/pin only. SoT `MisterPlex-wt-480p-lessons/Memory/lab/status/FARM_HDMI_EYES.md` + `docs/LESSONS.md` **L58**. Parent grab `parent-idle-2219.jpg` **`e74e3559`** FALSE-BLACK · ss1 **`cb565cbb`** I SAW Menu Bubble Bobble wallpaper · ss2 **`b899cb7a`** same Menu wallpaper. **CLASS=MENU_NOT_PLEX**. FPGA **NOW=MENU**. 2207 ss2 **`050fd6d1`** chevron is **HISTORY**. USB JPEG 1280×720 ≠ PHY PASS. unique24=**FAIL**. **HDMI_PASS=NO**. **PHY_PASS=NO**. **FIT_GO=NO**. Cite `/tmp/misterplex-agent-L-lessons-2219.txt` · SoT `docs/LESSONS.md` **L55/L58**.
