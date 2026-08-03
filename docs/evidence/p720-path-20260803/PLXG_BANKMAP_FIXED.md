# Fixed LEG/Option-C bank map on generic-native publish (rd-duck amplifier)

## Defect
`makeDdrFrameLayout(320×240)` sets `bank_stride=alignUp(115200)=0x40000` and
`doorbell=0x3007F000`. RTL capacity selector only has:
- LEG: stride `0x80000`, doorbell `0x300FF000`, base `0x30000000`
- Option-C: stride `0x180000`, doorbell `0x3047F000`, base `0x30180000`

Even with correct PLXG content dims, publish kicked the wrong physical map.

## Fix
- `ddrSelectBankMapForPayloadBytes` / `ddrPinLayoutToBankMap`
- `makeDdrPublishPlan` always pins LEG or Option-C after content layout
- Refuse `ddrLayoutBankMapIsGeometryDerived`
- Content `line_bytes`/`frame_bytes` stay source-native; bank window is fixed

## Evidence
```
test_plxg_publish_geometry → true rc=0  (320 LEG 0x80000/0x300FF000; NEG raw 0x40000)
test_native_480p_ddr_publish → true rc=0
test_frame_store_math → true rc=0
```
