#!/bin/sh
# =============================================================================
# VOID ENDPOINT — do not use. Parent RESULT_pms_supply_not_the_limiter.md
#
# This script previously scored ffmpeg /proc/<pid>/io **rchar** B/s vs NOMINAL_BPS.
# On the MiSTer kernel, product ffmpeg HTTP input uses recv(), which does NOT
# increment rchar (measured: rchar=1037, syscr=5, wchar≈414MB during healthy
# 480p play). The instrument returned STALL_LT_0_4X on 12/12 live windows —
# a blind RED defect verdict. NOMINAL_BPS was also an assumed constant (ERROR 17).
#
# Replacement: tools/pms_recvq_backlog_sample.sh
#   - scores ss Recv-Q backlog (pid= AND fd=), no assumed nominal
#   - mandatory daemon wall_s liveness gate
#   - NO-DATA (rc=77) never defect-from-blind-counter
# =============================================================================
echo "VOID_ENDPOINT tools/pms_arrival_rate_sample.sh"
echo "reason=rchar_blind_to_recv_on_this_kernel measured_syscr=5 measured_rchar_stale"
echo "reason2=NOMINAL_BPS_was_ERROR_17_assumed_constant"
echo "use=tools/pms_recvq_backlog_sample.sh"
echo "RESULT=NO-DATA"
echo "true rc=77"
exit 77
