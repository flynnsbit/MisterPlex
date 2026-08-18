#!/usr/bin/env bash
# Install CRT 15 kHz sibling cores + daemons onto the MiSTer.
#
# Does not overwrite digital 24 fps GOLD:
#   Plex_480p.rbf / Plex_720p24.rbf / misterplexd.480p / misterplexd.720p24
# Merges rbf_daemon_pairs.txt (keeps 07f54d9f / 03f1b95a). Does not start a
# second watcher if one is already locked.
#
# Exit 2 if any CRT rbf/bin/pairs/watch is missing. Sibling BUILD_OK is not
# claimed yet — empty REL is the expected state until a fit lands.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REL="${REL:-$ROOT/release_artifacts/v0.8.0-crt-240p-480i}"
HOST="${MISTER_HOST:-192.168.1.183}"
PASS="${MISTER_PASS:-1}"
SSH=(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=12 root@"$HOST")
SCP=(sshpass -p "$PASS" scp -o StrictHostKeyChecking=no)

rel_find() {
  local f
  for f in "$@"; do
    if [[ -f "$f" ]]; then
      printf '%s\n' "$f"
      return 0
    fi
  done
  return 1
}

MISSING=0
missing() {
  echo "missing $1" >&2
  MISSING=1
}

RBF_240=$(rel_find "$REL/cores/Plex_240p15.rbf" "$REL/Plex_240p15.rbf" || true)
RBF_480I=$(rel_find "$REL/cores/Plex_480i.rbf" "$REL/Plex_480i.rbf" || true)
BIN_240=$(rel_find "$REL/bin/misterplexd.240p15" "$REL/misterplexd.240p15" || true)
BIN_480I=$(rel_find "$REL/bin/misterplexd.480i" "$REL/misterplexd.480i" || true)
PAIRS=$(rel_find "$REL/rbf_daemon_pairs.txt" "$REL/bin/rbf_daemon_pairs.txt" || true)
WATCH=$(rel_find \
  "$REL/bin/misterplex_core_watch.sh" \
  "$REL/misterplex_core_watch.sh" \
  "$ROOT/scripts/misterplex_core_watch.sh" || true)
SUP=$(rel_find \
  "$REL/bin/misterplexd_supervise.sh" \
  "$REL/misterplexd_supervise.sh" \
  "$ROOT/scripts/misterplexd_supervise.sh" || true)
README=$(rel_find "$REL/Plex_CRT_README.txt" "$REL/Plex_README.txt" "$REL/README.md" || true)

[[ -n "$RBF_240" ]] || missing "$REL/cores/Plex_240p15.rbf (or $REL/Plex_240p15.rbf)"
[[ -n "$RBF_480I" ]] || missing "$REL/cores/Plex_480i.rbf (or $REL/Plex_480i.rbf)"
[[ -n "$BIN_240" ]] || missing "$REL/bin/misterplexd.240p15"
[[ -n "$BIN_480I" ]] || missing "$REL/bin/misterplexd.480i"
[[ -n "$PAIRS" ]] || missing "$REL/rbf_daemon_pairs.txt"
[[ -n "$WATCH" ]] || missing "$REL/bin/misterplex_core_watch.sh (or scripts/misterplex_core_watch.sh)"
[[ -n "$SUP" ]] || missing "$REL/bin/misterplexd_supervise.sh (or scripts/misterplexd_supervise.sh)"

if [[ "$MISSING" -ne 0 ]]; then
  echo "CRT sibling BUILD_OK is not claimed yet; refuse install (no RBF/bin)." >&2
  echo "Need Plex_240p15.rbf + Plex_480i.rbf + misterplexd.240p15 + misterplexd.480i + pairs + watch." >&2
  echo "Digital 24 fps GOLD (Plex_480p / Plex_720p24) was not touched." >&2
  exit 2
fi

for p in "$RBF_240" "$RBF_480I" "$BIN_240" "$BIN_480I"; do
  case "$(basename "$p")" in
    Plex_480p.rbf|Plex_720p24.rbf|misterplexd.480p|misterplexd.720p24)
      echo "refuse: CRT payload uses protected digital-24p name $(basename "$p")" >&2
      exit 2
      ;;
  esac
done

echo "=== install_paired_crt -> $HOST from $REL ==="
echo "  rbf 240p15=$(basename "$RBF_240") 480i=$(basename "$RBF_480I")"
echo "  bin 240p15=$(basename "$BIN_240") 480i=$(basename "$BIN_480I")"
echo "  will not overwrite Plex_480p.rbf Plex_720p24.rbf misterplexd.480p misterplexd.720p24"

