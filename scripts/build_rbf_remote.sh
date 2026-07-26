#!/usr/bin/env bash
# Dispatch a Plex_MiSTer Quartus build to an isolated remote build slot.
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $(basename "$0") SLOT [PROJECT_PATH]

SLOT          Remote build slot name/number (letters, digits, dot, underscore, hyphen).
PROJECT_PATH  Local Quartus project directory to sync. Defaults to fpga/Plex_MiSTer.

Environment:
  MISTER_REMOTE_HOST          SSH host/alias (default: docker)
  MISTER_REMOTE_BASE          Remote slot base (default: <remote-home>/mplex-builds)
  MISTER_REMOTE_DEV           Remote misterfpga-dev path (default: <remote-home>/misterfpga-dev)
  MISTER_REMOTE_PROCESSORS    NUM_PARALLEL_PROCESSORS patched in remote slot copy (default: 4)

Artifacts are copied back to PROJECT_PATH/remote_out/SLOT/.
USAGE
}

if [[ $# -lt 1 || $# -gt 2 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  [[ $# -eq 0 || "${1:-}" == "-h" || "${1:-}" == "--help" ]] && exit 0 || exit 2
fi

SLOT="$1"
if [[ ! "$SLOT" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "Invalid slot '$SLOT': use only letters, digits, dot, underscore, and hyphen." >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="${2:-$ROOT/fpga/Plex_MiSTer}"
if [[ ! -d "$PROJECT" ]]; then
  echo "Project directory not found: $PROJECT" >&2
  exit 2
fi
if [[ ! -f "$PROJECT/Plex.qpf" || ! -f "$PROJECT/Plex.qsf" ]]; then
  echo "Project does not look like Plex_MiSTer (missing Plex.qpf/Plex.qsf): $PROJECT" >&2
  exit 2
fi

HOST="${MISTER_REMOTE_HOST:-docker}"
PROCESSORS="${MISTER_REMOTE_PROCESSORS:-4}"
if [[ ! "$PROCESSORS" =~ ^[0-9]+$ ]]; then
  echo "MISTER_REMOTE_PROCESSORS must be a positive integer (got '$PROCESSORS')." >&2
  exit 2
fi
if (( PROCESSORS < 1 )); then
  echo "MISTER_REMOTE_PROCESSORS must be a positive integer (got '$PROCESSORS')." >&2
  exit 2
fi

REMOTE_HOME="$(ssh "$HOST" 'printf "%s\n" "$HOME"')"
REMOTE_BASE="${MISTER_REMOTE_BASE:-$REMOTE_HOME/mplex-builds}"
REMOTE_DEV="${MISTER_REMOTE_DEV:-$REMOTE_HOME/misterfpga-dev}"
PROJECT_NAME="$(basename "$PROJECT")"
REMOTE_SLOT="$REMOTE_BASE/$SLOT"
REMOTE_PROJECT="$REMOTE_SLOT/$PROJECT_NAME"
LOCAL_OUT="$PROJECT/remote_out/$SLOT"

printf 'Remote host: %s\n' "$HOST"
printf 'Remote slot: %s\n' "$REMOTE_SLOT"
printf 'Remote project: %s\n' "$REMOTE_PROJECT"
printf 'Remote processors: %s\n' "$PROCESSORS"

ssh "$HOST" bash -s -- "$REMOTE_PROJECT" "$REMOTE_DEV" <<'REMOTE_PREP'
set -euo pipefail
remote_project="$1"
remote_dev="$2"
mkdir -p "$remote_project"
if [[ ! -x "$remote_dev/scripts/mister-dev" ]]; then
  echo "Remote mister-dev not executable at $remote_dev/scripts/mister-dev" >&2
  exit 1
fi
if [[ ! -f "$remote_dev/scripts/lib.sh" ]]; then
  echo "Remote mister-dev lib not found at $remote_dev/scripts/lib.sh" >&2
  exit 1
fi
REMOTE_PREP

rsync -a --delete --delete-excluded \
  --exclude '/db/' \
  --exclude '/incremental_db/' \
  --exclude '/output_files/' \
  --exclude '/remote_out/' \
  --exclude '/greybox_tmp/' \
  --exclude '*.qws' \
  "$PROJECT/" "$HOST:$REMOTE_PROJECT/"

ssh "$HOST" bash -s -- "$REMOTE_PROJECT" "$PROCESSORS" <<'REMOTE_PATCH'
set -euo pipefail
remote_project="$1"
processors="$2"
qsf="$remote_project/Plex.qsf"
if grep -qE '^[[:space:]]*set_global_assignment[[:space:]]+-name[[:space:]]+NUM_PARALLEL_PROCESSORS' "$qsf"; then
  sed -i -E "s/^([[:space:]]*set_global_assignment[[:space:]]+-name[[:space:]]+NUM_PARALLEL_PROCESSORS)[[:space:]]+[0-9]+/\1 ${processors}/" "$qsf"
else
  printf '\nset_global_assignment -name NUM_PARALLEL_PROCESSORS %s\n' "$processors" >>"$qsf"
fi
grep -E 'NUM_PARALLEL_PROCESSORS' "$qsf"
REMOTE_PATCH

ssh "$HOST" bash -s -- "$REMOTE_DEV" "$REMOTE_PROJECT" <<'REMOTE_BUILD'
set -euo pipefail
remote_dev="$1"
remote_project="$2"
# Use the remote misterfpga-dev Docker helper, but compile inside the slot copy
# directly so concurrent slots never share Quartus db/output/log paths.
# shellcheck source=/dev/null
source "$remote_dev/scripts/lib.sh"
load_env
log "Project: Plex.qpf"
log "Image:   $QUARTUS_IMAGE"
info "Core dir: $remote_project"
quartus_run "$remote_project" quartus_sh --flow compile Plex.qpf
REMOTE_BUILD

mkdir -p "$LOCAL_OUT"
rsync -a "$HOST:$REMOTE_PROJECT/output_files/Plex.rbf" "$LOCAL_OUT/"
rsync -a "$HOST:$REMOTE_PROJECT/output_files/Plex.sta.rpt" "$LOCAL_OUT/"
rsync -a "$HOST:$REMOTE_PROJECT/output_files/Plex.fit.rpt" "$LOCAL_OUT/"

RBF="$LOCAL_OUT/Plex.rbf"
STA="$LOCAL_OUT/Plex.sta.rpt"
FIT="$LOCAL_OUT/Plex.fit.rpt"
MD5="$(md5sum "$RBF" | awk '{print $1}')"
NEG_SLACK_COUNT="$(grep -cE ';[[:space:]]*-[0-9]+\.[0-9]+[[:space:]]*;' "$STA" || true)"
LOGIC_UTILIZATION="$(grep -m1 -E '^[[:space:]]*;?[[:space:]]*Logic utilization|Logic utilization' "$FIT" || true)"

printf 'Artifacts: %s\n' "$LOCAL_OUT"
printf 'Plex.rbf md5: %s\n' "$MD5"
printf 'Negative-slack rows: %s\n' "$NEG_SLACK_COUNT"
printf 'Logic utilization: %s\n' "${LOGIC_UTILIZATION:-not found}"
