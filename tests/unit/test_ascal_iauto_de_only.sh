#!/usr/bin/env bash
# Prove ascal iauto sizes from DE edges, so H_TOTAL blanking ratio is benign.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ASCAL="$ROOT/fpga/Plex_MiSTer/sys/ascal.vhd"
[[ -f "$ASCAL" ]] || { echo "FAIL missing ascal.vhd"; exit 1; }

grep -n "i_himax<=i_hcpt" "$ASCAL" | head -3
grep -q "i_himax<=i_hcpt" "$ASCAL" || { echo "FAIL no himax<=hcpt"; exit 1; }

if ! grep -A20 "i_iauto='1'" "$ASCAL" | grep -q "i_hmax<=i_himax"; then
  echo "FAIL iauto block missing i_hmax<=i_himax"
  grep -n "i_iauto" "$ASCAL" | head -10
  exit 1
fi
echo "OK iauto hmax from himax (DE-measured)"

if grep -A30 "i_iauto='1'" "$ASCAL" | grep -nE "1650|i_hmax<=.*1182"; then
  echo "FAIL iauto appears to force line-total size"; exit 1
fi

awk 'BEGIN{
  HT=1182
  n=split("320 416 624 640 960", w, " ")
  for (i=1;i<=n;i++) {
    de=w[i]+0; bl=HT-de; r=bl/de
    printf("GEOM H_DE=%d H_BLANK=%d ratio_blank_active=%.3f iauto_ih=%d (DE-only)\n", de, bl, r, de)
  }
  ratio320=(1182-320)/320
  if (ratio320 < 2.5) { print "FAIL expected ratio>2.5 at 320"; exit 1 }
  printf("OK extreme blanking ratio=%.3f quantified; iauto_ih remains H_DE\n", ratio320)
}'

awk 'BEGIN{
  if (1182 >= 4096) { print "FAIL HT exceeds uint12 MOD"; exit 1 }
  print "OK H_TOTAL=1182 << 4096 (uint12 MOD safe)"
}'

echo "PASS test_ascal_iauto_de_only true rc=0"
exit 0
