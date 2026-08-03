#!/usr/bin/env bash
# H_TOTAL=1182 sanity across DE widths (parent: do not assume one HT suits 3× DE span).
# clk_sys = 20e6. Line rate f_h = clk/H_TOTAL. Active duty = H_DE/H_TOTAL.
set -euo pipefail
CLK=20000000
HT=1182
VT30=564
VT24=705

echo "H_TOTAL=$HT clk=$CLK"
echo "f_h_Hz=$(awk -v c=$CLK -v h=$HT 'BEGIN{printf "%.6f", c/h}')  (independent of H_DE)"
echo "f_v30_Hz=$(awk -v c=$CLK -v h=$HT -v v=$VT30 'BEGIN{printf "%.6f", c/(h*v)}')"
echo "f_v24_Hz=$(awk -v c=$CLK -v h=$HT -v v=$VT24 'BEGIN{printf "%.6f", c/(h*v)}')"

ok=1
while read -r name de; do
  blank=$((HT - de))
  duty=$(awk -v d=$de -v h=$HT 'BEGIN{printf "%.4f", d/h}')
  fh=$(awk -v c=$CLK -v h=$HT 'BEGIN{printf "%.3f", c/h}')
  # ascal-ish comfort: blanking >= 64 and duty <= 0.95; f_h in 10–100 kHz class for SD/ED
  echo "GEOM $name H_DE=$de H_BLANK=$blank duty=$duty f_h_kHz=$(awk -v f=$fh 'BEGIN{printf "%.4f", f/1000}')"
  if [[ $blank -lt 64 ]]; then echo "FAIL $name blank $blank < 64"; ok=0; fi
  awk -v d="$duty" 'BEGIN{exit !(d<=0.95)}' || { echo "FAIL $name duty $duty"; ok=0; }
  awk -v f="$fh" 'BEGIN{exit !(f>=10000 && f<=100000)}' || { echo "FAIL $name f_h $fh out of 10k-100k"; ok=0; }
done <<'EOF'
320x240 320
416x234 416
624x480 624
640x360 640
960x540 960
EOF

# Compare alternate HT = H_DE+222 (same blank as 960 class) — f_h would *rise* for small DE
echo "ALT_NOTE: if H_TOTAL tracked H_DE+222, f_h would be:"
while read -r name de; do
  ht=$((de + 222))
  awk -v c=$CLK -v h=$ht -v n="$name" 'BEGIN{printf "  %s HT=%d f_h_kHz=%.4f\n", n, h, c/h/1000}'
done <<'EOF'
320x240 320
624x480 624
960x540 960
EOF
echo "VERDICT: fixed HT=1182 keeps f_h constant (~16.92 kHz) and f_v locked to 30.0008/24.0007;"
echo "  small DE only increases blanking (ascal-friendly). Tracking HT to H_DE would raise line rate 3× from 960→320."

if [[ "$ok" -ne 1 ]]; then
  echo "FAIL test_beam_htotal_line_rate"
  exit 1
fi
echo "PASS test_beam_htotal_line_rate true rc=0"
exit 0
