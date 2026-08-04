#!/usr/bin/env bash
# Static regression: GDM storm gate + 32412/32414 listen wiring cannot silently
# revert to bare strstr(buf,"plex") or a single-port bind.
#
# Post busy-loop fix (parent Sweep 114–116): production gate is M-SEARCH-only via
# host/libmisterplex/gdm_filter.hpp (gdmShouldReply), wrapped by gdmIsDiscoveryProbe.
# Self-advertise bodies ("HTTP/1.0 200", "Content-Type: plex/media-player", bare
# "plex") must NOT match. The old inline strncmp(HTTP/) shape is still accepted if
# present, but is no longer required when gdm_filter.hpp owns the contract.
#
# Correctness/robustness only — answering GDM is NOT what populates the Plex Web
# cast picker (that is companionServer friendlyName selection on the PMS side).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMP="$ROOT/arm/misterplexd/companion.cpp"
ID="$ROOT/arm/misterplexd/player_identity.hpp"
FILTER="$ROOT/host/libmisterplex/gdm_filter.hpp"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "OK $*"; }

[[ -f "$COMP" && -f "$ID" ]] || fail "missing companion.cpp or player_identity.hpp"

# --- storm gate must exist and reject self-replies ---
grep -q 'gdmIsDiscoveryProbe' "$ID" || fail "player_identity.hpp missing gdmIsDiscoveryProbe"
# Prefer shared M-SEARCH-only filter (landed busy-loop fix). Legacy inline HTTP/
# rejection in player_identity.hpp is still accepted as an alternate shape.
if [[ -f "$FILTER" ]] && grep -q 'gdmShouldReply' "$FILTER"; then
  grep -q 'm-search' "$FILTER" || fail "gdm_filter.hpp must match M-SEARCH probes"
  grep -q 'gdmShouldReply' "$ID" || fail "player_identity.hpp must delegate to gdmShouldReply"
  grep -q 'kGdmAdvertiseShape' "$FILTER" || fail "gdm_filter.hpp missing advertise negative oracle"
  grep -q 'Content-Type: plex/media-player' "$FILTER" || \
    fail "gdm_filter advertise oracle must include media-player Content-Type"
  grep -q 'HTTP/1.0 200' "$FILTER" || \
    fail "gdm_filter advertise oracle must include HTTP/1.0 200 self-reply shape"
elif grep -q 'strncmp(buf, "HTTP/"' "$ID"; then
  grep -q 'Content-Type: plex/media-player' "$ID" || \
    fail "gate must reject media-player Content-Type replies"
else
  fail "gate must reject HTTP/ self-replies (gdm_filter.hpp or strncmp HTTP/)"
fi
# Production loop must call the gate — not a bare substring match.
grep -q 'gdmIsDiscoveryProbe(' "$COMP" || fail "companion.cpp must call gdmIsDiscoveryProbe"
if grep -nE 'strstr\([[:space:]]*buf[[:space:]]*,[[:space:]]*"plex"' "$COMP" >/dev/null; then
  fail "companion.cpp reintroduced bare strstr(buf,\"plex\") — storm regression"
fi
# Also ban bare plex match in the identity header.
if grep -nE 'strstr\([[:space:]]*buf[[:space:]]*,[[:space:]]*"plex"' "$ID" >/dev/null 2>&1; then
  fail "player_identity.hpp reintroduced bare strstr(buf,\"plex\")"
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
mkdir -p "$ROOT/build"
red_tmp="$ROOT/build/gdm_storm_red_fixture_$$.cpp"
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
