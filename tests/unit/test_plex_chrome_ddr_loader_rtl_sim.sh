#!/usr/bin/env bash
# plex_chrome_ddr_loader RTL: seqlock + halfword order (rd-duck hole 1).
# Product: incomplete HI-only must not commit; magic-last commits.
# Fault arm halfword_magic_first: magic-only MUST wrong-accept seq0.
# Mutation twin (+HALFWORD_PRODUCT_MAGIC_FIRST): reverse product half order → RED.
set -euo pipefail

assert_exec() {
  local label="$1"; shift
  local log="$1"; shift
  local missing=0 m
  for m in "$@"; do
    grep -q -- "$m" <<<"$log" || { echo "FAIL $label missing: $m" >&2; missing=1; }
  done
  [[ "$missing" -eq 0 ]] || { echo "FAIL $label compile-only/empty" >&2; exit 2; }
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
  "$ROOT/tests/rtl/plex_chrome_ddr_loader_tb_top.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/plex_chrome_ddr_loader.sv"
  "$ROOT/tests/rtl/plex_chrome_ddr_loader_tb.cpp"
)

run_one() {
  local name="$1" cdefine="$2" expect_rc="$3"; shift 3
  local bdir="$ROOT/build/verilator/plex_chrome_ddr_loader_${name}"
  mkdir -p "$bdir"
  # C++ TB gates use -D; SV FAULT_* would use +define+ separately.
  local cflags="-std=c++17 -O2"
  if [[ -n "$cdefine" ]]; then
    cflags+=" -D${cdefine}"
  fi
  local vf=(--cc --exe --build --top-module plex_chrome_ddr_loader_tb
    -Wno-fatal -Wno-WIDTH -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND
    -CFLAGS "$cflags")
  echo "=== BUILD ddr_loader $name cdefine=$cdefine ===" >&2
  "$RUN" "${vf[@]}" --Mdir "$bdir" "${SV[@]}"
  echo "=== RUN ddr_loader $name ===" >&2
  set +e
  local out rc
  out="$("$bdir/Vplex_chrome_ddr_loader_tb" 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "$out"
  echo "ddr_loader_${name} true rc=$rc"
  assert_exec "ddr_loader-$name" "$out" "$@"
  if [[ "$rc" -ne "$expect_rc" ]]; then
    echo "FAIL ddr_loader_$name want rc=$expect_rc got $rc" >&2
    exit 1
  fi
}

run_one product "" 0 \
  "EXECUTED quiet" "PASS quiet" \
  "EXECUTED load" "PASS load" \
  "EXECUTED same_seq" "PASS same-seq" \
  "EXECUTED plxo" "PASS plxo" \
  "EXECUTED bad_magic" "PASS bad-magic" \
  "EXECUTED concurrent" "PASS concurrent" \
  "EXECUTED torn_mid" "PASS torn_mid" \
  "EXECUTED retained" "PASS retained" \
  "EXECUTED retained_inv" "PASS retained_inv" \
  "EXECUTED halfword" "PASS halfword" \
  "EXECUTED halfword_magic_first" "PASS halfword_magic_first" \
  "wrong_accept=1" \
  "plex_chrome_ddr_loader_tb: PASS"

# Product mutation: reverse half order must fail incomplete-half observation.
run_one mutate "HALFWORD_PRODUCT_MAGIC_FIRST" 1 \
  "EXECUTED halfword" \
  "halfword PRODUCT_MUTATION magic_first" \
  "FAIL halfword accepted after incomplete ctrl half"

echo "test_plex_chrome_ddr_loader_rtl_sim: PASS"
exit 0
