# w-mem Option-C capacity fix — `a1fad081` (+ SPS `0a82f89c`)

## Defect (parent-verified)
`ddr_frame_store` selected Option-C only if `coded_w >= 1280`. Product
source **960×540** → legacy 512 KiB bank → payload **777600 > 524288** overrun.

## Fix (LANDED — tip `0a82f89c`, capacity `a1fad081`)
Option-C iff I420 frame bytes > legacy bank stride (`0x80000` / `LEG_BANK_STRIDE_QWORDS`).
RTL: `(rt_y_bytes_qw + (rt_c_bytes_qw<<1)) > LEG_BANK_STRIDE_QWORDS`
Host: `ddrI420PayloadNeedsOptionCBank` / `ddrSelectBankMapForContent`
**No `rt_cw_cl >= 11'd1280` remains** (only a comment banning it).

## Coded vs display (parent SPS SETTLED 2026-08-03)
SPS: mbs_w=59 → 960; map_h=33 → **544**; crop_bottom=2 → display **540**.
| Role | Geometry | Bytes |
|------|----------|------:|
| Display / native_push / fabric content | **960×540** | **777600** |
| MB-coded (bitstream ring / fabric DPB) | **960×544** | **783360** |
| Bank canvas (Option-C PLXG) | **1280×720** | 1382400 |

Publish must stay **777600**. Ring ABI constants: `kProduct960x540Sps*` in
`ddr_bitstream_ring.hpp` (`0a82f89c`).

## Parent verify (no device)
```bash
cd /home/flynnsbit/Projects/MisterPlex-wt-mem
git log -3 --oneline   # expect 0a82f89c / 78c8c1b6 / a1fad081
rg -n "rt_cw_cl\s*>=\s*11'd1280" fpga/Plex_MiSTer/rtl/ddr_frame_store.sv || echo GONE
python3 tests/unit/test_rtl_invariants.py; echo "true rc=$?"
make /home/flynnsbit/Projects/MisterPlex-wt-mem/build/test_ddr_720p_abi \
     /home/flynnsbit/Projects/MisterPlex-wt-mem/build/test_bitstream_ring_abi
./build/test_ddr_720p_abi; echo "true rc=$?"
./build/test_bitstream_ring_abi; echo "true rc=$?"
# expect: 960→OptionC, publish=777600, SPS coded=544 display=540
```

## Quartus
**Release exclusive slot** — capacity predicate fixed; geometry freeze otherwise unchanged.
No Quartus from this lane. rd-duck review welcome on `a1fad081`.
