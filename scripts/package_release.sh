#!/usr/bin/env bash
# Package misterplexd ARM binary + conf example + Plex.rbf + docs for SD deploy.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Plain `make package` builds the current published release. Development/lab
# pair wrappers pass an explicit VERSION plus exact RBF_PATH and DAEMON_PATH.
VERSION="${VERSION:-v0.4.1}"
OUT_DIR="${OUT_DIR:-$ROOT/dist}"
STAGE="$OUT_DIR/stage-misterplex"
TAR="$OUT_DIR/misterplex-${VERSION}.tar.gz"

ARM_BIN="$ROOT/build/arm/misterplexd"
DAEMON_MD5_PINNED=""
DAEMON_SHA256_PINNED=""
DAEMON_GZ_DEFAULT=""
# Each published release line uses its own immutable, hardware-validated RBF.
# RBF_PATH may point at a byte-identical copy; the per-version MD5 cannot be
# overridden. Packaging never rebuilds or reattributes these frozen artifacts.
case "$VERSION" in
  v0.4.1|0.4.1|v0.4.1-*|0.4.1-*|v0.4.1+*|0.4.1+*)
    # Already-published true480 artifact; immutable across source merges.
    RBF_MD5_PINNED="07f54d9f8f0eda2fe75d9cc314f6de54"
    RBF_DEFAULT="$ROOT/release_artifacts/v0.4.1/Plex.rbf"
    DAEMON_MD5_PINNED="f44c0dc1610561a8278e8fd4ece9aa53"
    DAEMON_SHA256_PINNED="646645ca2fb276c8266ee360a9df67b1dfefe91f67241e71f12b9ebfb880f6c8"
    DAEMON_GZ_DEFAULT="$ROOT/release_artifacts/v0.4.1/misterplexd.gz"
    ;;
  v0.4.0|0.4.0|v0.4.0-*|0.4.0-*|v0.4.0+*|0.4.0+*)
    # softc24 HOLD=2 + CONF_STR v9 Content O[5:4] + Display O[15:14] Follow
    RBF_MD5_PINNED="1c6ed06fe832fb54259d4f4ce504ccae"
    RBF_DEFAULT="$ROOT/release_artifacts/v0.4.0/Plex.rbf"
    ;;
  v0.3.0|0.3.0|v0.3.0-*|0.3.0-*|v0.3.0+*|0.3.0+*)
    RBF_MD5_PINNED="41adb98c7a630b541091c22ce291be68"
    RBF_DEFAULT="$ROOT/release_artifacts/v0.3.0/Plex.rbf"
    ;;
  *)
    if [[ -z "${RBF_PATH:-}" || -z "${DAEMON_PATH:-}" ]]; then
      echo "ERROR: unsupported release VERSION=$VERSION without an explicit validated pair." >&2
      echo "       Set both RBF_PATH and DAEMON_PATH; pair_ship_policy still gates them." >&2
      exit 1
    fi
    RBF_DEFAULT="$RBF_PATH"
    RBF_MD5_PINNED="$(md5sum "$RBF_PATH" | awk '{print $1}')"
    ;;
esac
if [[ -n "${RBF_MD5_EXPECTED:-}" && "$RBF_MD5_EXPECTED" != "$RBF_MD5_PINNED" ]]; then
  echo "ERROR: refusing RBF_MD5_EXPECTED override for immutable $VERSION artifact." >&2
  echo "       pinned md5: $RBF_MD5_PINNED" >&2
  exit 1
