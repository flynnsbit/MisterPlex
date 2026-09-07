#!/usr/bin/env bash
# Real emitted bytes, not a successful profile header. Never expand tokens into argv.
set +x
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
limit_args=()
if [[ -n "${MISTERPLEX_BASELINE_MAX_AU_BYTES:-}" ]]; then
  limit_args=(--max-au-bytes "$MISTERPLEX_BASELINE_MAX_AU_BYTES")
fi
if [[ -n "${MISTERPLEX_BASELINE_MAX_VCL_RBSP_BYTES:-}" ]]; then
  limit_args+=(--max-vcl-rbsp-bytes "$MISTERPLEX_BASELINE_MAX_VCL_RBSP_BYTES")
fi
case "${MISTERPLEX_BASELINE_REQUIRE_LIMITED_BT601:-0}" in
  0) ;;
  1) limit_args+=(--require-limited-bt601) ;;
  *) echo "FAIL: MISTERPLEX_BASELINE_REQUIRE_LIMITED_BT601 must be0 or1" >&2; exit 2 ;;
esac
exec python3 "$ROOT/assets/plex-profiles/probe_pms.py" \
  --prototype "${MISTERPLEX_BASELINE_PROTOTYPE:-ip}" \
  --fps "${MISTERPLEX_BASELINE_FPS:-24}" \
  --filter "${MISTERPLEX_BASELINE_FILTER:-on}" \
  --seconds "${MISTERPLEX_BASELINE_SECONDS:-8}" \
  --stream-read-timeout "${MISTERPLEX_BASELINE_STREAM_READ_TIMEOUT:-30}" \
  --output "${MISTERPLEX_BASELINE_OUTPUT:-build/pms-profile-capture}" "${limit_args[@]}" "$@"
