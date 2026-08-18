#!/usr/bin/env bash
# Unit: rbf_daemon_pairs select + live-glass tag. No device, no Quartus.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/scripts/lib/rbf_pair.sh"
WATCH="$ROOT/scripts/misterplex_core_watch.sh"
WORK="$ROOT/build/core-watch-pairs"
fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$LIB" ] || fail "missing $LIB"
# shellcheck disable=SC1090
. "$LIB"

rm -rf "$WORK"
mkdir -p "$WORK/bin"
for b in misterplexd misterplexd.480p misterplexd.720p24 \
         misterplexd.crt240p15 misterplexd.crt480i misterplexd.weird; do
  printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/$b"
  chmod +x "$WORK/bin/$b"
done

# Fixture: 2-col v0.7.0 + 3-col CRT placeholders (not live hashes).
PAIRS="$WORK/rbf_daemon_pairs.txt"
cat >"$PAIRS" <<EOF
# comment must be ignored
07f54d9f8f0eda2fe75d9cc314f6de54 $WORK/bin/misterplexd.480p
03f1b95ac67a568f24193234ea8cb072 $WORK/bin/misterplexd.720p24 l4
c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0 $WORK/bin/misterplexd.crt240p15 crt240p15
d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1 $WORK/bin/misterplexd.crt480i crt480i
e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2 $WORK/bin/misterplexd.weird not-a-glass
EOF

DEFAULT="$WORK/bin/misterplexd"
MD5_480=07f54d9f8f0eda2fe75d9cc314f6de54
MD5_720=03f1b95ac67a568f24193234ea8cb072
MD5_CRT=c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0
MD5_480I=d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1
MD5_BADTAG=e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2
MD5_UNK=ffffffffffffffffffffffffffffffff

# --- Permanent red twin: old hardcoded-md5 glass must not pass CRT ---
legacy_glass_hardcoded() {
  if [ "$1" = "$MD5_720" ]; then
    printf '%s\n' l4
  else
    printf '%s\n' true480
  fi
}
[ "$(legacy_glass_hardcoded "$MD5_CRT")" = "crt240p15" ] && \
  fail "red twin unexpectedly GREEN (hardcoded glass returned crt240p15)"
echo "RED TWIN OK: hardcoded md5 glass is not crt240p15"

check_pair() {
  local md5=$1 want_bin=$2 want_glass=$3 label=$4
  rbf_pair_lookup "$PAIRS" "$md5" "$DEFAULT"
  [ "$rbf_pair_bin" = "$want_bin" ] || \
    fail "$label bin=$rbf_pair_bin want=$want_bin"
  case "$want_glass" in
    l4|L4)
      case "$rbf_pair_glass" in
        l4|L4) ;;
        *) fail "$label glass=$rbf_pair_glass want l4|L4" ;;
      esac
      ;;
    *)
      [ "$rbf_pair_glass" = "$want_glass" ] || \
        fail "$label glass=$rbf_pair_glass want=$want_glass"
      ;;
  esac
  echo "OK $label bin=$(basename "$rbf_pair_bin") glass=$rbf_pair_glass"
}

# 03f1b95a → 720p24 daemon + L4/l4
check_pair "$MD5_720" "$WORK/bin/misterplexd.720p24" l4 "03f1b95a-3col-l4"

# 07f54d9f-style 2-col → 480p daemon + true480
check_pair "$MD5_480" "$WORK/bin/misterplexd.480p" true480 "07f54d9f-2col-true480"

# 3-col CRT placeholders (not live hashes)
check_pair "$MD5_CRT" "$WORK/bin/misterplexd.crt240p15" crt240p15 "3col-crt240p15"
check_pair "$MD5_480I" "$WORK/bin/misterplexd.crt480i" crt480i "3col-crt480i"

# unknown / missing tag → default or paired bin + true480
check_pair "$MD5_UNK" "$DEFAULT" true480 "unknown-md5-default"
[ "$rbf_pair_hit" = "0" ] || fail "unknown md5 should miss pairs"
check_pair "$MD5_BADTAG" "$WORK/bin/misterplexd.weird" true480 "unknown-tag-true480"

