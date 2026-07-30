#!/usr/bin/env bash
# Install the v0.3.0 fallback bundle to /media/fat/misterplex_v3/ on the MiSTer.
#
# Side-by-side with the dev install:
#   - DOES NOT write /media/fat/misterplex/**
#   - DOES NOT write /media/fat/_Utility/Plex.rbf (dev core)
#   - DOES NOT write /media/fat/_Utility/Plex_v3.rbf (parent already installed)
#
# Usage (from this repo / worktree, run by parent — not by agents on device lab):
#   ./scripts/install_plex_v3_fallback.sh
#   MISTER_HOST=... ./scripts/install_plex_v3_fallback.sh
#
# Optional: INSTALL_START=1 also runs switch_to_v3 on the device after copy.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${MISTER_HOST:-192.168.1.183}"
USER="${MISTER_USER:-root}"
PASS="${MISTER_PASS:-1}"
REMOTE_ROOT="${MISTERPLEX_V3_ROOT:-/media/fat/misterplex_v3}"
BUNDLE="$ROOT/release_artifacts/v3_fallback"
BIN_SRC="$BUNDLE/misterplexd"
CONF_EX="$BUNDLE/misterplex.conf.example"

export PATH="${PATH}:${ARM_TOOLCHAIN_BIN:-$HOME/Projects/mistercast-linux/third_party/arm-gnu-toolchain/bin}"

die() { echo "install_plex_v3_fallback: $*" >&2; exit 1; }

# Prefer the tracked fallback binary; rebuild from this tree if missing.
if [[ ! -f "$BIN_SRC" ]]; then
  echo "install_plex_v3_fallback: no $BIN_SRC — building arm-plexd from this tree"
  make -C "$ROOT" arm-plexd
  mkdir -p "$BUNDLE"
  cp -a "$ROOT/build/arm/misterplexd" "$BIN_SRC"
fi
[[ -f "$BIN_SRC" ]] || die "missing binary $BIN_SRC"
[[ -f "$CONF_EX" ]] || die "missing $CONF_EX"

# Sanity: refuse if binary looks like a host ELF.
if file "$BIN_SRC" | grep -qi 'x86-64\|x86_64\|Intel'; then
  die "binary is not ARM: $(file "$BIN_SRC")"
fi

BIN_MD5="$(md5sum "$BIN_SRC" | awk '{print $1}')"
echo "install_plex_v3_fallback: host=$HOST remote=$REMOTE_ROOT"
echo "install_plex_v3_fallback: misterplexd md5=$BIN_MD5"
echo "install_plex_v3_fallback: expected core md5=41adb98c7a630b541091c22ce291be68 (Plex_v3.rbf; not modified here)"

command -v sshpass >/dev/null 2>&1 || die "sshpass required"

# Remote prep: only misterplex_v3 paths. Explicitly never rm/cp into misterplex/.
sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$HOST" \
  "set -e
   mkdir -p '$REMOTE_ROOT/bin' '$REMOTE_ROOT/scripts'
   # Guard rails: refuse if someone points REMOTE_ROOT at the dev tree.
   case '$REMOTE_ROOT' in
     /media/fat/misterplex|/media/fat/misterplex/)
       echo 'REFUSING to install into dev tree $REMOTE_ROOT' >&2; exit 2 ;;
   esac
   # Do not touch dev tree or cores.
   test ! -e /media/fat/misterplex || true
   ls -la /media/fat/_Utility/Plex_v3.rbf 2>/dev/null || echo 'NOTE: Plex_v3.rbf not found yet (parent installs core separately)'
  "

sshpass -p "$PASS" scp -o StrictHostKeyChecking=no \
  "$BIN_SRC" \
  "$USER@$HOST:$REMOTE_ROOT/bin/misterplexd"

