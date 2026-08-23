#!/usr/bin/env bash
# Landmine 2: leftover L4 PLXJ 0x504C584A at 0x3047F130 with frozen PLXD must
# not pair the 720p daemon onto Plex_480p / Plex_240p15 / Plex_480i.
# Pair by Main argv / RBFNAME Utility path / MISTERPLEX_LIVE_RBF.
# Negative: a LIVE changing L4 PLXD still classifies L4.
set -u
set -o pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NAMED="$ROOT/scripts/misterplex_named_rbf.sh"
PAIR="$ROOT/scripts/misterplex_pair_conf.sh"
WATCH="$ROOT/scripts/misterplex_core_watch.sh"
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
ok() { echo "OK: $*"; }

[ -f "$NAMED" ] || { echo "missing $NAMED" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
ut="$work/Utility"
mkdir -p "$ut"
# Dummy named siblings — resolve only needs -f, not a real bitstream.
: >"$ut/Plex_480p.rbf"
: >"$ut/Plex_240p15.rbf"
: >"$ut/Plex_480i.rbf"
: >"$ut/Plex_720p24.rbf"
echo Plex >"$work/CORENAME"
echo Plex >"$work/RBFNAME"

# Busybox-style devmem stub. Sample index is per-address so A/B can differ.
stub="$work/devmem"
cat >"$stub" <<'STUB'
#!/bin/sh
addr=$1
dir=${MISTERPLEX_DEVMEM_STATE:-/tmp/mplex-devmem-state}
mkdir -p "$dir"
key=$(echo "$addr" | tr 'a-f' 'A-F' | tr -d 'X#')
nfile="$dir/$key.n"
n=$(cat "$nfile" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" >"$nfile"
pick() {
  a=$1
  b=$2
  if [ "$n" -le 1 ]; then
    echo "$a"
  else
    echo "$b"
  fi
}
case "$key" in
  *3047F12C*) pick "${FAKE_L4_PLXD_A:-0x00000000}" "${FAKE_L4_PLXD_B:-${FAKE_L4_PLXD_A:-0x00000000}}" ;;
  *3007F128*) pick "${FAKE_T480_PLXD_A:-0x00000000}" "${FAKE_T480_PLXD_B:-${FAKE_T480_PLXD_A:-0x00000000}}" ;;
  *300FF128*) pick "${FAKE_T480B_PLXD_A:-0x00000000}" "${FAKE_T480B_PLXD_B:-${FAKE_T480B_PLXD_A:-0x00000000}}" ;;
  *3047F130*) echo "${FAKE_L4_PLXJ:-0x00000000}" ;;
  *3047F100*) echo "${FAKE_L4_PLXS:-0x00000000}" ;;
  *3007F100*) echo "${FAKE_T480_PLXS:-0x00000000}" ;;
  *300FF100*) echo "${FAKE_T480B_PLXS:-0x00000000}" ;;
  *) echo 0x00000000 ;;
esac
STUB
chmod +x "$stub"

reset_stub() {
  rm -rf "$work/devmem-state"
  mkdir -p "$work/devmem-state"
}

export PATH="$work:$PATH"
export MISTERPLEX_UTILITY="$ut"
export MISTERPLEX_LIVE_RBF="$ut/Plex_480p.rbf"
export RBFNAME_FILE="$work/RBFNAME"
export CORENAME_FILE="$work/CORENAME"
export MISTERPLEX_DEVMEM="$stub"
export MISTERPLEX_DEVMEM_STATE="$work/devmem-state"
export MISTERPLEX_GLASS_SAMPLE_S=0
export MISTERPLEX_MAIN_ARGV=""
# Leftover L4 PLXJ, frozen PLXD (the landmine).
export FAKE_L4_PLXJ=0x504C584A
export FAKE_L4_PLXD_A=0x504C5844
export FAKE_L4_PLXD_B=0x504C5844
export FAKE_T480_PLXD_A=0x00000000
export FAKE_T480_PLXD_B=0x00000000
export FAKE_T480B_PLXD_A=0x00000000
export FAKE_T480B_PLXD_B=0x00000000
export FAKE_L4_PLXS=0x504C5853
export FAKE_T480_PLXS=0x00000000
export FAKE_T480B_PLXS=0x00000000

