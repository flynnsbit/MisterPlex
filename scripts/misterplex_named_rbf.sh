#!/bin/sh
# Named Utility RBF identity. Sourced by misterplex_core_watch.sh.
# Do not exec this file (no main).
#
# Every Plex_* sibling reports CORENAME/RBFNAME=Plex. A generic Plex.rbf
# (root or _Utility) therefore always hashes as whichever copy was last
# dropped there — 480p daemon on 720p24 fabric = no chevron, no play.
#
# Pair by the RBF actually loaded: Main argv, then RBFNAME Utility path,
# then MISTERPLEX_LIVE_RBF. Leftover L4 PLXJ 0x504C584A at 0x3047F130 with
# frozen PLXD must not pin the 720p daemon on Plex_480p / Plex_240p15 /
# Plex_480i. A LIVE changing L4 PLXD still classifies L4.
# Lab one-pair: Plex_SDfamily.rbf md5 1e77c26d (mux6) + misterplexd.480p gold (5f1c8614).
# NOT gold / NOT rollback until parent marks unique+sync+tear.
# Never return generic /Plex.rbf. Gold 480p/240p15/480i stay rollback files.

UTILITY_DIR="${MISTERPLEX_UTILITY:-${UTILITY_DIR:-/media/fat/_Utility}}"
LIVE_RBF="${MISTERPLEX_LIVE_RBF:-${LIVE_RBF:-$UTILITY_DIR/Plex_480p.rbf}}"
RBFNAME_FILE="${RBFNAME_FILE:-/tmp/RBFNAME}"
CORENAME_FILE="${CORENAME_FILE:-/tmp/CORENAME}"
L4_PLXS_ADDR="${MISTERPLEX_L4_PLXS:-${L4_PLXS_ADDR:-0x3047F100}}"
T480_PLXS_ADDR="${MISTERPLEX_T480_PLXS:-${T480_PLXS_ADDR:-0x3007F100}}"
T480_PLXS_ADDR_B="${MISTERPLEX_T480_PLXS_B:-${T480_PLXS_ADDR_B:-0x300FF100}}"

# 720p24 fabric publishes PLXS/PLXJ/PLXD at 0x3047F1xx. 480p-class cores
# publish on 0x3007F000 / 0x300FF000. Leftover magics survive in HPS DRAM:
# leftover 480p PLXS must not beat a live L4 scanout (28cb5a75 was pinned
# true480 and GLASS-MAX capped 1280x720 → 640x480). Changing PLXD wins.
# Static leftover PLXJ (0x504C584A) is L4-only fabric, but sticky leftover
# must not win pairing when an SD-family RBF is loaded.
L4_PLXD_ADDR="${MISTERPLEX_L4_PLXD:-${L4_PLXD_ADDR:-0x3047F12C}}"
L4_PLXJ_ADDR="${MISTERPLEX_L4_PLXJ:-${L4_PLXJ_ADDR:-0x3047F130}}"
T480_PLXD_ADDR="${MISTERPLEX_T480_PLXD:-${T480_PLXD_ADDR:-0x3007F128}}"
T480_PLXD_ADDR_B="${MISTERPLEX_T480_PLXD_B:-${T480_PLXD_ADDR_B:-0x300FF128}}"

rbf_family_from_path() {
  n=$(echo "$1" | sed 's|.*/||; s|\.rbf$||; s|\.RBF$||')
  case "$n" in
    *[Pp]lex_720*|*[Pp]lex-720*) echo l4 ;;
    *[Pp]lex_240*) echo sd240 ;;
    *[Pp]lex_480i*|*[Pp]lex-480i*) echo sd480i ;;
    *[Pp]lex_480p*|*[Pp]lex-480p*) echo sd480 ;;
    [Pp]lex) echo generic ;;
    *) echo other ;;
  esac
}

utility_rbf_for_family() {
  ut="${UTILITY_DIR:-/media/fat/_Utility}"
  case "$1" in
    l4) echo "$ut/Plex_720p24.rbf" ;;
    sd240) echo "$ut/Plex_240p15.rbf" ;;
    sd480i) echo "$ut/Plex_480i.rbf" ;;
    sd480) echo "$ut/Plex_480p.rbf" ;;
    *) echo "" ;;
  esac
}

extract_named_plex_rbf_token() {
  for t in $1; do
    case "$t" in
      *[Pp]lex*.rbf|*[Pp]lex*.RBF)
        echo "$t"
        return 0
        ;;
    esac
  done
  return 1
}

main_argv_cmdline() {
  if [ -n "${MISTERPLEX_MAIN_ARGV+x}" ]; then
    printf '%s\n' "${MISTERPLEX_MAIN_ARGV:-}"
    return 0
  fi
  for c in /proc/[0-9]*/cmdline; do
    [ -r "$c" ] || continue
    raw=$(tr '\0' ' ' <"$c" 2>/dev/null || true)
    case "$raw" in
      *misterplex*) continue ;;
    esac
    case "$raw" in
      *MiSTer*|*mister*)
        case "$raw" in
          *[Pp]lex*.rbf*|*[Pp]lex*.RBF*)
            printf '%s\n' "$raw"
            return 0
            ;;
        esac
        ;;
    esac
  done
  if command -v ps >/dev/null 2>&1; then
    line=$(ps w 2>/dev/null | awk '/MiSTer/ && /[Pp]lex/ && /[.][rR][bB][fF]/ && !/misterplex/ {print; exit}')
    if [ -n "$line" ]; then
      printf '%s\n' "$line"
      return 0
    fi
  fi
  return 1
}

main_argv_rbf_path() {
  cmd=$(main_argv_cmdline) || cmd=""
  [ -n "$cmd" ] || return 1
  extract_named_plex_rbf_token "$cmd"
}

