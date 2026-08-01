# Parent: B2 delivered_geom + ARM CPU soak sampler

## DELIVERABLE 1 — B2 (code)

Product rawvideo ffmpeg path already uses `-loglevel info` + stderr pump.
MEASURED_DELIVERY now logs:

```
media: MEASURED_DELIVERY delivered_geom=WxH src=ffmpeg_banner bytes=… …
```

**Derivation (permanent):** `parseFfmpegGeometryLine` on ffmpeg stderr Stream Video banner  
under `-loglevel info`. **Not** PMS `/status/sessions`, **not** library metadata,  
**not** `videoResolution=` request.

Gate: `tests/unit/test_delivered_geom_loglevel.sh` (wired in `make unit`).

Non-product paths (audio-only, demux, probe) stay `-loglevel error` — intentional;  
they are not delivery-geometry observers. Info lines that are not geometry/`frame=`  
are discarded by the pump (no flood).

### Parent verify after daemon deploy

```sh
# During/after a cast, on device journal or companion log:
grep 'delivered_geom=' /path/to/misterplexd.log
# Expect: delivered_geom=624x480 src=ffmpeg_banner  (or whatever PMS actually sent)
# If NO-DATA at FINAL: banner not parsed — tip daemon not deployed or loglevel regressed.
true; echo "true rc=$?"
```

## DELIVERABLE 2 — ARM CPU% during soak

### Method (quote in every soak report)

| Field | Derivation |
|-------|------------|
| %onecpu | `P = 100 * dticks / (HZ * dwall)`, HZ=100, ticks=utime+stime |
| Identity | `readlink -f /proc/<pid>/exe` only — never cmdline (ERROR 14 flock) |
| Missing class | `NO-DATA` — never 0.0 |
| SYSTEM_BUSY | `100 * ncpu * (1 - Δidle/Δtotal)` from `/proc/stat` line field1=`cpu` via awk |
| H1_inelastic | ffmpeg + misterplexd only (Main elastic excluded) |

Sampler overhead: two `/proc` walks + sleep; no renice/pin/kill. Expect ≪1 %onecpu for window≥5s.

### Preferred (Python on device if python3 present)

```sh
# Copy tools/arm_cpu_sample.py to device, then during cast:
python3 /media/fat/misterplex/arm_cpu_sample.py --soak 120 --interval 10 \
  --label cast480 -o /media/fat/misterplex/cpu_soak.json
echo "true rc=$?"
# One-shot 30s window:
python3 /media/fat/misterplex/arm_cpu_sample.py --seconds 30 --label cast480 \
  -o /media/fat/misterplex/cpu30.json
echo "true rc=$?"
```

### Busybox pure-sh (no python required)

```sh
# Copy tools/arm_cpu_soak.sh to device:
sh /media/fat/misterplex/arm_cpu_soak.sh 30
echo "true rc=$?"
# Multi-window 120s / 10s:
sh /media/fat/misterplex/arm_cpu_soak.sh 120 10
echo "true rc=$?"
```

### Expected line shape

```
arm_cpu label=w0 wall_s=10 SYSTEM_BUSY=169.0/200 MiSTer=90.6 ffmpeg=69.6 misterplexd=25.6 H1_inelastic=95.2 accounted=162.8 method=exe+dticks ncpu=2 tag=measured
```

On dual A9: denominator is **200**. Host self-test uses host ncpu (e.g. /2000).

### Constraints enforced

- No `pgrep` / `pkill` / `killall`
- Never kills anything
- Exe basename classes: `MiSTer`, `ffmpeg`, `misterplexd` after realpath
- `/proc/stat` via awk (not `read a b c`)

## Host self-test evidence (agent, not device)

```
bash tests/unit/test_delivered_geom_loglevel.sh → true rc=0
sh -n tools/arm_cpu_soak.sh → true rc=0
sh tools/arm_cpu_soak.sh 1 → true rc=0 (NO-DATA for MiSTer/daemon on host; ffmpeg may appear)
python3 tools/arm_cpu_sample.py --seconds 1 → true rc=0
python3 tests/unit/test_unit_rollcall.py → UNIT_ROLLCALL_OK
```
