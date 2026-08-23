#!/usr/bin/env bash
# L8: 127.0.0.1 and *.plex.direct must rewrite to http://192.168.2.1:32400.
# GREEN = production buildPlexBase. RED = frozen old isUnreachableHost.
# Soft-skip is not a pass. Do not weaken if w-arm has not landed.
set -u
set -o pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fails=0

make -C "$ROOT" "$ROOT/build/test_pms_base_rewrite" "$ROOT/build/test_pms_base_rewrite_red"

set +e
GREEN_OUT=$("$ROOT/build/test_pms_base_rewrite" 2>&1)
GREEN_RC=$?
set -e
printf '%s\n' "$GREEN_OUT"
echo "pms_base_rewrite GREEN true rc=$GREEN_RC"
if [ "$GREEN_RC" -ne 0 ]; then
  echo "GREEN PMS rewrite BLOCKED (old isUnreachableHost leaves 127 as the base)" >&2
  fails=$((fails + 1))
fi

set +e
RED_OUT=$("$ROOT/build/test_pms_base_rewrite_red" 2>&1)
RED_RC=$?
set -e
printf '%s\n' "$RED_OUT"
echo "pms_base_rewrite RED (old isUnreachableHost) true rc=$RED_RC"
if [ "$RED_RC" -eq 0 ]; then
  echo "FAIL analog: old isUnreachableHost unexpectedly rewrote 127 / plex.direct" >&2
  fails=$((fails + 1))
elif ! printf '%s\n' "$RED_OUT" | grep -q "127.0.0.1"; then
  echo "FAIL RED twin must quote leftover 127 base" >&2
  fails=$((fails + 1))
else
  echo "OK RED: old isUnreachableHost leaves 127 as the base"
fi

if [ "$fails" -ne 0 ]; then
  echo "test_pms_base_rewrite: $fails failure(s)" >&2
  exit 1
fi
echo "test_pms_base_rewrite: OK"
exit 0