fi
RBF_MD5_EXPECTED="$RBF_MD5_PINNED"
RBF_SRC="${RBF_PATH:-$RBF_DEFAULT}"
RBF_REL="${RBF_DEFAULT#"$ROOT/"}"
CONF_EX="$ROOT/assets/misterplex.conf.example"
# Static armhf ffmpeg to bundle so the package is self-contained. Override with
# FFMPEG_ARMHF=/path/to/ffmpeg. It is GPLv3, so its licence and provenance ship
# alongside it (see the licenses/ffmpeg staging below).
# Prefer a repo-local staged binary (see scripts/fetch_release_ffmpeg.sh) over the
# machine-local mistercast-linux path so clean checkouts fail closed with a clear
# remedy instead of silently missing a sibling-tree dependency.
if [[ -z "${FFMPEG_ARMHF:-}" ]]; then
  if [[ -f "$ROOT/release_artifacts/ffmpeg-armhf/ffmpeg" ]]; then
    FFMPEG_ARMHF="$ROOT/release_artifacts/ffmpeg-armhf/ffmpeg"
  else
    FFMPEG_ARMHF="$HOME/Projects/mistercast-linux/third_party/ffmpeg-armhf/ffmpeg"
  fi
fi

echo "=== package_release $VERSION ==="

# Always rebuild rather than reusing whatever happens to sit in build/arm.
# A stale binary here silently shipped a pre-cleanup daemon that still carried
# a hardcoded private PMS address, so "the file exists" is not evidence that it
# matches the source being released. make handles the up-to-date check properly
# via its dependencies; a missing toolchain now fails loudly instead of
# packaging an unrelated build.
echo "Building arm misterplexd…"
export PATH="${PATH}:${ARM_TOOLCHAIN_BIN:-$HOME/Projects/mistercast-linux/third_party/arm-gnu-toolchain/bin}"
# DAEMON_PATH ships a specific, already-validated daemon binary instead of a
# fresh build. Without it this script could never produce a shippable release:
# it rebuilds the daemon on every run, so its md5 changes with any source edit
# and can therefore never match a hardware-validated row in the pair matrix,
# while the core stayed pinned to a fixed md5. The two could not both be
# satisfied, so `make package` refused unconditionally. A gate that can only
# ever say no is not a shipping path.
DAEMON_SRC="${DAEMON_PATH:-}"
if [[ -z "$DAEMON_SRC" && -n "$DAEMON_GZ_DEFAULT" ]]; then
  [[ -f "$DAEMON_GZ_DEFAULT" ]] || {
    echo "ERROR: frozen release daemon missing: $DAEMON_GZ_DEFAULT" >&2
    exit 1
  }
  DAEMON_SRC="$ROOT/build/release-daemon/${VERSION}/misterplexd"
  mkdir -p "$(dirname "$DAEMON_SRC")"
  gzip -cd "$DAEMON_GZ_DEFAULT" >"$DAEMON_SRC"
  chmod +x "$DAEMON_SRC"
fi
if [[ -n "$DAEMON_SRC" ]]; then
  [[ -f "$DAEMON_SRC" ]] || { echo "ERROR: DAEMON_PATH not found: $DAEMON_SRC" >&2; exit 1; }
  daemon_md5="$(md5sum "$DAEMON_SRC" | awk '{print $1}')"
  daemon_sha256="$(sha256sum "$DAEMON_SRC" | awk '{print $1}')"
  if [[ -n "$DAEMON_MD5_PINNED" && "$daemon_md5" != "$DAEMON_MD5_PINNED" ]]; then
    echo "ERROR: immutable $VERSION daemon MD5 mismatch." >&2
    echo "       expected $DAEMON_MD5_PINNED actual $daemon_md5" >&2
    exit 1
  fi
  if [[ -n "$DAEMON_SHA256_PINNED" && "$daemon_sha256" != "$DAEMON_SHA256_PINNED" ]]; then
    echo "ERROR: immutable $VERSION daemon SHA-256 mismatch." >&2
    echo "       expected $DAEMON_SHA256_PINNED actual $daemon_sha256" >&2
    exit 1
  fi
  echo "Using pre-validated daemon: $DAEMON_SRC (md5=$daemon_md5 sha256=$daemon_sha256)"
  ARM_BIN="$DAEMON_SRC"
else
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
PRESENT=fpga
STREAM=0
OSD_CONTROL=auto
IDLE_SCREEN=logo
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
echo "Frozen release artifact only; current merged source did not build this RBF."

