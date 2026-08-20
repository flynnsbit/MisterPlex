#!/usr/bin/env bash
# Package misterplexd ARM binary + conf example + named RBF pairs + docs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null || echo dev)}"
OUT_DIR="${OUT_DIR:-$ROOT/dist}"
STAGE="$OUT_DIR/stage-misterplex"
TAR="$OUT_DIR/misterplex-${VERSION}.tar.gz"

ARM_BIN="$ROOT/build/arm/misterplexd"
PAIRED=0
PAIR_ART="$ROOT/release_artifacts/v0.9.0-pre-paired"

# Dual-gate: v0.9.0-pre ships named gold pairs; older lines keep one Plex.rbf.
# Override either path or md5 via RBF_PATH / RBF_MD5_EXPECTED for lab freezes.
MD5_480P_RBF="07f54d9f8f0eda2fe75d9cc314f6de54"
MD5_240P15_RBF="4d6efef954acf7b33747f35ac2878c1b"
MD5_480I_RBF="61db00e7d54efad7c1a456b127b798bd"
MD5_720P24_RBF="0eea3580a5a0dacf60bf65c50499bcc9"
MD5_480P_DAEMON="5f1c861486844f4c83bf32a2112cfbb6"
MD5_720P24_DAEMON="0ffc1483677ef5733971d4f18e4624e4"

case "$VERSION" in
  v0.9.0-pre*|0.9.0-pre*)
    PAIRED=1
    RBF_MD5_EXPECTED="${RBF_MD5_EXPECTED:-$MD5_480P_RBF}"
    RBF_DEFAULT="$PAIR_ART/cores/Plex_480p.rbf"
    ;;
  v0.4.0*|0.4.0*)
    # softc24 HOLD=2 + CONF_STR v9 Content O[5:4] + Display O[15:14] Follow
    RBF_MD5_EXPECTED="${RBF_MD5_EXPECTED:-1c6ed06fe832fb54259d4f4ce504ccae}"
    RBF_DEFAULT="$ROOT/release_artifacts/v0.4.0/Plex.rbf"
    ;;
  *)
    RBF_MD5_EXPECTED="${RBF_MD5_EXPECTED:-41adb98c7a630b541091c22ce291be68}"
    RBF_DEFAULT="$ROOT/release_artifacts/v0.3.0/Plex.rbf"
    ;;
esac
RBF_SRC="${RBF_PATH:-$RBF_DEFAULT}"
CONF_EX="$ROOT/assets/misterplex.conf.example"
# Static armhf ffmpeg to bundle so the package is self-contained. Override with
# FFMPEG_ARMHF=/path/to/ffmpeg. It is GPLv3, so its licence and provenance ship
# alongside it (see the licenses/ffmpeg staging below).
FFMPEG_ARMHF="${FFMPEG_ARMHF:-$HOME/Projects/mistercast-linux/third_party/ffmpeg-armhf/ffmpeg}"
if [[ ! -f "$FFMPEG_ARMHF" ]]; then
  for cand in \
    "$PAIR_ART/bin/ffmpeg" \
    "$ROOT/release_artifacts/v0.9.0-pre-paired/bin/ffmpeg"; do
    if [[ -f "$cand" ]]; then
      FFMPEG_ARMHF="$cand"
      break
    fi
  done
fi

copy_gated_md5() {
  local src=$1 dest=$2 expect=$3
  [[ -f "$src" ]] || { echo "ERROR: missing $src" >&2; exit 1; }
  local actual
  actual="$(md5sum "$src" | awk '{print $1}')"
  if [[ "$actual" != "$expect" ]]; then
    echo "ERROR: refusing unverified $(basename "$src"): $src" >&2
    echo "       expected md5: $expect" >&2
    echo "       actual md5:   $actual" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$dest")"
  cp -a "$src" "$dest"
  echo "Included $(basename "$dest") from $src ($(wc -c <"$dest") bytes, md5=$actual)"
}

echo "=== package_release $VERSION paired=$PAIRED ==="

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

if [[ "$PAIRED" == "1" ]]; then
  copy_gated_md5 "$PAIR_ART/bin/misterplexd.480p" "$STAGE/bin/misterplexd.480p" "$MD5_480P_DAEMON"
  copy_gated_md5 "$PAIR_ART/bin/misterplexd.720p24" "$STAGE/bin/misterplexd.720p24" "$MD5_720P24_DAEMON"
  cp -a "$STAGE/bin/misterplexd.480p" "$STAGE/bin/misterplexd.240p15"
  cp -a "$STAGE/bin/misterplexd.480p" "$STAGE/bin/misterplexd.480i"
  # Direct-run default is the 480p gold daemon. Current-tree rebuild is
  # recorded next to it; do not overwrite the frozen pair.
  cp -a "$STAGE/bin/misterplexd.480p" "$STAGE/bin/misterplexd"
  SRC_MD5="$(md5sum "$ARM_BIN" | awk '{print $1}')"
  echo "Source-tree arm misterplexd md5=$SRC_MD5 (not shipped as a pair; freeze 480p=$MD5_480P_DAEMON 720p24=$MD5_720P24_DAEMON)"
  cp -a "$ARM_BIN" "$STAGE/bin/misterplexd.src-built"
  chmod +x "$STAGE/bin/misterplexd.src-built"
