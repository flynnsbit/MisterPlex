# w-device recipe — scale skip A/B (post host commit)

**Do not run from the ARM/host lane.** Device is the user's daily driver; w-device owns ssh/deploy.

## 0. Build / deploy daemon only (no RBF thrash)

```bash
# on host builder (or existing arm package path)
make arm-plexd   # or project equivalent
# deploy companion ONLY — no core bounce unless already planned
# scripts/deploy_misterplexd.sh  (w-device)
```

Confirm boot log contains:

```text
misterplexd: FFMPEG_SCALE=always FFMPEG_SWS_FLAGS=(default) FFMPEG_SCALE_ASSUME_MATCH=0
```

## 1. Baseline (shipping behaviour)

Same clip, offset, settle, window as prior p480 A/B (harness defaults OK).

```bash
# conf: ensure NO FFMPEG_SCALE lines (or explicit always)
# then:
TIER=480p WINDOW_S=60 SETTLE_S=20 \
  bash tests/hw/test_p480_ab_harness.sh
```

Capture JSON + `media: vf_plan` lines from daemon log. Expect:

- `reason=scale_pad_crop` (480p) or `scale_pad_center` (240p)
- `scale_applied=1`
- vf contains `scale=` and **no** `:flags=`

## 2. Identity skip (P1/P2)

```bash
# on device misterplex.conf (lab):
FFMPEG_SCALE=skip_identity
FFMPEG_SCALE_ASSUME_MATCH=1
# FFMPEG_SWS_FLAGS left unset
```

Restart daemon only. Re-run harness same clip/tier/window.

Expect log:

```text
media: vf_plan reason=identity_skip_crop_pad_clear scale_applied=0 identity_skip=1 ...
```

or `identity_skip` @240p. vf has no `scale=`.

Compare mandatory CPU method fields in harness JSON:

- `ffmpeg_pct_onecpu`, per-thread `vf#0:0` if still named, mplex %, totals
- `ddr_push_ms`, drops, av_drift window

## 3. fast_bilinear with scale still on (P3)

```bash
FFMPEG_SCALE=always
FFMPEG_SWS_FLAGS=fast_bilinear
FFMPEG_SCALE_ASSUME_MATCH=0
```

Expect vf contains `:flags=fast_bilinear` and `scale_applied=1`.

## 4. 240p control (P4)

Repeat 1 and 2 with `TIER=240p`.

## 5. Publish

- One JSON record per arm under `docs/evidence/p480-scale-skip/`
- Stamp `SOURCE_SHA`, conf keys, `vf_plan` log line
- Mark each P1–P5 HIT or MISS against `SCALE_SKIP_PREREG.md`
- **Do not** flip shipping defaults or bitrate from results without parent decision

## Hard rules

- Soft-skip 77 ≠ pass
- Capture `cmd; echo "true rc=$?"` directly
- No Quartus / no thrash of banned RBFs
- One menu deploy max if core reload is unavoidable (prefer daemon-only)
