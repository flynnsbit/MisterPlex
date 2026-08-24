# slot720p24j 480p/480p play reject (user 2026-08-13)

Lab: `_Utility/Plex.rbf` was **968b828a** (720p24j). User saved **480p/480p**, cast
Wherever You Go (`158527`). Glass: **chevron + slow audio**, OSD jumped toward 720p.

## Evidence (`misterplexd.log`)

1. Host *did* see 480p/480p: `content=480p display=480p DECODE=640x480`
   TRANSCODE_PROFILE=480p, PMS `640x272`.
2. Live canvas **did not shrink**: after that save, `decode=1280x720`.
   `osdRetargetDecodeSizeFromPresented` **refuses to shrink L4→480p**
   (`media_player.hpp`, P4-DISPLAY / P4-720P-MIX comment).
3. 480p play **rejected**: `sendSourceAspect: PLXJ ACK timeout want=47:20 token=35 last=47:20 token=34` → `PLAY rejected`.
4. Earlier same session a **720p decode** play ran `decode=1280x720` pfps **1.0–2.8**,
   `av_drift_ms=436–789`, many resync drops — slow audio, almost no video.
5. After reject: `content→720p display→480p` (`OSD word=0xa020`).

## What this RBF is

Compile-locked **1280×720 @ 24 Hz** present. Not the 240/480 product.
480p/480p on **Plex.true480.07f54d9f**.

## Lab restore (this card)

- `Plex.720p24.968b828a.rbf` = j (kept)
- `Plex.rbf` = copy of `Plex.true480.07f54d9f.rbf` (`07f54d9f`) so the name
  **Plex** is 480p glass again.

P4-720P-MIX stays **TODO**. Chevron ≠ 480p play PASS.
