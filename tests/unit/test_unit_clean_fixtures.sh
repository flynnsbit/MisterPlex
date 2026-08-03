#!/usr/bin/env bash
# Fail when make unit acquires a new untracked-file / machine-local fixture dependency.
#
# Catches the class that made clean `git worktree add` + `make unit` RED only on
# machines with leftover .agent-work / avsync_hdmi_out / poisoned build caches.
#
# Soft-skip never. true rc direct. Applied-match counts printed for RBG.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

FAIL=0
pass=0

# --- 1) Required fixtures must exist and be git-tracked ---
REQUIRED=(
  "tests/fixtures/c5382bee_freeze/ddr_frame_store.sv"
  "tests/fixtures/avsync/pts_grid_30fps_20s.mkv"
  "scripts/verilator_mdir_guard.py"
)
for rel in "${REQUIRED[@]}"; do
  if [[ ! -e "$ROOT/$rel" ]]; then
    echo "FAIL FIXTURE_MISSING path=$rel"
    FAIL=$((FAIL + 1))
  elif ! git -C "$ROOT" ls-files --error-unmatch "$rel" >/dev/null 2>&1; then
    echo "FAIL FIXTURE_UNTRACKED path=$rel (clean checkout would miss it)"
    FAIL=$((FAIL + 1))
  else
    echo "OK tracked_fixture $rel"
    pass=$((pass + 1))
  fi
done

# md5 of freeze must stay the silicon-fitted leftedge3 claim
if [[ -f "$ROOT/tests/fixtures/c5382bee_freeze/ddr_frame_store.sv" ]]; then
  md=$(md5sum "$ROOT/tests/fixtures/c5382bee_freeze/ddr_frame_store.sv" | awk '{print $1}')
  if [[ "$md" != "c139274e814a4696c485c0bba3781ad8" ]]; then
    echo "FAIL freeze_md5 got=$md expected=c139274e814a4696c485c0bba3781ad8"
    FAIL=$((FAIL + 1))
  else
    echo "OK freeze_md5=$md"
    pass=$((pass + 1))
  fi
fi

# --- 2) Unit scripts must not hard-require untracked machine paths ---
# applied_match: each pattern must hit known-safe sites only after our fixes.
# Forbidden as REQUIRED inputs (read of missing → fail is OK; path must not be
# the only way to pass make unit).
SCAN_ROOTS=(tests/unit)
FORBIDDEN_REQ_PATTERNS=(
  '\.agent-work/'
  'avsync_hdmi_out/'
  '\.worktrees/'
)

# Allowlist: paths that may mention forbidden dirs in comments or as outputs
# we still create under build/. Matches are inspected line-by-line.
violations=0
while IFS= read -r hit; do
  file=${hit%%:*}
  rest=${hit#*:}
  line=${rest%%:*}
  body=${rest#*:}
  # skip comments / docs
  if [[ "$body" =~ ^[[:space:]]*# ]]; then
    continue
  fi
  # allow explicit FAIL/REASON messages that name the forbidden path
  if [[ "$body" =~ FAIL|REASON=|must\ be\ git-tracked|never\  ]]; then
    continue
  fi
  # allow mkdir of build paths only — still flag .agent-work assignments
  if [[ "$body" =~ \.agent-work/|avsync_hdmi_out/|\.worktrees/ ]]; then
    echo "FAIL UNIT_UNTRACKED_DEP $file:$line:$body"
    violations=$((violations + 1))
  fi
done < <(rg -n '\.agent-work/|avsync_hdmi_out/|\.worktrees/' "${SCAN_ROOTS[@]}" --glob '!test_unit_clean_fixtures.sh' || true)

echo "applied_match_forbidden_scan violations=$violations"
if [[ "$violations" -ne 0 ]]; then
  FAIL=$((FAIL + 1))
else
  echo "OK no_unit_untracked_path_deps"
  pass=$((pass + 1))
fi

# --- 3) Mdir guard: foreign path → purge (red-before-green) ---
GUARD="$ROOT/scripts/verilator_mdir_guard.py"
PROBE="$ROOT/build/mdir_guard_probe_$$"
rm -rf "$PROBE"
mkdir -p "$PROBE"
# Plant a fake makefile referencing another worktree absolute path
cat >"$PROBE/Vfake.mk" <<EOF
# fake verilator mk
foo.o: /home/flynnsbit/Projects/MisterPlex/.worktrees/supervisor-sot/build/h264_intra_nb_ctx_main.cpp
EOF
set +e
python3 "$GUARD" --mdir "$PROBE" --source-root "$ROOT" >"$ROOT/build/mdir_guard_probe.log" 2>&1
grc=$?
set -e
echo "mdir_guard_purge true_rc=$grc"
if [[ "$grc" -ne 0 ]]; then
  echo "FAIL mdir_guard rc=$grc"
  FAIL=$((FAIL + 1))
elif [[ -f "$PROBE/Vfake.mk" ]]; then
  echo "FAIL mdir_guard did not purge foreign makefile (mutation would be silent)"
  FAIL=$((FAIL + 1))
elif ! grep -q 'MDIR_STALE' "$ROOT/build/mdir_guard_probe.log"; then
  echo "FAIL mdir_guard missing MDIR_STALE token"
  FAIL=$((FAIL + 1))
elif [[ ! -f "$PROBE/.misterplex_source_root" ]]; then
  echo "FAIL mdir_guard missing stamp after prepare"
  FAIL=$((FAIL + 1))
else
  echo "OK mdir_guard_purges_foreign applied_match=1"
  pass=$((pass + 1))
fi
# second call: clean stamp match, no purge of empty-ish dir
set +e
python3 "$GUARD" --mdir "$PROBE" --source-root "$ROOT" >"$ROOT/build/mdir_guard_probe2.log" 2>&1
grc2=$?
set -e
echo "mdir_guard_clean true_rc=$grc2"
if [[ "$grc2" -ne 0 ]] || ! grep -q 'purged=no' "$ROOT/build/mdir_guard_probe2.log"; then
  echo "FAIL mdir_guard clean reuse"
  FAIL=$((FAIL + 1))
else
  echo "OK mdir_guard_clean_reuse"
  pass=$((pass + 1))
fi
rm -rf "$PROBE"

# --- 4) .gitignore covers agent-work + worktrees ---
if grep -qxF '.agent-work/' "$ROOT/.gitignore" && grep -qxF '.worktrees/' "$ROOT/.gitignore"; then
  echo "OK gitignore_agent_work_and_worktrees"
  pass=$((pass + 1))
else
  echo "FAIL gitignore missing .agent-work/ or .worktrees/"
  FAIL=$((FAIL + 1))
fi

echo "SUMMARY pass=$pass fail=$FAIL"
if [[ "$FAIL" -ne 0 ]]; then
  echo "UNIT_CLEAN_FIXTURES_FAIL"
  exit 1
fi
echo "UNIT_CLEAN_FIXTURES_OK pass=$pass"
exit 0
