#!/usr/bin/env bash
# SD-family package / SD layout policy.
# Future one-pair Utility core: Plex_SDfamily.rbf (NEVER Plex.rbf)
# + misterplexd.480p gold bytes 5f1c8614. Gold 480p / 240p15 / 480i stay
# as rollback rows. Do not invent an RBF md5. Product QSF must not enable
# PLEX_PRESENT_720P_L4.
set -u
set -o pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
QSF="$ROOT/fpga/Plex_MiSTer/Plex.qsf"
PKG="$ROOT/scripts/package_release.sh"
INST="$ROOT/scripts/install_paired_all.sh"
NAMED="$ROOT/scripts/misterplex_named_rbf.sh"
PAIRS_ASSETS="$ROOT/assets/rbf_daemon_pairs.txt"
PAIR_ART="${PAIR_ART:-$ROOT/release_artifacts/v0.9.0-pre-paired}"
PAIRS_FREEZE="$PAIR_ART/rbf_daemon_pairs.txt"

MD5_480P_RBF="07f54d9f8f0eda2fe75d9cc314f6de54"
MD5_240P15_RBF="4d6efef954acf7b33747f35ac2878c1b"
MD5_480I_RBF="61db00e7d54efad7c1a456b127b798bd"
MD5_720P24_RBF="0eea3580a5a0dacf60bf65c50499bcc9"
MD5_480P_DAEMON="5f1c861486844f4c83bf32a2112cfbb6"
ALLOWED_RBF_MD5="${MD5_480P_RBF} ${MD5_240P15_RBF} ${MD5_480I_RBF} ${MD5_720P24_RBF}"

fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
ok() { echo "OK: $*"; }

# --- product QSF must not enable L4 (SD-family / 480p gold) ---
if grep -E '^[[:space:]]*set_global_assignment[[:space:]]+-name[[:space:]]+VERILOG_MACRO[[:space:]]+"PLEX_PRESENT_720P_L4=1"' "$QSF" >/dev/null; then
  fail "product QSF must not enable PLEX_PRESENT_720P_L4"
else
  ok "product QSF PLEX_PRESENT_720P_L4 not active"
fi
if ! grep -E '^[[:space:]]*#set_global_assignment.*PLEX_PRESENT_720P_L4=1' "$QSF" >/dev/null; then
  fail "product QSF missing commented PLEX_PRESENT_720P_L4 recipe"
fi
if ! grep -E '^[[:space:]]*set_global_assignment[[:space:]].*FRAME_W=640' "$QSF" >/dev/null; then
  fail "product QSF must keep FRAME_W=640 active"
fi
if ! grep -E '^[[:space:]]*set_global_assignment[[:space:]].*FRAME_H=480' "$QSF" >/dev/null; then
  fail "product QSF must keep FRAME_H=480 active"
fi
qsf_red=$(mktemp)
sed 's/^#set_global_assignment -name VERILOG_MACRO "PLEX_PRESENT_720P_L4=1"/set_global_assignment -name VERILOG_MACRO "PLEX_PRESENT_720P_L4=1"/' "$QSF" >"$qsf_red"
if grep -E '^[[:space:]]*set_global_assignment[[:space:]]+-name[[:space:]]+VERILOG_MACRO[[:space:]]+"PLEX_PRESENT_720P_L4=1"' "$qsf_red" >/dev/null; then
  ok "RED twin: uncommented PLEX_PRESENT_720P_L4 is detected"
else
  fail "RED twin missed active PLEX_PRESENT_720P_L4"
fi
rm -f "$qsf_red"

# --- pairs files: gold rollback rows; no invented SDfamily md5 ---
check_pairs() {
  local f=$1
  [[ -f "$f" ]] || { fail "missing $f"; return; }
  grep -q 'Plex_SDfamily.rbf' "$f" || fail "$f must name future Plex_SDfamily.rbf"
  grep -q 'NEVER generic Plex.rbf' "$f" || fail "$f must forbid generic Plex.rbf"
  grep -q '5f1c861486844f4c83bf32a2112cfbb6' "$f" || fail "$f must pin gold daemon 5f1c8614"
  grep -q "^${MD5_480P_RBF} .*misterplexd.480p" "$f" || fail "$f missing Plex_480p rollback row"
  grep -q "^${MD5_240P15_RBF} .*misterplexd.240p15" "$f" || fail "$f missing Plex_240p15 rollback row"
  grep -q "^${MD5_480I_RBF} .*misterplexd.480i" "$f" || fail "$f missing Plex_480i rollback row"
  # RED: a data row whose md5 is not a known gold/lab hash is invented.
  while read -r md5 rest; do
    [[ -z "${md5:-}" || "$md5" == \#* ]] && continue
    case " $ALLOWED_RBF_MD5 " in
      *" $md5 "*) ;;
      *) fail "$f invented RBF md5 $md5 (no SDfamily freeze yet)" ;;
    esac
  done <"$f"
  ok "$(basename "$(dirname "$f")")/$(basename "$f") rollback rows; no invented md5"
}
check_pairs "$PAIRS_ASSETS"
check_pairs "$PAIRS_FREEZE"

