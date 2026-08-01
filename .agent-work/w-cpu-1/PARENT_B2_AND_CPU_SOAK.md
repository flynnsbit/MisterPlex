# Parent: B2 rescope (DROP) + ARM CPU soak sampler (READY)

## DELIVERABLE 1 — B2 / loglevel — **DROP further work**

**Verdict: no remaining observability gap worth log-volume cost for geometry.**

Parent evidence (live daemon, retained logs):
- `measured_delivery=624x480 measured_delivery_src=measured delivery_verified=1`
- 2127× 624x480, 118× 624x350, 29× 426x240 across retained logs

Geometry is already observed on the live path. Changing `-loglevel` further is
**not** required. Tip still has `delivered_geom=… src=ffmpeg_banner` + gate against
regressing product rawvideo to `-loglevel error` (harmless freeze of current tip
behavior; not a deploy priority).

### Residual gaps (not loglevel; optional later)
| Gap | Notes |
|-----|--------|
| `decode_src=caller_supplied` hardcoded in status line | Honesty/partition issue if product ever uses non-argv geometry; **not** fixed by loglevel |
| v1 vs v2 default paths in main.cpp | **w-promote** owns (rd-review trap) |

**Do not spend more cycles on B2 loglevel.**

---

## DELIVERABLE 2 — ARM CPU% sampler — **USE THIS**

### Zero-placeholder device command (busybox, no python required)

Copy `tools/arm_cpu_soak.sh` to the device (e.g. `/media/fat/misterplex_v2/`), then
**during the cast/soak**:

```sh
RBF_PATH=/media/fat/_Utility/Plex.rbf \
LOG=/media/fat/misterplex_v2/misterplexd.log \
sh /media/fat/misterplex_v2/arm_cpu_soak.sh 120 10
echo "true rc=$?"
```

Or one 30 s window:

```sh
RBF_PATH=/media/fat/_Utility/Plex.rbf \
LOG=/media/fat/misterplex_v2/misterplexd.log \
sh /media/fat/misterplex_v2/arm_cpu_soak.sh 30
echo "true rc=$?"
```

Optional explicit partition (if log scrape unavailable):

```sh
DECODE_SRC=caller_supplied RBF_PATH=/media/fat/_Utility/Plex.rbf \
sh /media/fat/misterplex_v2/arm_cpu_soak.sh 120 10
echo "true rc=$?"
```

### Python variant (if python3 on device)

```sh
python3 /media/fat/misterplex_v2/arm_cpu_sample.py --soak 120 --interval 10 \
  --label cast480 \
  --rbf /media/fat/_Utility/Plex.rbf \
  --log /media/fat/misterplex_v2/misterplexd.log \
  -o /media/fat/misterplex_v2/cpu_soak.json
echo "true rc=$?"
```

### Expected output shape (one line per window)

```
arm_cpu label=w0 wall_s=10 SYSTEM_BUSY=169.0/200 MiSTer=90.6 ffmpeg=69.6 misterplexd=25.6 H1_inelastic=95.2 accounted=162.8 sampler_self=0.2 rbf_md5=<32hex> daemon_md5=7c991e47… daemon_exe=/media/fat/misterplex_v2/bin/misterplexd decode_src=caller_supplied ncpu=2 method=exe+dticks tag=measured
```

On dual A9: **denominator is 200**. Missing process class ⇒ **NO-DATA** (never 0.0).
Empty scrape ⇒ `decode_src=NO-DATA` / `rbf_md5=NO-DATA` / `daemon_md5=NO-DATA`.

### Field name → derivation (binding)

| Field | Derivation |
|-------|------------|
| `wall_s` | One wall-clock window (sleep / perf_counter) |
| `HZ` | 100 (or `SC_CLK_TCK` in Python) |
| `*_pct_onecpu` | `P = 100 * Δ(utime+stime) / (HZ * wall_s)` from `/proc/<pid>/stat` f14+f15 |
| identity | `basename(realpath(readlink /proc/pid/exe))` only — never cmdline |
| `SYSTEM_BUSY=X/CAP` | `X = 100*ncpu*(1-Δidle/Δtotal)` on `/proc/stat` line field1=`cpu`; idle=idle+iowait; `CAP=100*ncpu` |
| `H1_inelastic` | ffmpeg + misterplexd only (Main elastic excluded) |
| `rbf_md5` | `md5sum` of `RBF_PATH` (default `/media/fat/_Utility/Plex.rbf`) |
| `daemon_md5` | `md5sum` of live misterplexd exe (prefer `misterplex_v2`); via `/proc/<pid>/exe` |
| `decode_src` | `DECODE_SRC` env / `--decode-src`, else last `decode_src=` in log tail |
| `sampler_self` | Same P formula on sampler PID — **measured** overhead |

### Measured sampler overhead (host self-test, not device)

| window | sampler_self %onecpu | note |
|--------|----------------------|------|
| 5.0 s  | **0.2** | `tools/arm_cpu_sample.py` host, tag=measured |
| 1.0 s  | 1.0 (py) / up to ~12 (sh short window) | prefer ≥5–10 s windows on device |

On device expect `sampler_self` ≪ 1 for 10 s windows; always print the measured value.

### Constraints enforced

- No `pgrep` / `pkill` / `killall` — tool never kills
- Never cmdline identity (flock + dual roots)
- Never invent 0.0 for missing processes
- Artifact pair auto-stamped every line (`rbf_md5` + `daemon_md5`)
- Partition key `decode_src` on every line — do not pool across values

### Host gates

```
bash tests/unit/test_arm_cpu_sample_contract.sh  → true rc=0
python3 tests/unit/test_unit_rollcall.py         → UNIT_ROLLCALL_OK
```
