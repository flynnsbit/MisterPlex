#!/usr/bin/env bash
# RBG: (deleted) exe path counts as live daemon; trailing glob */misterplexd) is blind.
# n_daemon=0 + http=200 → matcher-blind FAIL (not OK, not 0.0 CPU).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../scripts/lib/live_daemon_enum.sh
source "$ROOT/scripts/lib/live_daemon_enum.sh"
# shellcheck source=../../scripts/pair_pin_resolve.inc.sh
source "$ROOT/scripts/pair_pin_resolve.inc.sh"

pass=0
fail=0
ok() { echo "OK   $*"; pass=$((pass + 1)); }
bad() { echo "FAIL $*"; fail=$((fail + 1)); }

echo "=== strip (deleted) ==="
got=$(live_daemon_strip_deleted "/media/fat/misterplex_v2/bin/misterplexd (deleted)")
if [ "$got" = "/media/fat/misterplex_v2/bin/misterplexd" ]; then
  ok "strip deleted suffix"
else
  bad "strip got='$got'"
fi

echo "=== exe_is_misterplexd ==="
if live_daemon_exe_is_misterplexd "/media/fat/misterplex_v2/bin/misterplexd (deleted)"; then
  ok "deleted path is misterplexd"
else
  bad "deleted path rejected"
fi
if live_daemon_exe_is_misterplexd "/media/fat/misterplex_v2/bin/misterplexd"; then
  ok "clean path is misterplexd"
else
  bad "clean path rejected"
fi
if live_daemon_exe_is_misterplexd "/media/fat/misterplex_v2/bin/misterplexd_supervise.sh"; then
  bad "supervise matched"
else
  ok "supervise rejected"
fi
if live_daemon_exe_is_misterplexd "/usr/bin/flock"; then
  bad "flock matched"
else
  ok "flock rejected"
fi

echo "=== trailing glob blindness (historic matcher) ==="
# Simulate case */misterplexd) against deleted path — must NOT match.
x="/media/fat/misterplex_v2/bin/misterplexd (deleted)"
match=0
case "$x" in
  */misterplexd) match=1 ;;
esac
if [ "$match" -eq 0 ]; then
  ok "historic */misterplexd) misses deleted (blindness reproduced)"
else
  bad "historic pattern unexpectedly matched deleted"
fi
# Required matcher
if live_daemon_exe_is_misterplexd "$x"; then
  ok "required matcher counts deleted"
else
  bad "required matcher missed deleted"
fi

echo "=== classify n=0 + http 200 = matcher blind FAIL ==="
set +e
out=$(live_daemon_classify 0 "" 200)
rc=$?
set -e
echo "  out=$out rc=$rc"
if [ "$rc" -eq 3 ] && echo "$out" | grep -q 'matcher blind'; then
  ok "n=0 http=200 → FAIL matcher-blind"
else
  bad "classify n0+200 got rc=$rc out=$out"
fi

set +e
out=$(live_daemon_classify 1 "865d4c8aaaaaaaaaaaaaaaaaaaaaaaaa" "")
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  ok "n=1 + md5 → OK"
else
  bad "n=1 classify rc=$rc"
fi

set +e
out=$(live_daemon_classify "" "" 200)
rc=$?
set -e
if [ "$rc" -eq 4 ] && echo "$out" | grep -q NO-DATA; then
  ok "empty n → NO-DATA"
else
  bad "empty n classify rc=$rc out=$out"
fi

echo "=== pair_pin accepts CURRENT 865d4c8a and PREV edc3 ==="
if pair_pin_daemon_accepted "865d4c8a"; then ok "865d4c8a accepted"; else bad "865d4c8a rejected"; fi
if pair_pin_daemon_accepted "edc3a46b9d1c6b86337deb90f896eb0f"; then ok "edc3 full accepted"; else bad "edc3 rejected"; fi
if pair_pin_daemon_accepted "deadbeefdeadbeefdeadbeefdeadbeef"; then bad "unknown accepted"; else ok "unknown rejected"; fi

echo "=== remote snippet contains deleted strip, not skip ==="
snip=$(live_daemon_remote_snippet)
if echo "$snip" | grep -q 'basename'; then ok "snippet uses basename"; else bad "no basename"; fi
if echo "$snip" | grep -q '(deleted)'; then ok "snippet handles deleted"; else bad "no deleted"; fi
if echo "$snip" | grep -qE 'continue.*deleted|skip.*deleted'; then
  # allow strip branch only
  if echo "$snip" | grep -q 'deleted=1'; then ok "deleted marks flag not skip-all"; else bad "may skip deleted"; fi
else
  ok "no skip-deleted continue pattern"
fi
# banned trailing case in ACTIVE code path of snippet (doc lines OK in other files)
if echo "$snip" | grep -qE 'case "\$x" in \*/misterplexd\)'; then
  bad "snippet still has trailing */misterplexd)"
else
  ok "snippet has no trailing */misterplexd)"
fi

echo "=== PASS=$pass FAIL=$fail ==="
if [ "$fail" -ne 0 ]; then
  echo "true rc=1"
  exit 1
fi
echo "true rc=0"
exit 0