# RED twin: invented SDfamily md5 in a pairs copy must be rejected.
red_pairs=$(mktemp)
cat "$PAIRS_ASSETS" >"$red_pairs"
echo "deadbeefdeadbeefdeadbeefdeadbeef /media/fat/misterplex/bin/misterplexd.480p sdfamily" >>"$red_pairs"
red_hit=0
while read -r md5 rest; do
  [[ -z "${md5:-}" || "$md5" == \#* ]] && continue
  case " $ALLOWED_RBF_MD5 " in
    *" $md5 "*) ;;
    *) red_hit=1 ;;
  esac
done <"$red_pairs"
rm -f "$red_pairs"
if [[ "$red_hit" -eq 1 ]]; then
  ok "RED twin: invented pairs md5 is rejected"
else
  fail "RED twin did not flag invented SDfamily md5"
fi

# --- freeze binaries: gold daemon; no generic Plex.rbf; no ungated SDfamily ---
if [[ -f "$PAIR_ART/bin/misterplexd.480p" ]]; then
  act=$(md5sum "$PAIR_ART/bin/misterplexd.480p" | awk '{print $1}')
  if [[ "$act" != "$MD5_480P_DAEMON" ]]; then
    fail "misterplexd.480p md5 $act != gold $MD5_480P_DAEMON"
  else
    ok "gold daemon misterplexd.480p md5=$act"
  fi
else
  fail "missing $PAIR_ART/bin/misterplexd.480p"
fi
if [[ -f "$PAIR_ART/cores/Plex.rbf" ]]; then
  fail "paired freeze must not contain cores/Plex.rbf"
else
  ok "freeze has no generic cores/Plex.rbf"
fi
if [[ -f "$PAIR_ART/cores/Plex_SDfamily.rbf" ]]; then
  fail "Plex_SDfamily.rbf in freeze without a gated md5 (do not invent)"
else
  ok "Plex_SDfamily.rbf not in freeze (bitstream not frozen)"
fi
if [[ -f "$ROOT/assets/Plex.rbf" || -f "$ROOT/cores/Plex.rbf" ]]; then
  fail "generic Plex.rbf must not sit in assets/ or repo cores/"
fi

# --- package_release: named dest only; no invented SDfamily md5 default ---
grep -q 'Plex_SDfamily.rbf' "$PKG" || fail "package_release must name future Plex_SDfamily.rbf"
grep -q 'MD5_480P_DAEMON="5f1c861486844f4c83bf32a2112cfbb6"' "$PKG" || \
  fail "package_release must freeze gold daemon 5f1c8614"
grep -q 'generic cores/Plex.rbf must not ship' "$PKG" || \
  fail "package_release must refuse generic Plex.rbf in paired builds"
if grep 'MD5_SDFAMILY_RBF=' "$PKG" | grep -E '[0-9a-f]{32}' >/dev/null; then
  fail "RED: package_release invented a default MD5_SDFAMILY_RBF"
else
  ok "MD5_SDFAMILY_RBF has no invented default"
fi
# copy_gated_md5 is paired-only and must never target generic Plex.rbf.
if grep copy_gated_md5 "$PKG" | grep -q 'cores/Plex.rbf'; then
  fail "copy_gated_md5 must not target generic cores/Plex.rbf"
else
  ok "paired copy_gated_md5 dests are named siblings"
fi

# --- install_paired_all: rollback cores required; generic Plex.rbf only rm ---
grep -q 'need "$REL/cores/Plex_480p.rbf"' "$INST" || fail "install must require Plex_480p rollback"
grep -q 'need "$REL/cores/Plex_240p15.rbf"' "$INST" || fail "install must require Plex_240p15 rollback"
grep -q 'need "$REL/cores/Plex_480i.rbf"' "$INST" || fail "install must require Plex_480i rollback"
grep -q 'Plex_SDfamily.rbf' "$INST" || fail "install must name optional Plex_SDfamily.rbf"
if grep -n '_Utility/Plex.rbf' "$INST" | grep -v 'rm -f'; then
  fail "install_paired_all must not copy to _Utility/Plex.rbf (rm-only)"
