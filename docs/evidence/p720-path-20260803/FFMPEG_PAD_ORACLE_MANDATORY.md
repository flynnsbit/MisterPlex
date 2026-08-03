# FFmpeg pad oracle — mandatory (rd-duck soft-skip hole)

## Defect
`tests/unit/test_ffmpeg_vf.cpp` live pad oracle used `std::system`; on `rc_expr != 0`
it printed `NOTE ... skipped` and left the suite green. Missing ffmpeg, bad quoting,
or execution failure reduced placement evidence to the self-model.

## Fix
- Require `command -v $FFMPEG` (default `ffmpeg`) — hard expect, no soft-skip.
- Require expr pad and explicit `:2:0` pad both `system_rc==0` before placement asserts.
- Keep stderr in `build/pad_oracle_426_432.err` for diagnosis (not `2>/dev/null`).
- `GREEN_FFMPEG_PAD_ORACLE` only prints when both rcs are 0 and L=2.

## Evidence (direct rc, never through a pipe)
```
./build/test_ffmpeg_vf → true rc=0
  GREEN_FFMPEG_PAD_ORACLE expr_rc=0 explicit_rc=0 L=2 mandatory
  PASS test_ffmpeg_vf

FFMPEG=/nonexistent/ffmpeg_missing ./build/test_ffmpeg_vf → true rc=1
  FAIL: ffmpeg oracle … mandatory; no soft-skip
  NO GREEN_FFMPEG_PAD_ORACLE
```
Artifacts: `ffmpeg_pad_oracle_mandatory.{out,err,rc}`, `ffmpeg_pad_oracle_missing.{out,err,rc}`.

## Fit-release
`build/test_ffmpeg_vf` is already in `make unit-unlocked`. Soft-skip string removed
(`rg "NOTE: ffmpeg oracle skipped"` → empty). Set `FFMPEG=` only to override binary path.
