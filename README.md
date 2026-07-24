# MiSTerPlex

**Native Plex media client for [MiSTer FPGA](https://mister-devel.github.io/MkDocs_MiSTer/)** — FPGA owns pixels and audio present (console-core philosophy); ARM owns Plex protocol and network.

Not a PC cast app with the DE10 as a dumb display. Lessons and protocol code from [mistercast-linux](https://github.com/flynnsbit/mistercast-linux) are harvested; the product path is a **dedicated `Plex.rbf` + `misterplexd`**.

## Priority

Best attainable **video + sound, perfectly synchronized**, on **CRTs and LCDs**. Full **user-level tests**. Ship feature-rich cast + library playback on-device.

## Architecture (target)

| Resource | Role |
|----------|------|
| **FPGA** | Decode (profile), frame store, vsync present, 3:2/2:2 cadence, audio FIFO |
| **BRAM** | Linebufs, bit FIFOs, audio ring |
| **SDRAM** | Working VRAM / unique frames |
| **DDR3** | Stream buffers, ARM↔FPGA payload |
| **ARM** | GDM, companion, resolve, demux control — **not** the present loop |

See [docs/architecture.md](docs/architecture.md).

## Status

| Phase | State |
|-------|--------|
| **0** Scaffold monorepo | done |
| **1** Native present core (color bars + tone + cadence) | in progress |
| **2** Plex cast → native present | next |
| **3** FPGA decode (Profile MiSTerPlex-1) | planned |
| **4** Feature-rich client | planned |

## Layout

```text
misterplex/
  fpga/Plex_MiSTer/   # Quartus core → Plex.rbf
  arm/misterplexd/    # HPS daemon
  host/libmisterplex/ # shared algorithms (cadence, …)
  tests/unit|hw/
  docs/
  scripts/
```

## Quick start (dev host)

```bash
cd /home/shawn/Projects/misterplex
make unit                 # cadence math tests
make plexd                # host skeleton daemon
```

### Build RBF (Quartus via misterfpga-dev)

```bash
export PATH=/home/shawn/Projects/misterfpga-dev/bin:$PATH
# once: mister-dev setup
make build-rbf            # long; outputs under misterfpga-dev/out or core tree
```

### OSD (Phase 1 core)

- **Content FPS** 24 / 30 / 60 / 12 — unique advance rate vs display
- **Pattern** bars / bars+block / grid / ramp
- **Audio tone** on/off
- **TV Mode** NTSC / PAL family

Film on fixed 60 Hz: set Content FPS **24** — FPGA holds frames (3:2 density), block motion advances only on unique ticks.

## Relationship to mistercast-linux

| mistercast-linux | MiSTerPlex |
|------------------|------------|
| Groovy UDP present | Native `Plex.rbf` present |
| ARM/host FFmpeg decode as product | Transitional only; FPGA decode is the goal |
| Proven companion + lip-sync lessons | Port into `misterplexd` (Phase 2) |

## License

- FPGA core / sys: GPL-2.0-or-later (MiSTer)
- Host/ARM tools: MIT unless noted
