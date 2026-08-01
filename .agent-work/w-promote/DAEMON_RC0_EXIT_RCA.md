# Daemon clean `rc=0` exit RCA (w-promote / rollback-honest)

**Rule 0:** quoted source or measured artifact only.  
`grep -E "shutdown|SIGTERM|fatal|panic"` finding nothing in the daemon log is
**absence of evidence in that log**, not proof the exit was voluntary-by-design.

## Product path that returns 0 (this worktree `arm/misterplexd/main.cpp`)

| Site | Quoted behaviour |
|------|------------------|
| `on_signal` → `g_stop.store(true)` | SIGINT/SIGTERM only writers of `g_stop` |
| `while (!g_stop.load()) { ... }` then `return 0;` | Product main loop ends **only** when `g_stop` is set → process **exit status 0** |

There is **no** fixed-timer / idle-auto-exit / MAX_RUN product path in this tree's
`main.cpp` (search: no `MAX_RUN`, no idle timeout exit). Lab-only `return 0` is
`--help` and `--play-file` done.

## Why supervisor logs `EXIT pid=… rc=0 run_s=…`

Handled SIGTERM → process exits **0** (`WIFEXITED`, not `WIFSIGNALED`).  
`scripts/misterplexd_supervise.sh` / plexctl supervise treat `st < 128` as exit
status `st`. So **external SIGTERM looks identical to a clean voluntary exit**
in the supervise log alone.

Varying `run_s` (196 / 514 / 1543) is **consistent with external SIGTERM**,
**inconsistent with a fixed internal timer** (and no timer exists in source).

## What we do **not** have without device breadcrumbs

Sender of SIGTERM (`si_pid` / `sender_cmd`) — **unknown** until death file or
`SUPERVISE_EXIT` with SI fields is captured on-device. Candidates (not findings):
plexctl stop/reload/deploy, supervisor trap when supervisor is killed, manual kill.

Sibling tree `w-cpu-fps-measure` adds `exitReported` + `deathBreadcrumb` +
`si_pid` preservation — not yet in this worktree's main.cpp. Recommend parent
deploy that breadcrumb binary when attributing the next death.

## Counter / soak impact (source)

- `droppedFrames_` / `presentCount_` reset per stream (`media_player.cpp` play start).
- Respawn zeroes lifetime counters again.
- `session_epoch=process_epoch.stream_seq` on `supply_bucket` / media lines uniquely
  IDs a session. **Soak claims must assert one distinct `session_epoch`.**

Tool (host, no SSH):

```bash
python3 tools/soak_continuity_assert.py \
  --log /path/to/misterplexd.log.slice \
  --require-single-session-epoch
echo "true rc=$?"   # 0 OK, 2 FAIL multi-session/respawn, 77 NO-DATA
```

## Parent read-only device checks

```bash
# Supervise exits (evidence of respawn timing — not of cause)
grep -E 'EXIT pid=|SUPERVISE_EXIT' /media/fat/misterplex_v2/misterplexd_supervise.log | tail -20

# Breadcrumbs if present (newer binaries)
ls -la /media/fat/misterplex_v2/misterplexd.death 2>/dev/null
tail -5 /media/fat/misterplex_v2/misterplexd.death 2>/dev/null
grep -E 'EXIT_REASON|main_loop exit|session_epoch=|process_epoch=' \
  /media/fat/misterplex_v2/misterplexd.log | tail -40

# Distinct session_epoch in a soak window (pull log off-device first)
```
