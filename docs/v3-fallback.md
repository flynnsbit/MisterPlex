# v0.3.0 (v3) known-good fallback bundle

## What this is

A **side-by-side** daily-driver fallback while development HEAD has a visible
scanline left-edge wander on the DDR frame-store path.

| Piece | Path / identity |
|-------|-----------------|
| Core (already on device) | `/media/fat/_Utility/Plex_v3.rbf` |
| Core md5 | `41adb98c7a630b541091c22ce291be68` |
| Core source | `release_artifacts/v0.3.0/Plex.rbf` (byte-identical) |
| Daemon binary | `release_artifacts/v3_fallback/misterplexd` |
| Daemon base | git tag `v0.3.0` (`cacd8717`) |
| On-device install root | `/media/fat/misterplex_v3/` |

Dev install stays at `/media/fat/misterplex/` + `/media/fat/_Utility/Plex.rbf`.
This bundle **must not** overwrite those paths.

## Why it exists

Development HEAD’s present path is DDR YUV420p canvas scanout
(`ddr_frame_store.sv`). On a DDR miss the RTL returns black for the rest of the
visible line, so a late fill makes the left edge wander (~44 px class defect).

Tag `v0.3.0` has **no** `ddr_frame_store.sv`. Its present path is a 320×240 RGB
`frame_store` fed over SPI and stretched across the active display:

```text
# git ls-tree -r --name-only v0.3.0 -- fpga/Plex_MiSTer/rtl/
# includes frame_store.sv + present_core.sv; no ddr_frame_store.sv
```

From `v0.3.0:fpga/Plex_MiSTer/rtl/present_core.sv` (quoted constants):

```systemverilog
localparam H_DE = 10'd529;
localparam H_STORE = 10'd320;
localparam DE_LAG = 3'd3;
// instantiated as frame_store #(...)
```

## Incompatibility: v3 core ↔ current daemon

Today’s daemon **always** opens the FPGA path for every non-`none` PRESENT and
publishes a 624-stride DDR YUV420p canvas the v3 core cannot consume:

```cpp
// arm/misterplexd/media_player.cpp (development HEAD)
const bool wantFpga = true; // every non-none PRESENT must open FPGA for core scanout
// ...
log("media: FPGA frame path OK (PRESENT=" + presentMode_ + " -> DDR YUV420p)");
```

The v0.3.0 daemon still uses the era-matched present ladder (fb0 and/or FPGA
RGB565 DDR bulk 320×240 with SPI F1 fallback):

```cpp
// v0.3.0 arm/misterplexd/media_player.cpp — initPresent()
bool wantFb = (presentMode_ == "fb0" || presentMode_ == "both" || presentMode_.empty());
bool wantFpga = (presentMode_ == "fpga" || presentMode_ == "both");
// ...
log("media: FPGA frame path OK (PRESENT=fpga → DDR bulk 3.1b, SPI F1 fallback)");
```

Running **current** `misterplexd` against `Plex_v3.rbf` yields black/frozen
scanout because the core has no YUV420p DDR frame store.

## CPU back-ports applied on this branch

Branch: `fallback/plex-v3` (from `v0.3.0`).

### Candidate A — “idle CPU spin fix”

**Finding:** This is the **same root cause** as candidate B.

Evidence from commit `f992f269` / lab notes: creation-order worker `mplex-gdm`
(`Companion::gdmLoop`) measured **98% onecpu at true idle** (`d_vol=0`) because
the daemon’s own GDM advertisements loop back on UDP 32412 and match a bare
`strstr(..., "plex")`, re-emitting forever.

| | |
|--|--|
| Touches present/scanout? | **No** — `companion.cpp` GDM only |
| Applied? | **Yes** (as candidate B’s commit) |
| Confidence | **High** — quoted pre-fix match + measured storm mechanism |

### Candidate B — `gdmIsDiscoveryProbe` GDM CPU-storm fix

**v0.3.0 code replaced** (`arm/misterplexd/companion.cpp` `gdmLoop`):

```cpp
if (std::strstr(buf, "M-SEARCH") || std::strstr(buf, "plex")) {
    auto payload = gdmPayload();
    sendto(fd, payload.data(), payload.size(), 0, ...);
}
```

**Back-port** (present-path-neutral): reject own replies (`HTTP/` prefix and
`Content-Type: plex/media-player`), keep answering real probes; sleep 200 ms on
non-EINTR `select` errors. See commit message on this branch.

| | |
|--|--|
| Touches present/scanout? | **No** |
| Applied? | **Yes** — own commit so it can be reverted alone |
| Confidence | **High** |

### Not applied (reported only)

| Candidate | Why not applied |
|-----------|-----------------|
| Dual listen 32412+32414 (`71c8989e`) | Present-neutral and useful for PMS probes, but **larger** than the minimum storm fix; not required to stop the self-reply loop on 32412. |
| Idle/screensaver unfreeze / `wantFpga=true` / YUV DDR canvas (`69027620`, HEAD `media_player.cpp`) | **Touches present path** — would reintroduce the HEAD incompatibility with the v3 core. **Do not port.** |
| Skip-identity scale / STREAM_SKIP_RGB product changes | Present/decode path — out of scope for “demonstrably worked” v3 video. |

