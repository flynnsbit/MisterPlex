#!/usr/bin/env bash
# Policy gate (NEW files only — history purge out of scope / parent-forbidden):
# tracked working-tree blobs must not exceed MAX_BYTES unless grandfathered.
#
# Inventory (this branch HEAD): assets/ ~10.3MB tracked. History still holds
# 98.29MB assets/avsync/sync_audio_id_glass_480p24_1800s.mp4 and ~27MB glass
# clips (GitHub push warning). Do not rewrite history here.
#
# Policy for new commits:
#   - Prefer generator scripts (scripts/gen_avsync_blip.py etc.) + on-demand fetch
#   - Or Git LFS if a durable large fixture is truly required
#   - Soft limit 20MB; hard fail 50MB (GitHub warning threshold)
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 2
MAX_SOFT=20971520   # 20 MiB
MAX_HARD=52428800   # 50 MiB

# Paths already in history/tree that we do not fail on if re-added at same path
# (still discourage growth). Empty on this branch's HEAD for >20MB.
GRANDFATHERED='
assets/avsync/sync_audio_id_glass_480p24_1800s.mp4
assets/avsync/sync_glass_av_480p24_600s.mp4
assets/avsync/sync_glass_av_480p24_600s_audioPlus100ms.mp4
'

SOFT=0
HARD=0
REPORT=""
while IFS= read -r line; do
  # mode type hash size path — git ls-tree -r -l
  size=$(echo "$line" | awk '{print $4}')
  path=$(echo "$line" | awk '{print $5}')
  [ -n "$path" ] || continue
  case " $size " in *" "*) ;; esac
  if ! [[ "$size" =~ ^[0-9]+$ ]]; then
    continue
  fi
  if [ "$size" -le "$MAX_SOFT" ]; then
    continue
  fi
  mb=$(awk -v s="$size" 'BEGIN{printf "%.2f", s/1048576}')
  if echo "$GRANDFATHERED" | grep -qxF "$path"; then
    REPORT="${REPORT}GRANDFATHERED ${mb}MB ${path}"$'\n'
    continue
  fi
  if [ "$size" -gt "$MAX_HARD" ]; then
    echo "FAIL LARGE_ASSET_HARD ${mb}MB ${path} (limit 50MB — use generator/LFS)" >&2
    HARD=$((HARD + 1))
  else
    echo "FAIL LARGE_ASSET_SOFT ${mb}MB ${path} (limit 20MB — use generator/LFS)" >&2
    SOFT=$((SOFT + 1))
  fi
done < <(git ls-tree -r -l HEAD)

echo "COVERAGE gate=no_large_assets soft_fail=$SOFT hard_fail=$HARD"
echo "POLICY new media >20MB: generator script or Git LFS; do not commit raw blobs"
echo "HISTORY (not purged): 98.29MB sync_audio_id_glass_480p24_1800s.mp4 + 2×~27MB glass clips"
if [ -n "$REPORT" ]; then
  printf '%s' "$REPORT"
fi

if [ "$HARD" -ne 0 ] || [ "$SOFT" -ne 0 ]; then
  echo "FAIL test_no_large_assets hard=$HARD soft=$SOFT" >&2
  exit 1
fi
echo "PASS test_no_large_assets (HEAD has no new >20MB tracked blobs)"
exit 0
