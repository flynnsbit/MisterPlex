#!/usr/bin/env bash
# Plex_SDfamily.rbf pairs misterplexd.480p gold. Leftover L4 PLXJ must not win.
set -u
set -o pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NAMED="$ROOT/scripts/misterplex_named_rbf.sh"
PAIR="$ROOT/scripts/misterplex_pair_conf.sh"
WATCH="$ROOT/scripts/misterplex_core_watch.sh"
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
ok() { echo "OK: $*"; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
ut="$work/Utility"
root="$work/misterplex"
mkdir -p "$ut" "$root/bin"
: >"$ut/Plex_480p.rbf"
: >"$ut/Plex_240p15.rbf"
: >"$ut/Plex_480i.rbf"
: >"$ut/Plex_720p24.rbf"
: >"$ut/Plex_SDfamily.rbf"
: >"$root/bin/misterplexd"
: >"$root/bin/misterplexd.480p"
: >"$root/bin/misterplexd.240p15"
: >"$root/bin/misterplexd.480i"
: >"$root/bin/misterplexd.720p24"
chmod +x "$root/bin/"misterplexd*

cat >"$root/rbf_daemon_pairs.txt" <<'EOF'
# md5  daemon  glass
07f54d9f8f0eda2fe75d9cc314f6de54 /media/fat/misterplex/bin/misterplexd.480p true480
0eea3580a5a0dacf60bf65c50499bcc9 /media/fat/misterplex/bin/misterplexd.720p24 l4
EOF

export MISTERPLEX_ROOT="$root"
export MISTERPLEX_PAIRS="$root/rbf_daemon_pairs.txt"
export MISTERPLEX_UTILITY="$ut"
export UTILITY_DIR="$ut"
export MISTERPLEX_LIVE_RBF="$ut/Plex_480p.rbf"
export RBFNAME_FILE="$work/RBFNAME"
export CORENAME_FILE="$work/CORENAME"
export MISTERPLEX_MAIN_ARGV=""
export MPX_FORCE_LIVE_GLASS=""
echo Plex >"$CORENAME_FILE"
echo Plex >"$RBFNAME_FILE"
# shellcheck disable=SC1090
. "$NAMED"
# shellcheck disable=SC1090
. "$PAIR"

# --- family ---
fam=$(rbf_family_from_path "$ut/Plex_SDfamily.rbf")
[[ "$fam" == sdfam ]] || fail "Plex_SDfamily family=$fam want sdfam"
fam=$(rbf_family_from_path "Plex_480p.rbf")
[[ "$fam" == sd480 ]] || fail "Plex_480p family=$fam"
ok "rbf_family_from_path sdfam"

# --- resolve: leftover L4 force must not beat SDfamily ---
export MISTERPLEX_MAIN_ARGV="/media/fat/MiSTer $ut/Plex_SDfamily.rbf"
got=$(resolve_loaded_rbf)
[[ "$got" == "$ut/Plex_SDfamily.rbf" ]] || fail "argv SDfamily → $got"
export MPX_FORCE_LIVE_GLASS=L4
got=$(resolve_loaded_rbf)
[[ "$got" == "$ut/Plex_SDfamily.rbf" ]] || fail "leftover L4 must not beat argv SDfamily (got $got)"
export MPX_FORCE_LIVE_GLASS=""
export MISTERPLEX_MAIN_ARGV=""
echo Plex >"$RBFNAME_FILE"
got=$(resolve_loaded_rbf)
[[ "$got" == "$ut/Plex_SDfamily.rbf" ]] || fail "CORENAME=Plex + SDfamily present → $got"
ok "resolve SDfamily beats leftover PLXJ"

# --- pair bin: SDfamily → misterplexd.480p, not 720p24 ---
out=$(pair_bin_glass_for_loaded_rbf "$ut/Plex_SDfamily.rbf")
bin=$(printf '%s\n' "$out" | awk '{print $1}')
glass=$(printf '%s\n' "$out" | awk '{print $2}')
case "$bin" in
  */misterplexd.480p) ok "SDfamily pairs misterplexd.480p" ;;
  *) fail "SDfamily pair bin=$bin want */misterplexd.480p" ;;
