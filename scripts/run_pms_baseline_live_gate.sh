#!/usr/bin/env bash
# Safe live PMS Baseline/CAVLC contract gate.
#
# Token policy:
#   - PLEX_TOKEN must NOT be supplied on argv or pre-exported in the parent env.
#   - The script prompts with `read -rs` and passes the token only to the intended
#     curl config file, which is mode 0600 and removed on exit.
#   - Logs and stdout/stderr never print the token.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE="$ROOT/build/pms_baseline_probe"
WORK="$ROOT/build/pms-baseline-live-gate"
STAMP="$WORK/PASS.stamp"

usage() {
  cat <<'USAGE'
Usage:
  PLEX_BASE=http://plex:32400 MISTERPLEX_BASELINE_KEY=/library/metadata/N \
    scripts/run_pms_baseline_live_gate.sh

The Plex token is read interactively with a hidden prompt. Do NOT pass it on the
command line and do NOT export PLEX_TOKEN before invoking this script.

Offline test-only mode:
  MISTERPLEX_BASELINE_ANNEXB=path/to/stream.264 scripts/run_pms_baseline_live_gate.sh
USAGE
}

for arg in "$@"; do
  case "$arg" in
    -h|--help)
      usage
      exit 0
      ;;
    *token*|*TOKEN*|--token*|PLEX_TOKEN=*)
      echo "REFUSE pms_baseline_live_gate: token-like argv is forbidden; use the hidden prompt." >&2
      exit 2
      ;;
    *)
      echo "unknown argument: $arg" >&2
      usage >&2
      exit 2
      ;;
  esac
done

mkdir -p "$WORK"
SECRET_CFG="$WORK/curl-secret.$$.conf"
cleanup() {
  token=""
  rm -f "$SECRET_CFG"
}
trap cleanup EXIT

ensure_probe() {
  if [[ ! -x "$PROBE" ]]; then
    make -C "$ROOT" "$PROBE"
  fi
}

if [[ -n "${PLEX_TOKEN+x}" ]]; then
  echo "REFUSE pms_baseline_live_gate: PLEX_TOKEN is already exported; unset it and use the hidden prompt." >&2
  exit 2
fi

ensure_probe

if [[ -n "${MISTERPLEX_BASELINE_ANNEXB:-}" ]]; then
  exec "$PROBE" --annexb "$MISTERPLEX_BASELINE_ANNEXB"
fi

missing=()
[[ -n "${PLEX_BASE:-}" ]] || missing+=("PLEX_BASE")
[[ -n "${MISTERPLEX_BASELINE_KEY:-${PLEX_KEY:-}}" ]] || missing+=("MISTERPLEX_BASELINE_KEY")
command -v curl >/dev/null 2>&1 || missing+=("curl")
command -v ffmpeg >/dev/null 2>&1 || missing+=("ffmpeg")
if (( ${#missing[@]} )); then
  echo "SKIP-NOT-PASS pms_baseline_live_gate: missing ${missing[*]}; live PMS Baseline contract was NOT checked." >&2
  exit 77
fi
if [[ ! -r /dev/tty ]]; then
  echo "SKIP-NOT-PASS pms_baseline_live_gate: no controlling TTY for hidden token prompt; live PMS Baseline contract was NOT checked." >&2
  exit 77
fi

set +x
printf 'Plex token (hidden; not echoed): ' >/dev/tty
IFS= read -r -s token </dev/tty
printf '\n' >/dev/tty
set +x
if [[ -z "$token" ]]; then
  echo "SKIP-NOT-PASS pms_baseline_live_gate: empty token; live PMS Baseline contract was NOT checked." >&2
  exit 77
fi

BASE="${PLEX_BASE%/}"
KEY="${MISTERPLEX_BASELINE_KEY:-${PLEX_KEY:-}}"
CAPTURE_SECONDS="${MISTERPLEX_BASELINE_SECONDS:-14}"
if [[ ! "$CAPTURE_SECONDS" =~ ^[0-9]+$ || "$CAPTURE_SECONDS" -lt 4 || "$CAPTURE_SECONDS" -gt 30 ]]; then
  echo "REFUSE pms_baseline_live_gate: MISTERPLEX_BASELINE_SECONDS must be an integer 4..30" >&2
  exit 2
fi
SESSION="mplex-baseline-live-gate"
TS="$WORK/delivered.ts"
ANNEXB="$WORK/delivered.264"

URL="$(python3 - "$BASE" "$KEY" "$SESSION" <<'PY'
import sys
from urllib.parse import quote
base, key, session = sys.argv[1:4]
params = [
    ("hasMDE", "1"),
    ("path", key),
    ("mediaIndex", "0"),
    ("partIndex", "0"),
    ("protocol", "http"),
    ("fastSeek", "1"),
    ("directPlay", "0"),
    ("directStream", "0"),
    ("subtitleSize", "100"),
    ("audioBoost", "100"),
    ("location", "lan"),
    ("copyts", "1"),
    ("session", session),
    ("videoQuality", "60"),
    ("videoResolution", "640x480"),
    ("maxVideoBitrate", "2500"),
    ("videoCodec", "h264"),
    ("audioCodec", "aac"),
    ("videoProfile", "baseline"),
    ("videoLevel", "30"),
]
query = "&".join(f"{quote(k)}={quote(v, safe='')}" for k, v in params)
print(f"{base}/video/:/transcode/universal/start.mp4?{query}")
PY
)"

cat >"$SECRET_CFG" <<EOF
silent
show-error
globoff
insecure
location
http1.1
connect-timeout = 6
max-time = $((CAPTURE_SECONDS + 8))
header = "Accept: application/xml"
header = "X-Plex-Client-Identifier: misterplex"
header = "X-Plex-Product: Plex Web"
header = "X-Plex-Version: 4.125.0"
header = "X-Plex-Platform: Chrome"
header = "X-Plex-Platform-Version: 120.0"
header = "X-Plex-Device: Linux"
header = "X-Plex-Device-Name: Chrome"
header = "X-Plex-Client-Profile-Name: MiSTerPlex"
header = "X-Plex-Model: bundled"
header = "X-Plex-Provides: player"
header = "X-Plex-Session-Identifier: $SESSION"
header = "X-Plex-Token: $token"
url = "$URL"
output = "$TS"
EOF
chmod 600 "$SECRET_CFG"

set +e
curl -K "$SECRET_CFG"
curl_rc=$?
set -e
if [[ "$curl_rc" -ne 0 && "$curl_rc" -ne 28 ]]; then
  echo "FAIL pms_baseline_live_gate: curl failed rc=$curl_rc (token not printed)" >&2
  exit "$curl_rc"
fi
if [[ ! -s "$TS" ]]; then
  echo "FAIL pms_baseline_live_gate: no MPEG-TS bytes captured from PMS (token not printed)" >&2
  exit 1
fi

ffmpeg -hide_banner -loglevel error -nostdin \
  -i "$TS" -map 0:v:0 -t "$CAPTURE_SECONDS" -c:v copy -an -f h264 "$ANNEXB"

"$PROBE" --annexb "$ANNEXB"
{
  printf 'PMS_BASELINE_LIVE_PASS timestamp=%s\n' "$(date -Is)"
  printf 'base=%s\n' "$BASE"
  printf 'key=%s\n' "$KEY"
  printf 'seconds=%s\n' "$CAPTURE_SECONDS"
} >"$STAMP"
echo "pms_baseline_live_gate: PASS stamp=$STAMP"
