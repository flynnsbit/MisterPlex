# v0.3.0 lab-stable pair (320×240) — do not split

**Not a GitHub Release.** Published GitHub releases are **v0.2.0** and **v0.4.0** only.
Tag `v0.3.0` exists; release notes are draft. This directory freezes the **lab pair card**
from 2026-07-29 (`docs/release.md` § Lab stable pair) so we stop rediscovering it.

| Piece | MD5 | Notes |
|-------|-----|--------|
| `Plex.rbf` | `41adb98c7a630b541091c22ce291be68` | Phase A playback-controls core |
| `misterplexd` | `06c5735a2f85114688f0ff2ac36e4fd4` | Built at tag v0.3.0 / lab ship; **git object dangling post-rebase** but this **binary** is the partner |

| Conf (required) | Value |
|-----------------|--------|
| `PRESENT` | **`both`** (ship-verified 2026-08-11 — fb0 alone fails movie glass) |
| `DECODE` / content | **320×240** |
| `STREAM` | `0` |
| `IDLE_SCREEN` | `logo` |
| `OSD_CONTROL` | `1` |

**Bank rule:** 320×240 bank1 = `0x30040000`. A 480p-line daemon with this core corrupts background. Never mix with FOAR/yuv 624 daemons.

**Ship tarball:** `dist/misterplex-v0.3.0.tar.gz`

**Features (v0.3 scope):** local transport (space/esc/skip), **on-screen playback overlay**, companion/PMS timeline, 320 content. Not multi-res F12 ladder (that is v0.4).

**Deploy / verify:** `scripts/v3_stable_320_loop.sh` or `make v3-stable-320`.
