#!/usr/bin/env bash
# Native 1280×720 fabric idle — red-before-green.
# RED: FAULT_480P_GEOM=1 must fail 720p mon probe (or pass only as "fault engaged").
# GREEN: exact chevron geometry + vsync phase + subsample no video leak.
set -euo pipefail

assert_sim_executed() {
  local label="$1"; shift
  local log="$1"; shift
  local missing=0 m
  for m in "$@"; do
    grep -q -- "$m" <<<"$log" || { echo "FAIL $label missing: $m" >&2; missing=1; }
  done
  [[ "$missing" -eq 0 ]] || { echo "FAIL $label compile-only" >&2; exit 2; }
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN="$ROOT/scripts/run_verilator.sh"
set +e
VER="$($RUN --version 2>&1)"; RC=$?
set -e
if [[ "$RC" -eq 127 ]]; then
  [[ "${ALLOW_MISSING_VERILATOR:-0}" == "1" ]] && exit 77
  echo "RTL SIM ERROR: Verilator not found" >&2
  exit 3
elif [[ "$RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed" >&2
  exit "$RC"
fi

SV=(
  "$ROOT/tests/rtl/plex_chrome_idle720_tb_top.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/plex_chrome.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/plex_chrome_host_if.sv"
  "$ROOT/tests/rtl/plex_chrome_idle720_tb.cpp"
)
VFLAGS=(--cc --exe --build --top-module plex_chrome_idle720_tb
  -Wno-fatal -Wno-WIDTH -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-SELRANGE
  -CFLAGS "-std=c++17 -O2")

# --- RED: 480p-clamped mon ports must NOT look like 720p ---
BUILD_RED="$ROOT/build/verilator/plex_chrome_idle720_red"
mkdir -p "$BUILD_RED"
echo "=== BUILD idle720 RED (FAULT_480P_GEOM=1) ===" >&2
G0=(-GFAULT_480P_GEOM=0 -GFAULT_LEGACY_480P_LAYOUT=0 \
  -GFAULT_HDMI_LAYOUT_ON_CORE_DE=0 -GFAULT_NARROW_BEAM_X=0 \
  -GFAULT_LAYOUT_FROM_HTOTAL=0 -GCORE_DE_BEAM=0)

"$RUN" "${VFLAGS[@]}" -GFAULT_480P_GEOM=1 -GFAULT_LEGACY_480P_LAYOUT=0 \
  -GFAULT_HDMI_LAYOUT_ON_CORE_DE=0 -GFAULT_NARROW_BEAM_X=0 \
  -GFAULT_LAYOUT_FROM_HTOTAL=0 -GCORE_DE_BEAM=0 \
  --Mdir "$BUILD_RED" "${SV[@]}"
echo "=== RUN idle720 RED ===" >&2
set +e
OUT_RED="$(IDLE720_MODE=red "$BUILD_RED/Vplex_chrome_idle720_tb" 2>&1)"
RC_RED=$?
set -e
printf '%s\n' "$OUT_RED"
echo "idle720_red true rc=$RC_RED"
assert_sim_executed "idle720-red" "$OUT_RED" "PASS idle720-red-mon" "plex_chrome_idle720_tb: PASS (red fault engaged)"
[[ "$RC_RED" -eq 0 ]] || { echo "FAIL red rc=$RC_RED" >&2; exit "$RC_RED"; }

# --- LEGACY RED: true 720p mon, 480p-derived paint (must miss golden origin) ---
BUILD_LEG="$ROOT/build/verilator/plex_chrome_idle720_legacy"
mkdir -p "$BUILD_LEG"
echo "=== BUILD idle720 LEGACY (FAULT_LEGACY_480P_LAYOUT=1) ===" >&2
"$RUN" "${VFLAGS[@]}" -GFAULT_480P_GEOM=0 -GFAULT_LEGACY_480P_LAYOUT=1 \
  -GFAULT_HDMI_LAYOUT_ON_CORE_DE=0 -GFAULT_NARROW_BEAM_X=0 \
  -GFAULT_LAYOUT_FROM_HTOTAL=0 -GCORE_DE_BEAM=0 \
  --Mdir "$BUILD_LEG" "${SV[@]}"

echo "=== RUN idle720 LEGACY ===" >&2
set +e
OUT_LEG="$(IDLE720_MODE=legacy "$BUILD_LEG/Vplex_chrome_idle720_tb" 2>&1)"
RC_LEG=$?
set -e
printf '%s\n' "$OUT_LEG"
echo "idle720_legacy true rc=$RC_LEG"
assert_sim_executed "idle720-legacy" "$OUT_LEG" \
  "PASS idle720-legacy-layout-fault" \
  "plex_chrome_idle720_tb: PASS (legacy 480p layout fault engaged)"
[[ "$RC_LEG" -eq 0 ]] || { echo "FAIL legacy rc=$RC_LEG" >&2; exit "$RC_LEG"; }

# --- HDMI-on-CORE_DE RED: beam 960×540, layout forced 1280×720 (ascal-pivot class) ---
BUILD_HOD="$ROOT/build/verilator/plex_chrome_idle720_hdmi_on_de"
mkdir -p "$BUILD_HOD"
echo "=== BUILD idle720 HDMI_ON_DE (FAULT_HDMI_LAYOUT_ON_CORE_DE=1) ===" >&2
"$RUN" "${VFLAGS[@]}" -GFAULT_480P_GEOM=0 -GFAULT_LEGACY_480P_LAYOUT=0 \
  -GFAULT_HDMI_LAYOUT_ON_CORE_DE=1 -GFAULT_NARROW_BEAM_X=0 \
  -GFAULT_LAYOUT_FROM_HTOTAL=0 -GCORE_DE_BEAM=0 \
  --Mdir "$BUILD_HOD" "${SV[@]}"

echo "=== RUN idle720 HDMI_ON_DE ===" >&2
set +e
OUT_HOD="$(IDLE720_MODE=hdmi_on_de "$BUILD_HOD/Vplex_chrome_idle720_tb" 2>&1)"
RC_HOD=$?
set -e
printf '%s\n' "$OUT_HOD"
echo "idle720_hdmi_on_de true rc=$RC_HOD"
assert_sim_executed "idle720-hdmi-on-de" "$OUT_HOD" \
  "PASS idle720-hdmi-layout-on-core-de" \
  "plex_chrome_idle720_tb: PASS (hdmi layout on core DE fault engaged)"
[[ "$RC_HOD" -eq 0 ]] || { echo "FAIL hdmi_on_de rc=$RC_HOD" >&2; exit "$RC_HOD"; }

# --- CORE_DE GREEN: pre-ascal insertion path (beam+layout 960×540) ---
BUILD_CDE="$ROOT/build/verilator/plex_chrome_idle720_corede"
mkdir -p "$BUILD_CDE"
echo "=== BUILD idle720 CORE_DE green ===" >&2
"$RUN" "${VFLAGS[@]}" -GFAULT_480P_GEOM=0 -GFAULT_LEGACY_480P_LAYOUT=0 \
  -GFAULT_HDMI_LAYOUT_ON_CORE_DE=0 -GFAULT_NARROW_BEAM_X=0 \
  -GFAULT_LAYOUT_FROM_HTOTAL=0 -GCORE_DE_BEAM=1 \
  --Mdir "$BUILD_CDE" "${SV[@]}"

echo "=== RUN idle720 CORE_DE ===" >&2
set +e
OUT_CDE="$(IDLE720_MODE=corede "$BUILD_CDE/Vplex_chrome_idle720_tb" 2>&1)"
RC_CDE=$?
set -e
printf '%s\n' "$OUT_CDE"
echo "idle720_corede true rc=$RC_CDE"
assert_sim_executed "idle720-corede" "$OUT_CDE" \
  "PASS idle720-corede-geom" \
  "plex_chrome_idle720_tb: PASS (core DE green)"
[[ "$RC_CDE" -eq 0 ]] || { echo "FAIL corede rc=$RC_CDE" >&2; exit "$RC_CDE"; }

# --- NARROW_X RED: 10-bit X counter wraps before 1280 (parent counter trap) ---
BUILD_NX="$ROOT/build/verilator/plex_chrome_idle720_narrow_x"
mkdir -p "$BUILD_NX"
echo "=== BUILD idle720 NARROW_X (FAULT_NARROW_BEAM_X=1) ===" >&2
"$RUN" "${VFLAGS[@]}" -GFAULT_480P_GEOM=0 -GFAULT_LEGACY_480P_LAYOUT=0 \
  -GFAULT_HDMI_LAYOUT_ON_CORE_DE=0 -GFAULT_NARROW_BEAM_X=1 \
  -GFAULT_LAYOUT_FROM_HTOTAL=0 -GCORE_DE_BEAM=0 \
  --Mdir "$BUILD_NX" "${SV[@]}"

echo "=== RUN idle720 NARROW_X ===" >&2
set +e
OUT_NX="$(IDLE720_MODE=narrow_x "$BUILD_NX/Vplex_chrome_idle720_tb" 2>&1)"
RC_NX=$?
set -e
printf '%s\n' "$OUT_NX"
echo "idle720_narrow_x true rc=$RC_NX"
assert_sim_executed "idle720-narrow-x" "$OUT_NX" \
  "PASS idle720-narrow-x-wrap" \
  "plex_chrome_idle720_tb: PASS (narrow 10b X fault engaged)"
[[ "$RC_NX" -eq 0 ]] || { echo "FAIL narrow_x rc=$RC_NX" >&2; exit "$RC_NX"; }

# --- HTOTAL RED: layout_w from H_TOTAL=1600 (compact 720p24) not H_ACTIVE ---
BUILD_HT="$ROOT/build/verilator/plex_chrome_idle720_htotal"
mkdir -p "$BUILD_HT"
echo "=== BUILD idle720 HTOTAL (FAULT_LAYOUT_FROM_HTOTAL=1 W=1600) ===" >&2
"$RUN" "${VFLAGS[@]}" -GFAULT_480P_GEOM=0 -GFAULT_LEGACY_480P_LAYOUT=0 \
  -GFAULT_HDMI_LAYOUT_ON_CORE_DE=0 -GFAULT_NARROW_BEAM_X=0 \
  -GFAULT_LAYOUT_FROM_HTOTAL=1 -GFAULT_HTOTAL_W=1600 -GCORE_DE_BEAM=0 \
  --Mdir "$BUILD_HT" "${SV[@]}"

echo "=== RUN idle720 HTOTAL ===" >&2
set +e
OUT_HT="$(IDLE720_MODE=htotal "$BUILD_HT/Vplex_chrome_idle720_tb" 2>&1)"
RC_HT=$?
set -e
printf '%s\n' "$OUT_HT"
echo "idle720_htotal true rc=$RC_HT"
assert_sim_executed "idle720-htotal" "$OUT_HT" \
  "PASS idle720-htotal-layout-fault" \
  "plex_chrome_idle720_tb: PASS (H_TOTAL layout fault engaged)"
[[ "$RC_HT" -eq 0 ]] || { echo "FAIL htotal rc=$RC_HT" >&2; exit "$RC_HT"; }

# --- GREEN: full HDMI_OUT 720p idle (product insertion) ---
BUILD_G="$ROOT/build/verilator/plex_chrome_idle720"
mkdir -p "$BUILD_G"
echo "=== BUILD idle720 GREEN (HDMI_OUT) ===" >&2
"$RUN" "${VFLAGS[@]}" "${G0[@]}" --Mdir "$BUILD_G" "${SV[@]}"

echo "=== RUN idle720 GREEN ===" >&2
set +e
OUT_G="$("$BUILD_G/Vplex_chrome_idle720_tb" 2>&1)"
RC_G=$?
set -e
printf '%s\n' "$OUT_G"
echo "idle720_green true rc=$RC_G"
assert_sim_executed "idle720-green" "$OUT_G" \
  "PASS idle720-geom" "PASS idle720-phase" "PASS idle720-screensaver-motion" \
  "PASS idle720-subsample" "plex_chrome_idle720_tb: PASS"
[[ "$RC_G" -eq 0 ]] || { echo "FAIL green rc=$RC_G" >&2; exit "$RC_G"; }

# --- blank320 POSITIVE: H_BLANK=320 pacing (CORE_DE 720p24) must keep geom ---
BUILD_B="$ROOT/build/verilator/plex_chrome_idle720_blank320"
mkdir -p "$BUILD_B"
echo "=== BUILD idle720 BLANK320 ===" >&2
"$RUN" "${VFLAGS[@]}" "${G0[@]}" --Mdir "$BUILD_B" "${SV[@]}"

echo "=== RUN idle720 BLANK320 ===" >&2
set +e
OUT_B="$(IDLE720_MODE=blank320 "$BUILD_B/Vplex_chrome_idle720_tb" 2>&1)"
RC_B=$?
set -e
printf '%s\n' "$OUT_B"
echo "idle720_blank320 true rc=$RC_B"
assert_sim_executed "idle720-blank320" "$OUT_B" \
  "PASS idle720-blank320" \
  "plex_chrome_idle720_tb: PASS (blank320)"
[[ "$RC_B" -eq 0 ]] || { echo "FAIL blank320 rc=$RC_B" >&2; exit "$RC_B"; }

echo "test_plex_chrome_idle720_rtl_sim: PASS"
exit 0
