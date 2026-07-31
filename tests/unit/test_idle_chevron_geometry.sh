#!/usr/bin/env bash
# Translation-invariant chevron ID: screensaver bounce must not false-RED.
# Parent 2026-07-31: centroid cy bound rejected 5/25 healthy frames.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VIS="$ROOT/scripts/pair_visual_gate.sh"
FIX="$ROOT/tests/fixtures/promote"
pass=0; fail=0
ok(){ echo "OK $*"; pass=$((pass+1)); }
bad(){ echo "FAIL $*"; fail=$((fail+1)); }

run() {
  local label="$1" png="$2" want="$3"
  set +e
  out=$(PAIR_VISUAL_NO_RECAPTURE=1 PAIR_IDLE_PNG="$png" "$VIS" idle 2>&1)
  rc=$?
  set -e
  echo "  [$label] true rc=$rc"
  if [ "$rc" -eq "$want" ]; then ok "$label-rc$want"; else bad "$label want $want got $rc"; echo "$out" | tail -8; fi
  # Centroid must NEVER be a fail class
  if echo "$out" | grep -q 'orange_centroid_out_of_range'; then
    bad "$label-centroid-class-forbidden"
  else
    ok "$label-no-centroid-class"
  fi
  printf '%s\n' "$out" | sed -n '1,20p' | sed "s/^/  [$label] /"
}

echo "=== edge cy>0.80 healthy frames must PASS (were false RED) ==="
for f in s_037.png s_041.png s_026.png; do
  p="$FIX/screensaver_traverse/$f"
  [ -f "$p" ] || { bad "missing $p"; continue; }
  run "$f" "$p" 0
  # must print structure metrics
  out=$(PAIR_VISUAL_NO_RECAPTURE=1 PAIR_IDLE_PNG="$p" "$VIS" idle 2>&1 || true)
  echo "$out" | grep -q 'orange_dominance=' && ok "$f-dominance-metric" || bad "$f-dominance-metric"
  echo "$out" | grep -q 'orange_fill=' && ok "$f-fill-metric" || bad "$f-fill-metric"
done

echo "=== STOPPED overlay over chevron deliberately ACCEPT ==="
run "overlay-s023" "$FIX/screensaver_traverse/s_023.png" 0

echo "=== MENU / magenta / green still RED ==="
run "menu" "$FIX/mister_menu_postboot.png" 8
run "magenta" "$FIX/solid_magenta.png" 8
run "green" "$FIX/solid_green.png" 8
run "chevron-static" "$FIX/plex_idle_chevron.png" 0

# Optional full stopcap if present (parent host path)
if [ -d /tmp/stopcap ]; then
  echo "=== full stopcap s_026..s_050 expect 25/25 ==="
  n=0; badn=0
  for i in $(seq 26 50); do
    p=$(printf '/tmp/stopcap/s_%03d.png' "$i")
    [ -f "$p" ] || continue
    set +e
    PAIR_VISUAL_NO_RECAPTURE=1 PAIR_IDLE_PNG="$p" "$VIS" idle >/dev/null 2>&1
    rc=$?
    set -e
    n=$((n+1))
    [ "$rc" -eq 0 ] || badn=$((badn+1))
  done
  echo "  stopcap_checked=$n fail=$badn"
  [ "$n" -ge 25 ] && [ "$badn" -eq 0 ] && ok "stopcap-25-of-25" || bad "stopcap n=$n bad=$badn"
fi

echo "=== summary pass=$pass fail=$fail ==="
if [ "$fail" -ne 0 ]; then echo "true rc=1"; exit 1; fi
echo "true rc=0"
exit 0
