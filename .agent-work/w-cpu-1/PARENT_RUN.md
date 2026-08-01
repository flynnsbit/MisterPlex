# Parent runbook — w-cpu-1

Agent does **not** touch the device. Capture `true rc=` on every step **directly**.

## A. Deploy profile daemon

```sh
set +e
# copy build/arm/misterplexd from host tree → device daemon path you use
# ensure conf: PRESENT_PROFILE=1
# restart daemon; confirm one process by readlink -f /proc/*/exe
echo "true rc_deploy=$?"
```

## B. Discriminator — tip YUV no-op (before hires)

```sh
set +e
# cast 624 tier; settle 5s
# FORCE overlay: pause, wait 1s, play, pause, play… for ≥12s so one profile window sees chrome
# Then:
python3 - <<'PY'
import re, glob, pathlib
text=""
for g in ("/media/fat/misterplex*/logs/*.log",):
    for p in glob.glob(g):
        try: text += pathlib.Path(p).read_text(errors="replace")+"\n"
        except Exception: pass
lines=[ln for ln in text.splitlines() if "present_profile" in ln and "overlay_verdict=" in ln]
print("n", len(lines))
print(lines[-1] if lines else "NO_LINE")
if lines:
    ln=lines[-1]
    def g(k):
        m=re.search(rf"{k}=([A-Za-z0-9_]+)", ln)
        return m.group(1) if m else None
    print("verdict", g("overlay_verdict"), "calls", g("overlay_calls"), "empty", g("overlay_dirty_empty"),
          "max", g("overlay_cpu_us_max"), "p99", g("present_us_p99"), "maxp", g("present_us_max"), "drops", g("drops"))
print("true rc_parse=0")
PY
echo "true rc_py=$?"
```

Expect tip: forced → `MEASURED_FREE`; idle chrome off → `NEVER_CALLED`.

## C. Hires cost gate (after w-osd-hires daemon)

Same as B. Expect forced → `MEASURED_COST`.  
**Hold to:** `present_us_p99 < 35000`, `present_us_max < 41667`, drops delta ≤ +1 / ~90s vs baseline.  
Record `overlay_us_max` / `overlay_cpu_us_max` as silicon truth — **do not** scale host 476 µs.

## D. ARM CPU% every soak (never 200−busy)

Copy `tools/arm_cpu_sample.py` to device. During valid play (ffmpeg exe live):

```sh
set +e
python3 /media/fat/misterplex/tools/arm_cpu_sample.py --seconds 8 --label soak -o /media/fat/misterplex/headroom_v2/soak_cpu.json
echo "true rc_sample=$?"
# Quote: H1 inelastic (daemon+ffmpeg), per-core %, MiSTer_elastic separately.
```

## E. MiSTer elasticity (H2 + H3)

```sh
set +e
# H2 during play
python3 /media/fat/misterplex/tools/schedstat_sample.py --seconds 8 -o /media/fat/misterplex/headroom_v2/h2.json
echo "true rc_h2=$?"
# H3 fixed work idle vs play (same work quantum)
python3 /media/fat/misterplex/tools/fixed_work_probe.py --label play -o /media/fat/misterplex/headroom_v2/h3_play.json
echo "true rc_h3=$?"
```

## F. Method invariants

- `P=100*dticks/(HZ*dwall)`, HZ=100, one window  
- pid by `readlink -f /proc/<pid>/exe` only  
- absence of process = NO-DATA, never 0.0  
- unaccounted residual vs system busy = FINDING  