# shellcheck disable=SC1090
. "$NAMED"
# shellcheck disable=SC1090
. "$PAIR"

want_rbf() {
  got=$1
  want=$2
  tag=$3
  case "$got" in
    *"$want") ok "$tag -> $want" ;;
    *) fail "$tag: got '$got' want '*$want'" ;;
  esac
}

# --- 1. Main argv Plex_480p beats leftover PLXJ ---
reset_stub
export MISTERPLEX_MAIN_ARGV="/media/fat/MiSTer /media/fat/_Utility/Plex_480p.rbf"
echo Plex >"$RBFNAME_FILE"
rbf=$(resolve_loaded_rbf)
want_rbf "$rbf" "Plex_480p.rbf" "Main argv Plex_480p leftover PLXJ"
if live_glass_is_l4; then
  fail "leftover PLXJ + loaded Plex_480p must not classify L4"
else
  ok "live_glass not L4 for loaded Plex_480p leftover PLXJ"
fi

# --- 2. CORENAME=Plex, no argv: LIVE_RBF 480p beats leftover PLXJ ---
reset_stub
export MISTERPLEX_MAIN_ARGV=""
echo Plex >"$RBFNAME_FILE"
rbf=$(resolve_loaded_rbf)
want_rbf "$rbf" "Plex_480p.rbf" "LIVE_RBF 480p leftover PLXJ (CORENAME=Plex)"
if live_glass_is_l4; then
  fail "leftover PLXJ + frozen PLXD + Plex_480p LIVE_RBF must not classify L4"
else
  ok "sticky leftover PLXJ does not pin L4 when LIVE_RBF is 480p"
fi

# --- 3. RBFNAME Utility path Plex_480p ---
reset_stub
export MISTERPLEX_MAIN_ARGV=""
echo "/media/fat/_Utility/Plex_480p.rbf" >"$RBFNAME_FILE"
rbf=$(resolve_loaded_rbf)
want_rbf "$rbf" "Plex_480p.rbf" "RBFNAME Utility path Plex_480p leftover PLXJ"

# --- 4. Plex_240p15 ---
reset_stub
export MISTERPLEX_MAIN_ARGV="/media/fat/MiSTer /media/fat/_Utility/Plex_240p15.rbf"
echo Plex >"$RBFNAME_FILE"
rbf=$(resolve_loaded_rbf)
want_rbf "$rbf" "Plex_240p15.rbf" "Main argv Plex_240p15 leftover PLXJ"
if live_glass_is_l4; then
  fail "leftover PLXJ + loaded Plex_240p15 must not classify L4"
else
  ok "live_glass not L4 for loaded Plex_240p15"
fi

# --- 5. Plex_480i ---
reset_stub
export MISTERPLEX_MAIN_ARGV="/media/fat/MiSTer /media/fat/_Utility/Plex_480i.rbf"
echo Plex >"$RBFNAME_FILE"
rbf=$(resolve_loaded_rbf)
want_rbf "$rbf" "Plex_480i.rbf" "Main argv Plex_480i leftover PLXJ"
if live_glass_is_l4; then
  fail "leftover PLXJ + loaded Plex_480i must not classify L4"
else
  ok "live_glass not L4 for loaded Plex_480i"
fi

# --- 6. Changing 480p PLXD beats leftover PLXJ (generic Plex) ---
export MISTERPLEX_MAIN_ARGV=""
echo Plex >"$RBFNAME_FILE"
export FAKE_T480_PLXD_A=0x00000010
export FAKE_T480_PLXD_B=0x00000011
export MISTERPLEX_LIVE_RBF="$ut/Plex_480p.rbf"
reset_stub
if live_glass_is_l4; then
  fail "changing 480p PLXD must not classify L4 (leftover PLXJ)"
