#!/usr/bin/env bash
# Prep an isolated sibling-fit slot (L52 copy-over). Dry-run default. FIT=NO.
#
# Copies this worktree's fpga/Plex_MiSTer into SLOT/Plex_MiSTer, then copies
# Sibling.qsf over SLOT/Plex_MiSTer/Plex.qsf. Never overwrites shipping Plex.qsf
# in the product tree. Does not launch Quartus.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${MPLEX_PLEX_MISTER:-$ROOT/fpga/Plex_MiSTer}"
LOCK="${MPLEX_EXCLUSIVE_LOCK:-/tmp/misterplex-exclusive.lock}"
BUILDS="${MPLEX_BUILDS:-/home/flynnsbit/mplex-builds}"
LIVE_SLOT="${MPLEX_LIVE_SLOT:-$BUILDS/crt240p15}"
# Hard refuse of the live exclusive even if MPLEX_LIVE_SLOT is overridden.
LIVE_FIXED="/home/flynnsbit/mplex-builds/crt240p15"
PRODUCT="$ROOT/fpga/Plex_MiSTer"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--dry-run|--apply] SIBLING_QSF [SLOT]

SIBLING_QSF  Filename or path (Plex_240p15.qsf or Plex_480i.qsf).
SLOT         Isolated fit dir. Default: ${BUILDS}/<stem>
             stem is the QSF basename without .qsf.

Default is --dry-run (print the plan, copy nothing). --apply rsyncs then
copies the sibling QSF over SLOT/Plex_MiSTer/Plex.qsf.

Refuses (exit 4) if:
  - exclusive lock exists (${LOCK})
  - docker mplex-fit-* is Up
  - SLOT is the live crt240p15 path
  - dest would be this worktree's shipping fpga/Plex_MiSTer

Exit 3 if the sibling QSF is missing. FIT=NO (does not start Quartus).

Environment (tests / parent):
  MPLEX_PLEX_MISTER     source Plex_MiSTer (default: this worktree)
  MPLEX_BUILDS          slot parent (default: /home/flynnsbit/mplex-builds)
  MPLEX_EXCLUSIVE_LOCK  lock path (default: /tmp/misterplex-exclusive.lock)
  MPLEX_LIVE_SLOT       extra live-slot path to refuse
  MPLEX_DOCKER          docker binary (default: docker)
  MPLEX_DOCKER_PS       if set, read this file instead of docker ps
USAGE
}

APPLY=0
SIBLING=""
SLOT=""

for arg in "$@"; do
  case "$arg" in
    -h|--help)
      usage
      exit 0
      ;;
    --apply)
      APPLY=1
      ;;
    --dry-run)
      APPLY=0
      ;;
    -*)
      echo "unknown option: $arg" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -z "$SIBLING" ]]; then
        SIBLING="$arg"
      elif [[ -z "$SLOT" ]]; then
        SLOT="$arg"
      else
        echo "unexpected argument: $arg" >&2
        usage >&2
        exit 2
      fi
      ;;
  esac
done

if [[ -z "$SIBLING" ]]; then
  echo "SIBLING_QSF is required" >&2
  usage >&2
  exit 2
fi

qsf_name="$(basename "$SIBLING")"
if [[ "$qsf_name" != *.qsf ]]; then
  echo "SIBLING_QSF must be a .qsf name (got '$SIBLING')" >&2
  exit 2
fi
stem="${qsf_name%.qsf}"
SLOT="${SLOT:-$BUILDS/$stem}"

if [[ "$SIBLING" == */* ]]; then
  QSF="$SIBLING"
else
  QSF="$SRC/$SIBLING"
fi

canon() {
  realpath -m "$1"
}

same_or_inside() {
  local a b
  a="$(canon "$1")"
  b="$(canon "$2")"
  [[ "$a" == "$b" || "$a" == "$b"/* || "$b" == "$a"/* ]]
}

refuse() {
  echo "REFUSE: $1" >&2
  exit 4
}

DEST="$SLOT/Plex_MiSTer"

if [[ ! -f "$QSF" ]]; then
  echo "sibling QSF missing: $QSF" >&2
  exit 3
fi

if [[ ! -d "$SRC" ]]; then
  echo "source Plex_MiSTer not found: $SRC" >&2
  exit 2
fi

if [[ -e "$LOCK" ]]; then
  refuse "exclusive lock exists: $LOCK"
fi

mplex_fit_names=""
if [[ -n "${MPLEX_DOCKER_PS:-}" ]]; then
  mplex_fit_names="$(cat "$MPLEX_DOCKER_PS" 2>/dev/null || true)"
else
  mplex_fit_names="$("${MPLEX_DOCKER:-docker}" ps --format '{{.Names}}' 2>/dev/null || true)"
fi
if printf '%s\n' "$mplex_fit_names" | grep -qE '^mplex-fit-'; then
  refuse "docker mplex-fit-* is Up"
fi

if same_or_inside "$SLOT" "$LIVE_FIXED"; then
  refuse "SLOT is the live exclusive path: $LIVE_FIXED"
fi
if same_or_inside "$SLOT" "$LIVE_SLOT"; then
  refuse "SLOT is the live exclusive path: $LIVE_SLOT"
fi
if same_or_inside "$DEST" "$PRODUCT"; then
  refuse "would overwrite shipping Plex.qsf in $PRODUCT"
fi

mode="DRY-RUN (no copies)"
if [[ "$APPLY" == "1" ]]; then
  mode="APPLY"
fi

cat <<PLAN
mode: $mode
source: $SRC
sibling: $QSF
slot: $SLOT
dest: $DEST
would: rsync -a --exclude /db/ --exclude /incremental_db/ --exclude /output_files/ --exclude /remote_out/ --exclude /greybox_tmp/ --exclude /build/ --exclude *.qws ${SRC}/ ${DEST}/
would: cp ${QSF} ${DEST}/Plex.qsf
FIT=NO
PLAN

if [[ "$APPLY" != "1" ]]; then
  exit 0
fi

mkdir -p "$DEST"
rsync -a \
  --exclude '/db/' \
  --exclude '/incremental_db/' \
  --exclude '/output_files/' \
  --exclude '/remote_out/' \
  --exclude '/greybox_tmp/' \
  --exclude '/build/' \
  --exclude '*.qws' \
  "$SRC/" "$DEST/"
cp "$QSF" "$DEST/Plex.qsf"
if ! cmp -s "$QSF" "$DEST/Plex.qsf"; then
  echo "copy failed: dest Plex.qsf does not match sibling" >&2
  exit 1
fi
printf 'copied: %s -> %s/Plex.qsf\n' "$QSF" "$DEST"
