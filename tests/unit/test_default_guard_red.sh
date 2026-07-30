#!/usr/bin/env bash
# Mutation / negative proofs for tests/unit/test_default_guard.cpp.
# Each mutant removes one shipping guard; the positive suite MUST fail.
# Temp header copies only — production headers are never modified.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="$ROOT/build/default-guard-red"
SRC="$ROOT/tests/unit/test_default_guard.cpp"
mkdir -p "$BUILD"

CXX_BIN="${CXX:-g++}"
if [[ -n "${CXXFLAGS:-}" ]]; then
  # shellcheck disable=SC2206
  CXX_FLAGS=(${CXXFLAGS})
else
  CXX_FLAGS=(-std=c++17 -O2 -Wall -Wextra -I"$ROOT/host")
fi

SOURCE_SHA="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
echo "test_default_guard_red: SOURCE_SHA=$SOURCE_SHA"

# --- GREEN baseline: real headers, suite must pass ---
rm -f "$BUILD/test_default_guard_green"
"$CXX_BIN" "${CXX_FLAGS[@]}" -o "$BUILD/test_default_guard_green" "$SRC"
test -x "$BUILD/test_default_guard_green"
GREEN_MTIME=$(stat -c %Y "$BUILD/test_default_guard_green")
NOW=$(date +%s)
if (( NOW - GREEN_MTIME > 60 )); then
  echo "FAIL: green binary looks stale" >&2
  exit 1
fi
set +e
GREEN_OUT="$("$BUILD/test_default_guard_green" 2>&1)"
GREEN_RC=$?
set -e
printf '%s\n' "$GREEN_OUT"
if [[ "$GREEN_RC" -ne 0 ]]; then
  echo "FAIL: green test_default_guard rc=$GREEN_RC" >&2
  exit 1
fi
grep -q 'test_default_guard: OK' <<<"$GREEN_OUT" || {
  echo "FAIL: green missing OK line" >&2
  exit 1
}
echo "GREEN OK: test_default_guard passes on real headers (rc=0)"

prepare_inc() {
  local name="$1"
  local inc="$BUILD/inc_$name"
  rm -rf "$inc"
  mkdir -p "$inc/libmisterplex"
  cp -a "$ROOT/host/libmisterplex/." "$inc/libmisterplex/"
  printf '%s' "$inc"
}

compile_and_expect_fail() {
  local name="$1"
  local inc="$2"
  local expect_frag="$3"
  local bin="$BUILD/mutant_$name"
  rm -f "$bin"
  set +e
  local cerr
  # Mutant include MUST precede any -I$host from CXXFLAGS.
  cerr="$("$CXX_BIN" -I"$inc" "${CXX_FLAGS[@]}" -o "$bin" "$SRC" 2>&1)"
  local crc=$?
  set -e
  if [[ "$crc" -ne 0 ]]; then
    printf '%s\n' "$cerr"
    echo "FAIL: mutant $name did not compile (rc=$crc); mutation may be ill-formed" >&2
    exit 1
  fi
  test -x "$bin"
  echo "MUTANT_COMPILED: $name"

  set +e
  local out rc
  out="$("$bin" 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "$out"
  if [[ "$rc" -eq 0 ]]; then
    echo "FAIL: mutant $name unexpectedly PASSED — guard is vacuous" >&2
    exit 1
  fi
  grep -q "$expect_frag" <<<"$out" || {
    echo "FAIL: mutant $name failed but missing expected fragment: $expect_frag" >&2
    exit 1
  }
  echo "RED OK: $name rejected (rc=$rc) hit=$expect_frag"
}

# M1: drop lab-480p conf gate → stale 624x480 adopts as Ok.
INC1="$(prepare_inc lab480p_unguarded)"
python3 - "$INC1/libmisterplex/coded_size.hpp" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()
old = """    if (isLab480p && !allowLab480p) {
        r.status = CodedSizeParseStatus::Lab480pBlocked;
        r.reason = "624x480 lab coded decode blocked without DECODE_ALLOW_LAB_480P=1 "
                   "(stale conf guard; OSD O[4] still selects 480p at play time)";
        r.size = kDefaultCodedDecodeSize;
        return r;
    }"""
new = """    if (false && isLab480p && !allowLab480p) {
        r.status = CodedSizeParseStatus::Lab480pBlocked;
        r.reason = "mutant: lab gate disabled";
        r.size = kDefaultCodedDecodeSize;
        return r;
    }"""
if old not in t:
    raise SystemExit("lab480p gate block not found for mutation")
p.write_text(t.replace(old, new, 1))
PY
compile_and_expect_fail lab480p_unguarded "$INC1" \
  "P2 stale DECODE=624x480 without allow must be Lab480pBlocked"

# M2: drop presented-scanout reject → 640x480 parses as coded Ok.
INC2="$(prepare_inc presented_unguarded)"
python3 - "$INC2/libmisterplex/coded_size.hpp" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()
old = """    if (w == kPlex480pPresentedWidth.get() && h == kPlex480pPresentedHeight.get()) {
        r.status = CodedSizeParseStatus::PresentedMistake;
        r.reason = "640x480 is presented scanout, not coded decode (use 624x480 lab coded "
                   "with allow, or 320x240 product default)";
        return r;
    }"""