sshpass -p "$PASS" scp -o StrictHostKeyChecking=no \
  "$BUNDLE/run_misterplexd_v3.sh" \
  "$BUNDLE/switch_to_v3.sh" \
  "$BUNDLE/switch_to_dev.sh" \
  "$BUNDLE/README.txt" \
  "$USER@$HOST:$REMOTE_ROOT/scripts/"

# Conf: create only if absent — never clobber operator tokens.
sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$HOST" \
  "set -e
   chmod +x '$REMOTE_ROOT/bin/misterplexd' \
            '$REMOTE_ROOT/scripts/run_misterplexd_v3.sh' \
            '$REMOTE_ROOT/scripts/switch_to_v3.sh' \
            '$REMOTE_ROOT/scripts/switch_to_dev.sh'
   if [[ ! -f '$REMOTE_ROOT/misterplex.conf' ]]; then
     cat >'$REMOTE_ROOT/misterplex.conf' <<'CONF'
# MiSTerPlex v0.3.0 fallback — side-by-side with /media/fat/misterplex/
# Set PLEX_BASE / PLEX_TOKEN for your server (not committed).
# PRESENT=fb0 is the v0.3.0 lab-stable cast path (daemon default). Do not
# change to fpga to "fix" the current-daemon fb0 freeze trap — that trap is
# HEAD-only; this binary is the v0.3.0-era daemon.
DECODE=320x240
PRESENT=fb0
STREAM=0
MATCH_SOURCE_HZ=off
IDLE_SCREEN=logo
CONF
     echo 'created $REMOTE_ROOT/misterplex.conf'
   else
     echo 'kept existing $REMOTE_ROOT/misterplex.conf'
   fi
   # Copy example alongside for reference
   cat >'$REMOTE_ROOT/misterplex.conf.example' <<'CONF'
# Set this to your Plex Media Server, for example:
# PLEX_BASE=http://YOUR-PLEX-SERVER:32400
# PLEX_TOKEN=
DECODE=320x240
PRESENT=fb0
STREAM=0
MATCH_SOURCE_HZ=off
IDLE_SCREEN=logo
CONF
   echo '--- remote layout ---'
   ls -la '$REMOTE_ROOT' '$REMOTE_ROOT/bin' '$REMOTE_ROOT/scripts'
   md5sum '$REMOTE_ROOT/bin/misterplexd'
   # Prove we did not modify dev paths in this session (existence check only).
   echo 'dev tree still present:' \$(test -d /media/fat/misterplex && echo yes || echo no)
   echo 'dev core still present:' \$(test -f /media/fat/_Utility/Plex.rbf && echo yes || echo no)
   echo 'v3 core present:' \$(test -f /media/fat/_Utility/Plex_v3.rbf && echo yes || echo no)
  "

if [[ "${INSTALL_START:-0}" == "1" ]]; then
  echo "install_plex_v3_fallback: INSTALL_START=1 → switch_to_v3"
  sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$HOST" \
    "bash '$REMOTE_ROOT/scripts/switch_to_v3.sh'"
else
  echo "install_plex_v3_fallback: files only (daemon not started)."
  echo "  To switch runtime on device:"
  echo "    ssh root@$HOST 'bash $REMOTE_ROOT/scripts/switch_to_v3.sh'"
  echo "  Load OSD core: _Utility/Plex_v3.rbf"
fi

echo "install_plex_v3_fallback: DONE"
echo "Verify greps (parent on device after switch + core load):"
echo "  ssh root@$HOST 'md5sum /media/fat/_Utility/Plex_v3.rbf /media/fat/misterplex_v3/bin/misterplexd'"
echo "  ssh root@$HOST 'grep -E \"^PRESENT=|^DECODE=\" /media/fat/misterplex_v3/misterplex.conf'"
echo "  ssh root@$HOST 'grep -E \"media: fb |GDM: listening|companion: GDM|DDR YUV\" /media/fat/misterplex_v3/misterplexd.log | tail -20'"
echo "  healthy: media: fb ... decode=320x240   fail: DDR YUV420p (wrong daemon)"
