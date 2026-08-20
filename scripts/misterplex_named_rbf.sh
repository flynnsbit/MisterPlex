#!/bin/sh
# Named Utility RBF identity. Sourced by misterplex_core_watch.sh.
# Do not exec this file (no main).
#
# Every Plex_* sibling reports CORENAME/RBFNAME=Plex. A generic Plex.rbf
# (root or _Utility) therefore always hashes as whichever copy was last
# dropped there — 480p daemon on 720p24 fabric = no chevron, no play.

UTILITY_DIR="${MISTERPLEX_UTILITY:-${UTILITY_DIR:-/media/fat/_Utility}}"
LIVE_RBF="${MISTERPLEX_LIVE_RBF:-${LIVE_RBF:-$UTILITY_DIR/Plex_480p.rbf}}"
RBFNAME_FILE="${RBFNAME_FILE:-/tmp/RBFNAME}"
L4_PLXS_ADDR="${MISTERPLEX_L4_PLXS:-${L4_PLXS_ADDR:-0x3047F100}}"
T480_PLXS_ADDR="${MISTERPLEX_T480_PLXS:-${T480_PLXS_ADDR:-0x3007F100}}"
T480_PLXS_ADDR_B="${MISTERPLEX_T480_PLXS_B:-${T480_PLXS_ADDR_B:-0x300FF100}}"

# 720p24 fabric publishes PLXS/PLXJ/PLXD at 0x3047F1xx. 480p-class cores
# publish on 0x3007F000 / 0x300FF000. Leftover magics survive in HPS DRAM:
# leftover 480p PLXS must not beat a live L4 scanout (28cb5a75 was pinned
# true480 and GLASS-MAX capped 1280x720 → 640x480). Changing PLXD wins.
# Static leftovers: PLXJ (0x504C584A) is L4-only.
L4_PLXD_ADDR="${MISTERPLEX_L4_PLXD:-${L4_PLXD_ADDR:-0x3047F12C}}"
L4_PLXJ_ADDR="${MISTERPLEX_L4_PLXJ:-${L4_PLXJ_ADDR:-0x3047F130}}"
T480_PLXD_ADDR="${MISTERPLEX_T480_PLXD:-${T480_PLXD_ADDR:-0x3007F128}}"
T480_PLXD_ADDR_B="${MISTERPLEX_T480_PLXD_B:-${T480_PLXD_ADDR_B:-0x300FF128}}"
live_glass_is_l4() {
  if [ "${MPX_FORCE_LIVE_GLASS:-}" = "L4" ] || [ "${MPX_FORCE_LIVE_GLASS:-}" = "l4" ]; then
    return 0
  fi
  if [ -n "${MPX_FORCE_LIVE_GLASS:-}" ]; then
    return 1
  fi
  DEVMEM=/usr/sbin/devmem
  if [ ! -x "$DEVMEM" ]; then
    DEVMEM=$(command -v devmem 2>/dev/null || true)
  fi
  [ -n "${DEVMEM:-}" ] && [ -x "$DEVMEM" ] || return 1
  l4a=$("$DEVMEM" "$L4_PLXD_ADDR" 32 2>/dev/null || echo 0)
  t4a=$("$DEVMEM" "$T480_PLXD_ADDR" 32 2>/dev/null || echo 0)
  t4ba=$("$DEVMEM" "$T480_PLXD_ADDR_B" 32 2>/dev/null || echo 0)
  sleep 0.1
  l4b=$("$DEVMEM" "$L4_PLXD_ADDR" 32 2>/dev/null || echo 0)
  t4b=$("$DEVMEM" "$T480_PLXD_ADDR" 32 2>/dev/null || echo 0)
  t4bb=$("$DEVMEM" "$T480_PLXD_ADDR_B" 32 2>/dev/null || echo 0)
  if [ "$l4a" != "$l4b" ]; then
    return 0
  fi
  if [ "$t4a" != "$t4b" ] || [ "$t4ba" != "$t4bb" ]; then
    return 1
  fi
  plxj=$("$DEVMEM" "$L4_PLXJ_ADDR" 32 2>/dev/null || echo 0)
  # case-as-status: grep last-in-function aborts busybox ash on miss.
  case "$plxj" in
    *504C584A*|*504c584a*) return 0 ;;
  esac
  l4=$("$DEVMEM" "$L4_PLXS_ADDR" 32 2>/dev/null || echo 0)
  t480=$("$DEVMEM" "$T480_PLXS_ADDR" 32 2>/dev/null || echo 0)
  t480b=$("$DEVMEM" "$T480_PLXS_ADDR_B" 32 2>/dev/null || echo 0)
  case "$t480 $t480b" in
    *504C5853*|*504c5853*) return 1 ;;
  esac
  case "$l4" in
    *504C5853*|*504c5853*) return 0 ;;
  esac
  return 1
}

resolve_loaded_rbf() {
  raw=$(tr -d '\000\r\n' <"$RBFNAME_FILE" 2>/dev/null || true)
  base=$(echo "$raw" | sed 's|.*/||; s|\.rbf$||; s|\.RBF$||')
  [ -n "$base" ] || base=Plex
  ut="$UTILITY_DIR"
  case "$base" in
    *[Pp]lex_720*|*[Pp]lex-720*)
      if [ -f "$ut/Plex_720p24.rbf" ]; then echo "$ut/Plex_720p24.rbf"; return 0; fi
      ;;
    *[Pp]lex_240*)
      if [ -f "$ut/Plex_240p15.rbf" ]; then echo "$ut/Plex_240p15.rbf"; return 0; fi
      ;;
    *[Pp]lex_480i*|*[Pp]lex-480i*)
      if [ -f "$ut/Plex_480i.rbf" ]; then echo "$ut/Plex_480i.rbf"; return 0; fi
      ;;
    *[Pp]lex_480p*|*[Pp]lex-480p*)
      if [ -f "$ut/Plex_480p.rbf" ]; then echo "$ut/Plex_480p.rbf"; return 0; fi
      ;;
  esac
  # CORENAME=Plex for every sibling — never hash a generic Plex.rbf.
  if live_glass_is_l4 && [ -f "$ut/Plex_720p24.rbf" ]; then
    echo "$ut/Plex_720p24.rbf"
    return 0
  fi
  if [ -f "$ut/Plex_480p.rbf" ]; then
    echo "$ut/Plex_480p.rbf"
    return 0
  fi
  for cand in "$ut/Plex_240p15.rbf" "$ut/Plex_480i.rbf"; do
    if [ -f "$cand" ]; then
      echo "$cand"
      return 0
    fi
  done
  echo "$LIVE_RBF"
}
