#!/usr/bin/env bash
# SD-family: 480p / True480 must not prefer the 720p-only 127.0.0.1:9324 proxy.
# GREEN: 127 / 127:9324 / *.plex.direct / 169.254.* → http://192.168.2.1:32400
# RED: planted leftover 127 must fail the checker (true rc=1).
# Do not weaken tests/unit/test_p720_av_match_480p_policy.sh (parked 720p24).
set -u
set -o pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CXX="${CXX:-g++}"
MP="$ROOT/arm/misterplexd/main.cpp"
P720="$ROOT/tests/unit/test_p720_av_match_480p_policy.sh"
SRC="$ROOT/tests/unit/test_sd_family_pms_base.cpp"
RES="$ROOT/arm/misterplexd/plex_resolve.cpp"
INC="-std=c++17 -O2 -Wall -Wextra -I$ROOT/host -I$ROOT/arm/misterplexd"
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
ok() { echo "OK: $*"; }

[ -f "$MP" ] || { echo "missing $MP" >&2; exit 1; }
[ -f "$P720" ] || { echo "missing $P720" >&2; exit 1; }

# Parked 720p24 policy file must keep its 9324 prefer (do not drop).
grep -q '720p24 PLEX_BASE proxy' "$P720" || \
  fail "do not drop 720p24 9324 preference from test_p720_av_match_480p_policy.sh"
ok "720p24 parked policy still requires 9324 prefer (untouched)"

# The 9324 prefer in main.cpp must be LiveGlass::L4-gated.
if ! grep -n '127.0.0.1:9324' "$MP" | grep -q .; then
  fail "main.cpp lost 127.0.0.1:9324 (720p parked path)"
fi

if python3 - "$MP" <<'PY'
import pathlib, sys
src = pathlib.Path(sys.argv[1]).read_text()
lines = src.splitlines()
hits = []
for i, line in enumerate(lines):
    stripped = line.lstrip()
    if stripped.startswith("//"):
        continue
    if "127.0.0.1:9324" in line:
        hits.append((i + 1, line, lines[max(0, i - 8):i + 1]))
if not hits:
    print("FAIL: no non-comment 127.0.0.1:9324 in main.cpp", file=sys.stderr)
    sys.exit(1)
bad = 0
for lineno, line, window in hits:
    text = "\n".join(window)
    if "LiveGlass::L4" not in text:
        print(f"FAIL: 9324 at main.cpp:{lineno} is not L4-gated: {line.strip()}",
              file=sys.stderr)
        bad += 1
    if "True480" in line:
        print(f"FAIL: True480 must not prefer 9324 at main.cpp:{lineno}", file=sys.stderr)
        bad += 1
if bad:
    sys.exit(1)
print("OK: 9324 prefer is L4-gated; True480/480p cannot take it")
sys.exit(0)
PY
then
  ok "480p / True480 must not prefer 9324 (L4-gated only)"
else
  fail "9324 L4-gate python check true rc=$?"
fi

# isUnreachableHost (not merely a comment elsewhere) must classify the 0:00 class.
body=$(awk '/^bool isUnreachableHost\(/,/^std::string plexHttpGet\(/' "$RES")
printf '%s\n' "$body" | grep -q 'localhost' || fail "isUnreachableHost must reject localhost"
printf '%s\n' "$body" | grep -q '169.254' || fail "isUnreachableHost must reject 169.254"
printf '%s\n' "$body" | grep -q 'plex.direct' || fail "isUnreachableHost must reject *.plex.direct"
printf '%s\n' "$body" | grep -q '127.' || fail "isUnreachableHost must reject 127/8"
printf '%s\n' "$body" | grep -q 'PMS_REWRITE_FAULT_LEFTOVER_127' || \
  fail "isUnreachableHost must plant leftover-127 RED via PMS_REWRITE_FAULT_LEFTOVER_127"

mkdir -p "$ROOT/build"
green="$ROOT/build/test_sd_family_pms_base"
if ! $CXX $INC -o "$green" "$SRC" "$RES"; then
  echo "GREEN PMS rewrite compile failed" >&2
  exit 1
fi
set +e
GREEN_OUT=$("$green" 2>&1)
GREEN_RC=$?
set -e
printf '%s\n' "$GREEN_OUT"
echo "pms_rewrite GREEN true rc=$GREEN_RC"
if [ "$GREEN_RC" -ne 0 ]; then
  fail "GREEN PMS rewrite true rc=$GREEN_RC"
else
  ok "GREEN 127 / 9324 / plex.direct / 169.254 → http://192.168.2.1:32400"
fi

red="$ROOT/build/test_sd_family_pms_base_red"
if ! $CXX $INC -DPMS_REWRITE_FAULT_LEFTOVER_127 -o "$red" "$SRC" "$RES"; then
  fail "RED leftover-127 compile should succeed (runtime must fail)"
else
  set +e
  RED_OUT=$("$red" 2>&1)
  RED_RC=$?
  set -e
  printf '%s\n' "$RED_OUT"
  echo "pms_rewrite RED leftover-127 true rc=$RED_RC"
  if [ "$RED_RC" -eq 0 ]; then
    fail "RED leftover-127 twin ran rc=0 (planted 127 must fail the checker)"
  elif ! printf '%s\n' "$RED_OUT" | grep -q "127.0.0.1"; then
    fail "RED twin must quote leftover 127 base"
  else
    ok "RED planted leftover 127 true rc=$RED_RC"
  fi
fi

if [ "$fails" -ne 0 ]; then
  echo "test_sd_family_pms_base.sh: $fails failure(s)" >&2
  exit 1
fi
echo "test_sd_family_pms_base.sh: OK"
exit 0