else
  ok "changing 480p PLXD beats leftover PLXJ"
fi
reset_stub
rbf=$(resolve_loaded_rbf)
want_rbf "$rbf" "Plex_480p.rbf" "changing 480p PLXD leftover PLXJ"
export FAKE_T480_PLXD_A=0x00000000
export FAKE_T480_PLXD_B=0x00000000

# --- 7. Negative guard: LIVE changing L4 PLXD still L4 (720p parked, not the other way) ---
reset_stub
export MISTERPLEX_MAIN_ARGV=""
echo Plex >"$RBFNAME_FILE"
export FAKE_L4_PLXD_A=0x00000001
export FAKE_L4_PLXD_B=0x00000002
export FAKE_T480_PLXS=0x504C5853
if live_glass_is_l4; then
  ok "changing L4 PLXD still classifies L4 (negative guard)"
else
  fail "LIVE changing L4 PLXD must still classify L4"
fi
reset_stub
rbf=$(resolve_loaded_rbf)
want_rbf "$rbf" "Plex_720p24.rbf" "changing L4 PLXD pairs 720p24"
export FAKE_L4_PLXD_A=0x504C5844
export FAKE_L4_PLXD_B=0x504C5844
export FAKE_T480_PLXS=0x00000000

# --- 8. Named 720p24 file still pairs L4 even with leftover 480p magics frozen ---
reset_stub
export MISTERPLEX_MAIN_ARGV="/media/fat/MiSTer /media/fat/_Utility/Plex_720p24.rbf"
echo Plex >"$RBFNAME_FILE"
rbf=$(resolve_loaded_rbf)
want_rbf "$rbf" "Plex_720p24.rbf" "Main argv Plex_720p24"
if live_glass_is_l4; then
  ok "named Plex_720p24 classifies L4"
else
  fail "loaded Plex_720p24 must classify L4"
fi

# --- OSD_CONTROL=0 stays the SD gold overlay (do not ship 1) ---
keys=$(misterplex_pair_conf_keys 07f54d9f8f0eda2fe75d9cc314f6de54)
echo "$keys" | grep -q 'OSD_CONTROL=0' || fail "480p pair_conf missing OSD_CONTROL=0"
if echo "$keys" | grep -q 'OSD_CONTROL=1'; then
  fail "480p pair_conf must not ship OSD_CONTROL=1"
else
  ok "480p OSD_CONTROL=0"
fi
keys=$(misterplex_pair_conf_keys 4d6efef954acf7b33747f35ac2878c1b)
echo "$keys" | grep -q 'OSD_CONTROL=0' || fail "240p15 pair_conf missing OSD_CONTROL=0"
keys=$(misterplex_pair_conf_keys 61db00e7d54efad7c1a456b127b798bd)
echo "$keys" | grep -q 'OSD_CONTROL=0' || fail "480i pair_conf missing OSD_CONTROL=0"
ok "OSD_CONTROL=0 on SD gold overlays"

# Source pins: pair by argv / leftover PLXJ must not win / changing L4 still L4
grep -q 'MISTERPLEX_MAIN_ARGV\|main_argv_rbf' "$NAMED" || \
  fail "named_rbf must pair from Main argv"
grep -q '504C584A' "$NAMED" || fail "named_rbf must still mention leftover PLXJ 504C584A"
grep -q '0x3047F12C' "$NAMED" || fail "named_rbf must sample L4 PLXD"
grep -q 'misterplex_named_rbf.sh' "$WATCH" || fail "watch must source named_rbf"
ok "source pins"

if [ "$fails" -ne 0 ]; then
  echo "test_named_rbf_policy: $fails failure(s)" >&2
  exit 1
fi
echo "test_named_rbf_policy: OK"
exit 0