else
  cp -a "$ARM_BIN" "$STAGE/bin/misterplexd"
  chmod +x "$STAGE/bin/misterplexd"
fi
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
MATCH_SOURCE_HZ=off
EOF
fi

# RBF: releases must package the exact hardware-validated bitstream. Do not
# silently search output_files/, releases/, or MISTER_DEV: stale local cores are
# indistinguishable by path and have already nearly shipped once. Operators may
# pass RBF_PATH=/path/to/Plex.rbf, but every candidate is gated by this MD5.
if [[ -n "${PACKAGE_ALLOW_NO_RBF:-}" || -n "${PACKAGE_DAEMON_ONLY:-}" ]]; then
  echo "ERROR: daemon-only packages are disabled for release builds; $VERSION must ship a verified Plex.rbf." >&2
  exit 1
fi
if [[ "$RBF_MD5_EXPECTED" == "REPLACE_AT_FREEZE" ]]; then
  echo "ERROR: RBF_MD5_EXPECTED still REPLACE_AT_FREEZE for $VERSION." >&2
  echo "       Freeze a LOCK_OK core into release_artifacts/ and set RBF_MD5_EXPECTED=<md5>." >&2
  exit 1
fi

RBF_MD5_ACTUAL=""
if [[ "$PAIRED" == "1" ]]; then
  copy_gated_md5 "$PAIR_ART/cores/Plex_480p.rbf" "$STAGE/cores/Plex_480p.rbf" "$MD5_480P_RBF"
  copy_gated_md5 "$PAIR_ART/cores/Plex_240p15.rbf" "$STAGE/cores/Plex_240p15.rbf" "$MD5_240P15_RBF"
  copy_gated_md5 "$PAIR_ART/cores/Plex_480i.rbf" "$STAGE/cores/Plex_480i.rbf" "$MD5_480I_RBF"
  copy_gated_md5 "$PAIR_ART/cores/Plex_720p24.rbf" "$STAGE/cores/Plex_720p24.rbf" "$MD5_720P24_RBF"
  RBF_MD5_ACTUAL="$MD5_480P_RBF"
  cp -a "$PAIR_ART/rbf_daemon_pairs.txt" "$STAGE/rbf_daemon_pairs.txt"
  cp -a "$PAIR_ART/Plex_README.txt" "$STAGE/Plex_README.txt"
  cp -a "$PAIR_ART/README.md" "$STAGE/README.md"
  # No generic Plex.rbf — every sibling reports CORENAME=Plex.
else
  if [[ ! -f "$RBF_SRC" ]]; then
    echo "ERROR: verified release core missing: $RBF_SRC" >&2
    echo "       Use release_artifacts for $VERSION, or set RBF_PATH to a core with MD5 $RBF_MD5_EXPECTED." >&2
    exit 1
  fi
  RBF_MD5_ACTUAL="$(md5sum "$RBF_SRC" | awk '{print $1}')"
  if [[ "$RBF_MD5_ACTUAL" != "$RBF_MD5_EXPECTED" ]]; then
    echo "ERROR: refusing to package unverified Plex.rbf: $RBF_SRC" >&2
    echo "       expected md5: $RBF_MD5_EXPECTED" >&2
    echo "       actual md5:   $RBF_MD5_ACTUAL" >&2
    echo "       $VERSION ships only a hardware-validated core (see docs/release-notes-${VERSION#v}.md)." >&2
    exit 1
  fi
  cp -a "$RBF_SRC" "$STAGE/cores/Plex.rbf"
  echo "Included verified cores/Plex.rbf from $RBF_SRC ($(wc -c <"$STAGE/cores/Plex.rbf") bytes, md5=$RBF_MD5_ACTUAL)"
fi

# Operator docs
for doc in release.md release-notes-v0.3.0.md release-notes-v0.4.0.md release-notes-v0.9.0-pre.md display-resolution.md match-source-hz.md crt-lcd-matrix.md architecture.md subtitles-burnin.md glass-baseline-pair.md; do
  if [[ -f "$ROOT/docs/$doc" ]]; then
    cp -a "$ROOT/docs/$doc" "$STAGE/docs/"
  fi
done
mkdir -p "$STAGE/scripts"
for scr in plex_browse.sh plex_menu.sh misterplexd_supervise.sh misterplex_core_watch.sh misterplex_cast_ready.sh misterplex_pair_conf.sh misterplex_named_rbf.sh install_paired_all.sh pms_720p_proxy.py; do
  if [[ -f "$ROOT/scripts/$scr" ]]; then
    cp -a "$ROOT/scripts/$scr" "$STAGE/scripts/"
    chmod +x "$STAGE/scripts/$scr"
  fi