# 2-col 720p24 (v0.7.0 field file): still pin l4
PAIRS2="$WORK/pairs-2col-only.txt"
cat >"$PAIRS2" <<EOF
07f54d9f8f0eda2fe75d9cc314f6de54 $WORK/bin/misterplexd.480p
03f1b95ac67a568f24193234ea8cb072 $WORK/bin/misterplexd.720p24
EOF
rbf_pair_lookup "$PAIRS2" "$MD5_720" "$DEFAULT"
case "$rbf_pair_glass" in
  l4|L4) echo "OK 2col-03f1b95a-legacy-l4 glass=$rbf_pair_glass" ;;
  *) fail "2-col 03f1b95a glass=$rbf_pair_glass want l4|L4 (v0.7.0 pairs)" ;;
esac
rbf_pair_lookup "$PAIRS2" "$MD5_480" "$DEFAULT"
[ "$rbf_pair_glass" = "true480" ] || fail "2-col 07f54d9f glass=$rbf_pair_glass"

# Wrong glass tag on a CRT row must fail this assertion (column wins).
WRONG="$WORK/pairs-wrong-glass.txt"
cat >"$WRONG" <<EOF
$MD5_CRT $WORK/bin/misterplexd.crt240p15 true480
EOF
rbf_pair_lookup "$WRONG" "$MD5_CRT" "$DEFAULT"
if [ "$rbf_pair_glass" = "crt240p15" ]; then
  fail "wrong-tag row unexpectedly yielded crt240p15"
fi
[ "$rbf_pair_glass" = "true480" ] || fail "wrong-tag glass=$rbf_pair_glass"
echo "OK wrong-glass-tag-is-not-crt240p15 (got $rbf_pair_glass)"

# live-glass write
GLASS_OUT="$WORK/misterplex-live-glass"
rbf_pair_lookup "$PAIRS" "$MD5_CRT" "$DEFAULT"
rbf_pair_write_glass "$rbf_pair_glass" "$GLASS_OUT"
[ "$(tr -d '\r\n' <"$GLASS_OUT")" = "crt240p15" ] || \
  fail "live-glass file=$(cat "$GLASS_OUT")"
echo "OK write-live-glass crt240p15"

# CORENAME / RBFNAME: Plex_* CRT names are Plex cores (existing case pattern).
for n in Plex plex Plex_240p15 Plex_480i Plex_15k Plex_720p24 Plex_480p \
         plex_foo Plex-bar /media/fat/_Utility/Plex_15k.rbf Plex_15k.RBF; do
  rbf_pair_is_plex_name "$n" || fail "is_plex_name should match: $n"
done
for n in MENU Menu NES SNES Plexx 240p15 '' misterplex; do
  if rbf_pair_is_plex_name "$n"; then
    fail "is_plex_name should reject: $n"
  fi
done
echo "OK CORENAME Plex_240p15/Plex_480i/Plex_15k"

# Watch is not sourcable (main loop). It must load the lib and keep the lock.
[ -f "$WATCH" ] || fail "missing $WATCH"
grep -q 'rbf_pair.sh' "$WATCH" || fail "watch does not source rbf_pair.sh"
grep -q 'misterplex-watch.lock' "$WATCH" || fail "watch missing lock dir"
grep -q 'WATCH_DUP' "$WATCH" || fail "watch missing WATCH_DUP second-watcher exit"
# Hardcoded L4-only write must be gone from the watch script.
if grep -n 'echo L4 > /tmp/misterplex-live-glass' "$WATCH"; then
  fail "watch still hardcodes L4 live-glass"
fi
echo "OK watch sources lib + lock + no hardcoded L4 pin"

# Shipping pairs: digital md5↔bin rows unchanged; 720p24 may carry l4.
SHIP="$ROOT/scripts/rbf_daemon_pairs.txt"
[ -f "$SHIP" ] || fail "missing $SHIP"
grep -q '^07f54d9f8f0eda2fe75d9cc314f6de54 /media/fat/misterplex/bin/misterplexd.480p' "$SHIP" || \
  fail "shipping 480p md5↔bin row changed"
grep -q '^03f1b95ac67a568f24193234ea8cb072 /media/fat/misterplex/bin/misterplexd.720p24' "$SHIP" || \
  fail "shipping 720p24 md5↔bin row changed"
echo "OK shipping digital md5↔bin rows"

echo "test_core_watch_pairs: GREEN"
