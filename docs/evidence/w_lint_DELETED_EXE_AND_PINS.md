# w-lint: (deleted) exe blindness + validated-pair pins

## Defect (parent HW 2026-07-31)

After rename-in-place deploy, `/proc/PID/exe` reads
`/media/fat/misterplex_v2/bin/misterplexd (deleted)`.
Trailing glob `*/misterplexd)` → `n_daemon=0` while `/resources` returns 200.

## Fix

- `scripts/lib/live_daemon_enum.sh`: strip ` (deleted)`, `basename == misterplexd`,
  `md5sum /proc/PID/exe`; `n=0` + HTTP 200 → **FAIL matcher-blind** (not OK, not 0.0).
- Wired into `pair_live_probe.inc.sh`, deploy probe, rollback stop, fetch pins,
  `video_regression.sh` observe, `plexctl.sh` stop/status.

## Pin track

- `artifacts/validated-pair/CURRENT` → `DAEMON_PREFIX8=865d4c8a` (live breadcrumb)
- `pair_pin_update.sh` / `pair_pin_resolve.inc.sh` — no hand-edit of gate scripts per deploy
- PREV `edc3a46b` + hist `e9f79de2` remain accepted; SPI hybrids unchanged

## RBG

`tests/unit/test_live_daemon_enum.sh` reproduces historic `*/misterplexd)` miss and
proves required matcher counts deleted; classify n0+200 → rc=3.