else
  ok "install dest never generic Plex.rbf (rm-only)"
fi
if [[ -x "$INST" || -f "$INST" ]]; then
  if INSTALL_DRY=1 REL="$PAIR_ART" bash "$INST"; then
    ok "INSTALL_DRY=1 gold rollback freeze present"
  else
    fail "INSTALL_DRY=1 failed against v0.9.0-pre-paired freeze"
  fi
fi

# --- named_rbf: Plex_SDfamily when present; never generic Plex.rbf ---
grep -q 'Plex_SDfamily.rbf' "$NAMED" || fail "named_rbf must resolve Plex_SDfamily.rbf"
resolve_in() {
  local ut=$1 rbfname=$2 force=${3:-true480} live=${4:-}
  (
    export MISTERPLEX_UTILITY="$ut"
    export UTILITY_DIR="$ut"
    export LIVE_RBF="${live:-$ut/Plex_480p.rbf}"
    export RBFNAME_FILE="$ut/RBFNAME"
    export MPX_FORCE_LIVE_GLASS="$force"
    printf '%s\n' "$rbfname" >"$ut/RBFNAME"
    # shellcheck disable=SC1090
    . "$NAMED"
    resolve_loaded_rbf
  )
}

ut=$(mktemp -d)
trap 'rm -rf "$ut"' EXIT
touch "$ut/Plex.rbf" "$ut/Plex_480p.rbf" "$ut/Plex_240p15.rbf" \
  "$ut/Plex_480i.rbf" "$ut/Plex_720p24.rbf" "$ut/Plex_SDfamily.rbf"

got=$(resolve_in "$ut" Plex)
[[ "$got" == "$ut/Plex_SDfamily.rbf" ]] || fail "CORENAME=Plex with SDfamily present → $got"
got=$(resolve_in "$ut" Plex L4)
[[ "$got" == "$ut/Plex_SDfamily.rbf" ]] || fail "leftover L4 PLXJ must not beat Plex_SDfamily (got $got)"
got=$(resolve_in "$ut" Plex_480p)
[[ "$got" == "$ut/Plex_480p.rbf" ]] || fail "named Plex_480p rollback → $got"
got=$(resolve_in "$ut" Plex_240p15)
[[ "$got" == "$ut/Plex_240p15.rbf" ]] || fail "named Plex_240p15 rollback → $got"
got=$(resolve_in "$ut" Plex_480i)
[[ "$got" == "$ut/Plex_480i.rbf" ]] || fail "named Plex_480i rollback → $got"
got=$(resolve_in "$ut" Plex_720p24)
[[ "$got" == "$ut/Plex_720p24.rbf" ]] || fail "named Plex_720p24 lab → $got"
got=$(resolve_in "$ut" Plex_SDfamily)
[[ "$got" == "$ut/Plex_SDfamily.rbf" ]] || fail "named Plex_SDfamily → $got"
got=$(resolve_in "$ut" Plex true480 "$ut/Plex.rbf")
case "$got" in
  */Plex.rbf|*/Plex.RBF) fail "RED: resolve returned generic $got" ;;
  *) ok "LIVE_RBF generic Plex.rbf rejected (got $got)" ;;
esac

rm -f "$ut/Plex_SDfamily.rbf"
got=$(resolve_in "$ut" Plex)
[[ "$got" == "$ut/Plex_480p.rbf" ]] || fail "without SDfamily, CORENAME=Plex → Plex_480p (got $got)"
got=$(resolve_in "$ut" Plex L4)
[[ "$got" == "$ut/Plex_720p24.rbf" ]] || fail "without SDfamily, live L4 → Plex_720p24 (got $got)"

# RED twin: only generic Plex.rbf on disk must still not be selected.
rm -f "$ut/Plex_480p.rbf" "$ut/Plex_240p15.rbf" "$ut/Plex_480i.rbf" \
  "$ut/Plex_720p24.rbf" "$ut/Plex_SDfamily.rbf"
got=$(resolve_in "$ut" Plex true480 "$ut/Plex.rbf")
case "$got" in
  */Plex.rbf|*/Plex.RBF) fail "RED: only generic Plex.rbf still selected ($got)" ;;
  *) ok "generic-only dir does not hash Plex.rbf (got $got)" ;;
esac

if [[ "$fails" -ne 0 ]]; then
  echo "test_sd_family_package_policy: $fails failure(s)" >&2
  exit 1
fi
echo "test_sd_family_package_policy: OK"
exit 0
