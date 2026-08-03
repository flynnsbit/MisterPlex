# Capacity-selected PLXG on generic publish (rd-duck shear)

## Defect
`ddrFrameGeometryForFpgaPresent` returns identity storage (320/416/720/…).
w-mem `makeDdrPublishPlan` had hardcoded `makePlxgRecordLegacy480` for every
full-canvas publish. 320×240 payload (115200 B, stride 320) + PLXG 624×480
stride 624 ⇒ guaranteed shear.

## Fix (path)
- `host/libmisterplex/plxg_record.hpp` — packers + `makePlxgRecordFromGeometry`
- `makeDdrPublishPlan` builds PLXG from `frame.geometry`+layout
  - product 624×480 → Legacy480 pillar body
  - all other tiers → capacity-selected identity PLXG
- Guard: `plxgRecordMatchesStorage` before accept
- Tests: `test_plxg_publish_geometry` 320/416/624/720/540/720p + NEG Legacy480≠320

## Evidence
```
./build/test_plxg_publish_geometry → true rc=0
PASS … PLXG_matches_payload NO_LEGACY480_SHEAR
test_frame_store_math / test_native_480p / test_geom_frame_cost / glass_loss → true rc=0
```
