# w-mem Option-C capacity fix — `a1fad081`

## Defect (parent-verified)
`ddr_frame_store` selected Option-C only if `coded_w >= 1280`. Product
source **960×540** → legacy 512 KiB bank → payload **777600 > 524288** overrun.

## Fix
Option-C iff I420 frame bytes > legacy bank stride (`0x80000` / `LEG_BANK_STRIDE_QWORDS`).
RTL: `(rt_y_bytes_qw + (rt_c_bytes_qw<<1)) > LEG_BANK_STRIDE_QWORDS`
Host: `ddrI420PayloadNeedsOptionCBank` / `ddrSelectBankMapForContent`

## Coded vs display (definitive)
| Role | Geometry | Bytes |
|------|----------|------:|
| Display / native_push / fabric content | **960×540** | **777600** |
| MB-coded (bitstream/DPB only) | **960×544** | **783360** |
| Bank canvas (Option-C PLXG) | **1280×720** | 1382400 |

Publish must stay **777600**, never 783360.

## Parent verify (no device)
```bash
cd /home/flynnsbit/Projects/MisterPlex-wt-mem
python3 tests/unit/test_rtl_invariants.py; echo "true rc=$?"
make /home/flynnsbit/Projects/MisterPlex-wt-mem/build/test_ddr_720p_abi
./build/test_ddr_720p_abi; echo "true rc=$?"
# expect: 960→OptionC, publish=777600, capacity tests green
```

## Quartus
**Release exclusive slot** — capacity predicate fixed; geometry freeze otherwise unchanged.
No Quartus from this lane.
