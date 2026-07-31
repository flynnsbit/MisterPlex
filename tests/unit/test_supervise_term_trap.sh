#!/usr/bin/env bash
# RBG: supervisor TERM must not exit 0 (silent daily-driver disarm).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$ROOT/build/supervise-term-trap"
rm -rf "$WORK"
mkdir -p "$WORK/bin" "$WORK"
pass=0
fail=0
ok() { echo "OK   $*"; pass=$((pass + 1)); }
bad() { echo "FAIL $*"; fail=$((fail + 1)); }

echo "=== static: misterplexd_supervise + plexctl write_supervisor reject exit 0 on TERM ==="
sup=$(cat "$ROOT/scripts/misterplexd_supervise.sh")
if echo "$sup" | grep -q "SUPERVISE_SIGNAL"; then
  ok "supervise logs SUPERVISE_SIGNAL"
else
  bad "missing SUPERVISE_SIGNAL log"
fi
if echo "$sup" | grep -E "trap .* exit 0" | grep -v '^#' >/dev/null; then
  bad "supervise still has trap ... exit 0"
else
  ok "no trap exit 0 in misterplexd_supervise"
fi
if echo "$sup" | grep -qE "TERM 143|_on_supervise_signal TERM"; then
  ok "supervise TERM maps to 143"
else
  bad "supervise missing TERM→143 mapping"
fi

pct=$(cat "$ROOT/scripts/plexctl.sh")
if echo "$pct" | grep -q "SUPERVISE_SIGNAL"; then
  ok "plexctl supervisor template logs SUPERVISE_SIGNAL"
else
  bad "plexctl missing SUPERVISE_SIGNAL"
fi
# The heredoc previously had: trap '... exit 0' TERM INT
if echo "$pct" | grep -E "trap '.*exit 0'" | grep -v '^\s*#' >/dev/null; then
  bad "plexctl still embeds trap exit 0"
else
  ok "plexctl no trap exit 0"
fi

echo "=== dynamic: TERM child-less supervise script exits non-zero ==="
# Minimal clone of the signal contract
cat >"$WORK/sup.sh" <<'EOF'
#!/bin/sh
SUPLOG="$1"
child=""
resume_stopped_main() { :; }
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
_on_supervise_signal() {
  sig="$1"
  code="$2"
  echo "$(ts) SUPERVISE_SIGNAL sig=$sig killing_child=${child:-none} — exit $code (not silent disarm)" >>"$SUPLOG"
  if [ -n "${child:-}" ]; then
    kill "$child" 2>/dev/null || true
  fi
  resume_stopped_main
  exit "$code"
}
trap '_on_supervise_signal TERM 143' TERM
trap '_on_supervise_signal INT 130' INT
# hang until signal
sleep 30 &
child=$!
wait "$child"
exit 0
EOF
chmod +x "$WORK/sup.sh"
: >"$WORK/sup.log"
set +e
"$WORK/sup.sh" "$WORK/sup.log" &
sp=$!
sleep 0.2
kill -TERM "$sp" 2>/dev/null
wait "$sp"
rc=$?
set -e
echo "  supervise true rc=$rc"
echo "  log:"; sed 's/^/    /' "$WORK/sup.log" || true
if [ "$rc" -eq 143 ]; then
  ok "TERM → rc=143"
else
  bad "TERM rc=$rc want 143"
fi
if grep -q 'SUPERVISE_SIGNAL sig=TERM' "$WORK/sup.log"; then
  ok "log has SUPERVISE_SIGNAL TERM"
else
  bad "log missing SUPERVISE_SIGNAL"
fi
# Historic defect: exit 0 on TERM
cat >"$WORK/bad.sh" <<'EOF'
#!/bin/sh
trap 'exit 0' TERM
sleep 30 &
wait
EOF
chmod +x "$WORK/bad.sh"
set +e
"$WORK/bad.sh" &
bp=$!
sleep 0.2
kill -TERM "$bp" 2>/dev/null
wait "$bp"
brc=$?
set -e
echo "  historic trap exit 0 → true rc=$brc"
if [ "$brc" -eq 0 ]; then
  ok "historic silent-disarm defect reproduced (rc=0)"
else
  bad "historic trap did not exit 0 (rc=$brc)"
fi

echo "=== PASS=$pass FAIL=$fail ==="
if [ "$fail" -ne 0 ]; then
  echo "true rc=1"
  exit 1
fi
echo "true rc=0"
exit 0
