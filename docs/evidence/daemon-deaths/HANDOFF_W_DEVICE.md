# Handoff: daemon-deaths capture → `w-device`

**Owner of this doc:** reliability lane (host-side only).  
**Device work requires separate authorisation + a visible bounce.** Do not deploy from this lane.

## What already existed (`SUPERVISE_EXIT`)

`scripts/misterplexd_supervise.sh` already logged on each child death:

- UTC timestamp, child pid, shell `wait` rc
- Approx `WIFSIGNALED` (`rc>=128` → `signal=rc-128` + name) or `exit_status`
- `core_dump=UNKNOWN` (shell cannot know)
- Snapshots of `misterplexd.last` and `misterplexd.death`
- Respawn backoff

It did **not** record real `waitpid` WIF* macros, `siginfo_t`, `/proc` oom/Vm*, or log tail.

In-process `death_breadcrumb` wrote `.last` (state/frames/pos/uptime) and `.death` (`death signal=N` only) via `std::signal` crash guard.

## Hard limits (say this to the user)

| Death class | In-process handler | Parent supervisor |
|-------------|--------------------|-------------------|
| clean exit / handled SIGTERM | `.death` with `exit_code`/`why` | `WIFEXITED` + status |
| SIGSEGV/BUS/ABRT/… | `.death` with `si_signo/si_code/si_pid/si_addr` | `WIFSIGNALED` + `WTERMSIG` |
| **SIGKILL** | **nothing runs** | `WTERMSIG=9`, `.death` stale/absent |
| **OOM kill** | **nothing runs** (=SIGKILL) | same + **dmesg** correlation |

Silence in `.death` after a death is **not** evidence the process was not killed.

## What to install on device (copy-paste)

Assumes package or scp of:

- `bin/misterplexd` (with SA_SIGINFO breadcrumb build)
- `bin/death_capture_supervisor` (static armhf)
- `scripts/misterplexd_supervise.sh`

```sh
# On build host (after authorised package/arm-plexd):
#   make arm-plexd
#   # produces build/arm/misterplexd and build/arm/death_capture_supervisor

MISTER_HOST=${MISTER_HOST:-192.168.1.183}
MISTER_PASS=${MISTER_PASS:-1}

# 1) Copy binaries (authorised deploy only)
sshpass -p "$MISTER_PASS" scp -o StrictHostKeyChecking=no \
  build/arm/misterplexd build/arm/death_capture_supervisor \
  scripts/misterplexd_supervise.sh \
  root@${MISTER_HOST}:/media/fat/misterplex/bin/

sshpass -p "$MISTER_PASS" ssh -o StrictHostKeyChecking=no root@${MISTER_HOST} '
  set -e
  mkdir -p /media/fat/misterplex/bin /media/fat/misterplex
  mv -f /media/fat/misterplex/bin/misterplexd_supervise.sh /media/fat/misterplex/ 2>/dev/null || true
  # if scp landed supervise in bin/, move it:
  if [ -f /media/fat/misterplex/bin/misterplexd_supervise.sh ]; then
    mv -f /media/fat/misterplex/bin/misterplexd_supervise.sh /media/fat/misterplex/
  fi
  chmod +x /media/fat/misterplex/bin/misterplexd \
           /media/fat/misterplex/bin/death_capture_supervisor \
           /media/fat/misterplex/misterplexd_supervise.sh
'

# 2) Point startup at supervise (visible bounce — do not hide)
# Replace bare misterplexd start with:
#   /media/fat/misterplex/misterplexd_supervise.sh >>/media/fat/misterplex/misterplexd_supervise.log 2>&1 &
# Ensure only ONE supervise + ONE daemon.

# 3) Bounce (authorised, visible):
sshpass -p "$MISTER_PASS" ssh -o StrictHostKeyChecking=no root@${MISTER_HOST} '
  killall misterplexd death_capture_supervisor misterplexd_supervise.sh 2>/dev/null || true
  sleep 1
  nohup /media/fat/misterplex/misterplexd_supervise.sh \
    >>/media/fat/misterplex/misterplexd_supervise.log 2>&1 &
  sleep 1
  pgrep -a misterplex || true
  tail -n 5 /media/fat/misterplex/misterplexd_supervise.log || true
'
```

## After any unexplained death — collect (no guesswork)

```sh
sshpass -p "$MISTER_PASS" ssh -o StrictHostKeyChecking=no root@${MISTER_HOST} '
  echo "=== SUPERVISE tail ==="
  tail -n 30 /media/fat/misterplex/misterplexd_supervise.log
  echo "=== death_capture.log ==="
  tail -n 20 /media/fat/misterplex/death_capture.log 2>/dev/null || echo absent
  echo "=== death_events.jsonl ==="
  tail -n 5 /media/fat/misterplex/death_events.jsonl 2>/dev/null || echo absent
  echo "=== misterplexd.death ==="
  cat /media/fat/misterplex/misterplexd.death 2>/dev/null || echo absent
  echo "=== misterplexd.last ==="
  cat /media/fat/misterplex/misterplexd.last 2>/dev/null || echo absent
  echo "=== proc_sample.last ==="
  cat /media/fat/misterplex/proc_sample.last 2>/dev/null || echo absent
  echo "=== log tail ==="
  tail -n 40 /media/fat/misterplex/misterplexd.log 2>/dev/null || true
  echo "=== dmesg OOM ==="
  dmesg -T 2>/dev/null | grep -iE "killed process|out of memory|oom-kill|Memory cgroup" | tail -n 20 || true
'
```

### How to read the record

| Observation | Meaning (evidence-backed) |
|-------------|---------------------------|
| `WTERMSIG=11` + `death signal=11 si_code=1 si_addr=…` | Crash (SEGV_MAPERR typical) |
| `WTERMSIG=11` + `si_code=0`/`si_pid≠0` | External `kill -SEGV` / `SI_USER` |
| `WIFEXITED=1 WEXITSTATUS=0` + `why=signal-g_stop` | Handled SIGTERM orderly path |
| `WTERMSIG=9` + `death_freshness=stale_or_absent_expected` | SIGKILL or OOM; check dmesg |
| `WTERMSIG=9` + dmesg `Killed process … (misterplexd)` | **OOM** confirmed |
| `WTERMSIG=9` + no dmesg OOM line | External kill -9 or OOM log rotated — unknown without more kernel log |

## Host proof already done

```sh
bash scripts/prove_death_capture_host.sh
# evidence: docs/evidence/daemon-deaths/<SOURCE_SHA>/
```

Four induced classes: clean exit, SIGTERM→exit0, SIGSEGV, SIGKILL.
