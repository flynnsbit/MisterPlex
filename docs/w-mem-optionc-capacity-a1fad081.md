# w-mem Option-C + storage/canvas split (rd-duck STOP fixes)

## rd-duck blockers addressed
1. **Usable capacity** = `bank_stride - 0x1000` (doorbell page), not full stride.
   Legacy usable **520192**; edge 720×482=520560 → Option-C (was wrongly legacy).
2. **ARM path 777600** (display). 544/783360 = bitstream/DPB only.
3. **Storage ≠ canvas**: PLXG geometry = **960×540** storage; DE canvas = 1280×720;
   `ddrFrameGeometryForFpgaPresent` stays **624** product (FFmpeg path).

## Predicate
RTL: `(rt_y_bytes_qw + 2*rt_c_bytes_qw) > LEG_BANK_USABLE_QWORDS`
Host: `frameBytes > kPlex480pYuv420pBankUsableBytes` (520192)

## Parent verify
```bash
cd /home/flynnsbit/Projects/MisterPlex-wt-mem
python3 tests/unit/test_rtl_invariants.py; echo "true rc=$?"
./build/test_ddr_720p_abi; echo "true rc=$?"
# expect: usable edge 520560→OptionC; PLXG geom 960x540; FpgaPresent 624
```

No Quartus from this lane.
