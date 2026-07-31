#!/usr/bin/env bash
# RED-before-GREEN: deleted-exe path must still count as misterplexd.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=../../scripts/lib/live_daemon_enum.sh
source "$ROOT/scripts/lib/live_daemon_enum.sh"

fails=0
check() {
  if ! eval "$1"; then
    echo "FAIL: $1"
    fails=$((fails + 1))
  fi
}

# Pure path matcher (the install-script footgun).
check 'live_daemon_exe_is_ours "/media/fat/misterplex_v2/bin/misterplexd"'
check 'live_daemon_exe_is_ours "/media/fat/misterplex_v2/bin/misterplexd (deleted)"'
check 'live_daemon_exe_is_ours "/media/fat/misterplex_v2/bin/misterplexd(deleted)"' # no space variant
if live_daemon_exe_is_ours "/media/fat/misterplex_v2/bin/ffmpeg"; then
  echo "FAIL: ffmpeg must not match"
  fails=$((fails + 1))
fi
if live_daemon_exe_is_ours "/media/fat/misterplex_v2/bin/other"; then
  echo "FAIL: other must not match"
  fails=$((fails + 1))
fi

# Prove the BAD glob would fail (document the footgun).
bad_match() {
  path=$1
  case "$path" in
    */misterplexd) return 0 ;;
    *) return 1 ;;
  esac
}
if bad_match "/media/fat/misterplex_v2/bin/misterplexd (deleted)"; then
  echo "FAIL: unexpected — bad glob matched deleted path"
  fails=$((fails + 1))
else
  echo "OK red-check: bad glob */misterplexd does NOT match '...misterplexd (deleted)'"
fi
if ! bad_match "/media/fat/misterplex_v2/bin/misterplexd"; then
  echo "FAIL: bad glob should still match clean path"
  fails=$((fails + 1))
fi

if [ "$fails" -ne 0 ]; then
  echo "test_live_daemon_enum: $fails FAIL(s)"
  exit 1
fi
echo "test_live_daemon_enum: OK"
exit 0
