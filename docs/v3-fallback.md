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
| Daemon base | git tag `v0.3.0` (`cacd8717`) — **proxy** (see below) |
| Conf PRESENT | **`fb0`** (v0.3.0 default / lab-stable cast path) |
| On-device install root | `/media/fat/misterplex_v3/` |

Dev install stays at `/media/fat/misterplex/` + `/media/fat/_Utility/Plex.rbf`.
This bundle **must not** overwrite those paths.

## Exact partner SHA was lost — do not re-hunt `06c5735a`

A live-device conf comment from the v3 era recorded:

```text
# v0.3.0 lab-stable pair: 320x240 core 41adb98c + daemon 06c5735a (fb0 cast path)
```

`06c5735a` is **dangling** after a history rebase (tag `chroma-pre-rebase-ad30babe`
exists as a pre-rebase marker). `git log -1 06c5735a` fails with unknown revision.
**Do not waste time recovering that object.** Tag `v0.3.0` (`cacd8717`,
2026-07-26 20:00:10) is the closest surviving proxy and is what this bundle builds.

No on-device archived daemon can substitute either: `ddr_frame_layout.hpp` landed
56 minutes after the tag (`c39f93a0`), `ddr_frame_store.sv` the next morning
(`d0ea6dac`), and the oldest device binary
(`/media/fat/misterplex/bin/misterplexd.prev-cap`, Jul 27 09:52) post-dates the
DDR switch. Compiling from `v0.3.0` is the only path.

## Shipped PRESENT value: `fb0` (not `fpga`)

**Conf ships `PRESENT=fb0`.** That is the lab-stable cast path from the provenance
comment above and the v0.3.0 daemon default. Do **not** “fix” it to `PRESENT=fpga`.

### Quoted v0.3.0 code that justifies `PRESENT=fb0`

Default in `v0.3.0:arm/misterplexd/main.cpp`:

```cpp
// Phase 2: GDM + companion + FFmpeg → /dev/fb0 (FPGA scanout via MiSTer_fb).
std::string presentMode = "fb0";
// ...
v = loadConf(confPath, "PRESENT");
if (!v.empty())
    presentMode = v; // fb0 | fpga | both
```

`initPresent()` in `v0.3.0:arm/misterplexd/media_player.cpp` opens fb0 when
PRESENT is `fb0`, `both`, or empty — FPGA only when `fpga` or `both`:

```cpp
bool wantFb = (presentMode_ == "fb0" || presentMode_ == "both" || presentMode_.empty());
bool wantFpga = (presentMode_ == "fpga" || presentMode_ == "both");

if (wantFb) {
    if (fb_.open("/dev/fb0")) {
        fb_.clear();
        log("media: fb " + fb_.info() + " decode=" + ...);
```

With `PRESENT=fb0` and `STREAM=0`, the product path keeps continuous FFmpeg RGB
to fb0 (quoted from the same file):

```cpp
// STREAM=0 and PRESENT=both/fb0 always keep the proven FFmpeg RGB path.
```

Release packaging for v0.3.0 also defaulted the example conf to fb0
(`scripts/package_release.sh` example: `PRESENT=fb0`).

### Trap: do not apply the HEAD “PRESENT=fb0 freezes idle” fix here

In the **current** daemon, `PRESENT=fb0` is a known bug: `initPresent()` skips
`fpga_.open()` unless PRESENT is `fpga|both`, so the DDR frame store never
repaints and the idle screen freezes (AGENTS.md guessing-incident table). That
trap applies to **HEAD only**.

This bundle’s binary is the **v0.3.0-era** daemon, where fb0 is the intended
cast path (Linux framebuffer → MiSTer_fb → HDMI). Changing the conf to
`PRESENT=fpga` would push the v3 daemon onto the RGB565 DDR-bulk / SPI F1 ladder
instead of the proven fb0 cast path the lab pair used. **Do not modernise it.**

## Why it exists

Development HEAD’s present path is DDR YUV420p canvas scanout
(`ddr_frame_store.sv`). On a DDR miss the RTL returns black for the rest of the
visible line, so a late fill makes the left edge wander (~44 px class defect).

