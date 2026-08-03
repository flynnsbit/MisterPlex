# Decode-only (ffmpeg -f null) by geometry class

## Machine class (rule 0)
- **This table host column = x86_64 build machine** (`x86_64 Linux-7.1.5-arch1-1-x86_64-with-glibc2.44`).
- **NOT** the DE10-Nano dual Cortex-A9.
- Device A9 column is **archive only** (W-FEED ARM profile).
- Do **not** convert x86 ms/f into a ship verdict for the A9.

## Method
- instrument: `build/ffmpeg_cpu_probe` + `ffmpeg -f null -frames:v 240`
- sample: synthetic Baseline H.264 testsrc2 (same encode flags for all classes)
- wall_ms_f = 1000 * wall_s / frames; cpu_ms_f = 1000 * child_cpu_s / frames

## Table

| geom | pixels | x86 wall_ms/f | x86 cpu_ms/f | device_A9 decode_null wall_ms/f |
|------|-------:|--------------:|-------------:|--------------------------------:|
| 720x480 | 345600 | 0.2706 | 0.8247 | — unmeasured |
| 640x480 | 307200 | 0.2398 | 0.6905 | — unmeasured |
| 624x480 | 299520 | 0.2822 | 0.7241 | 21.5619 |
| 624x352 | 219648 | 0.2418 | 0.6155 | — unmeasured |
| 416x234 | 97344 | 0.1995 | 0.4287 | — unmeasured |
| 320x240 | 76800 | 0.1815 | 0.3770 | — unmeasured |

## Device FEED decomposition @624×480 (dual-A9 archive — the ship-relevant stack)

| bucket | ms/f | % of 30fps budget (33.333) |
|--------|-----:|---------------------------:|
| decode_null | 21.5619 | 64.7% |
| scale Δ | 2.9543 | 8.9% |
| pipe Δ | 5.2634 | 15.8% |
| parent copy | 2.3094 | 6.9% |
| **present/DDR** | **10.4106** | **31.2%** |
| **sum (full stack)** | **40.1902** | — |
| decode+pipe+present (no scale/copy) | 37.236 | — |
| decode+pipe only (fabric owns present) | **26.825** | **@30 PASS margin 6.51** |

Source: `docs/PHASE_BACKLOG.md` W-FEED bucket sum; `docs/evidence/p480/p720-bus-and-bitrate-margin.md`.

## x86 relative ranking (cpu_ms/f ascending)

- 320x240: 0.3770 cpu_ms/f
- 416x234: 0.4287 cpu_ms/f
- 624x352: 0.6155 cpu_ms/f
- 640x480: 0.6905 cpu_ms/f
- 624x480: 0.7241 cpu_ms/f
- 720x480: 0.8247 cpu_ms/f

## Loud-reject lane note
`geom_reject` → black + PLXF 0xE2 lives in **w-mem worktree, unmerged** — not product until merged.
