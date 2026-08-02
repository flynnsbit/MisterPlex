# RESULT: SUSPEND_MAIN_DURING_PLAY restored

## Source
Restored from git history (not on `w-cpu-fps-measure` ancestry; lived on `hybrid/v0.2.0-timeline`):
- `aa8392f3` feat(daemon): opt-in SUSPEND_MAIN_DURING_PLAY session hold
- `b815b417` harden SUSPEND_MAIN locator: exact argv0, multi-match refuse

Adapted to current death_breadcrumb crashGuard (not crashDumpInstall).

## What shipped
| Piece | Behavior |
|---|---|
| Conf | `SUSPEND_MAIN_DURING_PLAY` default **OFF** (`confTruthy`) |
| Locator | product Main = resolved `/proc/pid/exe` **OR** exact argv0 `== /media/fat/MiSTer` (never substring); multi-match **refuse** |
| Play | `suspendMainForPlayback()` once at play start |
| Resume | stop / shutdown / thread end / exception path / atexit / crashGuard CONT |
| SPI | `MainSafeWindow` does **not** SIGCONT while session-held |
| Watchdog | `resumeStrandedMain()` does **not** fight session hold |
| kill -9 | supervisor `resume_stopped_main` (exact argv0) — host recipe green |

## Host evidence (this machine)
```
test_main_guard: OK  true rc=0
test_main_session_suspend: OK  true rc=0
test_supervisor_resume_main: OK (Main was T → S after kill -9 daemon)  true rc=0
UNIT_ROLLCALL_OK
make arm-plexd OK
build/arm/misterplexd md5=ce727a43de7fc02a78d939f2621b7e08
strings SUSPEND_MAIN_DURING_PLAY count=8  (live 9ce2c2d1 was 0)
```

## Tradeoff (document, not solve)
While Main state=`T`: F12/OSD, `/dev/MiSTer_cmd`, `load_core`, controller input dead.
Plex-side stop still works (TCP :3005 in misterplexd — never stopped). User cannot stick.

## Open question (not settled by this patch alone)
Why playback ~50 KB/s vs lone curl ~127 KB/s with H-A/H-B dead:
- **Lead:** system busy 187–190/200 %onecpu during 480p; CPU contention limits ffmpeg progress → HTTP read slows → ~50 KB/s.
- **Renice miss** (nice +19) does not reclaim from unconditional Main spinner — only STOP does.
- **Settling instrument = this feature ON vs OFF** on identical rk=9 cast (below PRE_REG).

## PRE_REGISTER (parent measures on device)
Control: same rk=9 480p, same conf except `SUSPEND_MAIN_DURING_PLAY`.

| metric | predict SUSPEND=0 (baseline) | predict SUSPEND=1 |
|---|---|---|
| Main state during play | `R` | `T` |
| system busy /200 | ~187–190 | **~140–150** (−40 to −50; prior measured −45.7) |
| MiSTer %onecpu | ~65–75 | **~0** (stopped) |
| ffmpeg %onecpu | ~65 | **up or stable**; rq wait should fall |
| playback br_rate Bps | ~50e3 | **toward path ~100–127e3** if CPU was limiter |
| drops | climbing | **flat / near 0** (prior 3→0) |
| av_drift_ms | positive diverging | **negative bounded** |
| supply_ratio=audio_s/wall_s | ~0.47 | **~0.95–1.0** |
| after stop Main state | — | `S` or `R` (not stuck `T`) |

**MISS if:** Main stays `R` with SUSPEND=1 logged; busy drop <15; or Main stuck `T` after stop.

**If SUSPEND=1 and br_rate stays ~50 KB/s while busy drops ~45:** CPU saturation lead is **MISSED** as sole limiter — seek non-CPU H-C (sender pace / app-level throttle).

## Parent install (safe atomic)
Worktree binary:
`/home/flynnsbit/Projects/MisterPlex/.worktrees/w-cpu-fps-measure/build/arm/misterplexd`
md5 `ce727a43de7fc02a78d939f2621b7e08`

```sh
# On build host → device (parent owns paths; live root usually /media/fat/misterplex_v2)
ROOT=/media/fat/misterplex_v2   # or resolve from readlink -f /proc/$(pidof...)/exe parent dir
STAGE=$ROOT/bin/misterplexd.new
# scp build/arm/misterplexd root@MiSTer:$STAGE
ssh mister "md5sum $STAGE && mv -f $STAGE $ROOT/bin/misterplexd && \
  grep -q SUSPEND_MAIN_DURING_PLAY $ROOT/misterplexd.conf 2>/dev/null || \
  echo 'SUSPEND_MAIN_DURING_PLAY=0' >> $ROOT/misterplexd.conf && \
  # enable for experiment:
  sed -i 's/^SUSPEND_MAIN_DURING_PLAY=.*/SUSPEND_MAIN_DURING_PLAY=1/' $ROOT/misterplexd.conf && \
  kill \$(ps -eo pid,exe | awk '\$2 ~ /misterplexd\$/ {print \$1; exit}')"
# supervisor respawns; confirm boot log:
#   misterplexd: SUSPEND_MAIN_DURING_PLAY=1
#   strings $ROOT/bin/misterplexd | grep -c SUSPEND_MAIN_DURING_PLAY   # expect >0
# After cast start: grep SUSPEND_MAIN_DURING_PLAY stop pid=  in log
# Main state:  awk ... /proc/<mainpid>/stat  expect T
```

Identify Main by `readlink -f /proc/*/exe` → `/media/fat/MiSTer` only.