done
# Boot helpers also under bin/ so _user-startup paths stay short.
for scr in misterplexd_supervise.sh misterplex_core_watch.sh misterplex_cast_ready.sh misterplex_pair_conf.sh misterplex_named_rbf.sh; do
  if [[ -f "$STAGE/scripts/$scr" ]]; then
    cp -a "$STAGE/scripts/$scr" "$STAGE/bin/$scr"
  fi
done

if [[ -d "$ROOT/kmod/mplex_ddr" ]]; then
  mkdir -p "$STAGE/kmod/mplex_ddr"
  cp -a "$ROOT/kmod/mplex_ddr/mplex_ddr.c" "$ROOT/kmod/mplex_ddr/Makefile" "$STAGE/kmod/mplex_ddr/"
fi

# Path notes for operators (also docs/INSTALL.txt)
if [[ "$PAIRED" == "1" ]]; then
  cat >"$STAGE/README.txt" <<EOF
MiSTerPlex pre-release package
version: ${VERSION}

Named cores (pick ONE from _Utility — no generic Plex.rbf)
----------------------------------------------------------
  cores/Plex_480p.rbf     HDMI 240p/480p  md5 ${MD5_480P_RBF}
  cores/Plex_240p15.rbf   15 kHz 240p CRT md5 ${MD5_240P15_RBF}
  cores/Plex_480i.rbf     15 kHz 480i CRT md5 ${MD5_480I_RBF}
  cores/Plex_720p24.rbf   HDMI 720p24 lab md5 ${MD5_720P24_RBF}

  bin/misterplexd.480p    gold daemon (also .240p15 / .480i)
  bin/misterplexd.720p24  lab 720p remux-PCM daemon
  bin/misterplexd         copy of .480p (direct-run default)
  rbf_daemon_pairs.txt    watcher map

Install
-------
  ./scripts/install_paired_all.sh

Or from the repo freeze:
  REL=release_artifacts/v0.9.0-pre-paired ./scripts/install_paired_all.sh

Set PLEX_BASE in /media/fat/misterplex/misterplex.conf.
See docs/release-notes-v0.9.0-pre.md for 720p findings.
EOF
else
  cat >"$STAGE/README.txt" <<EOF
MiSTerPlex release package
version: ${VERSION}

Contents
--------
  bin/misterplexd               static ARM companion + media daemon
  bin/misterplex_core_watch.sh  start daemon on boot / when Plex core loads
  bin/misterplexd_supervise.sh  respawn misterplexd on crash
  bin/ffmpeg                    static armhf FFmpeg 7.0.2 (GPLv3 — see licenses/ffmpeg)
  bin/push_frame                optional SPI frame/bitstream tool
  bin/set_status                optional OSD status RMW tool (pattern/TV/FPS/…)
  conf/misterplex.conf.example
  cores/Plex.rbf                hardware-validated core (MD5 ${RBF_MD5_ACTUAL})
  scripts/plex_browse.sh        list library + play/status/stop via misterplexd
  scripts/plex_menu.sh          interactive on-device menu (sections → playMedia)
  licenses/ffmpeg/              GPLv3 text, build provenance, source pointers
  docs/                         install/release, display resolution, match-source-Hz, subtitles

Quick install from this extracted directory
-------------------------------------------
  ssh root@<mister-ip> "mkdir -p /media/fat/misterplex /media/fat/_Utility"
  scp -r bin scripts docs licenses root@<mister-ip>:/media/fat/misterplex/
  scp conf/misterplex.conf.example root@<mister-ip>:/media/fat/misterplex/misterplex.conf
  scp cores/Plex.rbf root@<mister-ip>:/media/fat/_Utility/Plex.rbf
EOF
fi
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
if [[ "$PAIRED" == "1" ]]; then
  echo "RBFs: Plex_480p/240p15/480i/720p24 (named; no generic Plex.rbf)"
else
  echo "RBF: present ($(wc -c <"$STAGE/cores/Plex.rbf") bytes, md5=$(md5sum "$STAGE/cores/Plex.rbf" | awk '{print $1}'))"
fi
file "$STAGE/bin/misterplexd" || true
# Fail soft-list of expected docs
for need in docs/release.md docs/INSTALL.txt conf/misterplex.conf.example bin/misterplexd; do
  [[ -e "$STAGE/$need" ]] || { echo "ERROR: missing $need in stage"; exit 1; }
done
if [[ "$PAIRED" == "1" ]]; then
  for need in cores/Plex_480p.rbf cores/Plex_240p15.rbf cores/Plex_480i.rbf cores/Plex_720p24.rbf \
              bin/misterplexd.480p bin/misterplexd.720p24 rbf_daemon_pairs.txt; do
    [[ -e "$STAGE/$need" ]] || { echo "ERROR: missing $need in stage"; exit 1; }
  done
  if [[ -e "$STAGE/cores/Plex.rbf" ]]; then
    echo "ERROR: generic cores/Plex.rbf must not ship in paired $VERSION" >&2
    exit 1
  fi
fi
echo "package_release: OK"
