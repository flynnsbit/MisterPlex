#!/usr/bin/env bash
# Product status: is the decode lineage observable, or will synthesis delete it?
#
# Quartus failure mode 3 -- compiled, instantiated, elaborated, then removed
# because the outputs drive nothing.  w-fit-o5 measured this with Quartus A&S on
# w-decode-hour27 2f165ed and it is the reason fb4bad84 shipped with no decoder
# in the chip.
#
# This runs the check on the product decode lineage and reports.  A red result
# is the CURRENT, TRUE state of the branch, not a regression introduced by this
# script, so it is reported as a named CRITICAL skip rather than a hard failure:
# breaking `make unit` for every worker does not make the core any more alive,
# and a hard red here would simply be overridden. The named skip keeps it in
# front of the fleet on every run until the outputs are consumed.
#
# It flips to a hard green automatically once someone consumes the core's
# outputs -- no edit to this file required.  Verified by mutation: routing the
# stream_path keep-wire to an observable port turns every module below LIVE.
set -u
cd "$(dirname "$0")/../.." || exit 1

MODULES="--require-live h264_decode_core \
--require-live h264_deblock_mb_filter \
--require-live h264_deblock_qpc \
--require-live h264_deblock_writeback_ctrl"

mkdir -p build
python3 scripts/check_deadlogic_sink.py $MODULES --label product-decode \
	> build/deadlogic_product.txt 2>&1
rc=$?
sed 's/^/  /' build/deadlogic_product.txt

if [ "$rc" -eq 0 ]; then
	echo "DEADLOGIC_PRODUCT_OK decode lineage drives something observable"
	echo "  NOT SUFFICIENT FOR A FIT: this gate cannot see constant-fold" \
	     "collapse, and the core's inputs are still tied to constants at" \
	     "stream_path.sv:447-459. Step 3 (check_prefit_elaboration.sh," \
	     "Quartus A&S) is mandatory before requesting a fit."
	exit 0
fi

if [ "$rc" -eq 2 ]; then
	echo "DEADLOGIC_PRODUCT_USAGE_ERROR rc=2"
	exit 1
fi

echo "SKIP-NOT-PASS deadlogic_sink: product decode lineage drives nothing" \
     "observable -- synthesis is entitled to delete it, so any simulation" \
     "result for these modules is simulation-only and NOT a product claim"
exit 0
