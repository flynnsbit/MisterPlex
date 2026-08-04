# Decoder conformance harness fixtures

Shared machinery for **fabric H.264 decode** (bit-exact vs ARM oracle).

| Asset | Role |
|-------|------|
| `corpus_manifest.json` | Subject **pool**. Runtime selection + recorded seed via `check_decoder_conformance.py select-corpus` / gate. `dev_fixture_ids` cannot be the sole selection when a stage claims complete. |
| `coverage_ledger.json` | Per-stage features tied to real decode capabilities. `claimed_complete` fails if features empty/unproven or `rtl_modules` empty. |

## Lane plug-in

```bash
# Bit-exact I420 (ARM oracle blob vs RTL/sim blob)
python3 scripts/check_decoder_conformance.py compare \
  --arm build/arm_frame.yuv --rtl build/rtl_frame.yuv \
  --format i420 --width 320 --height 240 --stage recon

# Seeded corpus selection (writes seed + selection JSON)
python3 scripts/check_decoder_conformance.py select-corpus \
  --k 2 --seed-out build/decoder_conformance/seed.txt \
  --selection-out build/decoder_conformance/selection.json

# Full gate (coverage + claimed REACHABILITY + corpus paths)
make decoder-conformance
# or: python3 scripts/check_decoder_conformance.py --gate
```

## REACHABILITY

Claimed `rtl_modules` under `claimed_complete` / `claim_delivered` must be
**REACHABLE** from `sys_top`/`emu` (not merely in `files.qip`). Today all
stages are honest-incomplete; claiming `h264_cavlc_residual_block` fails as
PRUNED (historical teeth class).

## Controls

`tests/unit/test_decoder_conformance_harness.sh` → `--self-test` POS/NEG table.
