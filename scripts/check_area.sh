#!/usr/bin/env bash
# Fast area pre-check: remote Quartus Analysis & Synthesis ONLY.
#
# No fitter, no place-and-route, no timing, no RBF.  This exists because area
# is the binding constraint on the DE10-Nano and a full fit costs ~11 minutes
# of the single exclusive slot, which is far too slow to iterate an area
# reduction against.  A&S alone yields per-entity ALUT / DSP / register /
# memory estimates, which is exactly the signal a worker needs to answer
# "did my module get smaller?".
#
# It does NOT replace a fit: A&S estimates combinational ALUTs, the fitter
# packs them into ALMs, and only the fitter can say "can't fit".  Treat the
# ALM number here as an estimate, and never report it as BUILD_OK.
#
# Usage:
#   scripts/check_area.sh SLOT [--baseline FILE] [--save-baseline FILE] [--top N]
#
# Exit codes: 0 AREA_OK · 1 AREA_FAIL (regression or over budget) · 2 refusal/skip
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/fpga/Plex_MiSTer"
HOST="${MISTER_REMOTE_HOST:-docker}"

if [[ $# -lt 1 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  sed -n '2,18p' "${BASH_SOURCE[0]}"; exit 0
fi
SLOT="$1"; shift

if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" true 2>/dev/null; then
  echo "SKIP: remote build host '$HOST' unreachable"; exit 2
fi

REMOTE_HOME="$(ssh "$HOST" 'printf "%s\n" "$HOME"')"
REMOTE_PROJECT="$REMOTE_HOME/mplex-builds/$SLOT/Plex_MiSTer"
LOCAL_OUT="$PROJECT/remote_out/$SLOT"
mkdir -p "$LOCAL_OUT"

started=$(date +%s)
echo "AREA_SCOPE project=$PROJECT slot=$SLOT host=$HOST stage=map/A&S-only"

ssh "$HOST" "mkdir -p '$REMOTE_PROJECT'" || { echo "remote mkdir failed" >&2; exit 2; }
rsync -a --delete --delete-excluded \
  --exclude '/output_files/' --exclude '/db/' --exclude '/incremental_db/' \
  --exclude '/remote_out/' --exclude '/greybox_tmp/' --exclude '/build/' \
  "$PROJECT/" "$HOST:$REMOTE_PROJECT/" || { echo "rsync failed" >&2; exit 2; }

ssh "$HOST" bash -s -- "$REMOTE_HOME/mplex-builds/$SLOT" "$REMOTE_PROJECT" \
  > "$LOCAL_OUT/area.log" 2>&1 <<'REMOTE'
set -uo pipefail
remote_slot="$1"; remote_project="$2"
lock="$remote_slot/.build-lock"
mkdir -p "$remote_slot"
if ! mkdir "$lock" 2>/dev/null; then echo "SLOT_LOCKED $remote_slot"; exit 75; fi
trap 'rmdir "$lock" 2>/dev/null || true' EXIT
source "$HOME/misterfpga-dev/scripts/lib.sh"; load_env
# Analysis & Synthesis only. quartus_fit / quartus_asm are deliberately NOT
# run: no placement, no routing, no timing, no RBF. build_id.v comes from the
# PRE_FLOW_SCRIPT_FILE, which only fires on a full compile, so invoke it with
# Quartus's own argument positions or A&S dies at Plex.sv:48.
docker run --rm -v "$remote_project":/build -w /build -u "$(id -u):$(id -g)" \
  "$QUARTUS_IMAGE" sh -c \
  'quartus_sh -t sys/build_id.tcl compile Plex Plex && quartus_map Plex'
echo "QUARTUS_MAP_RC=$?"
REMOTE
srv=$?
if grep -q SLOT_LOCKED "$LOCAL_OUT/area.log" 2>/dev/null; then
  echo "SKIP: remote slot busy"; exit 2
fi
map_rc=$(grep -oP '(?<=QUARTUS_MAP_RC=)\d+' "$LOCAL_OUT/area.log" | tail -1)
echo "quartus_map rc=${map_rc:-unknown} (ssh rc=$srv)"

rsync -a "$HOST:$REMOTE_PROJECT/output_files/Plex.map.rpt" "$LOCAL_OUT/" 2>/dev/null
rsync -a "$HOST:$REMOTE_PROJECT/output_files/Plex.map.summary" "$LOCAL_OUT/" 2>/dev/null
elapsed=$(( $(date +%s) - started ))

if [[ ! -f "$LOCAL_OUT/Plex.map.rpt" ]]; then
  echo "AREA_NO_REPORT quartus_map rc=$map_rc elapsed=${elapsed}s"; exit 2
fi

python3 "$ROOT/scripts/area_report.py" "$LOCAL_OUT/Plex.map.rpt" "$@"
rc=$?
echo "AREA_ELAPSED ${elapsed}s (A&S only; a full fit on this design took 664s)"
exit $rc
