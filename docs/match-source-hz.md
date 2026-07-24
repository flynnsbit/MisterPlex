# Match source Hz / modeline (Phase 4)

## Goal

Smooth film (24p) and video (30p) on CRTs and LCDs without starving audio or tearing.

Two strategies (same as [mistercast-linux](https://github.com/flynnsbit/mistercast-linux)):

| Mode | Behavior |
|------|----------|
| **Fixed display Hz + cadence** (default) | Keep panel/CRT at 60 (or 50) Hz; present engine holds unique frames (3:2 / 2:2). |
| **Match source Hz** | Switch modeline so refresh ≈ content (24 / 30 / 50 / 60). Frames stay native. |

## What works today (no RBF change)

### A) FPGA present cadence (shipped in Phase 1 `Plex.rbf`)

OSD → **Content FPS** = 24 / 30 / 60 / 12.

Math (unit-tested in `host/libmisterplex/cadence.hpp` and `rtl/present_cadence.sv`):

```text
content_index = floor(display_index * content_fps / display_hz)
```

Film on fixed 60 Hz: Content FPS **24** → unique advance only on 3:2 density ticks; no forced `fps=60` in FFmpeg.

Conf keys (logged by `misterplexd`, authoritative control is OSD until switchres lands):

```bash
MATCH_SOURCE_HZ=off   # default — cadence path
SOURCE_FPS=auto       # reserved; OSD Content FPS wins today
```

### B) ARM decode path (Phase 2)

FFmpeg delivers **unique** frames at content rate (or weak-ladder rate) into `/dev/fb0` or FPGA frame store. Do **not** reclock to 60 unique RGB/s in a single-process A/V demux — that starves PCM (`/dev/MrAudio`).

## What needs work (TODOs — may need RBF / Main_MiSTer hooks)

True **Match source Hz = on** as in mistercast-linux/Groovy requires:

1. **Runtime modeline switch** on the HPS side (Groovy `CmdSwitchres` / PLL reconfig path), **or** a Plex-core OSD that changes `sys` video timing the same way.
2. A **`modelines.dat`** family for 15 kHz CRTs (Film 24 / NTSC 30 / NTSC 60 / PAL 50) — copy from mistercast-linux `assets/modelines.dat` when wiring starts.
3. **Source FPS hint** from PMS `videoFrameRate` → pick modeline; log line like  
   `match-source-Hz: switchres → 320x240 Film (24Hz)`.

| Item | Status |
|------|--------|
| Cadence math FPGA + unit tests | **done** |
| OSD Content FPS | **done** (`Plex.sv`) |
| Conf `MATCH_SOURCE_HZ` / `SOURCE_FPS` keys | **parsed/logged** (no-op switchres) |
| HPS modeline switch from `misterplexd` | **TODO** (likely needs Main/sys hooks; not free without RBF or companion binary support) |
| Auto-select Content FPS from PMS metadata | **TODO** (software-only; no RBF) |
| Ship `assets/modelines.dat` with release | **TODO** when switchres wires |

**Verdict:** ship cadence-only for Phase 4 foundation. Do **not** block Phase 3 FPGA decode on modeline switch. Wire match-Hz when a present path can change refresh without regressing lip-sync.

## Pipeline (target when match-Hz lands)

```text
Plex videoFrameRate (e.g. 24p)
  → pick modeline @ 24 Hz
  → switchres / PLL
  → unique frames @ content rate
  → WaitSync / VBL at modeline period
  → audio continuous @ 48 kHz
```

## Related

- [architecture.md](architecture.md) — display policy
- [profiles.md](profiles.md) — codec ladder
- mistercast-linux `docs/match-source-hz.md` — proven Groovy host path
