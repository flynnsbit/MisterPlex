# slot720p24i post-BUILD_OK HDMI validate (recipe)

**CARD only.** Exclusive **LIVE** `slot720p24i` at write (map). **BUILD_OK=NO.**
**READY_TO_DEPLOY=NO.** **GLASS=NOT RUN.** Soft-skip ≠ PASS.
**This card ≠ BUILD_OK ≠ DEPLOY_OK ≠ chevron PASS ≠ T7 ≠ P4-DISPLAY.**
No Quartus. No deploy. No `load_core`. Do **not** invent BUILD_OK or glass PASS.

## When this gate may run (not now)

After **parent** **BUILD_OK** of a **NEW** `slot720p24i` RBF **and** **LOCK_OK**
**and** NEW_RBF ∉ banned `{8832824e,75da8bb1,4d6ee356,4deaf6cc,dabdaeb0,
17dd3b56,e494a767,740e19d6,c052be56,5a7c5085,07f54d9f,0bcc6081,ebfe4a12,…}`
**and** **ONE** `DEPLOY_LOAD=menu` (deploy owner) **and** lab
`/media/fat/_Utility/Plex.rbf` **MATCH** that prefix. Idle (not playing).
Grabber free (close OBS). Mid-fit / LIVE exclusive / same **`ebfe4a12`** =
**do not run.** Keep true480 **`07f54d9f`**.

## Lab grabber

UVC **`534d:2109`** on **`/dev/video4`** (this machine). MJPEG.
Never bare `ffmpeg -frames:v 1` (**L16**). First frames are **false black**.

## Recipe

From lessons tree (dirty `main` has no copy):

```
HDMI_DEV=/dev/video4 HDMI_SIZE=1280x720 \
  /home/shawn/Projects/MisterPlex-wt-480p-lessons/scripts/hdmi_capture_idle.sh \
  Memory/lab/captures/slot720p24i_idle_hdmi_1280.png 45
```

Prints `MEAN=… STD=… ORANGE_PX=… ACTIVE=WxH FILE=…`.
`HDMI_TRIES` default 3. Exit 1 = `GRABBER_NOT_READY` (**not** a core FAIL).

## Chevron PASS (this gate only)

**PASS:** `ORANGE_PX>0` **and** not uniform black.
**FAIL:** `ORANGE_PX=0` or uniform black (`MEAN==0` `STD==0`).
Healthy 480p chevron was `ORANGE_PX=33852` / MEAN 15..70 (cite only).

`HDMI_SIZE=1280x720` is the **grabber request**. Overlay may still say
**640×480 HDMI** (`25.18 MHz 59.9 Hz`) under `1280×720 24.0 Hz` —
that is **P4-DISPLAY** (TODO), **not** a fail of this gate.

## Not this gate

- Unique pfps **T7** (≥23.9). 24 Hz beam ≠ 24 unique fps.
- Native 720p raster / F12 Display (**P4-DISPLAY** / **P4-720P-MIX** TODO).
- **FABRIC_PASS.** Live **`ebfe4a12`** idle was MEAN=2.1 **ORANGE_PX=0**
  (`HDMI_USB_EYES.md`) — black beam; **not** slot720p24i evidence.

## Do not

Run mid-fit. Second menu for luck. `load_core`. Treat first-frame black
as FAIL. Treat overlay 640×480 as this FAIL. Stamp BUILD_OK / glass
from this file.

## Evidence (recipe, not result)

- lessons `scripts/hdmi_capture_idle.sh`
- `docs/LESSONS.md` **L16**
- `Memory/lab/status/HDMI_USB_EYES.md` (ebfe4a12 black, not this gate)
- `Memory/lab/status/DISPLAY_RES_MUST_CHANGE_RASTER.md` (P4)
