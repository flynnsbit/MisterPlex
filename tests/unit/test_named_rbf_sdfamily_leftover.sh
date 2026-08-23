#!/usr/bin/env bash
# named_rbf: Plex_SDfamily.rbf + leftover L4 PLXJ 0x504C584A @ 0x3047F130
# must pair misterplexd.480p, never misterplexd.720p24.
# GREEN = current named_rbf.sh. RED = unfixed leftover-PLXJ-wins resolve.
# Soft-skip is not a pass. Do not invent an SDfamily RBF md5.
set -u
set -o pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NAMED="$ROOT/scripts/misterplex_named_rbf.sh"
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
ok() { echo "OK: $*"; }

[ -f "$NAMED" ] || { echo "missing $NAMED" >&2; exit 1; }
grep -q 'Plex_SDfamily.rbf' "$NAMED" || fail "named_rbf must name Plex_SDfamily.rbf"
grep -q '504C584A' "$NAMED" || fail "named_rbf must mention leftover PLXJ 504C584A"
grep -q 'misterplexd.480p' "$NAMED" || fail "named_rbf must pair SDfamily to misterplexd.480p"
grep -q 'pair_daemon_for_loaded_rbf' "$NAMED" || fail "named_rbf missing pair_daemon_for_loaded_rbf"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
ut="$work/Utility"
mkdir -p "$ut" "$work/bin"
: >"$ut/Plex_480p.rbf"
: >"$ut/Plex_240p15.rbf"
: >"$ut/Plex_480i.rbf"
: >"$ut/Plex_720p24.rbf"
: >"$ut/Plex_SDfamily.rbf"
: >"$work/bin/misterplexd.480p"
: >"$work/bin/misterplexd.720p24"
echo Plex >"$work/CORENAME"
echo Plex >"$work/RBFNAME"

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
  if [ "$n" -le 1 ]; then echo "$a"; else echo "$b"; fi
}
case "$key" in
  *3047F12C*) pick "${FAKE_L4_PLXD_A:-0x00000000}" "${FAKE_L4_PLXD_B:-${FAKE_L4_PLXD_A:-0x00000000}}" ;;
  *3007F128*) pick "${FAKE_T480_PLXD_A:-0x00000000}" "${FAKE_T480_PLXD_B:-${FAKE_T480_PLXD_A:-0x00000000}}" ;;
  *300FF128*) pick "${FAKE_T480B_PLXD_A:-0x00000000}" "${FAKE_T480B_PLXD_B:-${FAKE_T480B_PLXD_A:-0x00000000}}" ;;
  *3047F130*) echo "${FAKE_L4_PLXJ:-0x00000000}" ;;
  *) echo 0x00000000 ;;
esac
STUB
chmod +x "$stub"

reset_stub() { rm -rf "$work/devmem-state"; mkdir -p "$work/devmem-state"; }

export MISTERPLEX_UTILITY="$ut"
export UTILITY_DIR="$ut"
export MISTERPLEX_LIVE_RBF="$ut/Plex_480p.rbf"
export MISTERPLEX_ROOT="$work"
export RBFNAME_FILE="$work/RBFNAME"
export CORENAME_FILE="$work/CORENAME"
export MISTERPLEX_DEVMEM="$stub"
export MISTERPLEX_DEVMEM_STATE="$work/devmem-state"
export MISTERPLEX_GLASS_SAMPLE_S=0
export MISTERPLEX_MAIN_ARGV=""
export MPX_FORCE_LIVE_GLASS=""
unset MPX_FORCE_LIVE_GLASS
export FAKE_L4_PLXJ=0x504C584A
export FAKE_L4_PLXD_A=0x504C5844
export FAKE_L4_PLXD_B=0x504C5844
export FAKE_T480_PLXD_A=0x00000000
export FAKE_T480_PLXD_B=0x00000000
export FAKE_T480B_PLXD_A=0x00000000
export FAKE_T480B_PLXD_B=0x00000000

# shellcheck disable=SC1090
. "$NAMED"

want_daemon_480p() {
  got=$1
  tag=$2
  case "$got" in
    */misterplexd.480p) ok "$tag -> misterplexd.480p" ;;
    *) fail "$tag: got '$got' want '*/misterplexd.480p'" ;;
  esac
}

