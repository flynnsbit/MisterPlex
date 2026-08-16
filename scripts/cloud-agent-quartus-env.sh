# Source this file (do not execute): restore Quartus bindirs after Cloud Agent
# overwrites the image PATH. Safe to source more than once.
# shellcheck shell=bash

: "${QUARTUS_PATH:=/opt/intelFPGA}"
: "${QUARTUS_ROOTDIR:=${QUARTUS_PATH}/quartus}"
: "${SOPC_KIT_NIOS2:=${QUARTUS_PATH}/nios2eds}"
export QUARTUS_PATH QUARTUS_ROOTDIR SOPC_KIT_NIOS2

_misterplex_prepend_path() {
  local d="$1"
  [ -d "$d" ] || return 0
  case ":$PATH:" in
    *":$d:"*) ;;
    *) PATH="$d${PATH:+:$PATH}" ;;
  esac
}

_misterplex_prepend_path "$QUARTUS_ROOTDIR/sopc_builder/bin"
_misterplex_prepend_path "$QUARTUS_ROOTDIR/linux64/gnu"
_misterplex_prepend_path "$QUARTUS_ROOTDIR/bin"
export PATH
unset -f _misterplex_prepend_path
