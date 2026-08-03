# p480-headroom — dual-core ceiling + ffmpeg thread shape

**SOURCE_SHA:** `72166bebc53ee8186a694a8ba709b4bf6f192353`  
**Instrument:** on-device `headroom_sample.py` — one window, `P = 100 * dticks / (HZ * dwall)`, no fps scaling, per-thread `/proc/<pid>/task/*/stat`.  
**Clip:** same real PMS media as prior soaks (rk path via playMedia), OSD O[4]=1 → coded **624x480**.  
**Window:** idle 10.6 s → play settle ~20 s + sample **46.8 s** → idle_post 10.6 s.  
**Thermals:** **SKIPPED** — `/sys/class/thermal` absent on device (`00_topology_thermal.txt`). No SoC temp claim.

## Topology (measured)

| Fact | Value | Artifact |
|------|-------|----------|
| CPUs | **2** (ARMv7 A9 ×2, Altera SOCFPGA) | `00_topology_thermal.txt` |
| Ceiling | **200 %onecpu** | ncpu×100 |
| Thermal zones | **none** | `ls /sys/class/thermal` → no such file |

## Pre-registered predictions vs actual

| ID | Prediction | Actual | Verdict |
|----|------------|--------|---------|
| P1 | nproc=2 | nproc=2, cpuinfo 2× part 0xc09 | **HIT** |
| P2 | ffmpeg multi-threaded; top thread **&lt;100%**; sum≈process% | top **16.544%** (`vf#0:0`); sum threads 68.93 ≈ proc 69.10 | **HIT** |
| P3 | idle rem ≈ leftover after stream; stream dominates userspace | stream ff+mp=**94.1%** but **MiSTer alone 74.9%** during play; machine_busy=**173.6%**, idle_rem=**26.4%** | **PARTIAL** — stream is largest *product* sum; MiSTer is largest *single* process and eats most of the “free” core even at idle |
| P4 | thermal delta or sensors absent | sensors **absent** → no thermal soak | **HIT (skip)** |

## Headline table (%onecpu, same formula)

| phase | dwall_s | machine_busy | idle_rem (to 200) | MiSTer | ffmpeg | misterplexd | stream (ff+mp) | ffmpeg TOP thr | mplex TOP thr |
|-------|---------|--------------|-------------------|--------|--------|-------------|----------------|----------------|---------------|
| idle_pre | 10.623 | 107.859 | **92.141** | **99.219** | 0 | 1.883 | 1.883 | — | 1.035 |
| **play_480p** | **46.844** | **173.615** | **26.385** | **74.908** | **69.102** | **24.977** | **94.079** | **16.544** | **16.993** |
| idle_post | 10.619 | 108.192 | 91.808 | 99.441 | 0 | 1.883 | 1.883 | — | 0.942 |

Artifacts: `headroom_idle.json`, `headroom_play480.json`, `headroom_idle_post.json`, `analysis.txt`.

## Critical question: is ffmpeg one saturated thread?

**No.** Evidence from `headroom_play480.json` `top_threads`:

| rank | tid | comm | %onecpu |
|------|-----|------|---------|
| 1 | 3586 | `vf#0:0` | **16.544** |
| 2 | 3596 | `vf#0:0` | 14.602 |
| 3 | 3594 | `vf#0:0` | 14.452 |
| 4 | 3601 | `mux0:rawvideo` | 6.212 |
| 5 | 3589 | `dec0:1:aac` | 2.732 |
| … | | h264 df0/df1/df2 + dec0:0:h264 | ~1.0–1.7 each |

- **16 ffmpeg threads** sampled; **TOP = 16.5%** of one CPU (filter pool), not ~69% on one thread.  
- Process ffmpeg **69.1%** ≈ sum of its threads **68.9%** (accounting closes).  
- H.264 decode threads are cheap here; **scale/filter (`vf#0:0`) dominates** the ffmpeg bill.  
- **Implication for 720p:** the ceiling is **not** “one ffmpeg thread at 100%.” It is **aggregate** CPU across both cores, with **MiSTer already holding ~75–99% of one core** as baseline tax. A single-thread decode wall is **not** the binding constraint in this measurement; **machine idle remainder ~26% at 480p** is.

## Headroom picture (product decision input)

```
Ceiling                         200.0 %onecpu
480p play machine_busy          173.6
  MiSTer (main binary)           74.9   ← always-on core tax (99% when idle!)
  ffmpeg                         69.1   ← multi-thread, top thr 16.5%
  misterplexd                    25.0   ← top thr 17.0%
  other (kworkers, sample, …)     ~4.6
idle remainder                   26.4
```

- **Stream-only** (daemon + ffmpeg) ≈ **94%** — matches prior 180s harness ~89.8% within session/window noise.  
- **Real remaining headroom at 480p play ≈ 26 %onecpu** (one-eighth of the dual-core budget), **not** 200−94=106, because MiSTer is not free.  
- At **idle**, machine is already ~**108% busy** almost entirely from **MiSTer ≈ 99%** on one core; second core mostly idle → ~92% headroom before play.  
- **Do not** project 720p from stream-only ratios without subtracting the MiSTer floor. Parent owns 720p decision; this lane did not run 720p.

## What was not claimed

- No HDMI lipsync / thermal number.  
- No 720p experiment.  
- `TRANSCODE_PROFILE=480p` is present in live conf (observed, not changed this run). Content tier restored via **OSD bit4=0** + conf `DECODE=320x240`; shipping **presentation default remains 240p** on the OSD path used for product.

## Device left as

| Item | Value |
|------|-------|
| RBF | `14eaeff3` (`14eaeff3270a6f59a434e0f777ed823d` `/media/fat/_Utility/Plex.rbf`) |
| daemon | v10 `fb9f7619` |
| CORENAME | Plex (`/tmp/CORENAME`) |
| n_d / n_s | 1 / 1 (supervise up) |
| OSD lo | `0x6000` — **bit4 clear** (240p) |
| DECODE | 320x240 |
| OSD_CONTROL | 1 |
| PRESENT_PROFILE | 0 |
| timeline | location=navigation, not playing |

See `device_restored.txt`.
