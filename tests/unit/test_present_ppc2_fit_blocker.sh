#!/usr/bin/env bash
# RED/GREEN: PRESENT PPC2 hollow claim must fail; self-test + product tree pass.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHK="$ROOT/scripts/check_present_ppc2_fit_blocker.py"
WORKDIR="${ROOT}/Memory/lab/fitgate-ppc2-blocker"
mkdir -p "$WORKDIR"
echo "=== test_present_ppc2_fit_blocker EXECUTED ==="

set +e
python3 "$CHK" --self-test >"$WORKDIR/self.out" 2>"$WORKDIR/self.err"
s_rc=$?
set -e
echo "self-test true rc=$s_rc"
cat "$WORKDIR/self.out"
[[ "$s_rc" -eq 0 ]] || exit "$s_rc"
grep -q PRESENT_PPC2_FIT_BLOCKER_EXECUTED "$WORKDIR/self.out"

# Product tree (likely no MULTI/PPC2): must not false-green a PPC2 claim
set +e
python3 "$CHK" --root "$ROOT" >"$WORKDIR/prod.out" 2>"$WORKDIR/prod.err"
p_rc=$?
set -e
echo "product true rc=$p_rc"
tail -15 "$WORKDIR/prod.out"
[[ "$p_rc" -eq 0 ]] || { cat "$WORKDIR/prod.err" >&2; exit "$p_rc"; }
grep -q 'BLOCKER_PRESENT_PPC2=required' "$WORKDIR/prod.out"
grep -q 'PARTIAL_CLOSED_READER' "$WORKDIR/prod.out"
grep -q 'fabric_bw_closed=false' "$WORKDIR/prod.out"
grep -q 'PPC2_ACCEPT_scalar_NEG_control=required' "$WORKDIR/prod.out"
grep -q 'PPC2_ACCEPTED_REQUEST_STEADY_DELTA=CLOSED_IF_PROVEN' "$WORKDIR/prod.out"
grep -q 'PPC2_ACCEPT_scorer_observes_rd_n_lane_rgb_underrun=required' "$WORKDIR/prod.out"
grep -q 'PPC2_DEADLINE_CLOSED=false' "$WORKDIR/prod.out"

# RED: hollow present_core + QSF PPC=2
cat >"$WORKDIR/hollow.sv" <<'SV'
// synthesis translate_off
initial begin
  if (PRESENT_PPC != 1)
    $error("PRESENT_MULTI_PIXEL land requires PRESENT_PX_PER_CLK=1 until ddr_frame_store N-wide RGB (got %0d)", PRESENT_PPC);
end
// synthesis translate_on
wire [PRESENT_PPC*8-1:0] mp_npx_r = {PRESENT_PPC{fr}};
wire [PRESENT_PPC*8-1:0] mp_npx_g = {PRESENT_PPC{fg}};
wire [PRESENT_PPC*8-1:0] mp_npx_b = {PRESENT_PPC{fb}};
wire _unused_mp_glass = |{mp_glass_x0, mp_glass_y};
// Note: fstore still wired to store_x/y from Template regs above — full MULTI
SV
cat >"$WORKDIR/hollow.qsf" <<'QSF'
set_global_assignment -name VERILOG_MACRO "PRESENT_MULTI_PIXEL=1"
set_global_assignment -name VERILOG_MACRO "PRESENT_PX_PER_CLK=2"
QSF
set +e
python3 "$CHK" --root "$ROOT" --present-core "$WORKDIR/hollow.sv" --qsf "$WORKDIR/hollow.qsf" \
  >"$WORKDIR/red.out" 2>"$WORKDIR/red.err"
r_rc=$?
set -e
echo "hollow_ppc2 true rc=$r_rc"
cat "$WORKDIR/red.err" || true
[[ "$r_rc" -ne 0 ]] || { echo "FAIL hollow PPC2 claim must be RED" >&2; exit 1; }
grep -q 'PRESENT_PPC2_HOLLOW_CLAIM\|PRESENT_PPC2_NO_DUAL' "$WORKDIR/red.err"

# Optional: live w-scaler tip if present — expect hollow detect, rc depends on QSF
SCALER_PC="/home/flynnsbit/Projects/MisterPlex-wt-scaler/fpga/Plex_MiSTer/rtl/present_core.sv"
SCALER_QSF="/home/flynnsbit/Projects/MisterPlex-wt-scaler/fpga/Plex_MiSTer/Plex.qsf"
if [[ -f "$SCALER_PC" ]]; then
  set +e
  python3 "$CHK" --present-core "$SCALER_PC" --qsf "${SCALER_QSF:-/dev/null}" \
    >"$WORKDIR/scaler.out" 2>"$WORKDIR/scaler.err"
  sc_rc=$?
  set -e
  echo "w-scaler present_core true rc=$sc_rc"
  grep -E 'HOLLOW_PATTERNS|BLOCKER_PRESENT' "$WORKDIR/scaler.out" | head -5
  # Must at least detect hollow patterns on scaler tip (rd-duck citations)
  grep -q 'scalar_fr_replicated_to_mp_npx_r' "$WORKDIR/scaler.out" \
    || grep -q 'sim_only_ppc_ne_1' "$WORKDIR/scaler.out" \
    || { echo "FAIL scaler tip should show hollow PPC patterns" >&2; exit 1; }
fi

echo "EXECUTED present_ppc2_fit_blocker self=0 product=0 hollow_red=$r_rc"
echo "true rc=0"
exit 0
