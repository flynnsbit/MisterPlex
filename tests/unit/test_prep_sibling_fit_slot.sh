#!/usr/bin/env bash
# Isolated-slot prep: temp tree + fake qsf. Quotes true rc. FIT=NO.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PREP="$ROOT/scripts/prep_sibling_fit_slot.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SRC="$TMP/src/Plex_MiSTer"
SLOT="$TMP/mplex-builds/Plex_240p15"
LIVE="$TMP/mplex-builds/crt240p15"
LOCK="$TMP/exclusive.lock"
DOCKER_EMPTY="$TMP/docker_ps.empty"
DOCKER_UP="$TMP/docker_ps.up"

mkdir -p "$SRC/rtl" "$TMP/mplex-builds"
printf 'FAKE_SRC_MARKER\n' >"$SRC/marker.txt"
printf 'PRODUCT_QSF_BODY\n' >"$SRC/Plex.qsf"
printf 'SIBLING_240P15_BODY\n' >"$SRC/Plex_240p15.qsf"
: >"$DOCKER_EMPTY"
printf 'mplex-fit-fake-crt240p15-1\n' >"$DOCKER_UP"

run() {
  MPLEX_PLEX_MISTER="$SRC" \
  MPLEX_EXCLUSIVE_LOCK="$LOCK" \
  MPLEX_LIVE_SLOT="$LIVE" \
  MPLEX_DOCKER_PS="$DOCKER_EMPTY" \
  MPLEX_BUILDS="$TMP/mplex-builds" \
  "$PREP" "$@"
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# --- dry-run (default): plan only, no copies ---
set +e
DRY_OUT="$(run Plex_240p15.qsf "$SLOT" 2>&1)"
DRY_RC=$?
set -e
printf 'dry-run rc=%s\n' "$DRY_RC"
printf '%s\n' "$DRY_OUT"
[[ "$DRY_RC" -eq 0 ]] || fail "dry-run want rc=0 got rc=$DRY_RC"
grep -q 'DRY-RUN' <<<"$DRY_OUT" || fail "dry-run did not print DRY-RUN"
[[ ! -e "$SLOT/Plex_MiSTer/Plex.qsf" ]] || fail "dry-run wrote dest Plex.qsf"
[[ ! -e "$SLOT/Plex_MiSTer/marker.txt" ]] || fail "dry-run rsynced source"
echo "PASS dry-run (rc=$DRY_RC, no copies)"

# --- apply: rsync + sibling over Plex.qsf ---
set +e
APPLY_OUT="$(run --apply Plex_240p15.qsf "$SLOT" 2>&1)"
APPLY_RC=$?
set -e
printf 'apply rc=%s\n' "$APPLY_RC"
printf '%s\n' "$APPLY_OUT"
[[ "$APPLY_RC" -eq 0 ]] || fail "apply want rc=0 got rc=$APPLY_RC"
[[ -f "$SLOT/Plex_MiSTer/Plex.qsf" ]] || fail "apply missing dest Plex.qsf"
[[ -f "$SLOT/Plex_MiSTer/marker.txt" ]] || fail "apply missing rsynced marker"
got="$(cat "$SLOT/Plex_MiSTer/Plex.qsf")"
[[ "$got" == "SIBLING_240P15_BODY" ]] || fail "dest Plex.qsf is not sibling (got '$got')"
src_prod="$(cat "$SRC/Plex.qsf")"
[[ "$src_prod" == "PRODUCT_QSF_BODY" ]] || fail "apply mutated source Plex.qsf"
echo "PASS apply (rc=$APPLY_RC, dest Plex.qsf == sibling)"

# --- refuse-live-slot: never write crt240p15 ---
set +e
LIVE_OUT="$(run --apply Plex_240p15.qsf "$LIVE" 2>&1)"
LIVE_RC=$?
set -e
printf 'refuse-live-slot rc=%s\n' "$LIVE_RC"
printf '%s\n' "$LIVE_OUT"
[[ "$LIVE_RC" -eq 4 ]] || fail "refuse-live-slot want rc=4 got rc=$LIVE_RC"
grep -q 'live exclusive' <<<"$LIVE_OUT" || fail "refuse-live-slot did not cite live exclusive"
[[ ! -e "$LIVE/Plex_MiSTer/Plex.qsf" ]] || fail "refuse-live-slot wrote into live slot"
echo "PASS refuse-live-slot (rc=$LIVE_RC)"

# --- missing sibling QSF ---
set +e
MISS_OUT="$(run --apply Plex_480i.qsf "$TMP/mplex-builds/Plex_480i" 2>&1)"
MISS_RC=$?
set -e
printf 'missing-qsf rc=%s\n' "$MISS_RC"
printf '%s\n' "$MISS_OUT"
[[ "$MISS_RC" -eq 3 ]] || fail "missing-qsf want rc=3 got rc=$MISS_RC"
echo "PASS missing-qsf (rc=$MISS_RC)"

printf 'OK test_prep_sibling_fit_slot dry-run rc=%s apply rc=%s refuse-live-slot rc=%s missing-qsf rc=%s\n' \
  "$DRY_RC" "$APPLY_RC" "$LIVE_RC" "$MISS_RC"
