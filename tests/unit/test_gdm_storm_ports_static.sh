#!/usr/bin/env bash
# Static regression: GDM storm gate + 32412/32414 listen wiring cannot silently
# revert to bare strstr(buf,"plex") or a single-port bind.
#
# Correctness/robustness only — answering GDM is NOT what populates the Plex Web
# cast picker (that is companionServer friendlyName selection on the PMS side).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMP="$ROOT/arm/misterplexd/companion.cpp"
ID="$ROOT/arm/misterplexd/player_identity.hpp"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "OK $*"; }

[[ -f "$COMP" && -f "$ID" ]] || fail "missing companion.cpp or player_identity.hpp"

# --- storm gate must exist and reject self-replies ---
grep -q 'gdmIsDiscoveryProbe' "$ID" || fail "player_identity.hpp missing gdmIsDiscoveryProbe"
grep -q 'strncmp(buf, "HTTP/"' "$ID" || fail "gate must reject HTTP/ replies (storm loop)"
grep -q 'Content-Type: plex/media-player' "$ID" || fail "gate must reject media-player Content-Type replies"
# Production loop must call a storm gate — not a bare substring match.
# Reconcile: origin used gdmIsDiscoveryProbe (rejects HTTP replies + media-player
# Content-Type, still allows bare "plex"); land uses stricter gdmShouldReply
# (M-SEARCH-only via host/libmisterplex/gdm_filter.hpp). Either is a gate; bare
# strstr(buf,"plex") is the regression. Prefer gdmShouldReply when both present.
if grep -q 'gdmShouldReply(' "$COMP"; then
  pass "companion.cpp calls gdmShouldReply (M-SEARCH-only storm gate)"
elif grep -q 'gdmIsDiscoveryProbe(' "$COMP"; then
  pass "companion.cpp calls gdmIsDiscoveryProbe (origin storm gate)"
else
  fail "companion.cpp must call gdmShouldReply or gdmIsDiscoveryProbe"
fi
if grep -nE 'strstr\([[:space:]]*buf[[:space:]]*,[[:space:]]*"plex"' "$COMP" >/dev/null; then
  fail "companion.cpp reintroduced bare strstr(buf,\"plex\") — storm regression"
fi
pass "storm gate present; bare strstr(buf,\"plex\") absent from companion.cpp"

# --- listen ports: measured PMS M-SEARCH targets 32412 + 32414 ---
grep -q 'kGdmListenPorts' "$ID" || fail "kGdmListenPorts missing"
grep -q 'kGdmListenPorts' "$COMP" || fail "companion gdmLoop must iterate kGdmListenPorts"
# Both ports must appear in the listen-port constant definition.
ports_line="$(grep -E 'kGdmListenPorts\[\]' -A2 "$ID" | tr -d '\n')"
echo "$ports_line" | grep -q '32412' || fail "kGdmListenPorts missing 32412"
echo "$ports_line" | grep -q '32414' || fail "kGdmListenPorts missing 32414"
pass "kGdmListenPorts includes 32412 and 32414; gdmLoop references it"

# --- RED direction: a synthetic bare-gate file must be rejected by the same rules ---
red_tmp="$(mktemp)"
trap 'rm -f "$red_tmp"' EXIT
cat >"$red_tmp" <<'RED'
// synthetic regression fixture — bare plex match (the pre-storm-fix shape)
if (strstr(buf, "plex") != nullptr) reply();
RED
if ! grep -nE 'strstr\([[:space:]]*buf[[:space:]]*,[[:space:]]*"plex"' "$red_tmp" >/dev/null; then
  fail "red fixture did not contain bare strstr (test broken)"
fi
# The production companion must NOT match the red fixture pattern.
if grep -nE 'strstr\([[:space:]]*buf[[:space:]]*,[[:space:]]*"plex"' "$COMP" >/dev/null; then
  fail "companion matches red bare-strstr pattern"
fi
pass "red bare-strstr fixture is detected; production companion does not match it"

echo "test_gdm_storm_ports_static: OK"
exit 0
