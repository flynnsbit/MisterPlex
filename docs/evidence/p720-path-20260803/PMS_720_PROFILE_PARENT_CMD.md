# Parent live PMS 720p baseline command

## Measurement identity
- Branch: `w-path-720p`
- SHA: run `git rev-parse --short HEAD` in path worktree
- main@3fa01a9b (parent): only 240p/480p — this branch lifts the ceiling

## What changed
| Item | Value | Evidence |
|------|-------|----------|
| Profile `720p` | `1280x720`, maxBR **3100**, quality 70, baseline, **level 30** | lab: 3000→720x404; 3100→1280x720; rk=7 bytes L3.0 |
| Ceiling | hard-fail `w>1280 \|\| h>720` | NEG 1920x1080 |
| Profile pin | baseline only | NEG high |
| Level pin | ≤30 (720p/480p); 540p still ≤31 | NEG L31 on 720 |
| 720 bitrate knee | hard-fail `<3100` | NEG 1500/3000 |
| HD xcode target | **720p** (not 540) | parent top priority |
| Native ≤1280x720 | Direct Play eligible | rk=7 cheapest |
| Probe | `--profile 720p` (default still `480p`) | no skip launder |

## Bitrate justification (not eye-scale)
- Asset rk=7 ≈ 1.9 MB / ~30 s → ~500 kbps native (DP path).
- Universal geometry knee measured: **≥3100** required for true 1280x720 coded (else 720x404).
- Fabric sink: I420 1280x720 @24 = 33.2 MB/s push; bitrate is compressed ES, not DDR rate.
- Do not use 2500×(1280×720)/(640×480) — rejected as step-function fit.

## Parent: run this LIVE (you have creds)

Build from this worktree (or after merge):

```bash
cd /path/to/MisterPlex-wt-path   # or detached pin of this commit
make build/pms_baseline_probe
# Prefer env for token — never commit it
export PLEX_BASE='http://192.168.1.24:32400'   # or your lab base
export PLEX_TOKEN='…'                          # from your secret store
export MISTERPLEX_BASELINE_KEY='/library/metadata/7'
./build/pms_baseline_probe --profile 720p --seconds 14 \
  --expect-coded 1280x720 --expect-display 1280x720
echo "true rc=$?"
```

Equivalent with flags (token still not for commits/logs):

```bash
./build/pms_baseline_probe \
  --base "$PLEX_BASE" --token "$PLEX_TOKEN" \
  --key /library/metadata/7 --profile 720p --seconds 14
echo "true rc=$?"
```

### Expected PASS shape
```
PMS_BASELINE_SOURCE live_pms=… key=/library/metadata/7 profile=720p req=1280x720 maxBR=3100
PMS_BASELINE_DELIVERED profile_idc=66 … coded=1280x720 display=1280x720 …
test_pms_baseline_profile: OK delivered Baseline/CAVLC/ref=1/no-B 1280x720 stream (profile=720p)
true rc=0
```

### Expected FAIL shapes (honest, not skip)
- decision failed → rc=1 (was parent’s main failure with only 480p table / broken ladder)
- coded 720x404 → geometry mismatch FAIL (bitrate knee / PMS trap)
- missing creds → **rc=77 SKIP-NOT-PASS** (loud; not a pass)

### Regression default
```bash
./build/pms_baseline_probe --profile 480p   # default if omitted
```

## Unit evidence (path worktree)
```
build/test_resolve; echo "true rc=$?"   # expect 0
```

## Ladder
| Unit | ON_MAIN vs 3fa01a9b | Level |
|------|---------------------|-------|
| plexTranscodeProfiles 720p | no (main only 240/480) | L0 path |
| validateWeakLadder 1280 ceil | no | L0 path |
| pms_baseline_probe --profile | no | L0 path |
