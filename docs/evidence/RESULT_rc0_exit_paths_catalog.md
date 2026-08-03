# RESULT — clean rc=0 exit catalog + live EXIT_REASON e2e

**Branch:** `w-cpu-rc0-exit` @ worktree `.worktrees/w-cpu-rc0-exit`  
**Base:** `5458a142`  
**Device:** not touched.

## fps=24/1 retraction

No product work in this lane depended on PARENT ERROR 17 (23.976 vs 24.000).
Nothing to drop. Assets report `frameRate="24.000"`; `fps=24/1` remains correct.

## 1) Every product rc=0 path (quoted)

| site | file:line | live product? |
|------|-----------|---------------|
| `--version` | `main.cpp:264-265` `deathBreadcrumbExit(0,"site=main.cpp:--version")` | CLI only |
| `--help` | `main.cpp:295-296` same | CLI only |
| lab play done | `main.cpp:904` `exitReported(0,"site=main.cpp:lab-play-file-done")` | lab `--play-file` only |
| **main loop** | `main.cpp:1697` `exitReported(0, why)` why=`site=main.cpp:main_loop_g_stop sig=…` | **only product-loop rc=0** |

Sole `g_stop.store(true)`: `main.cpp:80` inside `on_signal_info` (SIGINT/SIGTERM, SA_SIGINFO at `:626-633`).

Non-zero process exits (not rc=0): lab-play-failed(1), zero-frames(2), companion-start-failed(1); child `_exit(127)` on exec fail (`media_player.cpp:306`, `:1432`).

No `exit(0)` / `quick_exit` / timer keywords (`MAX_RUN_S`/`IDLE_EXIT`) in product main.

## 2) Rank + discriminator

| rank | path | how to discriminate in log/death |
|------|------|----------------------------------|
| 1 | external SIGTERM/INT → `main_loop_g_stop` | `EXIT_REASON … sig=15 si_code_name=SI_USER si_pid=N` |
| 2 | lab CLI | `why=site=main.cpp:--help\|--version\|lab-play-file-done` |
| 3 | voluntary idle exit | **does not exist in source** |

Host e2e (this commit) proved rank-1: SIGTERM → wait rc=0 + death `signal=15 SI_USER si_pid≠0`.

**Live device sender for run_s=1543/196/514:** unknown without the device death file. Parent:

```sh
cat /media/fat/misterplex_v2/misterplexd.death; echo "true rc=$?"
grep EXIT_REASON /media/fat/misterplex_v2/misterplexd.log | tail -5; echo "true rc=$?"
```

Do **not** treat “grep shutdown empty” as proof of design or of external kill — that is log absence only.

## 3) Shipped this commit

- `fflush(stderr)` + `fsync(death fd)` in `deathBreadcrumbExit` (flush before return)
- `si_code_name=SEGV_MAPERR|SEGV_ACCERR` on death paths (rc=139 attribution)
- Host live `tests/unit/test_exit_reason_sigterm_e2e.sh` (red: stripped EXIT_REASON fails)
- Register `test_daemon_rc0_paths.sh` + e2e in Makefile + both rollcall lists (168→170)

## Host true rc

| cmd | true rc |
|-----|---------|
| `./build/test_death_breadcrumb` | 0 |
| `bash tests/unit/test_exit_reason_sigterm_e2e.sh` | 0 |
| `bash tests/unit/test_main_rc0_paths.sh` | 0 |
| `bash tests/unit/test_daemon_rc0_paths.sh` | 0 |
| `python3 tests/unit/test_unit_rollcall.py` | 0 |
| `make unit` | **0** |
