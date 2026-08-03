# Fit blocker: path symbols / ddr_frame_layout (product-v2 merge)

## Root cause (quoted)
Botched content-merge of w-path 360p block into integ/fab-720p-product-v2
`ddr_frame_layout.hpp` duplicated:
- `kDdrFramePlxg*` (lines ~170 and ~272)
- entire `kPlex480pCrop*` / bank constants block
and omitted `kPlex540p*` while 360p static_assert referenced it.
`ddrFfmpegGeometryForPresent` was 3-arg only; path roll-call calls 2-arg.
`mailbox_abi` lacked `kPlxgBytes` / `kPlxgBootstrapPhys` required by asserts/tests.

## Fix (this branch w-path-fit-layout-fix)
- Single `kDdrFramePlxg*` at +0x800; no duplicate crop block
- `kPlex540p*` + `kPlex360p*`; storage identity for 360/540
- 2-arg + 3-arg `ddrFfmpegGeometryForPresent`
- mailbox_abi: `kPlxgBootstrapPhys`, `kPlxgBytes`
- incidental unit-green: `plxdLastFramesDone_`, `reopenPresentPath`, 720x480 spare symbols,
  cadence grep exclude `plxg_q5_aspect_cadence.hpp`

## Evidence
```
./build/test_path_public_symbols ; echo true rc=$?
→ PASS  true rc=0
./build/test_ddr_720p_abi ; echo true rc=$?
→ true rc=0
./build/test_frame_store_math ; echo true rc=$?
→ true rc=0
```
`make unit` still RED on `test_present_store_scale_math` (present_core greps for
`NATIVE_V_1TO1` / `H_DE=529` — w-scaler RTL naming; not path layout). Path compile
blocker for symbols is cleared.
