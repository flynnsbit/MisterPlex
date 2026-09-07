#!/usr/bin/env bash
# One case; only the explicit new-fixture scope can authorize reversible Part selection.
set +x
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
if [[ $# -ne 1 || ( "$1" != off && "$1" != on ) ]]; then
  echo "FAIL: choose exactly one authorized subtitle case: off or on" >&2
  exit 2
fi
if [[ -z "${MISTERPLEX_BASELINE_KEY:-}" ]]; then
  echo "FAIL: set the explicitly selected lab fixture's MISTERPLEX_BASELINE_KEY" >&2
  exit 2
fi
if [[ -z "${MISTERPLEX_LAB_FIXTURE_SCOPE:-}" ]]; then
  echo "FAIL: set MISTERPLEX_LAB_FIXTURE_SCOPE to the explicit new-fixture allowlist" >&2
  exit 2
fi
subtitle_args=()
if [[ "$1" == on ]]; then
  if [[ ! "${MISTERPLEX_BASELINE_SUBTITLE_STREAM_ID:-}" =~ ^[1-9][0-9]*$ ]]; then
    echo "FAIL: set the actual positive MISTERPLEX_BASELINE_SUBTITLE_STREAM_ID from metadata" >&2
    exit 2
  fi
  subtitle_args=(--subtitle-stream-id "$MISTERPLEX_BASELINE_SUBTITLE_STREAM_ID")
fi
exec python3 assets/plex-profiles/probe_pms.py \
  --prototype idr --mode 240p --fps 24000/1001 --filter off \
  --seconds 8 --offset 0 --stream-read-timeout 30 \
  --require-source-codec mpeg2video --require-full-size \
  --lab-fixture-scope "$MISTERPLEX_LAB_FIXTURE_SCOPE" \
  --max-au-bytes 8192 --max-vcl-rbsp-bytes 8192 \
  --output "build/targeted-23976-idr-off-subtitles-$1" "${subtitle_args[@]}"
