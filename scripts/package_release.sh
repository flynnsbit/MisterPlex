#!/usr/bin/env bash
# Package misterplexd ARM binary + conf example + Plex.rbf path notes for SD deploy.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null || echo dev)}"
OUT_DIR="${OUT_DIR:-$ROOT/dist}"
STAGE="$OUT_DIR/stage-misterplex"
TAR="$OUT_DIR/misterplex-${VERSION}.tar.gz"

ARM_BIN="$ROOT/build/arm/misterplexd"
RBF_RELEASE="$ROOT/fpga/Plex_MiSTer/releases/Plex.rbf"
RBF_OUT="$ROOT/fpga/Plex_MiSTer/output_files/Plex.rbf"
CONF_EX="$ROOT/assets/misterplex.conf.example"

echo "=== package_release $VERSION ==="

if [[ ! -f "$ARM_BIN" ]]; then
  echo "Building arm misterplexd…"
  export PATH="${PATH}:/home/shawn/Projects/mistercast-linux/third_party/arm-gnu-toolchain/bin"
  make -C "$ROOT" arm-plexd
fi
[[ -f "$ARM_BIN" ]] || { echo "missing $ARM_BIN"; exit 1; }

rm -rf "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/conf" "$STAGE/docs" "$STAGE/cores"

cp -a "$ARM_BIN" "$STAGE/bin/misterplexd"
chmod +x "$STAGE/bin/misterplexd"
if [[ -f "$ROOT/build/arm/push_frame" ]]; then
  cp -a "$ROOT/build/arm/push_frame" "$STAGE/bin/push_frame"
  chmod +x "$STAGE/bin/push_frame"
fi

if [[ -f "$CONF_EX" ]]; then
  cp -a "$CONF_EX" "$STAGE/conf/misterplex.conf.example"
else
  cat >"$STAGE/conf/misterplex.conf.example" <<'EOF'
PLEX_BASE=http://192.168.1.41:32400
DECODE=320x240
PRESENT=fb0
MATCH_SOURCE_HZ=off
EOF
fi

# Optional RBF copy when present in tree (do not fail package if user only wants daemon)
if [[ -f "$RBF_RELEASE" ]]; then
  cp -a "$RBF_RELEASE" "$STAGE/cores/Plex.rbf"
  echo "Included cores/Plex.rbf from releases/"
elif [[ -f "$RBF_OUT" ]]; then
  cp -a "$RBF_OUT" "$STAGE/cores/Plex.rbf"
  echo "Included cores/Plex.rbf from output_files/"
else
  echo "NOTE: Plex.rbf not in tree — see README paths below (package is daemon-only)."
fi

# Path notes for operators
cat >"$STAGE/README.txt" <<EOF
MiSTerPlex release package
version: ${VERSION}

Contents
--------
  bin/misterplexd          static ARM companion + media daemon
  bin/push_frame           optional SPI frame/bitstream tool
  conf/misterplex.conf.example
  cores/Plex.rbf           (if built) Phase 1–3 present/decode core
  docs/                    short path notes

Install on MiSTer SD
--------------------
  /media/fat/misterplex/bin/misterplexd
  /media/fat/misterplex/misterplex.conf   # copy from conf example; set PLEX_* / DECODE
  /media/fat/linux/_user-startup.sh      # start daemon (see scripts/deploy_misterplexd.sh)

Plex.rbf locations (build tree / device)
----------------------------------------
  In this monorepo after Quartus:
    fpga/Plex_MiSTer/releases/Plex.rbf          # preferred release copy
    fpga/Plex_MiSTer/output_files/Plex.rbf      # Quartus primary output
    misterfpga-dev/out/Plex_MiSTer/Plex.rbf    # when built via mister-dev

  On MiSTer (typical):
    /media/fat/_Arcade/Plex.rbf   or
    /media/fat/games/Plex/Plex.rbf
  Load core from OSD; misterplexd is independent of which core is running
  for Phase 2 fb0/MrAudio, but Phase 3 STREAM/FPGA present needs Plex.rbf.

Deploy helper (from dev host)
-----------------------------
  ./scripts/deploy_misterplexd.sh
  ./scripts/deploy_plex_core.sh     # copies RBF when built

Phase notes
-----------
  Phase 2: companion :3005 + FFmpeg → fb0 + MrAudio
  Phase 3: FPGA decode (in progress) — does not block Phase 4 cast UX
  Phase 4: scrubber / resume hold / soak — see README
EOF

if [[ -f "$ROOT/docs/match-source-hz.md" ]]; then
  cp -a "$ROOT/docs/match-source-hz.md" "$STAGE/docs/"
fi
cp -a "$STAGE/README.txt" "$STAGE/docs/INSTALL.txt"

mkdir -p "$OUT_DIR"
tar -C "$STAGE/.." -czf "$TAR" "$(basename "$STAGE")"
ls -la "$TAR"
echo "Packaged → $TAR"
file "$STAGE/bin/misterplexd" || true
