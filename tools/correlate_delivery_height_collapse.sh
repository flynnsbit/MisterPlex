#!/bin/sh
# Correlate measured_delivery height with collapse telemetry (busybox awk OK).
# Parent runs on device. Read-only.
#
# PRE_REGISTER:
#   short h in {350,352} → COLLAPSE; h==480 → HEALTHY
#   MISS if inverted
#
# Usage:
#   sh tools/correlate_delivery_height_collapse.sh /media/fat/misterplex_v2/misterplexd.log
#   sh tools/correlate_delivery_height_collapse.sh "$L"; echo "true rc=$?"
#
# rc: 0 scored/incomplete; 77 NO-DATA; 2 usage

set -eu

LOG=${1:-}
if [ -z "$LOG" ] || [ ! -f "$LOG" ]; then
  echo "usage: $0 /path/to/misterplexd.log" >&2
  exit 2
fi

echo "correlate_delivery_height_collapse path=$LOG"
echo "PRE_REGISTER predict_350_collapse=1 predict_480_healthy=1"
echo "NOTE measured_delivery=INPUT_banner; OUTPUT may be 624x480 after pad tag=caller_supplied_note"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

sed -n \
  -e 's/.*media: spawn single-process.*/S/p' \
  -e 's/.*session end .*/S/p' \
  -e 's/.*measured_delivery=\([0-9][0-9]*\)x\([0-9][0-9]*\).*/D \1 \2/p' \
  -e 's/.*delivered_geom=\([0-9][0-9]*\)x\([0-9][0-9]*\).*/D \1 \2/p' \
  -e 's/.*identity_skip=\([01]\).*/I \1/p' \
  -e 's/.*reason=\([a-z0-9_]*\).*/R \1/p' \
  -e 's/.*vfps=\([0-9.][0-9.]*\).*pfps=\([0-9.][0-9.]*\).*drops=\([0-9][0-9]*\).*av_drift_ms=\([+-]*[0-9.][0-9.]*\).*wall_s=\([0-9.][0-9.]*\).*/T \1 \2 \3 \4 \5/p' \
  "$LOG" >"$tmp" || true

if [ ! -s "$tmp" ]; then
  echo "RESULT=NO-DATA reason=no_sed_events"
  exit 77
fi

awk '
function flush(    climb, class, vf, pf, d0, d1, dr, wl) {
  if (sid < 1) return
  if (nt == 0 && dh == 0) return
  vf = (nt > 0) ? vfps[nt] : "NO-DATA"
  pf = (nt > 0) ? pfps[nt] : "NO-DATA"
  d0 = (nt > 0) ? drops[1] : "NO-DATA"
  d1 = (nt > 0) ? drops[nt] : "NO-DATA"
  dr = (nt > 0) ? drift[nt] : "NO-DATA"
  wl = (nt > 0) ? wall[nt] : "NO-DATA"
  climb = "NO-DATA"
  if (nt >= 2 && d0 == d0 + 0 && d1 == d1 + 0) {
    if (d1 > d0 + 20) climb = "CLIMBING"
    else if (d1 <= d0 + 5) climb = "FLAT"
    else climb = "MILD"
  }
  class = "AMBIGUOUS"
  if (dh + 0 == 0) class = "NO_DELIVERY_H"
  else if (vf == "NO-DATA") class = "NO_TELEMETRY"
  else if (dh + 0 == 480 && vf + 0 >= 22 && climb != "CLIMBING") class = "HEALTHY_480"
  else if (dh + 0 == 480 && vf + 0 < 18) class = "COLLAPSE_480"
  else if ((dh + 0 == 350 || dh + 0 == 352) && vf + 0 < 18) class = "COLLAPSE_SHORT"
  else if ((dh + 0 == 350 || dh + 0 == 352) && vf + 0 >= 22) class = "HEALTHY_SHORT"
  else if (vf + 0 < 18) class = "COLLAPSE_OTHER"
  else if (vf + 0 >= 22) class = "HEALTHY_OTHER"
  printf "session=%d delivery=%sx%s deliv_h=%s reason=%s identity_skip=%s tele_n=%d vfps_last=%s pfps_last=%s drops_first=%s drops_last=%s drops=%s drift_last=%s wall_last=%s class=%s tag=measured\n", \
    sid, dw, dh, dh, (reason == "" ? "NO-DATA" : reason), (idskip == "" ? "NO-DATA" : idskip), nt, vf, pf, d0, d1, climb, dr, wl, class
  if (class ~ /^COLLAPSE/) cc++
  if (class ~ /^HEALTHY/) ch++
  if (dh + 0 == 350) { n350++; if (class ~ /COLLAPSE/) n350c++; if (class ~ /HEALTHY/) n350h++ }
  if (dh + 0 == 352) { n352++; if (class ~ /COLLAPSE/) n352c++; if (class ~ /HEALTHY/) n352h++ }
  if (dh + 0 == 480) { n480++; if (class ~ /COLLAPSE/) n480c++; if (class ~ /HEALTHY/) n480h++ }
}
function reset() {
  flush()
  sid++
  dw = 0; dh = 0; reason = ""; idskip = ""; nt = 0
}
BEGIN {
  sid = 0; cc = 0; ch = 0
  n350 = n352 = n480 = 0
  n350c = n352c = n480c = 0
  n350h = n352h = n480h = 0
  reset()
}
$1 == "S" { reset(); next }
$1 == "D" { dw = $2; dh = $3; next }
$1 == "I" { idskip = $2; next }
$1 == "R" { reason = $2; next }
$1 == "T" {
  nt++
  vfps[nt] = $2
  pfps[nt] = $3
  drops[nt] = $4
  drift[nt] = $5
  wall[nt] = $6
  next
}
END {
  flush()
  print "=== tallies tag=measured ==="
  print "delivery_350_sessions=" n350 " collapse=" n350c " healthy=" n350h
  print "delivery_352_sessions=" n352 " collapse=" n352c " healthy=" n352h
  print "delivery_480_sessions=" n480 " collapse=" n480c " healthy=" n480h
  print "sessions_collapse_class=" cc " sessions_healthy_class=" ch
  if (n350 + n352 + n480 == 0) {
    print "RESULT=NO-DATA reason=no_delivery_height_with_sessions"
    exit 77
  }
  if (n350 + n352 > 0 && n480 > 0) {
    short_c = n350c + n352c
    short_n = n350 + n352
    if (short_c == short_n && n480c == 0 && n480h == n480 && short_n > 0) {
      print "RESULT=HIT_PRE_REG short_all_collapse_480_all_healthy"
      exit 0
    }
    if (short_c == 0 && n480c > 0) {
      print "RESULT=MISS_PRE_REG inverted"
      exit 0
    }
    print "RESULT=PARTIAL_OR_MIXED short_collapse=" short_c "/" short_n " collapse_480=" n480c "/" n480
    exit 0
  }
  print "RESULT=INCOMPLETE_SINGLE_CLASS"
  exit 0
}
' "$tmp"
exit $?
