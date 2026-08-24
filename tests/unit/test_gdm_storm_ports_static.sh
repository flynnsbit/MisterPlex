#!/usr/bin/env bash
# Pin GDM dual-listen + M-SEARCH-only reply so a "contains plex" catch-all
# cannot come back.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMP="$ROOT/arm/misterplexd/companion.cpp"
FILT="$ROOT/host/libmisterplex/gdm_filter.hpp"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "OK: $*"; }

[[ -f "$COMP" && -f "$FILT" ]] || fail "missing companion.cpp or gdm_filter.hpp"

grep -q 'kGdmListenPorts' "$FILT" || fail "gdm_filter.hpp missing kGdmListenPorts"
grep -q '32412' "$FILT" || fail "kGdmListenPorts missing 32412"
grep -q '32414' "$FILT" || fail "kGdmListenPorts missing 32414"
grep -q 'kGdmListenPorts' "$COMP" || fail "companion gdmLoop must iterate kGdmListenPorts"
pass "kGdmListenPorts includes 32412 and 32414"

grep -q 'gdmShouldReply(' "$COMP" || fail "companion.cpp must call gdmShouldReply"
if grep -n 'strstr(buf, "plex")' "$COMP"; then
  fail "companion.cpp still replies on bare substring plex"
fi
pass "storm gate gdmShouldReply; no bare strstr(buf,\"plex\")"

grep -q 'gdmIsDiscoveryProbe' "$FILT" || fail "gdm_filter.hpp missing gdmIsDiscoveryProbe"
grep -q 'strncmp(buf, "HTTP/"' "$FILT" || fail "gdmIsDiscoveryProbe must reject HTTP/ replies"
grep -q 'Content-Type: plex/media-player' "$FILT" || fail "gdmIsDiscoveryProbe must reject media-player replies"
pass "gdmIsDiscoveryProbe rejects self-advertise"

echo "test_gdm_storm_ports_static: OK"
