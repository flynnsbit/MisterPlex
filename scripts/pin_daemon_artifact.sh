#!/usr/bin/env bash
# pin_daemon_artifact.sh — host-only: install a measured misterplexd ELF as a
# first-class rollback pin under artifacts/daemon-pins/.
#
# WHY: the daily driver may run a lane build/ binary that is glass-verified but
# not yet in daemon-pins/. Without a pin, atomic rollback cannot restore the
# *currently working* bytes — only older pins.
#
# Rule 0: pin the MEASURED bytes. Do not "tidy" by rebuilding first unless the
# rebuild is proven byte-identical (cmp) to the live/measured artifact. Lane
# build/ outputs ARE acceptable pins when:
#   - md5 matches device live /proc/PID/exe (parent-measured), AND
#   - glass/soak evidence exists for that md5.
# Rebuild-from-tree is optional provenance hygiene, not a gate.
#
# Usage:
#   scripts/pin_daemon_artifact.sh <path-to-misterplexd> [--set-primary]
#   scripts/pin_daemon_artifact.sh --from-device-live   # PARENT ONLY (SSH)
#
# Env:
#   PIN_OUT_DIR  default: $ROOT/artifacts/daemon-pins
#   PIN_NOTE     free-text provenance line (optional)
#
# Exit: true rc=0 on verified pin file; non-zero refuses (no partial write).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${PIN_OUT_DIR:-$ROOT/artifacts/daemon-pins}"
SET_PRIMARY=0
SRC=""
FROM_DEVICE=0

usage() {
  cat <<'EOF'
usage:
  scripts/pin_daemon_artifact.sh <path-to-misterplexd> [--set-primary]
  scripts/pin_daemon_artifact.sh --from-device-live [--set-primary]

Pins are gitignored. README + policy constants are committed separately.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --set-primary) SET_PRIMARY=1; shift ;;
    --from-device-live) FROM_DEVICE=1; shift ;;
    -h|--help) usage; echo "true rc=0"; exit 0 ;;
    -*)
      echo "FAIL unknown flag $1" >&2
      usage
      echo "true rc=9"
      exit 9
      ;;
    *)
      if [ -n "$SRC" ]; then
        echo "FAIL extra arg $1" >&2
        echo "true rc=9"
        exit 9
      fi
      SRC=$1
      shift
      ;;
  esac
done

mkdir -p "$OUT_DIR"

if [ "$FROM_DEVICE" -eq 1 ]; then
  # Parent-only path. Agents must not run this.
  HOST="${MISTER_HOST:-192.168.1.183}"
  USER="${MISTER_USER:-root}"
  PASS="${MISTER_PASS:-1}"
  tmp="$OUT_DIR/.pin-live.$$"
  set +e
  remote=$(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=12 \
    "$USER@$HOST" 'set +e
n=0; exe=""; md=""
for d in /proc/[0-9]*; do
  [ -e "$d/exe" ] || continue
  x=$(readlink -f "$d/exe" 2>/dev/null) || continue
  case "$x" in *"(deleted)"*) continue ;; esac
  b=$(basename "$x" 2>/dev/null) || continue
  [ "$b" = "misterplexd" ] || continue
  n=$((n+1)); exe=$x; md=$(md5sum "$d/exe" 2>/dev/null | awk "{print \$1}")
done
echo "N=$n"
echo "EXE=$exe"
echo "MD5=$md"
')
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "FAIL ssh true rc=$rc"
    echo "true rc=5"
    exit 5
  fi
  n=$(printf '%s\n' "$remote" | sed -n 's/^N=//p' | tail -1)
  exe=$(printf '%s\n' "$remote" | sed -n 's/^EXE=//p' | tail -1)
  md=$(printf '%s\n' "$remote" | sed -n 's/^MD5=//p' | tail -1)
  if [ "$n" != "1" ] || [ -z "$exe" ] || [ "${#md}" -ne 32 ]; then
    echo "FAIL device live identity n=$n exe=$exe md5=$md (need n_daemon=1 + 32-hex)"
    echo "true rc=3"
    exit 3
  fi
  set +e
  sshpass -p "$PASS" scp -o StrictHostKeyChecking=no -o ConnectTimeout=12 \
    "$USER@$HOST:$exe" "$tmp"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    rm -f "$tmp"
    echo "FAIL scp live exe true rc=$rc"
    echo "true rc=5"
    exit 5
  fi
  host_md=$(md5sum "$tmp" | awk '{print $1}')
  if [ "$host_md" != "$md" ]; then
    rm -f "$tmp"
    echo "FAIL scp md5 $host_md != live /proc md5 $md (ETXTBSY/race)"
    echo "true rc=3"
    exit 3
  fi
  SRC=$tmp
  PIN_NOTE="${PIN_NOTE:-from-device-live exe=$exe}"
