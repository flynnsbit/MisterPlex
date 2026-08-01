# w-lint — four parent gate holes (2026-07-31 device-verified)

Branch: `w-lint-gate-integrity`. Host-only. Mutation-proven.

## Summary

| # | Hole | Fix | Mutation RED | Fixed GREEN |
|---|------|-----|-------------:|------------:|
| 1 | `telem_flags` no positional gate | SoT in `status_telemetry.hpp` + `test_telem_flags_abi.py` + one-hot walk in `test_status_telemetry` | drop `stub_busy` from RTL concat | product 8-field match |
| 2 | stop → API `buffering` forever while HDMI STOPPED | `holdIdle` requires media plant (`pendingKey` or duration) | old holdIdle → `state=buffering` | `state=stopped` |
| 3 | identity 624×480 still full rescale | `test_identity_resample_gate.sh` (w-geom owns product fix) | parent GEOM line `arm_rescale=1 mode=always` | synthetic `identity_skip=1` |
| 4 | `(deleted)` exe + deploy install | `*misterplexd*` + stage `.new`/`mv -f` | trailing-only glob MISS on deleted | MATCH deleted+live |

## (1) telem_flags bit positions

RTL (`Plex.sv`):
```systemverilog
wire [7:0] telem_flags = {
	pps_valid, sps_valid, stub_busy, has_idr,
	audio_underrun, has_stream, has_audio, has_frame
};
```
ARM (`fpga_spi.cpp`) decodes via `1u << kTelemFlag*Bit` from `status_telemetry.hpp`.

Severity if `stub_busy` dropped: wrong-status (upper flags shift), not picture loss.

```
python3 tests/unit/test_telem_flags_abi.py --self-test; echo "true rc=$?"
# MUTATION_RED drop_stub_busy … true rc=0 (self-test passes because mutation is RED inside)
./build/test_status_telemetry; echo "true rc=$?"
```

## (2) Timeline stop terminal

`companion.cpp` holdIdle previously:
`!wantPlay_ && (prePlayHold_ || castBound_)` → after `clearMedia`, `castBound_` alone forced `buffering@navigation` forever.

**Not a same-day regression** — blame `814df4a8` (2026-07-24). Latent until castBound + clearMedia exercised on `9ce2c2d1`.

```
# mutated old hold:
.agent-work/companion-hold-mut/test_stop; echo "true rc=$?"   # → 1 state=buffering
./build/test_companion_stop_terminal; echo "true rc=$?"       # → 0 state=stopped
```

Parent device verify (parent runs):
```
# after cast + play + stop:
curl -s "http://127.0.0.1:3005/player/timeline/poll?commandID=1" | grep -o 'state="[^"]*"'
# expect state="stopped" (not buffering) within first poll
```

## (3) Identity resample

Gate only: source/delivery/target match ⇒ `arm_rescale=0` / `identity_skip=1`.
Does **not** ban `DDR_YUV_FORCE_SCALE` (non-identity 480p).

```
bash tests/unit/test_identity_resample_gate.sh; echo "true rc=$?"
# identity_parent_measured true rc=1
# identity_good true rc=0
# identity_unknown/empty true rc=77
```

Product default conf token remains `skip_identity` in `main.cpp`. Device RED today is `mode=always` on identity 624 — w-geom fix path.

## (4) Deploy traps

- Match: `case "$exe" in *misterplexd*)` after `readlink` fallback (not `-f` alone).
- Install: `scp → misterplexd.new` then `mv -f` (rename legal over running exe).

```
bash tests/unit/test_deploy_deleted_exe_match.sh; echo "true rc=$?"
```

## Verify all (host)

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-lint
python3 tests/unit/test_telem_flags_abi.py --self-test; echo "true rc=$?"
python3 tests/unit/test_telem_flags_abi.py; echo "true rc=$?"
make "$(pwd)/build/test_status_telemetry" "$(pwd)/build/test_companion_eof" \
     "$(pwd)/build/test_companion_stop_terminal"
./build/test_status_telemetry; echo "true rc=$?"
./build/test_companion_eof; echo "true rc=$?"
./build/test_companion_stop_terminal; echo "true rc=$?"
bash tests/unit/test_identity_resample_gate.sh; echo "true rc=$?"
bash tests/unit/test_deploy_deleted_exe_match.sh; echo "true rc=$?"
python3 tests/unit/test_unit_rollcall.py; echo "true rc=$?"
```
