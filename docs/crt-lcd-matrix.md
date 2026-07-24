# CRT / LCD display matrix checklist (Phase 5)

Lab checklist for MiSTerPlex present paths on **15 kHz CRTs** and **HDMI LCDs**. Status reflects the monorepo as of Phase 5 foundation — not a full golden visual suite.

Related: [match-source-hz.md](match-source-hz.md), [architecture.md](architecture.md), [release.md](release.md).

## Display strategies

| Strategy | When | Status |
|----------|------|--------|
| Fixed display Hz + FPGA cadence | Default for both CRT and LCD | **Ship** — OSD **Content FPS** + `present_cadence` |
| Match source Hz (modeline ≈ content) | Multi-rate CRT or VRR-ish LCD | **TODO** — conf keys logged only; no switchres |
| ARM fb0 + ascal | Phase 2 cast without Plex core | **Ship** — continuous RGB24 → `/dev/fb0` |

## Hardware matrix

| Output | Typical path | Present path | Notes |
|--------|--------------|--------------|-------|
| **HDMI LCD** 60 Hz | Direct DE10 HDMI | `PRESENT=fb0` or Plex core frame store | Easiest lab path; use Content FPS 24 for film cadence |
| **HDMI LCD** 50 Hz | DE10 + TV Mode PAL | Same | Set TV Mode family in OSD when using Plex.rbf |
| **VGA → 15 kHz CRT** | Analog via MiSTer VGA/DAC | fb0/ascal **or** Plex.rbf | Prefer 320×240-class modelines; long VBlank for 15 kHz |
| **VGA → 31 kHz / PC CRT** | Higher line rate | Same | Less picky; 480p-class possible if ARM keeps up |
| **Y/C / component** | Board-dependent | Same as VGA family | Not separately tested in this suite |

## Content FPS vs content rate (cadence)

With **fixed 60 Hz** display (common LCD / NTSC CRT):

| Content | OSD Content FPS | Expected unique advance | Checklist |
|---------|-----------------|-------------------------|-----------|
| Film ~24p | **24** | 3:2 density on 60 Hz | [ ] motion block / recon advances on film ticks only |
| Video ~30p | **30** | 2:2 | [ ] smooth vs 60 unique |
| Progressive 60 | **60** | 1:1 | [ ] no extra hold |
| Slow debug | **12** | sparse | [ ] clearly stepped motion |

Math (unit-tested): `content_index = floor(display_index * content_fps / display_hz)` — see `host/libmisterplex/cadence.hpp`.

## Modeline / match-source-Hz status

| Item | Status | Action for lab |
|------|--------|----------------|
| OSD Content FPS 12/24/30/60 | **done** (`Plex.sv`) | Set per title type |
| Conf `MATCH_SOURCE_HZ=off` | **parsed/logged** | Leave off |
| Conf `SOURCE_FPS=auto` | **parsed/logged** | OSD wins |
| HPS modeline switch from misterplexd | **TODO** | Use MiSTer video menu / ini for CRT |
| Ship `assets/modelines.dat` | **TODO** | Copy from mistercast-linux when wiring |
| Auto Content FPS from PMS `videoFrameRate` | **TODO** | Manual OSD today |

### 15 kHz CRT modeline families (target when switchres lands)

Borrow names/rates from mistercast-linux `assets/modelines.dat` when implementing:

| Family | Approx refresh | Use |
|--------|----------------|-----|
| NTSC 60 | ~60 Hz | Default safe CRT |
| Film 24 | ~24 Hz | True 24p without 3:2 (match-Hz on) |
| NTSC 30 | ~30 Hz | 30p native |
| PAL 50 | ~50 Hz | PAL sets |

Film/30 modes need longer vertical blanking so horizontal rate stays near **15 kHz**. Some CRTs blank at 24 Hz — if so, force match-Hz **off** and use Content FPS **24** at 60 Hz.

## PRESENT / STREAM × display checklist

| Conf | HDMI LCD | 15 kHz CRT | What to verify |
|------|----------|------------|----------------|
| `PRESENT=fb0` `STREAM=0` | [ ] picture + sound | [ ] ascal/fb stable | Phase 2 cast golden |
| `PRESENT=both` `STREAM=0` | [ ] fb0 primary | [ ] optional F1 if core loaded | No regression vs fb0-only |
| `PRESENT=both` `STREAM=1` | [ ] fb0 + recon log | [ ] same + core status | Log: `STREAM=1 host I-slice recon` |
| `PRESENT=fpga` `STREAM=1` | [ ] frame store image | [ ] same | Needs Plex.rbf + Video source = Frame store |

## Audio checklist (all displays)

| Check | Pass criteria |
|-------|----------------|
| Single FFmpeg | `tests/hw/test_single_process.sh` — one demux for A/V |
| MrAudio | Tone/PCM on analog/HDMI audio path |
| Pause/resume | A/V both freeze and continue (`test_media_fb.sh`) |
| No 60 fps forced unique RGB | Lip-sync holds at weak ladder rates |

## Lab procedure (quick)

1. Confirm conf: `/media/fat/misterplex/misterplex.conf` (`PRESENT`, `STREAM`, `DECODE`).
2. Deploy: `./scripts/deploy_misterplexd.sh`.
3. Display under test: HDMI **or** CRT via VGA; note TV Mode / scaler.
4. Phase 2 smoke: `./tests/hw/test_media_fb.sh` + play known PMS episode.
5. If Plex.rbf: set **Content FPS** for title type; optional **Video source = Frame store** for FPGA path.
6. Soak: `SOAK_HOLD_S=8 SOAK_ROUNDS=1 ./tests/hw/test_soak.sh` (auto-uses MiSTer conf + PMS titles when token present).
7. Record: output type, PRESENT/STREAM, Content FPS, pass/fail, notes (blanking, tear, audio drop).

## Known display limits

- No automated frame-capture golden vs CRT.
- Match-source-Hz does **not** change PLL/modeline yet.
- High `DECODE` (e.g. 720p) may drop frames on dual-A9 before FPGA decode lands.
- STREAM recon is I-frame oriented; P-frames still rely on FFmpeg for fb0 continuity when `PRESENT=both`.

## Sign-off table (fill per session)

| Date | Output | PRESENT | STREAM | Content FPS | Media | Result | Notes |
|------|--------|---------|--------|-------------|-------|--------|-------|
| | HDMI 60 | fb0 | 0 | n/a | local test.mp4 | | |
| | HDMI 60 | both | 1 | 24 | library ep | | |
| | CRT 15 kHz | fb0 | 0 | n/a | library ep | | |
| | CRT 15 kHz | fpga | 1 | 24 | annex-B / weak | | |
