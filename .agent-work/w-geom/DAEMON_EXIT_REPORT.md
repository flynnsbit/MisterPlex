# Daemon exit RCA + harden — parent brief

**Branch:** `w-instr-motion-counter`  
**SHA:** `bb0fb5bb128d8383363e169c429e657789ee7e82`  
**ARM binary:** `build/arm/misterplexd`  
**md5:** `865d4c8ac246e827bfd524f76af3e18d` (ELF 32-bit ARM static)

## 1) Unit gate ownership (install blocker)

| Commit / tree | `fpga_spi.*` | rtl `selectDdrWriteBank` | notes |
|---|---|---|---|
| merge-base `77e1e78d` | n/a | PASS | worktree run true rc=0 |
| parent `2bbdffd4` | (pre-exit) | **FAIL** | red before exit work |
| exit commit `8f144ea1` | **0 bytes changed** (`git diff --stat 8f144ea1^..8f144ea1 -- arm/misterplexd/fpga_spi.*` empty) | still FAIL on tip-before-fix | death/ledger only |
| tip `bb0fb5bb` | ported bank select | PASS | **`make unit` true rc=0** |

**Verdict:** red was pre-existing on the branch (present at `2bbdffd4`), not introduced by the exit breadcrumb commit. Owned fix lands in `bb0fb5bb`.

## 2) Exit path (source)

Product main loop: `while (!g_stop) sleep` then `return 0`.  
`g_stop` set only from SIGINT/SIGTERM handlers (`main.cpp`).  
Handled SIGTERM ⇒ process exits with **WIFEXITED status 0** (not WIFSIGNALED).  
Variable run_s (1543/196/514) ⇒ **not** a fixed idle timeout (none in source).  
Somebody is sending SIGTERM (or the supervisor is TERM'd and kills the child).

## 3) Breadcrumb safety

| Path | Mechanism | Survives |
|---|---|---|
| Signal handler | `open`/`write`/`close` on pre-baked `g_deathPathC` only — **no** `fprintf`/`malloc` | SIGTERM/SIGINT |
| Orderly `exitReported` | `deathBreadcrumbExit` + stderr EXIT_REASON + uptime | normal return |
| Supervisor | `SUPERVISE_EXIT` with WIFEXITED/WIFSIGNALED/WTERMSIG | **SIGKILL** (handler cannot run) |

Death file: **`<confDir>/misterplexd.death`** from `--conf` (e.g. `/media/fat/misterplex_v2/misterplexd.death`), not `/tmp`.

Local proof (`tests/unit/test_supervise_exit_classify.sh` true rc=0):
- default SIGTERM → WIFSIGNALED 15, shell rc=143  
- SIGKILL → WIFSIGNALED 9, shell rc=137  
- handled SIGTERM → WIFEXITED 0, shell rc=0  

## 4) Signal-sender table

Full table: `.agent-work/w-geom/SIGNAL_SENDERS.md`

Highest value for rc=0 (handled TERM):
1. `scripts/plexctl.sh` `stop_all` — cmdline substring match `*"/bin/misterplexd"*`
2. `scripts/deploy_plex_core.sh` / `mister_soft_bounce.sh` — `killall misterplexd`
3. Supervisor trap if supervisor itself gets TERM

`kill -9` deploy paths ⇒ WIFSIGNALED 9, **not** your measured rc=0.

## 5) Hand-install + verify (parent)

```bash
ROOT=/media/fat/misterplex_v2
# copy build/arm/misterplexd → $ROOT/bin/misterplexd (your usual one-daemon restart)
PID=$(pidof misterplexd | awk '{print $1}')
md5sum $(readlink -f /proc/$PID/exe)
# expect: 865d4c8ac246e827bfd524f76af3e18d
n_daemon=$(pidof misterplexd | wc -w)   # must be 1
```

After next death:

```bash
grep EXIT_REASON $ROOT/misterplexd.log | tail -5
cat $ROOT/misterplexd.death          # includes si_pid when SA_SIGINFO fires
tail -30 $ROOT/misterplexd_supervise.log | grep SUPERVISE_EXIT
# if si_pid still alive: tr '\0' ' ' < /proc/<si_pid>/cmdline
```

## 6) Frame ledger residual (soak-wide)

```bash
LEDGER=/media/fat/misterplex_v2/misterplexd.frame_ledger
awk '
  /session_end|daemon_exit|restart/ { print }
  {
    for(i=1;i<=NF;i++){
      if($i ~ /^frames=/){split($i,a,"=");f+=a[2]}
      if($i ~ /^presents=/){split($i,a,"=");p+=a[2]}
      if($i ~ /^drops=/){split($i,a,"=");d+=a[2]}
    }
  }
  END{ print "SUM f="f" p="p" d="d" residual="(f-p-d) }
' "$LEDGER"
```

Restart rows must appear in the ledger; residual `frames-presents-drops` is soak-assertable.

## 7) Real fix status

**Cause of rc=0:** handled SIGTERM (established from source).  
**Sender:** unknown until `si_pid` / SUPERVISE_EXIT on device — candidates ranked above.  
Do not "fix" a sender without that evidence. Next silicon step is install breadcrumb binary and wait for one death.
