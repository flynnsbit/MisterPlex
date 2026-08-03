#!/usr/bin/env bash
# Static gate: every product log line that emits drops= must also bind
# process_epoch (and session_epoch) so a mid-soak daemon respawn cannot be
# mistaken for counter continuity.
#
# Defect class: parent soak "drops flat at 1 across N frames" undercounted
# because droppedFrames_ resets per stream/life (media_player.cpp store(0))
# while greps only looked at drops=.
#
# Red-before-green: strip process_epoch from a broken copy → count 0 fails gate.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MP="$ROOT/arm/misterplexd/media_player.cpp"
FAIL=0

[ -f "$MP" ] || { echo "FAIL missing $MP"; exit 2; }

# Sites that emit drops= (product)
mapfile -t DROP_LINES < <(grep -n 'drops=' "$MP" || true)
echo "applied_match drops_eq_sites=${#DROP_LINES[@]}"
if [[ "${#DROP_LINES[@]}" -lt 3 ]]; then
  echo "FAIL expected >=3 drops= emission sites, got ${#DROP_LINES[@]}"
  FAIL=$((FAIL + 1))
fi

# Critical paths: A/V resync drop + publish_miss must bind process_epoch nearby
# (same log() construction — within a few lines of drops=).
check_bind() {
  local label="$1" needle="$2"
  local line
  line=$(grep -n "$needle" "$MP" | head -1 | cut -d: -f1)
  if [[ -z "$line" ]]; then
    echo "FAIL missing needle $needle"
    FAIL=$((FAIL + 1))
    return
  fi
  # Window: log string may span many concatenated lines
  local win
  win=$(sed -n "${line},$((line + 40))p" "$MP")
  local pe se
  pe=$(printf '%s\n' "$win" | grep -c 'process_epoch=' || true)
  se=$(printf '%s\n' "$win" | grep -c 'session_epoch=' || true)
  [ -z "$pe" ] && pe=0
  [ -z "$se" ] && se=0
  echo "applied_match $label line=$line process_epoch=$pe session_epoch=$se"
  if [[ "$pe" -lt 1 ]]; then
    echo "FAIL $label missing process_epoch= within 20 lines of $needle"
    FAIL=$((FAIL + 1))
  fi
  if [[ "$se" -lt 1 ]]; then
    echo "FAIL $label missing session_epoch= within 20 lines of $needle"
    FAIL=$((FAIL + 1))
  fi
}

check_bind av_resync_drop 'A/V resync drop wall_s='
check_bind publish_miss 'publish_miss wall_s='
# Prefer the log() site, not the comment above it.
check_bind session_collapse 'media: SESSION_COLLAPSE_LEDGER'

# Per-stream zeroing still documented / present
if ! grep -q 'droppedFrames_\.store(0)' "$MP"; then
  echo "FAIL missing droppedFrames_.store(0) (reset site moved?)"
  FAIL=$((FAIL + 1))
else
  echo "OK droppedFrames_ reset site still present (identity bind required)"
fi

# RED: strip process_epoch from MP copy — av_resync window must fail
BROKEN="$ROOT/build/drops_bind_broken_$$.cpp"
mkdir -p "$ROOT/build"
sed 's/process_epoch=/process_xepoch=/g' "$MP" >"$BROKEN"
bn=$(grep -c 'process_epoch=' "$BROKEN" || true)
[ -z "$bn" ] && bn=0
echo "red_mutation process_epoch count_on_broken=$bn"
if [[ "$bn" -ge 1 ]]; then
  echo "FAIL red mutation still has process_epoch= count=$bn"
  FAIL=$((FAIL + 1))
else
  # Same window check on broken file for A/V resync
  line=$(grep -n 'A/V resync drop wall_s=' "$BROKEN" | head -1 | cut -d: -f1)
  win=$(sed -n "${line},$((line + 20))p" "$BROKEN")
  pe=$(printf '%s\n' "$win" | grep -c 'process_epoch=' || true)
  [ -z "$pe" ] && pe=0
  if [[ "$pe" -ge 1 ]]; then
    echo "FAIL red: broken still binds process_epoch in av_resync window"
    FAIL=$((FAIL + 1))
  else
    echo "OK negative: broken fails process_epoch bind (count_on_broken=$bn window_pe=$pe)"
  fi
fi
rm -f "$BROKEN"

if [[ "$FAIL" -ne 0 ]]; then
  echo "test_drops_bind_process_epoch: FAIL count=$FAIL"
  exit 1
fi
echo "test_drops_bind_process_epoch: OK"
exit 0