map_named_rbf_if_exists() {
  fam=$(rbf_family_from_path "$1")
  mapped=$(utility_rbf_for_family "$fam")
  if [ -n "$mapped" ] && [ -f "$mapped" ]; then
    echo "$mapped"
    return 0
  fi
  return 1
}

is_generic_plex_rbf() {
  n=$(echo "$1" | sed 's|.*/||')
  case "$n" in
    [Pp]lex.[Rr][Bb][Ff]) return 0 ;;
    *) return 1 ;;
  esac
}

read_name_file() {
  f=$1
  if [ -r "$f" ]; then
    tr -d '\000\r\n' <"$f" 2>/dev/null || true
  fi
}

# Identity of the RBF Main actually loaded. Does not consult LIVE_RBF or
# leftover mailbox magics (CORENAME=Plex for every sibling).
loaded_rbf_from_main_or_rbfname() {
  argv=$(main_argv_rbf_path) || argv=""
  if [ -n "$argv" ]; then
    map_named_rbf_if_exists "$argv" && return 0
  fi
  raw=$(read_name_file "$RBFNAME_FILE")
  if [ -n "$raw" ]; then
    map_named_rbf_if_exists "$raw" && return 0
  fi
  core=$(read_name_file "${CORENAME_FILE:-/tmp/CORENAME}")
  if [ -n "$core" ]; then
    map_named_rbf_if_exists "$core" && return 0
  fi
  return 1
}

read_u32_phys() {
  addr=$1
  if [ -n "${MISTERPLEX_DEVMEM:-}" ] && [ -x "$MISTERPLEX_DEVMEM" ]; then
    "$MISTERPLEX_DEVMEM" "$addr" 32 2>/dev/null || echo 0
    return 0
  fi
  DEVMEM=/usr/sbin/devmem
  if [ ! -x "$DEVMEM" ]; then
    DEVMEM=$(command -v devmem 2>/dev/null || true)
  fi
  if [ -n "${DEVMEM:-}" ] && [ -x "$DEVMEM" ]; then
    "$DEVMEM" "$addr" 32 2>/dev/null || echo 0
    return 0
  fi
  echo 0
  return 1
}

live_glass_is_l4() {
  if [ "${MPX_FORCE_LIVE_GLASS:-}" = "L4" ] || [ "${MPX_FORCE_LIVE_GLASS:-}" = "l4" ]; then
    return 0
  fi
  if [ -n "${MPX_FORCE_LIVE_GLASS:-}" ]; then
    return 1
  fi
  have_mem=1
  if [ -n "${MISTERPLEX_DEVMEM:-}" ] && [ -x "$MISTERPLEX_DEVMEM" ]; then
    have_mem=0
  elif [ -x /usr/sbin/devmem ]; then
    have_mem=0
  elif command -v devmem >/dev/null 2>&1; then
    have_mem=0
  fi
  if [ "$have_mem" -eq 0 ]; then
    l4a=$(read_u32_phys "$L4_PLXD_ADDR")
    t4a=$(read_u32_phys "$T480_PLXD_ADDR")
    t4ba=$(read_u32_phys "$T480_PLXD_ADDR_B")
    sample_s="${MISTERPLEX_GLASS_SAMPLE_S:-0.1}"
    if [ "$sample_s" != 0 ] && [ "$sample_s" != "0" ]; then
      sleep "$sample_s"
    fi
    l4b=$(read_u32_phys "$L4_PLXD_ADDR")
    t4b=$(read_u32_phys "$T480_PLXD_ADDR")
    t4bb=$(read_u32_phys "$T480_PLXD_ADDR_B")
    # Negative guard: LIVE changing L4 PLXD still classifies L4.
    if [ "$l4a" != "$l4b" ]; then
      return 0
    fi
    # Live 480p scanout beats leftover L4 PLXJ 504C584A.
    if [ "$t4a" != "$t4b" ] || [ "$t4ba" != "$t4bb" ]; then
      return 1
    fi
    # Leftover L4 PLXJ (0x504C584A) is sampled only to document the landmine.
    # Sticky leftover must not classify L4 — pair by the loaded RBF instead.
    plxj=$(read_u32_phys "$L4_PLXJ_ADDR")
    case "$plxj" in
      *504C584A*|*504c584a*) ;;
    esac
  fi
  named=$(loaded_rbf_from_main_or_rbfname) || named=""
  fam=$(rbf_family_from_path "$named")
  case "$fam" in
    sd480|sd240|sd480i) return 1 ;;
    l4) return 0 ;;
  esac
  return 1
}

resolve_loaded_rbf() {
  ut="$UTILITY_DIR"
  named=$(loaded_rbf_from_main_or_rbfname) || named=""
  if [ -n "$named" ] && [ -f "$named" ]; then
    echo "$named"
    return 0
  fi
  if [ -f "$ut/Plex_SDfamily.rbf" ]; then
    echo "$ut/Plex_SDfamily.rbf"
    return 0
  fi
  # CORENAME=Plex for every sibling — never hash a generic Plex.rbf.
  # Changing L4 PLXD (not leftover PLXJ) still selects Plex_720p24.
  if live_glass_is_l4 && [ -f "$ut/Plex_720p24.rbf" ]; then
    echo "$ut/Plex_720p24.rbf"
    return 0
  fi
  # Named LIVE_RBF only. Generic Plex.rbf always hashes the last drop
  # (CORENAME=Plex for every sibling) — never pair from that path.
  if [ -n "${LIVE_RBF:-}" ] && [ -f "$LIVE_RBF" ] && ! is_generic_plex_rbf "$LIVE_RBF"; then
    echo "$LIVE_RBF"
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
  # Last resort: named rollback, never generic Plex.rbf (even if missing).
  echo "$ut/Plex_480p.rbf"
}
