# HDMI-USB eyes-on (user 2026-08-13)

**PLUGGED 2026-08-13 ~23:08Z (user).** UVC `534d:2109` is `/dev/video4` again.
Idle capture on true480 `07f54d9f` 480p/480p: `true480_now.png`
MEAN=39.2 STD=23.4 **ORANGE_PX=5502** ACTIVE=618x480. Dongle works.
Do **not** treat this as P4-DISPLAY PASS or T7. T7 still needs j reload
(parent). Companion `6f1afebe` still not deployed.

Dongle: UVC `534d:2109` on **`/dev/video4`** (this machine) **when plugged**.
Recipe: `HDMI_DEV=/dev/video4 HDMI_SIZE=1280x720 scripts/hdmi_capture_idle.sh OUT.png 45`
(MJPEG, discard ~45-frame lock; first frames are false black.)

First capture of live `ebfe4a12` idle (F12 720p/720p):
- `Memory/lab/captures/ebfe4a12_idle_hdmi_1280.png`
- MEAN=2.1 ORANGE_PX=0 — **no chevron**
- MiSTer overlay: **1280×720  0.00KHz  24.0Hz** over **640×480  25.18MHz  59.9Hz**
- Picture is black. HDMI to the dongle is 640×480@60, not native 24 Hz 720p.

Soft-skip ≠ PASS. Do not invent glass chevron.
