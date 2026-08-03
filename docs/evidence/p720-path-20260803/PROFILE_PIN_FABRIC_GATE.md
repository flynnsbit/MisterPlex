# Baseline / CAVLC profile pin + fabric stream gate

**Lane:** w-path. **Parent ask (2026-08-03):** pin H.264 profile in the PMS
request; negative-test High/CABAC and refuse honestly (no silent garbage).

## Alignment (parent measured + RTL inventory)

| Fact | Evidence |
|--|--|
| Lab true-720 delivery | Constrained Baseline L3.1, yuv420p, no B-frames |
| Fabric RTL | CAVLC + intra + inter + MC + deblock + DPB; **CABAC ABSENT** |
| Match | Stream subset ≡ RTL subset — *if* pin holds |

## Pin surfaces (request path)

| Surface | Behaviour |
|--|--|
| `kPlexH264ProfilePin` | `"baseline"` constant in `plex_resolve.hpp` |
| `buildUniversalTranscodeUrl` | **Always** emits `videoProfile=baseline` (ignores mutated WeakLadder) |
| universal decision URL | Same hard pin |
| `plexClientCapabilities` / Profile-Extra | Advertise `profile:baseline` only |
| `validateWeakLadder` | Hard-fail non-baseline |
| `MiSTerPlex.xml` | `VideoEncodeFlags` baseline + cabac=0; Match baseline required |
| MiSTerPlex headers | Profile-Extra skipped so XML encode flags stay (existing) |

## Runtime refuse (bitstream / decision attr)

| API | Role |
|--|--|
| `gateFabricH264AnnexB` / `FromChain` / `Strict` | `h264_fabric_stream_gate.hpp` |
| Verdicts | `ok_baseline_cavlc`, `refuse_cabac`, `refuse_profile_not_baseline`, `refuse_b_slice`, … |
| `plexDeliveryProfileIsFabricSafe` | PMS Media/decision `@videoProfile` string |
| `plexVideoProfileAttrLooksLikeCabacRisk` | high/main/cabac substring risk |

Host FFmpeg pixel path may still decode High; **fabric bitstream path must call
the gate before consume**. Rendering High/CABAC on CAVLC fabric is forbidden.

## Tests (red-before-green negatives)

`tests/unit/test_h264_fabric_stream_gate.cpp`:

- Accept real Baseline annex-B fixture
- **Refuse** High profile_idc=100
- **Refuse** Main profile_idc=77
- **Refuse** Baseline + CABAC PPS (chain + appended annex-B NAL)
- **Refuse** B-slice
- Decision attr: baseline OK; high/main empty fail

`test_resolve`: evil `h264Profile=high` still builds URL with `videoProfile=baseline`;
`plexDeliveryProfileIsFabricSafe("high")` is false.

## What this does *not* claim

Fitted fabric decode on glass. Pin + gate only keep the stream inside the
subset the RTL was built for.
