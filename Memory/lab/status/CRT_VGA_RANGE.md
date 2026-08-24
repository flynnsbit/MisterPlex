# CRT_VGA_RANGE — connected VGA CRT analog limits

**User 2026-08-14:** VGA CRT **Hf 28–70 kHz**, **Vf 40–120 Hz**.
A **later TV** can do **15 kHz**. **HDMI first** (`HDMI_FIRST_720P60.md`).

| Signal | H | V | This CRT |
|--------|---|---|----------|
| Native 240p / 15 kHz | ~15.7 kHz | 60 Hz | **OUT** (H < 28) |
| Analog 720p24 CEA | ~18.2 kHz | ~24 Hz | **OUT** (H and V) |
| VGA 640×480@60 | ~31.5 kHz | 60 Hz | **IN** |
| Scandoubled 240p | ~31.5 kHz | 60 Hz | **IN** |
| 720p60 CEA | ~45.0 kHz | 60 Hz | **IN** (HDMI-first) |
| 1080p60 | ~67.5 kHz | 60 Hz | **edge** of 70 kHz |

`vga_scaler=1` ties VGA to HDMI. HDMI 720p60 ⇒ CRT 720p60 (in range).
HDMI 24 Hz ⇒ CRT 24 Hz (**below Vf 40**). Do not apply 24 Hz HDMI
while this CRT is on VGA scaler.

15 kHz / 240p / P4-HZ = later TV. Not this apply.
