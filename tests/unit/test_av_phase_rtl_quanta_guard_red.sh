#!/usr/bin/env bash
# Red/green pair: poison-macro guard must FAIL compile if kParentClusterSepMsX100
# is restored as a C++ constexpr (not a macro). #if defined() is inert for that.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HDR="$ROOT/host/libmisterplex/av_phase_rtl_quanta.hpp"
TEST_CPP="$ROOT/tests/unit/test_av_phase_rtl_quanta.cpp"
OUT="$ROOT/build/av_phase_rtl_quanta_guard_red"
mkdir -p "$OUT"
CXX="${CXX:-g++}"
# NOTE: do NOT put -I"$ROOT/host" before the wrap dir — first match wins.
BASE_CXXFLAGS=(-std=c++17 -O0 -Wall -Wextra)

if ! grep -q 'RETRACTED_OLD_ARGV_ARTIFACT_kParentClusterSepMsX100' "$TEST_CPP"; then
  echo "FAIL: test_av_phase_rtl_quanta.cpp missing string-poison macro guard" >&2
  exit 2
fi
if grep -qE '^[[:space:]]*#if[[:space:]]+defined[[:space:]]*\([[:space:]]*kParentClusterSepMsX100' "$TEST_CPP"; then
  echo "FAIL: inert #if defined(kParentClusterSepMsX100) guard reintroduced" >&2
  exit 2
fi
if grep -q 'kParentClusterSepMsX100' "$HDR"; then
  echo "FAIL: header already contains kParentClusterSepMsX100 (clean tree required)" >&2
  exit 2
fi

# --- RED: inject restored constant into a temp header copy via -include probe ---
# Safer than editing the live header: compile test.cpp with a forced probe header
# that reopens the namespace and redeclares the banned name after including the real one.
# But the poison is only active DURING the real header include. So we must inject
# into a copy of the real header.
PROBE_HDR="$OUT/av_phase_rtl_quanta_PROBE.hpp"
cp "$HDR" "$PROBE_HDR"
# Insert after kSevenDispMsX100
if ! grep -q 'kSevenDispMsX100' "$PROBE_HDR"; then
  echo "FAIL: probe anchor kSevenDispMsX100 missing in header" >&2
  exit 2
fi
python3 - "$PROBE_HDR" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
t = p.read_text()
needle = "inline constexpr int64_t kSevenDispMsX100 = nDisplayFramesMsX100(7); // 11701\n"
if needle not in t:
    # allow without comment
    import re
    m = re.search(r"inline constexpr int64_t kSevenDispMsX100 = nDisplayFramesMsX100\(7\);[^\n]*\n", t)
    if not m:
        raise SystemExit("anchor not found")
    needle = m.group(0)
insert = needle + "inline constexpr int64_t kParentClusterSepMsX100 = 11710; // GUARD_RED_PROBE\n"
p.write_text(t.replace(needle, insert, 1))
print("probe header ready")
PY

# Compile test against probe header by rewriting include path via -I and a wrapper dir
WRAP="$OUT/wrap_host/libmisterplex"
mkdir -p "$WRAP"
cp "$PROBE_HDR" "$WRAP/av_phase_rtl_quanta.hpp"
# Also need sibling headers reachable: put ROOT/host first for others, wrap first for poison target
# Order: -I wrap_host -I host  so av_phase comes from wrap
set +e
# wrap_host FIRST so probe header shadows the clean one (first -I wins).
"$CXX" "${BASE_CXXFLAGS[@]}" -I"$OUT/wrap_host" -I"$ROOT/host" \
  -o "$OUT/should_not_link" "$TEST_CPP" >"$OUT/red_build.txt" 2>&1
RED_RC=$?
set -e
echo "GUARD_RED_BUILD true rc=$RED_RC"
if [[ "$RED_RC" -eq 0 ]]; then
  echo "FAIL: restored kParentClusterSepMsX100 compiled GREEN — poison guard is inert" >&2
  sed 's/^/  | /' "$OUT/red_build.txt" | tail -30 >&2
  exit 2
fi
if ! grep -q 'kParentClusterSepMsX100\|RETRACTED_OLD_ARGV' "$OUT/red_build.txt"; then
  echo "FAIL: compile failed but not with poison/restore diagnostic" >&2
  sed 's/^/  | /' "$OUT/red_build.txt" | tail -40 >&2
  exit 2
fi
echo "PASS GUARD_RED restored constexpr fails compile rc=$RED_RC"

# --- GREEN: real header, normal make target path ---
set +e
"$CXX" "${BASE_CXXFLAGS[@]}" -I"$ROOT/host" -o "$OUT/green_ok" "$TEST_CPP" >"$OUT/green_build.txt" 2>&1
GREEN_RC=$?
set -e
echo "GUARD_GREEN_BUILD true rc=$GREEN_RC"
if [[ "$GREEN_RC" -ne 0 ]]; then
  echo "FAIL: clean header failed to compile" >&2
  cat "$OUT/green_build.txt" >&2
  exit 2
fi
set +e
"$OUT/green_ok" >"$OUT/green_run.txt" 2>&1
RUN_RC=$?
set -e
echo "GUARD_GREEN_RUN true rc=$RUN_RC"
if [[ "$RUN_RC" -ne 0 ]]; then
  echo "FAIL: green binary rc=$RUN_RC" >&2
  cat "$OUT/green_run.txt" >&2
  exit 2
fi
echo "PASS GUARD_GREEN clean header build+run rc=0"
echo "AV_PHASE_RTL_QUANTA_GUARD_RED_OK"
exit 0
