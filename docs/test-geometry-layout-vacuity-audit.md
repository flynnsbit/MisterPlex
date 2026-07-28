# Geometry/layout vacuity audit (W-GATE)

Base/tip audited: `c92cc39206ce1e7867d8d9e72e5c41203f2f532b`.

Pre-registration, before mutation runs: planned probes `12`, predicted
`sound=8, vacuous=3, over-tight=1`. Actual before fixes:
`sound=8, vacuous=4, over-tight=0`. The missed vacuity was the fixed 480p
YUV bank-stride constant: the derivation test proved the layout math but did not
prove the named constant used by acceptance logic matched that derivation.

Boundary: this audit treats two address families separately. DDR frame banks and
`doorbell_phys = physBase + bank_stride*2 - 0x1000` are geometry-derived. The
PLXS/PLXF/PLXD mailbox control page at `0x3007F100/0x3007F118/0x3007F128` is a
fixed ABI page and must not be moved when frame geometry moves.

## Findings fixed

| Probe | Property claimed | Mutation | Evidence | Verdict |
| --- | --- | --- | --- | --- |
| OSD 480p label | The OSD content-resolution label names coded geometry, not presented scanout. | Pre-fix: `kPlex480pCodedWidth 624->608`. | `build_rc=0 osd_rc=0`; `test_osd_menu: OK`. The label stayed hardcoded `624x480`, so the test was self-consistent with stale text. | Vacuous before `eb5db4f`; sound after deriving the label. |
| PMS 480p profile | The PMS universal profile resolution follows coded geometry. | Pre-fix: `kPlex480pCodedWidth 624->608`. | `build_rc=0 resolve_rc=0`; `test_resolve: OK`. The profile table and test both still said `624x480`. | Vacuous before `eb5db4f`; sound after deriving the profile string. |
| PMS bitrate floor | The weak-ladder minimum bitrate is selected from coded geometry, not a literal `640`. | Change `minBitrate` to the 240p floor. | `rc=1`; `FAIL ... test_resolve.cpp:131: !validateWeakLadder(bad480)`; `FAIL ...:135: !validateWeakLadder(bad480)`. | Sound after `eb5db4f`. |
| Named YUV bank stride | `kPlex480pYuv420pBankStride` equals the derived aligned frame size. | Pre-fix: `0x80000->0x40000`. | `build_rc=0 run_rc=0`; `test_frame_store_math: OK`. | Vacuous before `eb5db4f`; sound after adding the constant/layout equality check. |
| Named YUV doorbell | `kPlex480pYuv420pDoorbellPhys` equals the derived final page. | Change `0x300FF000->0x3007F000`. | `rc=1`; `FAIL ... test_frame_store_math.cpp:281 yuv480.doorbell_phys == misterplex::kPlex480pYuv420pDoorbellPhys`. | Sound after `eb5db4f`. |

## Post-fix mutation table

| Probe | Mutation | Quoted result | Verdict |
| --- | --- | --- | --- |
| Label helper conflates presented and coded width | Force `plex480pCodedResolutionLabel()` to `640x480`. | `test_osd_menu rc=1`; `FAIL ... test_osd_menu.cpp:64: std::string(plex480pCodedResolutionLabel()) == expected480`; `test_resolve rc=1`; `FAIL ... test_resolve.cpp:71: w480.videoResolution == expected480`. | Sound. |
| Profile table hardcodes presented width | Replace the 480p profile resolution with `640x480`. | `rc=1`; `FAIL ... test_resolve.cpp:71: w480.videoResolution == expected480`; `test_resolve: 6 failures`. | Sound. |
| Layout bank-stride derivation | Add one alignment quantum to `out.bank_stride`. | `rc=1`; `FAIL ... test_frame_store_math.cpp:51 l.bank_stride == derivedStride`; `FAIL ...:54 l.doorbell_phys == derivedDoorbell`; `test_frame_store_math: 11 fails`. | Sound. |
| Layout doorbell derivation | Use one bank instead of two in `doorbell_phys`. | `rc=1`; `FAIL ... test_frame_store_math.cpp:53 l.phys_base + l.bank_stride + l.frame_bytes <= l.doorbell_phys`; `test_frame_store_math: 13 fails`. | Sound. |
| RGB565 fixed constants | Change `kPlex480pRgb565BankStride` to `0x80000`. | `rc=1`; `FAIL ... test_frame_store_math.cpp:286 kPlex480pRgb565BankStride == alignUpU32(...)`; `FAIL ...:289 kPlex480pRgb565DoorbellPhys == ...`. | Sound. |
| Coded-width constant alone | Change `kPlex480pCodedWidth 624->608`. | `test_osd_menu rc=0`; `test_resolve rc=0`; `test_frame_store_math rc=1` with `FAIL ... p480.coded_width == 624` and layout validity failures. | Sound split: consumers derive; layout proof demands a coordinated geometry update. |
| Fixed mailbox page PLXS/PLXF/PLXD | Move each to the geometry doorbell page family (`0x300FF1xx`). | PLXS: `FAIL ... test_input_mailbox.cpp:95: kDdrStatusMailboxPhys == 0x3007F100u`; PLXF: `FAIL ...:101`; PLXD: `FAIL ...:103`. | Sound; mailbox control page is fixed ABI, not geometry-derived. |