Tag `v0.3.0` has **no** `ddr_frame_store.sv`. Its present path is a 320×240 RGB
`frame_store` fed over SPI and stretched across the active display (core-side),
while the **daemon** that paired with it painted via **/dev/fb0**:

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

Parent hardware evidence (parent-captured only; agents must not re-claim): loading
`Plex_v3.rbf` with the **dev** daemon produced a stable but garbage picture
(horizontal colour bands, one-line step, diagonal dashes) — consistent with the
v3 core being fed data it has no reader for.

The v0.3.0 daemon with `PRESENT=fb0` does **not** take that path: it opens
`/dev/fb0` and logs `media: fb ...` (see quotes above).

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
non-EINTR `select` errors. See commit `5960697f` on this branch.

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
| Changing conf `PRESENT=fb0` → `fpga` | Would leave the proven fb0 cast path; confuses HEAD’s fb0 freeze trap with v0.3.0 behaviour. **Do not “fix”.** |
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
  misterplex.conf          # PRESENT=fb0 (created only if absent)
  scripts/run_misterplexd_v3.sh
  scripts/switch_to_v3.sh
  scripts/switch_to_dev.sh
  scripts/README.txt
```

Core is **not** installed by this script (parent already placed
`/media/fat/_Utility/Plex_v3.rbf`).

**Conf template only** — never copy a live lab conf (tokens / LAN IPs). Set
`PLEX_BASE` / `PLEX_TOKEN` on the device after install if needed.

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

ssh root@"$MISTER_HOST" 'grep -E "^PRESENT=|^DECODE=" /media/fat/misterplex_v3/misterplex.conf'
# expect: DECODE=320x240 and PRESENT=fb0

ssh root@"$MISTER_HOST" 'ls -la /media/fat/misterplex_v3 /media/fat/misterplex_v3/bin /media/fat/misterplex_v3/scripts'
# prove dev tree still exists and was not replaced:
ssh root@"$MISTER_HOST" 'ls -la /media/fat/misterplex/bin/misterplexd /media/fat/_Utility/Plex.rbf'
```

### Runtime after `switch_to_v3` + Plex_v3 core

```bash
ssh root@"$MISTER_HOST" 'bash /media/fat/misterplex_v3/scripts/switch_to_v3.sh'
ssh root@"$MISTER_HOST" 'ps w | grep "[m]isterplexd"'
ssh root@"$MISTER_HOST" 'wget -qO- http://127.0.0.1:3005/resources | head -c 400; echo'
ssh root@"$MISTER_HOST" 'grep -E "media: fb |PRESENT=|GDM: listening|companion: GDM|DDR YUV|FPGA frame path|idle screen|PLAY " /media/fat/misterplex_v3/misterplexd.log | tail -40'
```

### Healthy v3 log lines (success) — fb0 cast path

```text
companion: GDM + HTTP :3005 name=MiSTerPlex-v3
GDM: listening UDP 32412
media: fb ... decode=320x240
```

(Exact `fb` info string depends on `/dev/fb0` geometry; the important tokens are
`media: fb` and `decode=320x240`, **not** `DDR YUV420p`.)

Optional cast smoke: timeline/resources respond; playback log shows
`misterplexd: PLAY ...` without present-path errors.

### Failure signatures

| Symptom in log / UI | Meaning |
|---------------------|---------|
| `DDR YUV420p` in present log | **Wrong daemon** (dev HEAD binary) against v3 core |
| `PRESENT=fpga → DDR bulk` only, no `media: fb` | Conf was changed off fb0 — not the lab-stable cast path |
| `media: /dev/fb0 unavailable` then `no present path` | fb0 open failed; check MiSTer_fb / core loaded |
| Garbage HDMI bands with HEAD daemon + Plex_v3 | Expected incompatibility (parent already captured) |
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
docs/scripts/artifact). Binary rebuild is required; no archived device binary
pre-dates the DDR switch.
