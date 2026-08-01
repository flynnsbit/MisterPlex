#!/bin/sh
# VOID ENDPOINT — do not use (parent rchar blind-RED incident).
#
# Previously scored ffmpeg /proc/<pid>/io rchar B/s vs NOMINAL_BPS.
# On MiSTer, product ffmpeg HTTP input uses recv() → rchar stays ~0 while
# wchar advances hundreds of MB. Instrument emitted STALL_LT_0_4X 12/12 on a
# healthy cast. NOMINAL_BPS was also an ERROR-17 assumed constant.
#
# Rule: tools/instrument_blind_counter.py — flat primary + secondary work
# → NO-DATA rc=77, never defect.
# Replacement path (w-cpu-1): tools/pms_recvq_backlog_sample.sh when present.
echo "VOID_ENDPOINT tools/pms_arrival_rate_sample.sh"
echo "reason=rchar_blind_to_recv_on_this_kernel"
echo "reason2=NOMINAL_BPS_was_ERROR_17_assumed_constant"
echo "use=tools/instrument_blind_counter.py"
echo "RESULT=NO-DATA"
echo "true rc=77"
exit 77
