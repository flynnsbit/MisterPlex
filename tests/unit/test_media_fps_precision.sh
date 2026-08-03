#!/usr/bin/env bash
# DEFECT 1 gate: media telemetry must not truncate vfps/pfps with substr(0,4).
# Parent: 8629/360→23.9694 and 8608/360→23.9111 both printed "23.9" — ±36 frames
# of ambiguity over 360 s. Exact counters (frames=/presents=/wall_ms=) are SoT.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MP="$ROOT/arm/misterplexd/media_player.cpp"
FAIL=0

[ -f "$MP" ] || { echo "FAIL missing $MP"; exit 2; }

# Forbidden: any to_string(...fps...).substr(0, N) truncator (parent ed1fc22f:3536 class).
if grep -nE 'to_string\([^)]*[fp]fps[^)]*\)\.substr\(0,\s*[0-9]+\)' "$MP" >/dev/null; then
  echo "FAIL forbidden truncating substr on *fps* rates:"
  grep -nE 'to_string\([^)]*[fp]fps[^)]*\)\.substr\(0,\s*[0-9]+\)' "$MP" || true
  FAIL=$((FAIL + 1))
fi
# Also forbid the exact historical needles on the media rate locals.
if grep -nE 'to_string\((vfps|pfps)\)\.substr\(' "$MP" >/dev/null; then
  echo "FAIL forbidden to_string(vfps|pfps).substr:"
  grep -nE 'to_string\((vfps|pfps)\)\.substr\(' "$MP" || true
  FAIL=$((FAIL + 1))
fi
# Exactly one vfps= emission site, and it must use fmtFpsRate (not bare to_string).
vfps_sites=$(grep -cE '" vfps="' "$MP" || true)
[ "$vfps_sites" -eq 1 ] || { echo "FAIL expected 1 vfps= site, got $vfps_sites"; FAIL=$((FAIL + 1)); }
grep -nE '" vfps="' "$MP" | grep -q 'fmtFpsRate' || {
  echo "FAIL vfps= site does not use fmtFpsRate"
  grep -nE '" vfps="' "$MP" || true
  FAIL=$((FAIL + 1))
}

# Required: fmtFpsRate / %.4f path
grep -q 'fmtFpsRate' "$MP" || { echo "FAIL missing fmtFpsRate helper"; FAIL=$((FAIL + 1)); }
grep -q '%.4f' "$MP" || { echo "FAIL missing %.4f format"; FAIL=$((FAIL + 1)); }
grep -q 'wall_ms=' "$MP" || { echo "FAIL missing wall_ms= exact counter on media line"; FAIL=$((FAIL + 1)); }

# Numeric proof: %.4f distinguishes the two rates parent measured as identical "23.9"
a=$(printf '%.4f' 23.9694)
b=$(printf '%.4f' 23.9111)
echo "fmt_a=$a fmt_b=$b"
[ "$a" = "23.9694" ] || { echo "FAIL printf a"; FAIL=$((FAIL + 1)); }
[ "$b" = "23.9111" ] || { echo "FAIL printf b"; FAIL=$((FAIL + 1)); }
[ "$a" != "$b" ] || { echo "FAIL a==b after format"; FAIL=$((FAIL + 1)); }

# Old substr(0,4) on typical to_string would collapse both to 23.9
# (documentation of the defect — not a runtime of to_string)
old_a=$(printf '%s' "23.969400" | cut -c1-4)
old_b=$(printf '%s' "23.911100" | cut -c1-4)
echo "old_substr_a=$old_a old_substr_b=$old_b"
[ "$old_a" = "$old_b" ] || { echo "FAIL expected old trunc collision"; FAIL=$((FAIL + 1)); }

# Single-frame resolution over 360 s: 1/360 ≈ 0.002778 fps < 0.0001 of %.4f step? 
# %.4f step is 0.0001 fps → 0.036 frames/360s — resolves multi-frame; integer
# frames= is still required for exact single-frame claims.
echo "note: use frames=/presents=/wall_ms= for exact soak math; vfps is derived display"

if [ "$FAIL" -ne 0 ]; then
  echo "test_media_fps_precision: FAIL count=$FAIL"
  exit 1
fi
echo "test_media_fps_precision: OK"
exit 0
