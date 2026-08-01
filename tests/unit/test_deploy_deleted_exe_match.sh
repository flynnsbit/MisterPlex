#!/usr/bin/env bash
# Mutation: /proc/PID/exe resolves to ".../misterplexd (deleted)" after replace.
# Trailing-only glob *misterplexd) misses it → false n_daemon=0 while HTTP 200.
# Product matchers must use *misterplexd* (or strip then basename).
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FAILS=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*" >&2; FAILS=$((FAILS + 1)); }

# Extract the match predicate used by deploy + video_regression (static + live sim).
match_exe() {
  # $1 = simulated readlink output
  local exe="$1"
  case "$exe" in
    *misterplexd*) echo MATCH ;;
    *) echo MISS ;;
  esac
}

# BROKEN predicate (the trap parent hit).
match_exe_broken() {
  local exe="$1"
  case "$exe" in
    *misterplexd) echo MATCH ;;  # trailing-only — misses " (deleted)"
    *) echo MISS ;;
  esac
}

DEL="/media/fat/misterplex_v2/bin/misterplexd (deleted)"
LIVE="/media/fat/misterplex_v2/bin/misterplexd"
OTHER="/usr/bin/flock"

# 1) Broken trailing glob MISS on deleted — proves the hazard class.
if [ "$(match_exe_broken "$DEL")" = "MISS" ]; then
  pass "broken *misterplexd) MISS on deleted (hazard reproduced)"
else
  fail "broken matcher unexpectedly matched deleted"
fi

# 2) Fixed *misterplexd* MATCH on deleted + live, MISS on flock.
r_del=$(match_exe "$DEL")
r_live=$(match_exe "$LIVE")
r_other=$(match_exe "$OTHER")
echo "match deleted=$r_del live=$r_live other=$r_other"
if [ "$r_del" = "MATCH" ] && [ "$r_live" = "MATCH" ] && [ "$r_other" = "MISS" ]; then
  pass "*misterplexd* matches deleted+live, rejects flock"
else
  fail "fixed matcher wrong: del=$r_del live=$r_live other=$r_other"
fi

# 3) Product scripts must contain *misterplexd* (not only trailing-only).
for f in "$ROOT/scripts/deploy_misterplexd.sh" "$ROOT/scripts/video_regression.sh"; do
  if grep -n '\*misterplexd\*' "$f" >/dev/null; then
    pass "$(basename "$f") uses *misterplexd*"
  else
    fail "$(basename "$f") missing *misterplexd* glob"
  fi
  # Flag any remaining trailing-only daemon case arms (excluding comments about the trap).
  if grep -n 'case .* in' -A20 "$f" | grep -E '\*misterplexd\)' | grep -v 'misterplexd\*' \
    | grep -v '^[^:]*:#' >/dev/null 2>&1; then
    # soft: only fail if a real case arm ends with misterplexd)
    if grep -nE '^\s+\*misterplexd\)' "$f" >/dev/null; then
      fail "$(basename "$f") still has trailing-only *misterplexd) case arm"
    else
      pass "$(basename "$f") no trailing-only case arm"
    fi
  else
    pass "$(basename "$f") no trailing-only *misterplexd) arm"
  fi
done

# 4) deploy uses stage .new + mv -f (rename OK over running exe).
if grep -n 'misterplexd\.new\|REMOTE_BIN_NEW\|\.new' "$ROOT/scripts/deploy_misterplexd.sh" \
  | grep -q 'new'; then
  pass "deploy stages via .new"
else
  fail "deploy missing .new stage path"
fi
if grep -nE 'mv -f .*REMOTE_BIN_NEW|mv -f.*\.new' "$ROOT/scripts/deploy_misterplexd.sh" >/dev/null \
  || grep -n "mv -f '\$REMOTE_BIN_NEW'" "$ROOT/scripts/deploy_misterplexd.sh" >/dev/null; then
  pass "deploy mv -f .new → live"
else
  # looser
  if grep -n 'mv -f' "$ROOT/scripts/deploy_misterplexd.sh" | grep -q 'NEW\|new'; then
    pass "deploy mv -f stage present"
  else
    fail "deploy missing mv -f of staged .new"
  fi
fi

if [ "$FAILS" -ne 0 ]; then
  echo "FAIL test_deploy_deleted_exe_match failures=$FAILS" >&2
  exit 1
fi
echo "PASS test_deploy_deleted_exe_match"
exit 0