esac
[[ "$glass" == true480 ]] || fail "SDfamily glass=$glass want true480"
case "$bin" in
  *720p24*|*misterplexd.720*) fail "RED: leftover PLXJ paired 720p daemon ($bin)" ;;
esac

out=$(pair_bin_glass_for_loaded_rbf "$ut/Plex_480p.rbf")
bin=$(printf '%s\n' "$out" | awk '{print $1}')
case "$bin" in
  */misterplexd.480p) ok "Plex_480p name-pairs 480p daemon" ;;
  *) fail "Plex_480p pair bin=$bin" ;;
esac

out=$(pair_bin_glass_for_loaded_rbf "$ut/Plex_720p24.rbf")
bin=$(printf '%s\n' "$out" | awk '{print $1}')
glass=$(printf '%s\n' "$out" | awk '{print $2}')
case "$bin" in
  */misterplexd.720p24) ok "named 720p24 still pairs L4 daemon (negative)" ;;
  *) fail "720p24 pair bin=$bin" ;;
esac
[[ "$glass" == l4 ]] || fail "720p24 glass=$glass want l4"

# RED twin: leftover PLXJ-wins pairing (old live_glass_is_l4 treated sticky
# 504C584A as L4 and hashed Plex_720p24).
legacy_pair_leftover_plxj_wins() {
  echo "$root/bin/misterplexd.720p24 l4"
}
legacy=$(legacy_pair_leftover_plxj_wins)
green=$(pair_bin_glass_for_loaded_rbf "$ut/Plex_SDfamily.rbf")
if [ "$legacy" = "$green" ]; then
  fail "RED twin: leftover-PLXJ-wins pairing matches GREEN SDfamily pair"
else
  ok "RED twin leftover-PLXJ-wins != GREEN SDfamily ($legacy vs $green)"
fi
case "$legacy" in
  *720p24*) ok "RED oracle still picks 720p24 on leftover PLXJ" ;;
  *) fail "RED oracle should pick 720p24 ($legacy)" ;;
esac

# pair_conf: SDfamily unknown md5 → 480p overlay; no PLEX_BASE; OSD_CONTROL=0
keys=$(misterplex_pair_conf_keys deadbeefdeadbeefdeadbeefdeadbeef)
echo "$keys" | grep -q 'OSD_CONTROL=0' || fail "SDfamily overlay missing OSD_CONTROL=0"
echo "$keys" | grep -q 'OSD_CONTROL=1' && fail "SDfamily overlay must not ship OSD_CONTROL=1"
echo "$keys" | grep -q 'ANALOG_RASTER=480p31' || fail "SDfamily overlay missing ANALOG_RASTER=480p31"
if echo "$keys" | grep -q '^PLEX_BASE='; then
  fail "pair_conf_keys must not own PLEX_BASE"
else
  ok "pair_conf does not own PLEX_BASE"
fi
tmp=$(mktemp)
printf 'PLEX_BASE=http://192.168.2.1:32400\nOSD_CONTROL=1\n' >"$tmp"
misterplex_apply_pair_conf deadbeefdeadbeefdeadbeefdeadbeef "$tmp"
grep -q 'PLEX_BASE=http://192.168.2.1:32400' "$tmp" || fail "apply clobbered PLEX_BASE"
grep -q 'OSD_CONTROL=0' "$tmp" || fail "apply did not pin OSD_CONTROL=0"
grep -q 'ANALOG_RASTER=480p31' "$tmp" || fail "apply missing ANALOG_RASTER"
rm -f "$tmp"
ok "SDfamily pair_conf ANALOG_RASTER OSD_CONTROL=0 PLEX_BASE untouched"

grep -q 'pair_bin_glass_for_loaded_rbf' "$WATCH" || \
  fail "watch must pair via pair_bin_glass_for_loaded_rbf"
grep -q 'Plex_SDfamily.rbf' "$NAMED" || fail "named_rbf must name Plex_SDfamily.rbf"

if [ "$fails" -ne 0 ]; then
  echo "test_sd_family_named_pair: $fails failure(s)" >&2
  exit 1
fi
echo "test_sd_family_named_pair: OK"
exit 0
