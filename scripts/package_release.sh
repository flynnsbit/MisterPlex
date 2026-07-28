#!/usr/bin/env bash
# Package misterplexd ARM binary + conf example + Plex.rbf + docs for SD deploy.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null || echo dev)}"
OUT_DIR="${OUT_DIR:-$ROOT/dist}"
STAGE="$OUT_DIR/stage-misterplex"
TAR="$OUT_DIR/misterplex-${VERSION}.tar.gz"

ARM_BIN="$ROOT/build/arm/misterplexd"
RBF_MD5_EXPECTED="41adb98c7a630b541091c22ce291be68"
RBF_DEFAULT="$ROOT/release_artifacts/v0.3.0/Plex.rbf"
RBF_SRC="${RBF_PATH:-$RBF_DEFAULT}"
CONF_EX="$ROOT/assets/misterplex.conf.example"
# Static armhf ffmpeg to bundle so the package is self-contained. Override with
# FFMPEG_ARMHF=/path/to/ffmpeg. It is GPLv3, so its licence and provenance ship
# alongside it (see the licenses/ffmpeg staging below).
FFMPEG_ARMHF="${FFMPEG_ARMHF:-$HOME/Projects/mistercast-linux/third_party/ffmpeg-armhf/ffmpeg}"

echo "=== package_release $VERSION ==="

# Always rebuild rather than reusing whatever happens to sit in build/arm.
# A stale binary here silently shipped a pre-cleanup daemon that still carried
# a hardcoded private PMS address, so "the file exists" is not evidence that it
# matches the source being released. make handles the up-to-date check properly
# via its dependencies; a missing toolchain now fails loudly instead of
# packaging an unrelated build.
echo "Building arm misterplexd…"
export PATH="${PATH}:${ARM_TOOLCHAIN_BIN:-$HOME/Projects/mistercast-linux/third_party/arm-gnu-toolchain/bin}"
make -C "$ROOT" arm-plexd
[[ -f "$ARM_BIN" ]] || { echo "missing $ARM_BIN"; exit 1; }

rm -rf "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/conf" "$STAGE/docs" "$STAGE/cores"

cp -a "$ARM_BIN" "$STAGE/bin/misterplexd"
chmod +x "$STAGE/bin/misterplexd"
if [[ -f "$ROOT/build/arm/push_frame" ]]; then
  cp -a "$ROOT/build/arm/push_frame" "$STAGE/bin/push_frame"
  chmod +x "$STAGE/bin/push_frame"
fi
if [[ -f "$ROOT/build/arm/set_status" ]]; then
  cp -a "$ROOT/build/arm/set_status" "$STAGE/bin/set_status"
  chmod +x "$STAGE/bin/set_status"
fi

# ffmpeg: bundled so a fresh install needs nothing else. GPLv3 obliges us to ship
# the licence text and say exactly which build this is and where its source lives.
if [[ -f "$FFMPEG_ARMHF" ]]; then
  cp -a "$FFMPEG_ARMHF" "$STAGE/bin/ffmpeg"
  chmod +x "$STAGE/bin/ffmpeg"
  mkdir -p "$STAGE/licenses/ffmpeg"
  FFMPEG_SRC_DIR="$(dirname "$FFMPEG_ARMHF")"
  for lic in GPLv3.txt readme.txt; do
    [[ -f "$FFMPEG_SRC_DIR/$lic" ]] && cp -a "$FFMPEG_SRC_DIR/$lic" "$STAGE/licenses/ffmpeg/"
  done
  cat >"$STAGE/licenses/ffmpeg/README.md" <<'EOF'
# Bundled ffmpeg

`bin/ffmpeg` is an unmodified static armhf build of **FFmpeg 7.0.2**, produced by
John Van Sickle and redistributed here so that MiSTerPlex works out of the box.

It is configured with `--enable-gpl --enable-version3` and is therefore licensed
under the **GNU General Public License, version 3**. The full licence text is in
`GPLv3.txt`, and `readme.txt` records the exact build configuration and the
version of every bundled library.

## Corresponding source

- FFmpeg 7.0.2 source: <https://ffmpeg.org/releases/ffmpeg-7.0.2.tar.xz>
- Build and source tarballs for this specific static build:
  <https://johnvansickle.com/ffmpeg/>

The binary is unmodified. It is a separate program that MiSTerPlex merely invokes
as a subprocess, so it is an aggregate: bundling it does not place MiSTerPlex's
own sources under the GPLv3.

## Replacing it

Any statically linked armhf ffmpeg with HTTPS support will do. Replace
`bin/ffmpeg`, or point `FFMPEG=` in `misterplex.conf` at another binary.
EOF
  echo "Included bin/ffmpeg from $FFMPEG_ARMHF ($(wc -c <"$STAGE/bin/ffmpeg") bytes) + GPLv3 licence"