## How to install (parent only — no agent device access)

From this worktree (or any checkout of `fallback/plex-v3` after the packaging
commit):

```bash
cd /path/to/MisterPlex   # worktree with release_artifacts/v3_fallback/misterplexd
./scripts/install_plex_v3_fallback.sh
# optional: also stop dev daemon and start v3
INSTALL_START=1 ./scripts/install_plex_v3_fallback.sh
```

Install root on device:

```text
/media/fat/misterplex_v3/
  bin/misterplexd
  misterplex.conf
  scripts/run_misterplexd_v3.sh
  scripts/switch_to_v3.sh
  scripts/switch_to_dev.sh
  scripts/README.txt
```

Core is **not** installed by this script (parent already placed
`/media/fat/_Utility/Plex_v3.rbf`).

## How to switch

**Use v3 daily driver**

1. OSD → load `_Utility/Plex_v3.rbf`
2. On device: `bash /media/fat/misterplex_v3/scripts/switch_to_v3.sh`  
   (stops whatever `misterplexd` is running, starts v3 bundle; leaves
   `/media/fat/misterplex/` files intact)

**Back to dev**

1. OSD → load `_Utility/Plex.rbf` (dev core)
2. On device: `bash /media/fat/misterplex_v3/scripts/switch_to_dev.sh`

## Parent hardware verification (commands only — agents do not run these)

### Install integrity

```bash
ssh root@"$MISTER_HOST" 'md5sum /media/fat/_Utility/Plex_v3.rbf /media/fat/misterplex_v3/bin/misterplexd'
# expect core: 41adb98c7a630b541091c22ce291be68
# expect daemon: md5 of release_artifacts/v3_fallback/misterplexd in this tree

ssh root@"$MISTER_HOST" 'ls -la /media/fat/misterplex_v3 /media/fat/misterplex_v3/bin /media/fat/misterplex_v3/scripts'
# prove dev tree still exists and was not replaced:
ssh root@"$MISTER_HOST" 'ls -la /media/fat/misterplex/bin/misterplexd /media/fat/_Utility/Plex.rbf'
```

### Runtime after `switch_to_v3` + Plex_v3 core

```bash
ssh root@"$MISTER_HOST" 'bash /media/fat/misterplex_v3/scripts/switch_to_v3.sh'
ssh root@"$MISTER_HOST" 'ps w | grep "[m]isterplexd"'
ssh root@"$MISTER_HOST" 'wget -qO- http://127.0.0.1:3005/resources | head -c 400; echo'
ssh root@"$MISTER_HOST" 'grep -E "FPGA frame path OK|GDM: listening|companion: GDM|DDR YUV|idle screen painted|PLAY " /media/fat/misterplex_v3/misterplexd.log | tail -40'
```

### Healthy v3 log lines (success)

```text
companion: GDM + HTTP :3005 name=MiSTerPlex-v3
GDM: listening UDP 32412
media: FPGA frame path OK (PRESENT=fpga → DDR bulk 3.1b, SPI F1 fallback)
media: idle screen painted (mode=...)
```

Optional cast smoke: timeline/resources respond; playback log shows
`misterplexd: PLAY ...` without present-path errors.

### Failure signatures

| Symptom in log / UI | Meaning |
|---------------------|---------|
| `DDR YUV420p` in present log | **Wrong daemon** (dev HEAD binary) against v3 core |
| `no present path (fb0/fpga)` | FPGA SPI open failed and fb0 not enabled |
| `FPGA SPI unavailable` | Core not loaded / SPI busy — check Plex_v3 is the loaded core |
| Black/frozen HDMI with HEAD daemon + Plex_v3 | Expected incompatibility — switch to this bundle |
| ~100% one CPU at idle, GDM log spam | GDM back-port missing/reverted — self-reply storm |

### Negative check (dev tree untouched)

```bash
ssh root@"$MISTER_HOST" 'md5sum /media/fat/misterplex/bin/misterplexd; ls -la /media/fat/_Utility/Plex.rbf'
# md5 must still match the pre-install dev binary; Plex.rbf must still exist
```

## Build notes

```bash
# worktree on fallback/plex-v3
export PATH="${PATH}:$HOME/Projects/mistercast-linux/third_party/arm-gnu-toolchain/bin"
make arm-plexd
# true rc=0 observed; only GCC 7.1 ABI notes on vector, not errors
cp -a build/arm/misterplexd release_artifacts/v3_fallback/misterplexd
make unit   # must be true rc=0
```

Minimum source delta from pure `v0.3.0`: sole functional change is the GDM
probe filter commit on `arm/misterplexd/companion.cpp` (plus this packaging
docs/scripts/artifact).
