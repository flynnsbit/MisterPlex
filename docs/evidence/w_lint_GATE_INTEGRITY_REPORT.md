# w-lint GATE INTEGRITY REPORT

- branch: `w-lint-gate-integrity`
- sha: (post-commit)
- date: 2026-07-31
- scope: host/source only

## 0. BLOCKER — running bitstream + promotion pins

### Defects
1. On-disk RBF + vacuous CORENAME → SPI core + DDR daemon could pass green.
2. DDR pin lagged live pair (need c5382bee + edc3a46b).
3. Empty probe reported as FAIL got='' (NO-DATA missing).

### Running core (fail closed)
- claim + RBFNAME mtime mandatory (missing/stale → rc=1)
- pair table rejects SPI/DDR mix
- PLXC +0x130 reserved; GATE_CORE_IDENTITY=UNVERIFIED until PLXC

### Pins (demote CURRENT→PREV; never weaken)
| family | core | daemon CURRENT | daemon PREV |
|---|---|---|---|
| spi | dfebf2bf… | 50f4eb92… (+7cd10b4d, 3e2cbb98) | — |
| ddr | c5382bee | **edc3a46b** | **e9f79de2** |

### NO-DATA
classify_obs_hash empty → rc=4; ETXTBSY only if both non-empty.

### RBG host mutation (test_video_regression_liveness.sh)
dead/no-claim/stale/mix/http/etxtbsy/multi/timeout → 1; coherent SPI/DDR/PREV → 0; empty disk → 4; UNVERIFIED on green.

### Other
rollcall **113** sha16=eb770e5b9ffa849b; pipe-rc 0; false-green 0; soft-skip PASS_INCOMPLETE; PINNOTFOUND guard present.
WARN: idle telemetry pidof; f3_visual CORENAME-only.

### Parent
Merge before DDR promote; claim after load; PLXC rides next fit; full digests when known.