else
  echo "NOTE: static armhf ffmpeg not found at $FFMPEG_ARMHF"
  if [[ "${PACKAGE_ALLOW_NO_FFMPEG:-0}" != "1" ]]; then
    echo "ERROR: bin/ffmpeg missing — set FFMPEG_ARMHF=/path/to/ffmpeg or PACKAGE_ALLOW_NO_FFMPEG=1."
    exit 1
  fi
fi

if [[ -f "$CONF_EX" ]]; then
  cp -a "$CONF_EX" "$STAGE/conf/misterplex.conf.example"
else
  cat >"$STAGE/conf/misterplex.conf.example" <<'EOF'
# Set this to your Plex Media Server, for example:
# PLEX_BASE=http://YOUR-PLEX-SERVER:32400
DECODE=320x240
PRESENT=fb0
STREAM=0
OSD_CONTROL=1
MATCH_SOURCE_HZ=off
EOF
fi

# RBF: releases must package the exact hardware-validated bitstream. Do not
# silently search output_files/, releases/, or MISTER_DEV: stale local cores are
# indistinguishable by path and have already nearly shipped once. Operators may
# pass RBF_PATH=/path/to/Plex.rbf, but every candidate is gated by this MD5.
if [[ -n "${PACKAGE_ALLOW_NO_RBF:-}" || -n "${PACKAGE_DAEMON_ONLY:-}" ]]; then
  echo "ERROR: daemon-only packages are disabled for release builds; v0.3.0 must ship a verified Plex.rbf." >&2
  exit 1
fi
if [[ ! -f "$RBF_SRC" ]]; then
  echo "ERROR: verified release core missing: $RBF_SRC" >&2
  echo "       Use the tracked release_artifacts/v0.3.0/Plex.rbf, or set RBF_PATH to a core with MD5 $RBF_MD5_EXPECTED." >&2
  exit 1
fi
RBF_MD5_ACTUAL="$(md5sum "$RBF_SRC" | awk '{print $1}')"
if [[ "$RBF_MD5_ACTUAL" != "$RBF_MD5_EXPECTED" ]]; then
  echo "ERROR: refusing to package unverified Plex.rbf: $RBF_SRC" >&2
  echo "       expected md5: $RBF_MD5_EXPECTED" >&2
  echo "       actual md5:   $RBF_MD5_ACTUAL" >&2
  echo "       v0.3.0 ships only the Phase A playback-controls core validated on hardware." >&2
  exit 1
fi
cp -a "$RBF_SRC" "$STAGE/cores/Plex.rbf"
echo "Included verified cores/Plex.rbf from $RBF_SRC ($(wc -c <"$STAGE/cores/Plex.rbf") bytes, md5=$RBF_MD5_ACTUAL)"

# Operator docs
for doc in release.md release-notes-v0.3.0.md display-resolution.md match-source-hz.md crt-lcd-matrix.md architecture.md subtitles-burnin.md; do
  if [[ -f "$ROOT/docs/$doc" ]]; then
    cp -a "$ROOT/docs/$doc" "$STAGE/docs/"
  fi
done
mkdir -p "$STAGE/scripts"
for scr in plex_browse.sh plex_menu.sh; do
  if [[ -f "$ROOT/scripts/$scr" ]]; then
    cp -a "$ROOT/scripts/$scr" "$STAGE/scripts/"
    chmod +x "$STAGE/scripts/$scr"
  fi
done

# Path notes for operators (also docs/INSTALL.txt)
cat >"$STAGE/README.txt" <<EOF
MiSTerPlex release package
version: ${VERSION}

Contents
--------
  bin/misterplexd          static ARM companion + media daemon
  bin/ffmpeg               static armhf FFmpeg 7.0.2 (GPLv3 — see licenses/ffmpeg)
  bin/push_frame           optional SPI frame/bitstream tool
  bin/set_status           optional OSD status RMW tool (pattern/TV/FPS/…)
  conf/misterplex.conf.example
  cores/Plex.rbf           Phase A playback-controls core (MD5 41adb98c7a630b541091c22ce291be68)
  scripts/plex_browse.sh   list library + play/status/stop via misterplexd
  scripts/plex_menu.sh     interactive on-device menu (sections → playMedia)
  licenses/ffmpeg/         GPLv3 text, build provenance, source pointers
  docs/                    install/release, display resolution, match-source-Hz, subtitles

Quick install from this extracted directory
-------------------------------------------
  ssh root@<mister-ip> "mkdir -p /media/fat/misterplex /media/fat/_Utility"
  scp -r bin scripts docs licenses root@<mister-ip>:/media/fat/misterplex/
  scp conf/misterplex.conf.example root@<mister-ip>:/media/fat/misterplex/misterplex.conf
  scp cores/Plex.rbf root@<mister-ip>:/media/fat/_Utility/Plex.rbf

Install on MiSTer SD
--------------------
  /media/fat/misterplex/bin/misterplexd
  /media/fat/misterplex/bin/ffmpeg        # bundled static armhf FFmpeg (GPLv3)
  /media/fat/misterplex/misterplex.conf   # copy from conf example; set PLEX_* / DECODE / PRESENT
  /media/fat/linux/_user-startup.sh      # start daemon (see scripts/deploy_misterplexd.sh)
  /media/fat/_Utility/Plex.rbf           # verified v0.3.0 core; md5 41adb98c7a630b541091c22ce291be68