# Operator docs
for doc in release.md release-notes-v0.3.0.md release-notes-v0.4.0.md release-notes-v0.4.1.md display-resolution.md match-source-hz.md crt-lcd-matrix.md architecture.md subtitles-burnin.md; do
  if [[ -f "$ROOT/docs/$doc" ]]; then
    cp -a "$ROOT/docs/$doc" "$STAGE/docs/"
  fi
done
if [[ -d "$ROOT/examples/plex-cors-proxy" ]]; then
  mkdir -p "$STAGE/examples"
  cp -a "$ROOT/examples/plex-cors-proxy" "$STAGE/examples/"
fi
mkdir -p "$STAGE/scripts"
for scr in plex_browse.sh plex_menu.sh misterplexd_supervise.sh misterplex_core_watch.sh; do
  if [[ -f "$ROOT/scripts/$scr" ]]; then
    cp -a "$ROOT/scripts/$scr" "$STAGE/scripts/"
    chmod +x "$STAGE/scripts/$scr"
  fi
done
# Boot helpers also under bin/ so _user-startup paths stay short.
for scr in misterplexd_supervise.sh misterplex_core_watch.sh; do
  if [[ -f "$STAGE/scripts/$scr" ]]; then
    cp -a "$STAGE/scripts/$scr" "$STAGE/bin/$scr"
  fi
done

# Path notes for operators (also docs/INSTALL.txt)
cat >"$STAGE/README.txt" <<EOF
MiSTerPlex release package
version: ${VERSION}

Contents
--------
  bin/misterplexd               static ARM companion + media daemon
  bin/misterplex_core_watch.sh  optional core-load watcher
  bin/misterplexd_supervise.sh  respawn misterplexd on crash
  bin/ffmpeg                    static armhf FFmpeg 7.0.2 (GPLv3 — see licenses/ffmpeg)
  bin/push_frame                optional SPI frame/bitstream tool
  bin/set_status                optional OSD status RMW tool (pattern/TV/FPS/…)
  conf/misterplex.conf.example
  cores/Plex.rbf                hardware-validated core (MD5 ${RBF_MD5_ACTUAL})
                                frozen from ${RBF_REL}; not built by current source
  scripts/plex_browse.sh        list library + play/status/stop via misterplexd
  scripts/plex_menu.sh          interactive on-device menu (sections → playMedia)
  examples/plex-cors-proxy/     Docker PMS dual-origin timeline fix
  licenses/ffmpeg/              GPLv3 text, build provenance, source pointers
  docs/                         install/release, display resolution, match-source-Hz, subtitles

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
  /media/fat/_Utility/Plex.rbf           # verified ${VERSION} core; md5 ${RBF_MD5_ACTUAL}

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
  The FPGA RBF cannot start Linux processes. Use the single-instance supervisor:

    bin/misterplexd_supervise.sh   # respawns misterplexd; records exit/death evidence
    bin/misterplex_core_watch.sh   # optional Plex-core load watcher

  Append this to /media/fat/linux/_user-startup.sh (deploy_misterplexd.sh does it):

    nohup /media/fat/misterplex/bin/misterplexd_supervise.sh \\
      >>/media/fat/misterplex/misterplexd_supervise.log 2>&1 &

Launch the core
---------------
  On MiSTer, open the OSD with F12 and load Plex from _Utility. Plex apps on the
  same network should offer MiSTerPlex as a cast target:

    curl http://<mister-ip>:3005/resources

Plex.rbf locations (release / device)
-------------------------------------
  In this monorepo packaging lane:
    ${RBF_REL}      # tracked, MD5-gated release core

  Override the path only with a byte-identical copy of that release artifact:
    RBF_PATH=/path/to/Plex.rbf make package

  On MiSTer (lab canonical):
    /media/fat/_Utility/Plex.rbf
  Alternates (OSD folders):
    /media/fat/_Arcade/Plex.rbf   or
    /media/fat/games/Plex/Plex.rbf
  Load core from OSD; misterplexd is independent of which core is running
  for Phase 2 fb0/MrAudio, but Phase 3 STREAM/FPGA present needs Plex.rbf.

PRESENT / STREAM (conf)
-----------------------
  PRESENT=fb0|fpga|both|none  default fpga (core HDMI idle/OSD; fb0 alone freezes idle)
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

