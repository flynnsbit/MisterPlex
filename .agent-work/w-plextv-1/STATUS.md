# w-plextv — real-geom matrix + MEASURED_DELIVERY + session_epoch

Parent-proven earlier: picker/transitions/TEARDOWN. **Agent-run E2E ≠ evidence — you re-run.**

## Last finished (this tip)
1. **Real content matrix** rk=29,30,31,32 (`run_real_geom_matrix.sh`) — ratingKey only.
2. **MEASURED_DELIVERY** gate (not request/library) + **desync_risk=1 FAIL**.
3. **N=10** transitions (existing; matrix default 10).
4. **session_epoch** stable across continuous pause/resume/seek (stop/recast may bump).
5. **TEARDOWN** still closes only OUR Playwright controller.

## Parent paste — smoke (synthetic, prior path)
```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-plextv-e2e-fix
./tests/hw/e2e/run_cast_picker.sh; echo "true rc=$?"
```

## Parent paste — real geometry matrix (DoD path)
```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-plextv-e2e-fix
# Feed MEASURED_DELIVERY (live :3005/player/telemetry may 404):
#   grep -E 'MEASURED_DELIVERY|measured_delivery=|desync_risk=|session_epoch=|PIPE_DESYNC' LIVE_LOG | tail -80 \
#     > build/e2e-artifacts-matrix/daemon_snip.txt
export E2E_DAEMON_LOG="${E2E_DAEMON_LOG:-$PWD/build/e2e-artifacts-matrix/daemon_snip.txt}"
E2E_REAL_GEOM_KEYS=29,30,31,32 E2E_TRANSITION_CYCLES=10 \
  ./tests/hw/e2e/run_real_geom_matrix.sh; echo "true rc=$?"
```

Single interesting key:
```bash
E2E_CONTENT=real E2E_TIER=480p PLEX_RATING_KEY=32 \
E2E_REQUIRE_MEASURED_DELIVERY=1 E2E_REQUIRE_SESSION_EPOCH=1 \
E2E_TRANSITION_CYCLES=10 E2E_DAEMON_LOG=... \
./tests/hw/e2e/run_cast_picker.sh; echo "true rc=$?"
```

## Log markers to grep
- `MEASURED_DELIVERY_OK delivered=WxH desync_risk=0`
- `SESSION_EPOCH_OK epoch=…`
- `TRANSITIONS_OK cycles=10/10`
- `TEARDOWN_OK`
- `REAL_GEOM_MATRIX_ROW rk=…`

## NOT covered
- Pixels / overlay res / chevron / judder / lipsync (parent HDMI).
- PLXD frames_done (void until you glass-confirm).
- Agent-run as promotion evidence.
