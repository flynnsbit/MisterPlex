#!/bin/sh
# ON DEVICE: install supervise script + additive idempotent hook lines. No bootcore.
set -eu
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
SUP=/media/fat/misterplex/bin/misterplexd_supervise.sh
LINE="nohup /media/fat/misterplex/bin/misterplexd_supervise.sh >>/media/fat/misterplex/misterplexd_supervise.log 2>&1 &"
MARKER="misterplexd_supervise.sh"

install_one() {
  hook=$1
  [ -f "$hook" ] || { echo "MISSING $hook"; return 1; }
  bak="${hook}.bak-before-supervise-${STAMP}"
  cp -a "$hook" "$bak"
  echo "bak=$bak"
  # Remove bare misterplexd start lines AND old supervise lines, then append one supervise line
  # Keep other content. Idempotent: single LINE at end.
  tmp=$(mktemp)
  # drop lines that start the daemon or supervisor
  grep -v 'misterplex/bin/misterplexd' "$hook" | grep -v 'misterplexd_supervise' >"$tmp" || true
  # if file ended without newline, ensure
  printf '%s\n' "$LINE" >>"$tmp"
  # Avoid double if somehow
  # Count supervise lines
  n=$(grep -c "$MARKER" "$tmp" || true)
  if [ "$n" -ne 1 ]; then
    echo "FAIL hook supervise count=$n"
    rm -f "$tmp"
    return 2
  fi
  mv -f "$tmp" "$hook"
  chmod +x "$hook" 2>/dev/null || true
  echo "hook_ok=$hook"
  grep -n "$MARKER" "$hook" || true
}

# Ensure supervise binary present (caller scp's it)
[ -x "$SUP" ] || chmod +x "$SUP" 2>/dev/null || true
[ -x "$SUP" ] || { echo "FAIL missing $SUP"; exit 3; }

install_one /media/fat/linux/_user-startup.sh
install_one /media/fat/linux/user-startup.sh

# Verify no bootcore change
if grep -qE '^[[:space:]]*bootcore=' /media/fat/linux/*.ini 2>/dev/null; then
  echo "NOTE bootcore active somewhere (not modified by us)"
fi
grep -n bootcore /media/fat/MiSTer.ini 2>/dev/null | head -5 || true
echo HOOK_SUPERVISE_INSTALLED
