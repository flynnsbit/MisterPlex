#!/usr/bin/env python3
"""Device-side DDR frame-store readback (runs ON the MiSTer, needs /dev/mem).

read(2) on /dev/mem returns EFAULT on this kernel, so the dump must go through
mmap. Emits gzip+base64 on stdout so it survives an ssh pipe unmangled.

Usage (from the host):
    ssh root@MISTER 'python3 - --bank 0 <layout args>' < scripts/ddr_frame_dump_device.py

The layout arguments are mandatory and carry no defaults. This script runs on
the MiSTer over a bare stdin pipe, so it cannot import the repo's layout
helpers; instead the caller derives every address from the single source of
truth (host/libmisterplex/ddr_frame_layout.hpp, via scripts/ddr_layout_consts.py)
and passes them in. Hardcoding them here would fork the layout contract and is
rejected by the runtime DDR layout literal sweep in test_rtl_invariants.py.

Output format (stdout, line oriented):
    DOORBELL lo=0x... hi=0x...
    PLXD lo=0x... hi=0x...
    PLXF lo=0x... hi=0x...
    BANK <n> base=0x... len=<bytes>
    DATA <base64 of gzip of the raw bank bytes>
Anything else goes to stderr. Exit 0 on success, 1 on failure, 77 on skip.
"""

import argparse
import base64
import gzip
import mmap
import os
import sys
import time

def auto_int(text):
    return int(text, 0)


def rd32(buf, off):
    return int.from_bytes(buf[off:off + 4], "little")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bank", type=int, default=0, choices=(0, 1))
    ap.add_argument("--ddr-base", type=auto_int, required=True)
    ap.add_argument("--bank-stride", type=auto_int, required=True)
    ap.add_argument("--frame-bytes", type=auto_int, required=True)
    ap.add_argument("--doorbell-phys", type=auto_int, required=True)
    ap.add_argument("--plxd-phys", type=auto_int, required=True)
    ap.add_argument("--plxf-phys", type=auto_int, required=True)
    ap.add_argument("--len", type=auto_int, default=None)
    ap.add_argument("--no-data", action="store_true")
    ap.add_argument("--watch", type=int, default=0,
                    help="sample the mailboxes N times instead of dumping a bank")
    ap.add_argument("--interval", type=float, default=1.0)
    args = ap.parse_args()

    DDR_BASE = args.ddr_base
    BANK_STRIDE = args.bank_stride
    FRAME_BYTES = args.frame_bytes
    DOORBELL_PHYS = args.doorbell_phys
    PLXD_PHYS = args.plxd_phys
    PLXF_PHYS = args.plxf_phys
    MAP_BYTES = BANK_STRIDE * 2
    if args.len is None:
        args.len = FRAME_BYTES

    if not os.path.exists("/dev/mem"):
        print("SKIP no /dev/mem", file=sys.stderr)
        return 77
    try:
        fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
    except OSError as e:
        print("SKIP cannot open /dev/mem: %s" % e, file=sys.stderr)
        return 77

    try:
        mm = mmap.mmap(fd, MAP_BYTES, flags=mmap.MAP_SHARED,
                       prot=mmap.PROT_READ, offset=DDR_BASE)
    except OSError as e:
        print("FAIL mmap /dev/mem @0x%08x: %s" % (DDR_BASE, e), file=sys.stderr)
        os.close(fd)
        return 1

    try:
        db = DOORBELL_PHYS - DDR_BASE
        if args.watch:
            # PLXF hi = [31:16] underrun_count, [15:8] debug_state, [7:0] seq.
            # underrun_count saturates at 0xFFFF and only clears on core reset,
            # so a rate is only meaningful on a freshly reset core.
            for i in range(args.watch):
                fo = PLXF_PHYS - DDR_BASE
                po = PLXD_PHYS - DDR_BASE
                fhi = rd32(mm, fo + 4)
                phi = rd32(mm, po + 4)
                dhi = rd32(mm, db + 4)
                print("t=%d PLXF_hi=0x%08X underrun=%d debug=0x%02X seq=%d "
                      "PLXD_hi=0x%08X frames_done=%d free_mask=%d disp=%d swap=%d "
                      "DOORBELL_hi=0x%08X db_bank=%d db_seq=%d"
                      % (i, fhi, (fhi >> 16) & 0xFFFF, (fhi >> 8) & 0xFF, fhi & 0xFF,
                         phi, (phi >> 16) & 0xFFFF, phi & 0x3, (phi >> 2) & 1,
                         (phi >> 3) & 1, dhi, (dhi >> 31) & 1, dhi & 0x1FFFFFFF))
                sys.stdout.flush()
                if i + 1 < args.watch:
                    time.sleep(args.interval)
            return 0
        print("DOORBELL lo=0x%08X hi=0x%08X" % (rd32(mm, db), rd32(mm, db + 4)))
        for name, phys in (("PLXD", PLXD_PHYS), ("PLXF", PLXF_PHYS)):
            off = phys - DDR_BASE
            if 0 <= off + 8 <= MAP_BYTES:
                print("%s lo=0x%08X hi=0x%08X" % (name, rd32(mm, off), rd32(mm, off + 4)))
        base = args.bank * BANK_STRIDE
        n = min(args.len, MAP_BYTES - base)
        print("BANK %d base=0x%08X len=%d" % (args.bank, DDR_BASE + base, n))
        if not args.no_data:
            raw = mm[base:base + n]
            print("DATA " + base64.b64encode(gzip.compress(raw, 6)).decode("ascii"))
    finally:
        mm.close()
        os.close(fd)
    return 0


if __name__ == "__main__":
    sys.exit(main())
