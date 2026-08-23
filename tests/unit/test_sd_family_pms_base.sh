#!/usr/bin/env bash
# SD-family: 480p / True480 must not prefer the 720p-only 127.0.0.1:9324 proxy.
# Do not weaken tests/unit/test_p720_av_match_480p_policy.sh (parked 720p24).
set -u
set -o pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MP="$ROOT/arm/misterplexd/main.cpp"
P720="$ROOT/tests/unit/test_p720_av_match_480p_policy.sh"
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
RES="$ROOT/arm/misterplexd/plex_resolve.cpp"
body=$(awk '/^bool isUnreachableHost\(/,/^std::string plexHttpGet\(/' "$RES")
printf '%s\n' "$body" | grep -q 'localhost' || fail "isUnreachableHost must reject localhost"
printf '%s\n' "$body" | grep -q '169.254' || fail "isUnreachableHost must reject 169.254"
printf '%s\n' "$body" | grep -q 'plex.direct' || fail "isUnreachableHost must reject *.plex.direct"
printf '%s\n' "$body" | grep -q '127.' || fail "isUnreachableHost must reject 127/8"

if [ "$fails" -ne 0 ]; then
  echo "test_sd_family_pms_base.sh: $fails failure(s)" >&2
  exit 1
fi
echo "test_sd_family_pms_base.sh: OK"
exit 0