new = """    if (false && w == kPlex480pPresentedWidth.get() && h == kPlex480pPresentedHeight.get()) {
        r.status = CodedSizeParseStatus::PresentedMistake;
        r.reason = "mutant: presented guard disabled";
        return r;
    }"""
if old not in t:
    raise SystemExit("presented mistake block not found for mutation")
p.write_text(t.replace(old, new, 1))
PY
compile_and_expect_fail presented_unguarded "$INC2" \
  "P3 conf DECODE=640x480 must be PresentedMistake"

# M3: OSD O[4] returns CodedWidth{640} — presented-for-coded substitution.
INC3="$(prepare_inc osd_coded_width_640)"
python3 - "$INC3/libmisterplex/osd_menu.hpp" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()
old = """inline ContentResolution contentResolutionFor480p() {
    // 624x480 is still the 480p ladder. Use the 2000 kbps PMS/validator floor
    // until W-FEED (or equivalent ARM-boundary profiling) proves a higher
    // bitrate safe; this path has only millisecond-scale decode margin.
    return {kPlex480pCodedWidth, kPlex480pCodedHeight, plex480pCodedResolutionLabel(),
            kPlex480pWeakBitrateKbps};
}"""
new = """inline ContentResolution contentResolutionFor480p() {
    // MUTANT: pretend menu presented 640 is the coded ladder.
    return {CodedWidth{640}, kPlex480pCodedHeight, "640x480",
            kPlex480pWeakBitrateKbps};
}"""
if old not in t:
    raise SystemExit("contentResolutionFor480p block not found for mutation")
p.write_text(t.replace(old, new, 1))
PY
compile_and_expect_fail osd_coded_width_640 "$INC3" \
  "P5 OSD bit4 set coded width must be 624"

# M4: 480p bitrate falls back to 360p tier (header fault switch).
rm -f "$BUILD/mutant_bitrate_tier"
"$CXX_BIN" "${CXX_FLAGS[@]}" -I"$ROOT/host" -DOSD_MENU_FAULT_FALLBACK_624_BITRATE \
  -o "$BUILD/mutant_bitrate_tier" "$SRC"
test -x "$BUILD/mutant_bitrate_tier"
echo "MUTANT_COMPILED: bitrate_tier"
set +e
BR_OUT="$("$BUILD/mutant_bitrate_tier" 2>&1)"
BR_RC=$?
set -e
printf '%s\n' "$BR_OUT"
if [[ "$BR_RC" -eq 0 ]]; then
  echo "FAIL: bitrate tier mutant unexpectedly passed" >&2
  exit 1
fi
grep -q "P6 coded 624x480 bitrate is 480p tier" <<<"$BR_OUT" || {
  echo "FAIL: bitrate mutant did not hit P6 bitrate guard" >&2
  exit 1
}
echo "RED OK: bitrate_tier rejected (rc=$BR_RC)"

# M5: shipping default constant moved to 624x480.
INC5="$(prepare_inc default_moved_to_480p)"
python3 - "$INC5/libmisterplex/coded_size.hpp" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()
old = "constexpr CodedSize kDefaultCodedDecodeSize{CodedWidth{320}, CodedHeight{240}};"
new = "constexpr CodedSize kDefaultCodedDecodeSize{CodedWidth{624}, CodedHeight{480}};"
if old not in t:
    raise SystemExit("kDefaultCodedDecodeSize not found for mutation")
p.write_text(t.replace(old, new, 1))
PY
compile_and_expect_fail default_moved_to_480p "$INC5" \
  "P1 shipping default coded size must be 320x240"

# M6: adoptExternalCodedSize always returns default Ok — destroys CLI/conf policy.
INC6="$(prepare_inc adopt_always_default_ok)"
python3 - "$INC6/libmisterplex/coded_size.hpp" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()
old = """inline CodedSizeParseResult adoptExternalCodedSize(const std::string& text, bool allowLab480p) {
    CodedSizeParseResult r = parseCodedSizeString(text);
    if (!r.ok())
        return r;
    const bool isLab480p = r.size.width == kPlex480pCodedWidth &&
                           r.size.height == kPlex480pCodedHeight;
    if (isLab480p && !allowLab480p) {
        r.status = CodedSizeParseStatus::Lab480pBlocked;
        r.reason = "624x480 lab coded decode blocked without DECODE_ALLOW_LAB_480P=1 "
                   "(stale conf guard; OSD O[4] still selects 480p at play time)";
        r.size = kDefaultCodedDecodeSize;
        return r;
    }
    return r;
}"""
new = """inline CodedSizeParseResult adoptExternalCodedSize(const std::string& text, bool allowLab480p) {
    (void)text; (void)allowLab480p;
    // MUTANT: always claim product default Ok — destroys CLI/conf policy signal.
    CodedSizeParseResult r;
    r.status = CodedSizeParseStatus::Ok;
    r.size = kDefaultCodedDecodeSize;
    r.reason = "mutant always default";
    return r;
}"""
if old not in t:
    raise SystemExit("adoptExternalCodedSize block not found for mutation")
p.write_text(t.replace(old, new, 1))
PY
compile_and_expect_fail adopt_always_default_ok "$INC6" \
  "P4 CLI lab win size is 624x480 coded"

echo "test_default_guard_red: OK SOURCE_SHA=$SOURCE_SHA"
exit 0