fi

if [ -z "$SRC" ] || [ ! -f "$SRC" ]; then
  echo "FAIL missing source binary SRC=${SRC:-empty}"
  usage
  echo "true rc=2"
  exit 2
fi

if ! file "$SRC" | grep -Eq 'ELF 32-bit LSB executable, ARM'; then
  echo "FAIL not ARM32 ELF: $(file "$SRC")"
  rm -f "${tmp:-}"
  echo "true rc=3"
  exit 3
fi

full=$(md5sum "$SRC" | awk '{print $1}')
pfx="${full:0:8}"
dest="$OUT_DIR/misterplexd.${pfx}"

# Atomic install: write temp then rename; verify cmp.
stage="$OUT_DIR/.stage.${pfx}.$$"
cp -f "$SRC" "$stage"
chmod +x "$stage"
stage_md=$(md5sum "$stage" | awk '{print $1}')
if [ "$stage_md" != "$full" ]; then
  rm -f "$stage" "${tmp:-}"
  echo "FAIL stage md5 drift"
  echo "true rc=3"
  exit 3
fi
mv -f "$stage" "$dest"
if ! cmp -s "$SRC" "$dest" 2>/dev/null; then
  # SRC may be the temp we already moved away when FROM_DEVICE; re-check md5 only
  dest_md=$(md5sum "$dest" | awk '{print $1}')
  if [ "$dest_md" != "$full" ]; then
    echo "FAIL dest md5 $dest_md != $full"
    echo "true rc=3"
    exit 3
  fi
fi
rm -f "${tmp:-}"

# Trackable name (misterplexd.* binaries are gitignored; PROVENANCE-* is not).
prov="$OUT_DIR/PROVENANCE-${pfx}.txt"
{
  echo "prefix8=$pfx"
  echo "md5_full=$full"
  echo "bytes=$(wc -c <"$dest" | tr -d ' ')"
  echo "pinned_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "source_path=$SRC"
  echo "note=${PIN_NOTE:-}"
  echo "file=$(file "$dest")"
  echo "policy=pin measured bytes; rebuild only if cmp-identical to this pin"
} >"$prov"

echo "OK pinned $dest"
echo "PIN_PREFIX8=$pfx"
echo "PIN_MD5_FULL=$full"
echo "PIN_PATH=$dest"
echo "PIN_PROVENANCE=$prov"

if [ "$SET_PRIMARY" -eq 1 ]; then
  # Emit shell snippet parent can source; do not rewrite rbf_ship_policy.sh here
  # (policy constants are committed intentionally).
  echo "NOTE --set-primary: set in environment / commit policy:"
  echo "  export DAEMON_PIN_DDR_PRIMARY_FULL=$full"
  echo "  # and add $pfx to rbf_policy_ddr_daemon_accepted + pair matrix"
fi

# Optional: if policy already knows this pin, report accepted
set +e
# shellcheck disable=SC1091
source "$ROOT/scripts/rbf_ship_policy.sh"
rbf_policy_ddr_daemon_accepted "$full"
acc=$?
set -e
if [ "$acc" -eq 0 ]; then
  echo "OK policy-accepted prefix8=$pfx"
else
  echo "NOTE policy does not yet accept $pfx — commit rbf_ship_policy/pair_ship_policy update"
  echo "     pin FILE is present for rollback bytes; gates will still FAIL live-exe until accepted"
fi

echo "true rc=0"
exit 0
