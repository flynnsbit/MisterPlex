# Signal-sender table (source grep — product scripts + daemon)

Selection method is the load-bearing column. Substring cmdline matching is flagged.

| file:line | signal / call | target selection | Can hit live misterplexd? |
|---|---|---|---|
| `scripts/plexctl.sh:105` | `kill` (TERM default) | `pids_matching(pat)` scans `/proc/*/cmdline` for substring `pat` in `{plexctl_supervise.sh,misterplexd_supervise.sh,dedupe_daemon.sh,/bin/misterplexd}`; skips `*plexctl.sh*` | **YES** — `stop_all` / start_bundle. Uses substring `*"/bin/misterplexd"*` and supervisor script names. Not pidof. |
| `scripts/plexctl.sh:174` (generated supervise trap) | `kill $child` on supervisor TERM/INT | exact child pid of spawn | YES if supervisor itself is TERM'd |
| `scripts/deploy_misterplexd.sh:27-28` | `kill -9` | `pidof misterplexd` + `pidof ffmpeg` | **YES** — hard kill all named binaries (v1 path deploy) |
| `scripts/restore_misterplexd_prev.sh:30,34` | `kill` then `kill -9` | `pidof misterplexd` / `ffmpeg` | **YES** |
| `scripts/deploy_plex_core.sh:122,129` | `killall misterplexd` then `killall -9` | **killall by argv0 name** | **YES** — core deploy path |
| `scripts/deploy_plex_core.sh:133-134` | `killall -CONT MiSTer` | name match Main | no (CONT only) |
| `scripts/mister_soft_bounce.sh:438` | `killall misterplexd` | name match | **YES** — soft bounce |
| `scripts/validate_playback_controls_hw.sh:149,154` | `killall` / `killall -9` | name match | **YES** — lab validation only |
| `scripts/source_rate_rca.sh:84,110,113` | `kill $p` | local probe pids | lab host only |
| `arm/misterplexd/media_player.cpp:1023-1046` | `kill(-pgid, SIGTERM/SIGKILL)` | **ffmpeg/stream child process groups only** (`childPid_` / `streamPid_`) | NO — not self |
| `arm/misterplexd/fpga_spi.cpp:239-371` | `kill(p, SIGSTOP/SIGCONT)` | Main_MiSTer via `/proc` argv0 **exact** `/media/fat/MiSTer` | NO — Main only |
| `arm/misterplexd/main.cpp:519-520` | handles SIGINT/SIGTERM | self | N/A (receiver) |
| `tools/death_capture_supervisor.c:404` | `kill(pid, SIGTERM)` | its own supervised child when parent gets TERM | only if that supervisor owns the daemon |

## Ranked for unexplained rc=0 (handled SIGTERM)

1. **`plexctl.sh stop_all` / start_bundle** — sends TERM to every cmdline containing `/bin/misterplexd` or supervisor names. Variable run_s fits human/script stop/restart, not a fixed timer.
2. **`deploy_plex_core.sh` / `mister_soft_bounce.sh` `killall misterplexd`** — if anyone bounced core during soak.
3. **Supervisor trap** — only if the supervisor process itself received TERM (then child dies and supervisor exits 0 — would not keep respawning unless something restarts supervisor).
4. **`deploy_misterplexd.sh` / `restore_*` kill -9** — would be WIFSIGNALED 9, **not** rc=0. Ruled out for your measured rc=0.
5. **Daemon does not SIGTERM itself** in main/companion/media_player product path.

## Not a fixed timeout

No idle/watchdog `return 0` in the main loop (only `g_stop` from signals).

## How to read next death

```
grep EXIT_REASON $ROOT/misterplexd.log | tail -3
cat $ROOT/misterplexd.death
# si_pid=N → if still live: tr '\0' ' ' < /proc/N/cmdline
tail -5 $ROOT/misterplexd_supervise.log   # SUPERVISE_EXIT WIF*
```