Configure Plex server and credentials
-------------------------------------
  Edit /media/fat/misterplex/misterplex.conf:
    PLEX_BASE=http://YOUR-PLEX-SERVER:32400
    PLEX_TOKEN=<optional-token>

  PLEX_BASE points at your Plex Media Server. Cast sessions usually supply a
  transient X-Plex-Token, so PLEX_TOKEN is optional for casting. Set PLEX_TOKEN
  if you want on-device library browsing via scripts/plex_browse.sh or
  scripts/plex_menu.sh.

Start on boot
-------------
  Append this to /media/fat/linux/_user-startup.sh:

    /media/fat/misterplex/bin/misterplexd \\
      --name MiSTerPlex --id misterplex --port 3005 \\
      --conf /media/fat/misterplex/misterplex.conf \\
      >>/media/fat/misterplex/misterplexd.log 2>&1 &

  Then reboot, or run that command once over SSH for a first test.

Launch the core
---------------
  On MiSTer, open the OSD with F12 and load Plex from _Utility. After the daemon
  is running, Plex apps on the same network should offer MiSTerPlex as a cast
  target. Verify with:

    curl http://<mister-ip>:3005/resources

Plex.rbf locations (release / device)
-------------------------------------
  In this monorepo for v0.3.0 packaging:
    release_artifacts/v0.3.0/Plex.rbf          # tracked, MD5-gated release core

  Override only with an explicitly validated core:
    RBF_PATH=/path/to/Plex.rbf make package    # must md5 to 41adb98c7a630b541091c22ce291be68

  On MiSTer (lab canonical):
    /media/fat/_Utility/Plex.rbf
  Alternates (OSD folders):
    /media/fat/_Arcade/Plex.rbf   or
    /media/fat/games/Plex/Plex.rbf
  Load core from OSD; misterplexd is independent of which core is running
  for Phase 2 fb0/MrAudio, but Phase 3 STREAM/FPGA present needs Plex.rbf.

PRESENT / STREAM (conf)
-----------------------
  PRESENT=fb0|fpga|both     default fb0 (Phase 2 cast path)
  STREAM=0|1                annex-B → host I-recon F1 + F3 (STREAM hybrid 3.3k)
  Host recon owns present until FPGA 3.3l mae-competitive. See docs/release.md.
  Lab: bin/set_status --pattern grid --force-bars 1 --raw

Deploy helper (from dev host)
-----------------------------
  ./scripts/deploy_misterplexd.sh
  ./scripts/deploy_plex_core.sh     # copies RBF when built
  make package                      # this tarball

Phase notes
-----------
  Phase 2: companion :3005 + FFmpeg → fb0 + MrAudio
  Phase 3: FPGA decode (in progress) — does not block cast UX
  Phase 4: multi-server, browse/menu UX, Content FPS hint, scrubber steps, auto-next
  Phase 5: release docs, CRT/LCD matrix, hardened multi-title soak
  Full docs: docs/release.md docs/crt-lcd-matrix.md docs/match-source-hz.md docs/subtitles-burnin.md

On-device play (no cast phone)
-----------------------------
  /media/fat/misterplex/scripts/plex_browse.sh play <ratingKey>
  /media/fat/misterplex/scripts/plex_menu.sh
  # needs PLEX_TOKEN in misterplex.conf for library list; play hits :3005
EOF
cp -a "$STAGE/README.txt" "$STAGE/docs/INSTALL.txt"

# Checksums for every shipped payload file. The manifest necessarily excludes
# itself, then verifies before tar creation so coverage cannot silently regress.
(
  cd "$STAGE"
  find . -type f ! -name SHA256SUMS -printf '%P\0' | sort -z | xargs -0 sha256sum
) >"$STAGE/SHA256SUMS"
(
  cd "$STAGE"
  sha256sum -c SHA256SUMS
)

mkdir -p "$OUT_DIR"
# Extract as misterplex-<version>/ rather than leaking the staging directory name.
tar -C "$STAGE/.." --transform="s|^$(basename "$STAGE")|misterplex-${VERSION}|" \
  -czf "$TAR" "$(basename "$STAGE")"
ls -la "$TAR"
echo "Packaged → $TAR"
echo "RBF: present ($(wc -c <"$STAGE/cores/Plex.rbf") bytes, md5=$(md5sum "$STAGE/cores/Plex.rbf" | awk '{print $1}'))"
file "$STAGE/bin/misterplexd" || true
# Fail soft-list of expected docs
for need in docs/release.md docs/INSTALL.txt conf/misterplex.conf.example bin/misterplexd; do
  [[ -e "$STAGE/$need" ]] || { echo "ERROR: missing $need in stage"; exit 1; }
done
echo "package_release: OK"