# --- GREEN: leftover PLXJ + Plex_SDfamily.rbf → 480p daemon ---
reset_stub
echo Plex >"$RBFNAME_FILE"
rbf=$(resolve_loaded_rbf)
case "$rbf" in
  */Plex_SDfamily.rbf) ok "leftover PLXJ CORENAME=Plex resolves Plex_SDfamily.rbf" ;;
  *) fail "leftover PLXJ + SDfamily present: resolve '$rbf' want Plex_SDfamily.rbf" ;;
esac
if live_glass_is_l4; then
  fail "leftover PLXJ + Plex_SDfamily must not classify L4"
else
  ok "live_glass not L4 for leftover PLXJ + Plex_SDfamily"
fi
daemon=$(pair_daemon_for_loaded_rbf "$rbf")
want_daemon_480p "$daemon" "leftover PLXJ + Plex_SDfamily"

reset_stub
echo Plex_SDfamily >"$RBFNAME_FILE"
rbf=$(resolve_loaded_rbf)
case "$rbf" in
  */Plex_SDfamily.rbf) ok "RBFNAME=Plex_SDfamily leftover PLXJ resolves SDfamily" ;;
  *) fail "RBFNAME=Plex_SDfamily leftover PLXJ: got '$rbf'" ;;
esac
if live_glass_is_l4; then
  fail "named Plex_SDfamily leftover PLXJ must not classify L4"
else
  ok "named Plex_SDfamily leftover PLXJ is not L4"
fi
daemon=$(pair_daemon_for_loaded_rbf "$rbf")
want_daemon_480p "$daemon" "named Plex_SDfamily leftover PLXJ"
case "$daemon" in
  */misterplexd.720p24) fail "RED: leftover PLXJ pinned misterplexd.720p24 on SDfamily" ;;
esac

# --- RED twin: unfixed leftover PLXJ wins L4 / 720p24 even with SDfamily ---
unfixed_resolve_leftover_plxj_wins() {
  # Frozen landmine: sticky PLXJ 504C584A classifies L4 and hashes 720p24
  # before Plex_SDfamily.rbf is considered.
  plxj=$(read_u32_phys "$L4_PLXJ_ADDR")
  case "$plxj" in
    *504C584A*|*504c584a*)
      echo "$ut/Plex_720p24.rbf"
      return 0
      ;;
  esac
  resolve_loaded_rbf
}

set +e
RED_OUT=$(
  reset_stub
  echo Plex >"$RBFNAME_FILE"
  rbf=$(unfixed_resolve_leftover_plxj_wins)
  daemon=$(pair_daemon_for_loaded_rbf "$rbf")
  echo "unfixed rbf=$rbf daemon=$daemon"
  case "$rbf" in
    */Plex_SDfamily.rbf) echo "FAIL unfixed leftover PLXJ did not beat SDfamily" ;;
  esac
  case "$daemon" in
    */misterplexd.480p)
      echo "FAIL unfixed leftover PLXJ unexpectedly paired misterplexd.480p"
      ;;
    */misterplexd.720p24)
      echo "FAIL leftover PLXJ wins: unfixed script paired misterplexd.720p24 (not 480p)"
      ;;
    *)
      echo "FAIL unfixed leftover PLXJ daemon='$daemon'"
      ;;
  esac
)
RED_RC=1
printf '%s\n' "$RED_OUT" | grep -q 'leftover PLXJ wins: unfixed script paired misterplexd.720p24' || RED_RC=2
if printf '%s\n' "$RED_OUT" | grep -q 'unfixed leftover PLXJ unexpectedly paired misterplexd.480p'; then
  RED_RC=0
fi
set -e
printf '%s\n' "$RED_OUT"
echo "named_rbf leftover-PLXJ-wins RED true rc=$RED_RC"
if [ "$RED_RC" -eq 0 ]; then
  fail "RED: unfixed leftover PLXJ unexpectedly paired 480p (twin weakened)"
elif [ "$RED_RC" -eq 1 ]; then
  ok "RED: leftover PLXJ wins on unfixed script (720p24 daemon)"
else
  fail "RED twin missing leftover-PLXJ-wins diagnostic (rc=$RED_RC)"
fi

if [ "$fails" -ne 0 ]; then
  echo "test_named_rbf_sdfamily_leftover: $fails failure(s)" >&2
  exit 1
fi
echo "test_named_rbf_sdfamily_leftover: OK"
exit 0
