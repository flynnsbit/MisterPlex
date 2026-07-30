#!/bin/sh
set -eu
ID_WANT=misterplex-dev
BIN=/media/fat/misterplex/bin/misterplexd
CONF=/media/fat/misterplex/misterplex.conf
LINE="$BIN --name MiSTerPlex --id ${ID_WANT} --port 3005 --conf $CONF >>/media/fat/misterplex/misterplexd.log 2>&1 &"
TAG=$(date -u +%Y%m%dT%H%M%SZ)
EXPECT_MD5="${EXPECT_MD5:-a56bbc3c04863079ac0b29f81c45ceba}"

test -x "$BIN"
got=$(md5sum "$BIN" | awk '{print $1}')
echo "bin_md5=$got"
[ "$got" = "$EXPECT_MD5" ] || { echo "FAIL bin md5 want=$EXPECT_MD5 got=$got" >&2; exit 2; }
test -f "$CONF"

install_one() {
  hook=$1
  test -f "$hook" || { mkdir -p "$(dirname "$hook")"; printf '%s\n' '#!/bin/sh' "echo \"***\" \$1 \"***\"" >"$hook"; chmod +x "$hook"; }
  bak="${hook}.bak-before-misterplex-hook-${TAG}"
  cp -a "$hook" "$bak"
  echo "backup_ok $bak"

  if grep -q 'misterplex/bin/misterplexd' "$hook" 2>/dev/null && \
     grep -qE -- "--id[= ]${ID_WANT}( |$)" "$hook" 2>/dev/null; then
    n=$(grep -c 'misterplex/bin/misterplexd' "$hook" || true)
    if [ "$n" -eq 1 ]; then
      echo "hook_ok_noop $hook"
      return 0
    fi
  fi

  grep -v 'misterplex/bin/misterplexd' "$hook" >"${hook}.new" || true
  printf '\n# MiSTerPlex companion + media (hook restore %s)\n%s\n' "$TAG" "$LINE" >>"${hook}.new"
  mv -f "${hook}.new" "$hook"
  chmod +x "$hook"
  echo "hook_rewritten $hook"
}

install_one /media/fat/linux/_user-startup.sh
install_one /media/fat/linux/user-startup.sh

verify_one() {
  hook=$1
  echo "=== verify $hook ==="
  grep -n 'misterplex' "$hook" || true
  n=$(grep -c 'misterplex/bin/misterplexd' "$hook" || true)
  [ "$n" = "1" ] || { echo "FAIL count=$n want=1 $hook" >&2; exit 3; }
  grep -qE -- "--id[= ]${ID_WANT}( |$)" "$hook" || { echo "FAIL id $hook" >&2; exit 7; }
  grep -q -- '--port 3005' "$hook" || { echo "FAIL port $hook" >&2; exit 4; }
  grep -q -- "--conf $CONF" "$hook" || { echo "FAIL conf $hook" >&2; exit 5; }
  grep -q -- "$BIN" "$hook" || { echo "FAIL bin path $hook" >&2; exit 6; }
  if grep -qE -- '--id[= ]misterplex-183( |$)' "$hook"; then
    echo "FAIL still misterplex-183 $hook" >&2
    exit 7
  fi
  echo "verify_ok $hook"
}

verify_one /media/fat/linux/_user-startup.sh
verify_one /media/fat/linux/user-startup.sh

if grep -qE '^[[:space:]]*bootcore=' /media/fat/MiSTer.ini 2>/dev/null; then
  echo "FAIL bootcore active (we must not set it)" >&2
  exit 8
fi
echo "bootcore_still_inactive_ok"

echo "conf_keys=$(grep -E '^(PRESENT|DECODE|STREAM|OSD_CONTROL)=' "$CONF" | tr '\n' ' ')"
grep -qE '^[[:space:]]*PRESENT=fpga' "$CONF"
grep -qE '^[[:space:]]*DECODE=320x240' "$CONF"
echo "CORENAME=$(cat /tmp/CORENAME 2>/dev/null || true)"
echo HOOK_INSTALL_OK
