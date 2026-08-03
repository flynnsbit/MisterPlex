# telem_flags + castBound liveness (fit-critical)

Tip path: `w-lint-gate-integrity`. Host-only mutations.

## telem_flags / PRODUCT_NO_STUB

Pack (Plex.sv MSB-first):
`{pps_valid, sps_valid, stub_busy, has_idr, audio_underrun, has_stream, has_audio, has_frame}`

ARM masks bit0…bit7 via `status_telemetry.hpp`. **Removing `stub_busy` shifts only
fields above it** (wrong status; `has_frame` stays bit0 — picture looks fine).

Gate: `tests/unit/test_telem_flags_abi.py`
- product GREEN width=8 bit5=`stub_busy`
- mutation drop `stub_busy` → RED
- mutation reorder stub/sps → RED
- PRODUCT_NO_STUB policy: **gate the stub (tie to 0), never delete the bit**

```bash
python3 tests/unit/test_telem_flags_abi.py --self-test; echo "true rc=$?"
make build/test_status_telemetry && ./build/test_status_telemetry; echo "true rc=$?"
```

Coordinate w-fit-1: keep `stub_busy` in concat (or `wire stub_busy = 1'b0`).

## castBound liveness (not reporting choice)

Intentional: wire `buffering@navigation` while cast-bound after stop (Resume UX).
**Defect:** latch on `/resources` (LAN discovery) + **no expiry** → forever buffering
if controller vanishes without unsubscribe.

Fix:
- Latch only on `/player/*` via `touchCastBoundLocked()` (not `/resources`)
- `maybeExpireCastHoldLocked()` — default TTL 120s when `!wantPlay_`
- Unsubscribe still clears immediately

```bash
make build/test_castbound_liveness && ./build/test_castbound_liveness; echo "true rc=$?"
```

## make build/* + assets

Already landed `c1b93e06`: relative alias, `.agent-work/` ignore, large-asset policy
(no history rewrite; leave 98MB blob; stop adding new >20MB).
