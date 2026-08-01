# timeout=5 Main poll — risk / rollback / proof (w-cpu)

**Status:** lab-only proposal. **Not applied on the daily driver.**  
**Framing (parent-measured, 2026-03-29):** product pipeline at **24 fps is NOT starved**
(`d_frames=24–25`, `d_presents=24–25`, `d_drops=0`, `~103 %onecpu free`).  
This change is **headroom for higher tiers (25/30 fps, future work)**, **not** a fix for a
present playback failure. Do not sell it as “fixes judder” without a 25/30 cast.

## What it is

Stock MiSTer Main (`input.cpp`) uses `poll(..., timeout=0)` except Menu∧FB (`timeout=25`).
That is a busy SPI/input spin → **83–100 %onecpu at idle** (parent, exe-resolved).

Patch (repo): `.agent-work/w-cpu-1/patches/main_mister_input_timeout5_plex.patch`  
Intent: `timeout=5` ms while **Plex core** is loaded (preserve F12/OSD path; unlike
`SUSPEND_MAIN_DURING_PLAY` which SIGSTOPs Main and kills F12/`/dev/MiSTer_cmd`).

| Approach | Main CPU | F12/OSD | `/dev/MiSTer_cmd` | load_core |
|---|---|---|---|---|
| stock `timeout=0` | ~83–100 idle (measured) | works | works | works |
| `timeout=5` (proposed) | ESTIMATED large drop (need A/B) | must still work | must still work | must still work |
| `SUSPEND_MAIN_DURING_PLAY` | −45.7 dual-core busy (measured hist.) | **dead** while T | **dead** | **dead** |

## Risk case (daily driver)

1. **Wrong binary / failed flash** → box won’t boot menus cleanly. Mitigation: backup first.  
2. **Input latency** — 5 ms poll ceiling adds up to ~5 ms worst-case vs spin; usually fine for OSD, bad if a core needs sub-ms Main reaction (Plex does not for TCP stop).  
3. **Core detect wrong** — if Plex is not detected and timeout stays 0, no win; if always-on 5 ms on Menu, slight Menu latency. Patch must be **Plex-scoped** as written.  
4. **Upstream Main updates** overwrite `/media/fat/MiSTer` — patch is not durable across updates without re-apply.  
5. **Does not free wall-ms/frame for our pipe by itself** — Main is an elastic scavenger; occupancy win ≠ FEED margin unless a fixed-work benchmark shows it. Parent: do not convert with subtraction.

## Exact rollback

```bash
# ON DEVICE — parent only. Backup BEFORE any replace.
# Pre-register: after rollback, md5(/media/fat/MiSTer) == md5(backup); F12 opens OSD.

set -e
BK=/media/fat/MiSTer.stock-backup
test -f "$BK" || { echo "FAIL no backup $BK"; exit 1; }
# stop is optional; copying over live binary is what stock updates do
cp -a "$BK" /media/fat/MiSTer
sync
md5sum /media/fat/MiSTer "$BK"
echo "true rc=$?"
# Soft restart Main without thrashing cores — prefer user Menu path or documented mister restart.
# Do NOT kill -9 storms. Do NOT leave non-stock binary if test aborts mid-way.
```

## Apply (lab only — parent)

```bash
set -e
BK=/media/fat/MiSTer.stock-backup
test -f /media/fat/MiSTer
if [ ! -f "$BK" ]; then cp -a /media/fat/MiSTer "$BK"; fi
# Build patched Main on a HOST with Main_MiSTer tree + patch, then:
# scp MiSTer root@mister:/media/fat/MiSTer.new && mv on device after md5 check
# NEVER compile on the DE10 as the primary path unless already established.

md5sum /media/fat/MiSTer /media/fat/MiSTer.stock-backup
echo "true rc=$?"
```

## Proof F12/OSD survived (parent commands)

Pre-register predictions before measure:

| # | Check | Predict timeout=5 | Falsifier |
|---|---|---|---|
| P1 | F12 opens OSD on Plex core | OSD visible ≤1 s | no OSD in 3 s |
| P2 | OSD navigate + close | works | stick/keys dead |
| P3 | idle Main %onecpu (exe-resolved, 5×1s) | **\< 40** (ESTIMATED) | still ≥80 |
| P4 | 24 fps supply_bucket | still d_drops=0 | new drops |
| P5 | rollback restores stock md5 | match BK | mismatch |

```bash
# CPU sample — ONE window method; pids by readlink exe only (ERROR 14).
# Use repo tools/arm_cpu_sample.py if deployed; else parent’s gated sampler.
# Capture: Main %onecpu idle on Plex, then F12 press, then sample again.

# F12 is physical/CEC — parent observes HDMI capture:
# ffmpeg -v error -f v4l2 -input_format mjpeg -video_size 1920x1080 \
#   -i /dev/video0 -frames:v 1 -y /path/in/workspace/f12_osd.png
# true rc direct on each command.
```

## Recommendation

- **Ship default OFF** until P1–P5 pass on lab image with backup present.  
- Prefer `timeout=5` over `SUSPEND_MAIN` when F12 must remain.  
- **Do not** claim it fixes 25/30 margin until 25/30 cast + Main A/B both measured.  
- Occupancy reclaim is real and large on idle; conversion to pipe wall-ms is **unproven**.
