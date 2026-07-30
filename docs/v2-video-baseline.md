# v0.2.0 video regression baseline

## What this is

The GitHub release **v0.2.0** is the last combination proven on real hardware to
render Plex playback with no left-edge defect. It is installed side-by-side with
the development build so the MiSTer always has a working configuration, and it is
the reference every future build must be measured against.

| Component | Path on device | md5 |
|---|---|---|
| Core | `/media/fat/_Utility/Plex_v2.rbf` | `dfebf2bfd08dd70b473b587dd7e81848` |
| Daemon | `/media/fat/misterplex_v2/bin/misterplexd` | `7cd10b4d438c714a9b8c4766dc982d59` |
| Conf | `/media/fat/misterplex_v2/misterplex.conf` | `PRESENT=fpga` |

The daemon binary is byte-identical to the one shipped in the public
`misterplex-v0.2.0.tar.gz` release asset.

## PRESENT=fpga, not fb0

The v0.2.0 release notes say *"`PRESENT=fb0` is the default and the safe
configuration"*, and the on-device conf carried a `(fb0 cast path)` provenance
note. **On this hardware fb0 does not reach HDMI.** Measured: with `PRESENT=fb0`
the daemon decoded normally (`vfps=22.9`, `drops=0`, `av-lock`) but `pfps=0.00`
and the captured screen was a stable, genuine black. Switching to `PRESENT=fpga`
produced `pfps=23.6` and a correct picture. The v0.2.0 bitstream presents from a
320-wide SPI-fed frame store (`present_core.sv`: `H_DE=529`, `H_STORE=320`), and
`PRESENT=fpga` is what feeds it.

## Why the dev build cannot simply reuse this core

The v0.2.0/v0.3.0 bitstreams have **no `ddr_frame_store.sv`** — only
`frame_store.sv`. The current daemon writes a 624-stride DDR YUV420p canvas
(`media_player.cpp`: *"every non-none PRESENT must open FPGA for core scanout"*),
which those older bitstreams have no reader for. Loading `Plex_v3.rbf` while the
development daemon is running produces a garbage picture — confirmed on hardware.

The DDR path landed 56 minutes after v0.3.0 was tagged:

| Event | Timestamp |
|---|---|
| `v0.3.0` tag | 2026-07-26 20:00:10 |
| `ddr_frame_layout.hpp` added (`c39f93a0`) | 2026-07-26 20:56:17 |
| `ddr_frame_store.sv` added (`d0ea6dac`) | 2026-07-27 00:40:38 |

Every daemon binary archived on the SD card post-dates that switch, so no
archived binary can drive an older core.

## The defect this baseline detects

The picture defect is identified by **edge asymmetry**, not by eyeballing:

| Build | LEFT spread | RIGHT spread | Verdict |
|---|---|---|---|
| dev core, idle screen | 61 px | **0 px** | DEFECT |
| v0.2.0 baseline, playback | 13 px | 12 px | clean |

A pixel-perfect right edge with a wandering left edge means the **DDR line fetch
starts late** — `ddr_frame_store.sv` outputs black on a miss, so the head of each
line is blanked until the burst catches up:

```systemverilog
wire rd_miss_now = rd_active && rd_visible && has_frame && (!y_hit_now || !c_hit_now);
```

This is RTL-side and needs a Quartus fit; it cannot be patched from the daemon.
It appears on the **idle screen** too, so it is not decode-, ffmpeg- or
PMS-related.

## Running the regression

```bash
scripts/video_regression.sh verify      # check the baseline hashes only
scripts/video_regression.sh baseline    # measure the v0.2.0 reference
scripts/video_regression.sh dev         # measure the development build
```

Each run enforces a single daemon, loads the matching core, casts the 240p
telemetry clip, captures HDMI and measures edge straightness.

**Parent orchestrator only.** Agents have no device access (see AGENTS.md
"Who tests").

## Capture rules that this harness enforces

- The HDMI grabber emits ~15 warm-up frames that are a single flat value
  (`min == max`). `tools/measure_edges.py` discards every uniform frame and
  fails loudly if none remain. A uniform frame is **never** scored as a pass —
  misreading one as "black screen" previously caused three false findings.
- Only one `misterplexd` may run. Duplicates were observed binding UDP 32412
  simultaneously (SO_REUSEPORT) while only one owned TCP 3005. Launch through
  `scripts/plexctl.sh`, which holds an exclusive `flock`; the older
  `dedupe_daemon.sh` races and can spawn a second daemon.

## Switching bundles

```bash
/media/fat/misterplex/bin/plexctl.sh v2      # known-good v0.2.0
/media/fat/misterplex/bin/plexctl.sh dev     # development build
/media/fat/misterplex/bin/plexctl.sh status
/media/fat/misterplex/bin/plexctl.sh stop
```

Loading the matching core is separate:

```bash
printf '%s\n' 'load_core /media/fat/_Utility/Plex_v2.rbf' > /dev/MiSTer_cmd
```

Always pair `plexctl.sh v2` with `Plex_v2.rbf`, and `plexctl.sh dev` with
`Plex.rbf`. Mismatched pairs produce a garbage or black picture.