if [[ "${INSTALL_DRY:-0}" == "1" ]]; then
  echo "INSTALL_DRY=1 — file check only; no ssh"
  exit 0
fi

"${SSH[@]}" 'mkdir -p /media/fat/_Utility /media/fat/misterplex/bin'
SCP_UTIL=("$RBF_240" "$RBF_480I")
if [[ -n "$README" ]]; then
  # Always land as Plex_CRT_README.txt — never Plex_README.txt (24p).
  CRT_README="$(mktemp /tmp/Plex_CRT_README.XXXXXX.txt)"
  cp -f "$README" "$CRT_README"
  SCP_UTIL+=("$CRT_README")
fi
"${SCP[@]}" "${SCP_UTIL[@]}" root@"$HOST":/media/fat/_Utility/
if [[ -n "${CRT_README:-}" ]]; then
  "${SSH[@]}" 'if [ -f /media/fat/_Utility/'"$(basename "$CRT_README")"' ]; then
    mv -f /media/fat/_Utility/'"$(basename "$CRT_README")"' /media/fat/_Utility/Plex_CRT_README.txt
  fi'
  rm -f "$CRT_README"
fi
"${SCP[@]}" \
  "$BIN_240" "$BIN_480I" "$WATCH" "$SUP" \
  root@"$HOST":/media/fat/misterplex/bin/
"${SCP[@]}" "$PAIRS" root@"$HOST":/tmp/misterplex-crt-pairs.txt

"${SSH[@]}" 'bash -s' <<'REMOTE'
set -euo pipefail
chmod +x /media/fat/misterplex/bin/misterplexd.240p15 \
  /media/fat/misterplex/bin/misterplexd.480i \
  /media/fat/misterplex/bin/misterplex_core_watch.sh \
  /media/fat/misterplex/bin/misterplexd_supervise.sh

PAIRS=/media/fat/misterplex/rbf_daemon_pairs.txt
IN=/tmp/misterplex-crt-pairs.txt
OUT=/tmp/misterplex-pairs-merged.txt
GOLD_480P=07f54d9f8f0eda2fe75d9cc314f6de54
GOLD_720P=03f1b95ac67a568f24193234ea8cb072
: > "$OUT"
if [ -f "$PAIRS" ]; then
  cat "$PAIRS" >> "$OUT"
fi
while read -r hash path _; do
  case "$hash" in
    ''|\#*|TBD|tbd) continue ;;
  esac
  echo "$hash" | grep -qE '^[0-9a-fA-F]{32}$' || continue
  [ -n "${path:-}" ] || continue
  grep -q "^${hash} " "$OUT" 2>/dev/null && continue
  printf '%s %s\n' "$hash" "$path" >> "$OUT"
done < "$IN"
grep -q "^${GOLD_480P} " "$OUT" 2>/dev/null || \
  echo "# keep GOLD 24p if present on box: $GOLD_480P /media/fat/misterplex/bin/misterplexd.480p" >> "$OUT"
grep -q "^${GOLD_720P} " "$OUT" 2>/dev/null || \
  echo "# keep GOLD 24p if present on box: $GOLD_720P /media/fat/misterplex/bin/misterplexd.720p24" >> "$OUT"
mv -f "$OUT" "$PAIRS"
rm -f "$IN"

for f in \
  /media/fat/_Utility/Plex_240p15.rbf \
  /media/fat/_Utility/Plex_480i.rbf \
  /media/fat/misterplex/bin/misterplexd.240p15 \
  /media/fat/misterplex/bin/misterplexd.480i
do
  if [ -f "$f" ]; then md5sum "$f"; else echo "ABSENT $f"; fi
done
echo "PROTECTED_UNTOUCHED_EXPECT Plex_480p.rbf Plex_720p24.rbf misterplexd.480p misterplexd.720p24"
if [ -f /media/fat/_Utility/Plex_480p.rbf ]; then md5sum /media/fat/_Utility/Plex_480p.rbf; fi
if [ -f /media/fat/_Utility/Plex_720p24.rbf ]; then md5sum /media/fat/_Utility/Plex_720p24.rbf; fi

if ! grep -q misterplex_core_watch.sh /media/fat/linux/_user-startup.sh 2>/dev/null; then
  printf "\n/media/fat/misterplex/bin/misterplex_core_watch.sh &\n" >> /media/fat/linux/_user-startup.sh
  echo ADDED_WATCH_STARTUP
else
  echo WATCH_STARTUP_OK
fi
REMOTE

echo "=== install_paired_crt done (CRT siblings only; digital 24p GOLD not overwritten) ==="