# Ship-safety gate. The packaged (core, daemon) pair must be one the project's
# own ship policy accepts, and this runs BEFORE the tarball exists so a refused
# pair never becomes a downloadable artifact.
#
# Measured on hardware 2026-08-02 (parent, viewed pixels): packaging silently
# produced core 41adb98c + daemon 88e292fd, a combination pair_policy_check
# REFUSES. Installed on the device that tarball renders a BLACK SCREEN — the
# v0.3.0 core never frees a DDR bank for the DDR-era daemon, so every publish is
# dropped ("PLXD bank-select swap_pending, free_mask=0", frames_done frozen) and
# the idle paint fails. 90/90 captured frames had mean luma 0.00; rolling back to
# the stable pair on the same capture chain immediately restored the chevron.
#
# There is deliberately NO environment bypass. The supported way to ship a new
# pair is to hardware-validate it and add a row to scripts/pair_ship_policy.sh.
if [[ -f "$STAGE/cores/Plex.rbf" ]]; then
  pair_core_md5="$(md5sum "$STAGE/cores/Plex.rbf" | awk '{print $1}')"
  pair_daemon_md5="$(md5sum "$STAGE/bin/misterplexd" | awk '{print $1}')"
  if pair_verdict="$("$ROOT/scripts/pair_ship_policy.sh" check "$pair_core_md5" "$pair_daemon_md5" 2>&1)"; then
    echo "package_release: pair policy OK — $pair_verdict"
  else
    {
      echo "ERROR: refusing to package a (core, daemon) pair the ship policy rejects."
      echo "       $pair_verdict"
      echo "       core   = $pair_core_md5 ($STAGE/cores/Plex.rbf)"
      echo "       daemon = $pair_daemon_md5 ($STAGE/bin/misterplexd)"
      echo "       A mixed core/daemon pair black-screens the device; this was"
      echo "       reproduced on hardware, so it is not a theoretical risk."
      echo "       Keep the immutable release RBF. Supply its matching validated daemon"
      echo "       via DAEMON_PATH, or hardware-validate the pair and add a row to"
      echo "       scripts/pair_ship_policy.sh (PAIR_MATRIX_ROWS)."
    } >&2
    exit 6
  fi
fi

# Supplemental vf delivery gate. The pair policy above is the artifact-behavior
# authority: it binds exact daemon/core hashes to hardware validation. This gate
# classifies the staged daemon's policy vocabulary, then exercises the current
# checkout's reference planner for real PMS deliveries including 624x350.
# It does not execute the static ARM artifact on the packaging host.
if [[ -f "$STAGE/bin/misterplexd" ]]; then
  if ! vf_verdict="$("$ROOT/scripts/vf_delivery_behaviour_check.sh" "$STAGE/bin/misterplexd" 2>&1)"; then
    {
      echo "ERROR: refusing package: staged policy classification or reference vf plan failed."
      echo "$vf_verdict"
      echo "       Real PMS 624x350 into identity/unverified skip desyncs the raw pipe"
      echo "       (green field / zero frames). Rebuild misterplexd with product FOAR"
      echo "       into coded 624x480 and re-pin; do not ship a legacy identity policy."
    } >&2
    exit 7
  fi
  echo "package_release: vf policy/reference OK — $(printf '%s\n' "$vf_verdict" | grep 'VF_DELIVERY_OK' | tail -1)"
fi

mkdir -p "$OUT_DIR"
# Extract as misterplex-<version>/ rather than leaking the staging directory name.
# Force uid/gid 0 in the archive. /media/fat is exfat (no UNIX ownership);
# a tarball built as lab uid 1000 makes plain `tar xzf` fail with
# "Cannot change ownership to uid 1000" (true rc=2) on the only supported
# target even when every payload byte is correct. Parent-measured on device
# 2026-08-02: --owner=0 --group=0 --numeric-owner → plain tar xzf true rc=0.
tar -C "$STAGE/.." --transform="s|^$(basename "$STAGE")|misterplex-${VERSION}|" \
  --owner=0 --group=0 --numeric-owner \
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
