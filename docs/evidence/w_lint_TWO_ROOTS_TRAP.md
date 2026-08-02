# Two-roots trap — audit + gate (parent 2026-08-01, sixth occurrence)

**Lane:** w-lint gate-integrity  
**Branch tip:** see `git rev-parse --short=8 HEAD` on `w-lint-gate-integrity`  
**Host-only.** No device SSH from this lane.

## Defect (measured by parent)

| Path | Role |
|---|---|
| `/media/fat/misterplex/misterplexd.log` | **exists**, ~3 KB, mtime **days stale** |
| `/media/fat/misterplex_v2/misterplexd.log` | **live**, ~MB, currently written |
| Live process | `…/misterplex_v2/bin/misterplexd --conf …/misterplex_v2/misterplex.conf` |

First-hit-wins on a list that prefers v1, or a bare default
`LOG=…/misterplex/misterplexd.log`, reads the corpse. `[ -f ]` succeeds. Nothing
errors. Values look internally consistent and are **wrong**.

Today's hits: `avsync_wait_session` (fixed `ea255e04`), `avsync_pair_daemon_hdmi`
bare v1 default (voided daemon half of pair measurement), stale worktree copies.

**Preserved behaviour:** when the live log cannot establish session metrics,
tools return `UNSCORED rc=77` / `NO-DATA` rather than inventing zero. **Do not
weaken that.**

## Authority

`tools/avsync_live_log_resolve.inc.sh` — resolve via `/proc/*/exe` `*misterplexd*`,
root = dirname(dirname(exe)) for `…/bin/misterplexd`, pick `$root/misterplexd.log`.
Fallback list: **v2 before v1**. Empty pick = no path (caller must NO-DATA / skip-not-pass).

## Gate

| Artifact | Role |
|---|---|
| `tests/unit/test_two_roots_path_order.py` | product scan + mutation |
| `tests/fixtures/two_roots/avsync_pair_daemon_hdmi.BROKEN_v1_default.sh` | red fixture (6fc12bb6 pair) |
| `tests/fixtures/two_roots/avsync_wait_session.BROKEN_v1_first.sh` | red fixture v1-before-v2 list |

### Proven true rcs (direct)

```text
python3 tests/unit/test_two_roots_path_order.py --self-test; echo "true rc=$?"
# MUTATION_RED broken_pair (bare v1 DAEMON_LOG default)
# MUTATION_RED broken_wait (v1-before-v2 list)
# MUTATION_GREEN product pair/wait/resolve
# true rc=0

python3 tests/unit/test_two_roots_path_order.py --path \
  tests/fixtures/two_roots/avsync_pair_daemon_hdmi.BROKEN_v1_default.sh
echo "true rc=$?"   # expect 1

python3 tests/unit/test_two_roots_path_order.py; echo "true rc=$?"
# expect 0 on product tree after fixes
```

| Check | true rc |
|---|---:|
| self-test (broken RED + product GREEN) | **0** |
| BROKEN pair fixture alone | **1** |
| product tree scan | **0** |

## Fixes landed this tip

| File | Change |
|---|---|
| `tools/avsync_live_log_resolve.inc.sh` | brought from `ea255e04` |
| `tools/avsync_wait_session.sh` | live resolve (not v1-first list) |
| `tools/avsync_pair_daemon_hdmi.sh` | live resolve default (not bare v1) from `874df221` |
| `scripts/check_core_conf_geometry.sh` | live resolve when `LOG_PATH_ON_DEVICE` unset |
| `scripts/measure_c2_pixel_path.sh` | remote count via live resolve; empty → NO_DATA |
| `scripts/sweep_plex_video_modes.sh` | resolve before measure |
| `scripts/rollback_v2.sh` | plexctl candidates **v2 before v1** |
| `tests/hw/test_p480_ab_harness.sh` | live conf+log resolve; no bare v1 defaults |

## Classification snapshot (product scripts/tools — host scan)

### (a) Live-process resolve — correct
- `tools/avsync_live_log_resolve.inc.sh`
- `tools/avsync_wait_session.sh`
- `tools/avsync_pair_daemon_hdmi.sh`
- `scripts/check_core_conf_geometry.sh` (after fix)
- `scripts/measure_c2_pixel_path.sh` (after fix)
- `scripts/sweep_plex_video_modes.sh` (after fix)
- `tests/hw/test_p480_ab_harness.sh` (after fix)
- `scripts/video_regression.sh` daemon via `/proc/PID/exe` (prior)

### (b) List with v2 before v1 — tolerable fallback
- resolve.inc fallback for-loop
- `scripts/rbf_swap_preflight.sh` conf candidates (v2 then v1)
- `scripts/rollback_v2.sh` daemon pin search cands (v2 then v1)

### (c) Was BROKEN — fixed this tip
- bare v1 `LOG_REMOTE` / `DEVICE_LOG` defaults (geometry, c2, sweep, p480, pair)
- plexctl candidates v1-before-v2 in rollback

### Install / explicit v1 bundle targets (not silent live-read)
These **start or install into** the v1 tree (package recipe / lab harness that
owns that root). Gate does **not** treat them as first-hit live log readers.
Still dangerous if used against a v2-only live box without checking live exe —
prefer `plexctl` / live resolve when measuring:

- `scripts/package_release.sh`, `README.md` install recipes
- `scripts/mister_soft_bounce.sh`, `scripts/source_rate_rca.sh`,
  `scripts/validate_playback_controls_hw.sh` (start under v1 paths)
- many `tests/hw/test_f3_*.sh` / `push_frame` under `/media/fat/misterplex/bin/`
  (tool install root; not log first-hit)

### First-hit-wins generalized
Same class for **conf**, **bin**, **plexctl**, **RBF claim** — not only logs.
Gate checks order for log/conf/bin_daemon/bin_plexctl path pairs. Claim file
for running core remains `video_regression` / `plexctl` (mtime-bound), not
first-hit SD md5.

## Parent verify (no device required for gate)

```bash
cd .worktrees/w-lint   # tip with this card
python3 tests/unit/test_two_roots_path_order.py --self-test; echo "true rc=$?"
python3 tests/unit/test_two_roots_path_order.py \
  --path tests/fixtures/two_roots/avsync_pair_daemon_hdmi.BROKEN_v1_default.sh
echo "true rc=$?"   # 1
python3 tests/unit/test_two_roots_path_order.py; echo "true rc=$?"  # 0
```

Device (parent): after deploy, pair soak must print `log_remote=…/misterplex_v2/…`
or live root, never silent v1 when v2 is live.

## Standing: video_regression running bitstream
Still: no silicon content hash; `GATE_RESULT=CORE_IDENTITY_UNVERIFIED` rc=2
without PLXC/VIDREG; mixed pair rc=1. Artifacts should carry `rbf_md5`+`daemon_md5`
pair stamps (A/V scorer model). See `docs/evidence/w_lint_VIDEO_REGRESSION_RUNNING_CORE.md`.
