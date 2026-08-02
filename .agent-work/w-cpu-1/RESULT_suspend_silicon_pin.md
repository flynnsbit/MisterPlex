# RESULT — SUSPEND_MAIN_DURING_PLAY on silicon pin (post ce727a43 regression)

## Headline

**Do not redeploy tip `ce727a43` / `029470fd`.**  
Ship only **silicon-pin branch** `w-cpu-suspend-silicon-pin` built from live pin provenance `13d3c191` (`9ce2c2d1`) + suspend-only delta.

| artifact | md5 | notes |
|---|---|---|
| **THIS build** | `ea643e99c353fc64cee35782a631c0b3` | pin+suspend; `-nostats`; dual A/V gate green |
| live good pin | `9ce2c2d1…` | daily driver restored by parent |
| BAD tip ship | `ce727a43…` | frames=0×2; rolled back |

Binary size: pin 12977432 B → this 12979788 B (+2356 B suspend).

## RCA of ce727a43 (Rule 0)

**Proven attribution class:** tip binary ≠ silicon pin binary. Parent A/B:

- `ce727a43`: frames=0, `short read got=0/449280 totalBytes=0 eof=1`, audio pumped
- `9ce2c2d1`: frames=785, healthy

**Lead `-stats` vs `-nostats`:** tip spawn used `-stats`; pin uses `-nostats` (quoted `media_player.cpp` silicon-pin L2692–2693). Host dual-pipe A/B: same video bytes under both flags → **`-stats` alone is NOT proven device cause**. Real ship defect: **untested tip stack on daily driver without dual A/V gate**.

**Gate hole (more important than the bug):**
- `test_play_file_delivery` is **video-only** and stayed green
- Host unit/session/supervisor green ≠ can decode a dual A+V frame on product spawn path
- **Fix:** `tests/unit/test_play_file_av_dual.sh` — requires `frames>0`, rejects `short read got=0/… totalBytes=0` (device signature), asserts `-nostats` in spawn log

## What this branch contains

Base: `13d3c191` (claim provenance of live `9ce2c2d1`).

Delta only:
1. `SUSPEND_MAIN_DURING_PLAY` (default **OFF**) — `fpga_spi` session STOP/CONT, product Main via **exe | exact argv0**, multi-match refuse, SPI sessionHeldMode, crash/atexit CONT
2. media_player play/stop/shutdown/thread resume hooks
3. conf load/log in `main.cpp`
4. `test_main_session_suspend`, `test_supervisor_resume_main`, `test_play_file_av_dual`, rollcall

**Not included:** tip supply_ratio / bitrate floor / `-stats` / other tip work.

## Host gates (all `true rc=0`)

```
test_main_session_suspend: OK
test_supervisor_resume_main: OK (T→S after kill -9)
test_play_file_delivery: OK
test_play_file_av_dual: OK frames=48
test_unit_rollcall: UNIT_ROLLCALL_OK
make arm-plexd: OK → md5 ea643e99…
strings: SUSPEND_MAIN_DURING_PLAY present; -nostats present; no spawn -stats
```

## Parent deploy (SAFE order)

```bash
# 1) Stage (do NOT overwrite live yet)
SRC=/path/to/misterplexd.ea643e99   # this build
ssh root@${MISTER_HOST} "cp -a /media/fat/linux/misterplexd /tmp/plexd.9ce2c2d1.bak"
scp "$SRC" root@${MISTER_HOST}:/tmp/misterplexd.ea643e99.stage
ssh root@${MISTER_HOST} 'md5sum /tmp/misterplexd.ea643e99.stage; \
  test "$(md5sum /tmp/misterplexd.ea643e99.stage | cut -c1-32)" = ea643e99c353fc64cee35782a631c0b3'

# 2) Atomic install + restart
ssh root@${MISTER_HOST} 'install -m 755 /tmp/misterplexd.ea643e99.stage /media/fat/linux/misterplexd && \
  kill $(pidof misterplexd) || true'
# wait supervisor restart; verify:
ssh root@${MISTER_HOST} 'md5sum /proc/$(pidof misterplexd)/exe; \
  strings /proc/$(pidof misterplexd)/exe | grep -c SUSPEND_MAIN_DURING_PLAY; \
  strings /proc/$(pidof misterplexd)/exe | grep -E "^-nostats$"'
```

### Smoke A — SUSPEND=0 (MUST pass before ON)

Conf must have `SUSPEND_MAIN_DURING_PLAY=0` (or unset). Cast rk=9 480p.

**PRE_REG:**
- frames > 0 within first 5 s (HARD FAIL if 0)
- no `short read got=0/… totalBytes=0`
- vfps/pfps ~ healthy pin class (not frames=0)
- supply path plays; rollback to `/tmp/plexd.9ce2c2d1.bak` if frames=0

### Smoke B — SUSPEND=1 (only after A green)

Set `SUSPEND_MAIN_DURING_PLAY=1`, restart daemon, cast same clip.

**PRE_REG (from prior measured −45.7 %onecpu win):**
| metric | predict |
|---|---|
| Main state during play | `T` (stopped) |
| system busy /200 | drop ~40–50 vs ~187–190 baseline |
| ffmpeg %onecpu | rise (less rq wait) |
| br_rate / delivery Bps | rise toward path ~100+ KB/s if CPU was limiter |
| drops | flat / improve |
| on stop | Main resumes non-T; F12/OSD works again |

**Tradeoff (document, not solve):** while Main `T`, F12/OSD/`MiSTer_cmd`/`load_core`/controller dead. Plex stop via TCP :3005 still works. kill -9 → supervisor `resume_stopped_main`.

## Open question (unchanged)

Why solo playback ~50 KB/s vs curl ~127 with H-A/H-B dead: **unknown**. Settling instrument = SUSPEND ON vs OFF delivery Bps on same session class after Smoke A green.

## Misses published

- Prior tip ship assumed host gates ⇒ device play: **MISSED** (ce727a43)
- Dual-AV gate first draft false-red on normal EOF `got=0` after frames>0: **fixed** (require `totalBytes=0`)
