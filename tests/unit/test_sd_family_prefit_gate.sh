#!/usr/bin/env bash
# Pre-fit gate (no Quartus): product QSF keeps PLEX_PRESENT_720P_L4 commented;
# analog_raster_mux.sv is in files.qip so the SD-family analog beam is not an
# orphan (Quartus never sees unlisted modules).
set -u
set -o pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
QSF="$ROOT/fpga/Plex_MiSTer/Plex.qsf"
QIP="$ROOT/fpga/Plex_MiSTer/files.qip"
CORE="$ROOT/fpga/Plex_MiSTer/rtl/present_core.sv"
MUX="$ROOT/fpga/Plex_MiSTer/rtl/analog_raster_mux.sv"

fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
ok() { echo "OK: $*"; }

qip_lists_mux() {
  grep -E '^[[:space:]]*set_global_assignment[[:space:]]+-name[[:space:]]+SYSTEMVERILOG_FILE[[:space:]]+rtl/analog_raster_mux\.sv[[:space:]]*$' "$1" >/dev/null
}

l4_active() {
  grep -E '^[[:space:]]*set_global_assignment[[:space:]]+-name[[:space:]]+VERILOG_MACRO[[:space:]]+"PLEX_PRESENT_720P_L4=1"' "$1" >/dev/null
}

# --- analog mux on disk + QIP (product path) ---
[[ -f "$MUX" ]] || fail "missing $MUX"
if qip_lists_mux "$QIP"; then
  ok "files.qip lists analog_raster_mux.sv"
else
  fail "files.qip missing analog_raster_mux.sv"
fi
grep -q 'analog_raster_mux u_analog' "$CORE" || fail "present_core must instantiate analog_raster_mux u_analog"

# RED twin: drop mux from a QIP copy — same predicate must fail.
qip_red=$(mktemp)
grep -v 'analog_raster_mux' "$QIP" >"$qip_red"
if qip_lists_mux "$qip_red"; then
  fail "RED twin missed analog_raster_mux drop from QIP"
else
  ok "RED twin: QIP without analog_raster_mux is detected"
fi
rm -f "$qip_red"

# --- product QSF L4 stays commented; 640x480 stays active ---
if l4_active "$QSF"; then
  fail "product QSF must not enable PLEX_PRESENT_720P_L4"
else
  ok "product QSF PLEX_PRESENT_720P_L4 not active"
fi
if ! grep -E '^[[:space:]]*#set_global_assignment.*PLEX_PRESENT_720P_L4=1' "$QSF" >/dev/null; then
  fail "product QSF missing commented PLEX_PRESENT_720P_L4 recipe"
fi
if ! grep -E '^[[:space:]]*set_global_assignment[[:space:]].*FRAME_W=640' "$QSF" >/dev/null; then
  fail "product QSF must keep FRAME_W=640 active"
fi
if ! grep -E '^[[:space:]]*set_global_assignment[[:space:]].*FRAME_H=480' "$QSF" >/dev/null; then
  fail "product QSF must keep FRAME_H=480 active"
fi

# RED twin: uncomment L4 — same predicate must fire.
qsf_red=$(mktemp)
sed 's/^#set_global_assignment -name VERILOG_MACRO "PLEX_PRESENT_720P_L4=1"/set_global_assignment -name VERILOG_MACRO "PLEX_PRESENT_720P_L4=1"/' "$QSF" >"$qsf_red"
if l4_active "$qsf_red"; then
  ok "RED twin: uncommented PLEX_PRESENT_720P_L4 is detected"
else
  fail "RED twin missed active PLEX_PRESENT_720P_L4"
fi
rm -f "$qsf_red"

if [[ "$fails" -ne 0 ]]; then
  echo "test_sd_family_prefit_gate: $fails failure(s)" >&2
  exit 1
fi
echo "test_sd_family_prefit_gate: OK"
exit 0
