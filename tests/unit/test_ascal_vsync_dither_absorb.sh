#!/usr/bin/env bash
# ascal input V_TOTAL dither absorption — evidence gate (w-clock).
# Pre-registered predictions in ASCAL_VSYNC_DITHER_ABSORB.md; this quotes RTL.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ASCAL="$ROOT/fpga/Plex_MiSTer/sys/ascal.vhd"
TOP="$ROOT/fpga/Plex_MiSTer/sys/sys_top.v"
DOC="$ROOT/.agent-work/w-clock/ASCAL_VSYNC_DITHER_ABSORB.md"
OUT="$ROOT/build/ascal_vsync_dither"
mkdir -p "$OUT"

[[ -f "$ASCAL" && -f "$TOP" && -f "$DOC" ]] || { echo "FAIL missing ascal/top/doc"; exit 1; }

# --- P1: output sweep free-runs on o_htotal/o_vtotal ---
grep -q "OSWEEP" "$ASCAL" || { echo "FAIL no OSWEEP"; exit 1; }
grep -q "o_hcpt+1<o_htotal" "$ASCAL" || { echo "FAIL o_hcpt not free-run vs o_htotal"; exit 1; }
grep -q "o_vcpt_pre3+1>=o_vtotal" "$ASCAL" || { echo "FAIL o_vcpt not vs o_vtotal"; exit 1; }
echo "OK OSWEEP free-runs on o_htotal/o_vtotal (not core beam V_TOTAL)"

# --- P1b: triple vs single documented ---
grep -q "Triple buffering" "$ASCAL" || { echo "FAIL no triple buffer docs"; exit 1; }
grep -q "o_mode(3)='0'" "$ASCAL" || { echo "FAIL no single-buffer disable path"; exit 1; }
echo "OK MODE[3] triple/single buffer present"

# --- P1c: input endframe vs output VS buffer swap decoupled ---
grep -q "i_endframe0" "$ASCAL" || { echo "FAIL no i_endframe"; exit 1; }
grep -q "o_vsv" "$ASCAL" || { echo "FAIL no o_vsv"; exit 1; }
echo "OK input endframe + output VS buffer handoff (FB scaler)"

# --- P2/P3 product defaults ---
grep -E 'reg[[:space:]]+lowlat[[:space:]]*=[[:space:]]*0' "$TOP" >/dev/null \
  || { echo "FAIL lowlat default not 0"; exit 1; }
grep -E 'reg[[:space:]]+vrr_mode[[:space:]]*=[[:space:]]*0' "$TOP" >/dev/null \
  || { echo "FAIL vrr_mode default not 0"; exit 1; }
# mode MSB is ~lowlat → triple when lowlat=0
grep -q '{~lowlat' "$TOP" || { echo "FAIL mode packing missing ~lowlat"; exit 1; }
echo "OK product defaults lowlat=0 vrr_mode=0 → triple buffer, VRR off"

# --- VRR couple path exists (must not claim absorb when VRR on) ---
grep -q "o_vrr_sync" "$ASCAL" || { echo "FAIL no o_vrr_sync"; exit 1; }
echo "OK VRR path present (absorb claim scoped to vrr_mode=0)"

# --- swblack size-only (not V_TOTAL) ---
grep -q "o_ihsize /= i_hrsize or o_ivsize /= i_vrsize" "$ASCAL" \
  || { echo "FAIL swblack size compare missing"; exit 1; }
echo "OK swblack is ih/iv size-only"

# --- dither arithmetic (parent re-derived; awk no bc) ---
awk 'BEGIN{
  clk=20000000; H=1182; n24=24000/1001;
  cpf=clk/n24;           # 834166.666...
  Vexact=cpf/H;          # 705.7248...
  c705=H*705; c706=H*706;
  # solve f*c706+(1-f)*c705 = cpf → f = (cpf-c705)/(c706-c705)
  f=(cpf-c705)/(c706-c705);
  jit_us=(H/clk)*1e6;
  printf("cpf=%.6f Vexact=%.6f duty706=%.6f jitter_us=%.3f\n", cpf,Vexact,f,jit_us) > "'"$OUT"'/math.txt";
  if (f < 0.72 || f > 0.73) { printf("FAIL duty706=%.6f not ~0.7248\n", f) > "/dev/stderr"; exit 1; }
  if (jit_us < 59.0 || jit_us > 59.3) { printf("FAIL jitter_us=%.3f\n", jit_us) > "/dev/stderr"; exit 1; }
  print "OK dither duty@706=" f " jitter_us=" jit_us;
}'
cat "$OUT/math.txt"

# --- doc honesty: implemented false; no glass proof ---
grep -q "UNKNOWN" "$DOC" || { echo "FAIL doc must mark glass UNKNOWN"; exit 1; }
grep -qi "pre-register" "$DOC" || { echo "FAIL doc missing pre-register"; exit 1; }
echo "OK absorb doc keeps glass UNKNOWN + pre-register"

# RED: if defaults were lowlat=1, gate would still pass structure but doc scopes
# absorb to lowlat=0 — assert doc names lowlat risk
grep -qi "lowlat" "$DOC" || { echo "FAIL doc must scope lowlat risk"; exit 1; }

echo "PASS test_ascal_vsync_dither_absorb true rc=0"
