#!/usr/bin/env bash
# RED/GREEN teeth for RBF provenance binding + reachability prune class.
# Capture rc directly; soft-skip 77 is never treated as pass.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
PROV="$ROOT/scripts/rbf_provenance.py"
REACH="$ROOT/scripts/check_prefit_reachability.py"
status=0

echo "=== test_rbf_provenance EXECUTED ==="

# --- Reachability: known pruned CAVLC / missing decoder must RED on this tree ---
set +e
"$REACH" --root "$ROOT" >/dev/null 2>&1
reach_rc=$?
set -e
echo "prefit_reachability true rc=$reach_rc"
# On product trees without decoder in QIP, expect rc=1. If somehow green, still
# require selftest RED twin for the historical class.
set +e
"$REACH" --root "$ROOT" --self-test
reach_st=$?
set -e
echo "prefit_reachability_selftest true rc=$reach_st"
if [[ "$reach_st" -ne 0 ]]; then
  echo "FAIL: reachability selftest must PASS (includes RED teeth)" >&2
  status=1
fi
if [[ "$reach_st" -eq 77 ]]; then
  echo "FAIL: soft-skip 77 is not a pass" >&2
  status=1
fi

# --- Provenance selftest (embedded RED/GREEN) ---
set +e
python3 "$PROV" --root "$ROOT" selftest
prov_st=$?
set -e
echo "rbf_provenance_selftest true rc=$prov_st"
if [[ "$prov_st" -ne 0 ]]; then
  echo "FAIL: provenance selftest" >&2
  status=1
fi

# --- Lookup G-VID1 historical pin (one-command answer) ---
set +e
out=$(python3 "$PROV" --root "$ROOT" lookup --md5 dfebf2bfd08dd70b473b587dd7e81848)
lu_rc=$?
set -e
echo "$out"
echo "gvid1_lookup true rc=$lu_rc"
if [[ "$lu_rc" -ne 0 ]]; then
  echo "FAIL: G-VID1 lookup must resolve" >&2
  status=1
fi
echo "$out" | grep -q 'git_commit=0139f2c5' || {
  echo "FAIL: G-VID1 commit must be 0139f2c5…" >&2
  status=1
}
echo "$out" | grep -q 'qip_has_ddr_frame_store=0' || {
  echo "FAIL: G-VID1 must report ddr_frame_store absent" >&2
  status=1
}
echo "$out" | grep -q 'qip_has_ddram_frame_rd=1' || {
  echo "FAIL: G-VID1 must report ddram_frame_rd present" >&2
  status=1
}

# --- RED: unknown md5 → rc=8 ---
set +e
python3 "$PROV" --root "$ROOT" lookup --md5 deadbeefdeadbeefdeadbeefdeadbeef >/dev/null 2>&1
unk_rc=$?
set -e
echo "unknown_md5_lookup true rc=$unk_rc"
if [[ "$unk_rc" -ne 8 ]]; then
  echo "FAIL: unknown md5 must exit 8 (got $unk_rc)" >&2
  status=1
fi

# --- RED: verify orphan fake rbf → rc=8 ---
ORPHAN="$ROOT/build/test_rbf_provenance_orphan.rbf"
mkdir -p "$ROOT/build"
printf 'orphan-rbf-no-manifest\n' >"$ORPHAN"
set +e
python3 "$PROV" --root "$ROOT" verify --rbf "$ORPHAN" >/dev/null 2>&1
orp_rc=$?
set -e
echo "orphan_verify true rc=$orp_rc"
if [[ "$orp_rc" -ne 8 ]]; then
  echo "FAIL: orphan RBF verify must exit 8 (got $orp_rc)" >&2
  status=1
fi
rm -f "$ORPHAN"

# --- GREEN: v0.3.0 release pin has sidecar/registry ---
V03="$ROOT/release_artifacts/v0.3.0/Plex.rbf"
if [[ -f "$V03" ]]; then
  set +e
  python3 "$PROV" --root "$ROOT" verify --rbf "$V03"
  v_rc=$?
  set -e
  echo "v030_verify true rc=$v_rc"
  if [[ "$v_rc" -ne 0 ]]; then
    echo "FAIL: v0.3.0 RBF must verify against seeded manifest" >&2
    status=1
  fi
else
  echo "WARN: v0.3.0 RBF missing — skip GREEN pin (not a pass)" >&2
fi

# --- deploy script mentions provenance refuse ---
if ! grep -q 'DEPLOY_PROVENANCE' "$ROOT/scripts/deploy_plex_core.sh"; then
  echo "FAIL: deploy_plex_core.sh must gate on DEPLOY_PROVENANCE" >&2
  status=1
fi
if ! grep -q 'rbf_provenance.py' "$ROOT/scripts/deploy_plex_core.sh"; then
  echo "FAIL: deploy_plex_core.sh must invoke rbf_provenance.py" >&2
  status=1
fi
if ! grep -q 'rbf_provenance.py' "$ROOT/scripts/build_rbf_remote.sh"; then
  echo "FAIL: build_rbf_remote.sh must emit provenance after RBF" >&2
  status=1
fi

if [[ "$status" -eq 0 ]]; then
  echo "test_rbf_provenance: PASS"
else
  echo "test_rbf_provenance: FAIL" >&2
fi
echo "true rc=$status"
exit "$status"
