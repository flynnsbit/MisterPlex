#!/usr/bin/env bash
# Refuse untraceable misterplexd binaries for promotion / release identity.
#
# Observed defect: live daily-driver daemon md5 ea643e99 is only a content hash.
# `git cat-file -t ea643e99` returns "Not a valid object name" — the binary is
# not mappable to source. Session time was spent reasoning off a stale pair.
# Commit d44d5d1c stamps git_rev into --version output so a deployed binary is
# traceable. Absence of that stamp is NO-DATA for provenance, never a pass.
#
# Usage:
#   daemon_stamp_check.sh <path-to-misterplexd>
#   daemon_stamp_check.sh --require-stamped <path>   # promotion (default mode)
#   daemon_stamp_check.sh --allow-matrix-pin <path>  # historical PAIR_MATRIX row
#
# Exit codes:
#   0 STAMP_OK / MATRIX_PIN_OK
#   1 usage / missing file
#   2 STAMP_FAIL reason=no_git_rev_string
#   3 STAMP_FAIL reason=git_rev_unknown
#   4 STAMP_FAIL reason=not_elf_or_empty
set -euo pipefail

mode=require-stamped
path=""
while [ $# -gt 0 ]; do
  case "$1" in
    --require-stamped) mode=require-stamped; shift ;;
    --allow-matrix-pin) mode=allow-matrix-pin; shift ;;
    -h|--help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *)
      path=$1
      shift
      ;;
  esac
done

if [ -z "$path" ] || [ ! -f "$path" ]; then
  echo "STAMP_FAIL reason=missing_file path=${path:-}"
  exit 1
fi

sz=$(wc -c <"$path" | tr -d ' ')
if [ "${sz:-0}" -lt 1000 ]; then
  echo "STAMP_FAIL reason=not_elf_or_empty bytes=$sz path=$path"
  exit 4
fi

# Probe --version. Prefer native exec when the ELF matches this host; else short
# timeout under qemu-arm. Unstamped historical ARM pins may hang under qemu —
# never block the gate on that path. Fall back to strings for a concrete
# git_rev= value only (printf format "git_rev=%s" alone is NOT a stamp).
# Never treat empty probe output as git_rev=ok.
ver_line=""
run_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 3 "$@" 2>/dev/null || true
  else
    "$@" 2>/dev/null || true
  fi
}
ft=$(file -b "$path" 2>/dev/null || true)
if printf '%s' "$ft" | grep -qiE 'ELF (64-bit|32-bit).*(x86-64|Intel 80386|x86_64)'; then
  ver_line=$(run_timeout "$path" --version | head -1)
elif printf '%s' "$ft" | grep -qiE 'ELF 32-bit.*ARM'; then
  if command -v qemu-arm-static >/dev/null 2>&1; then
    ver_line=$(run_timeout qemu-arm-static "$path" --version | head -1)
  elif command -v qemu-arm >/dev/null 2>&1; then
    ver_line=$(run_timeout qemu-arm "$path" --version | head -1)
  fi
fi

git_rev=""
if printf '%s' "$ver_line" | grep -q 'git_rev='; then
  git_rev=$(printf '%s\n' "$ver_line" | sed -n 's/.*git_rev=\([^[:space:]]*\).*/\1/p' | head -1)
fi
if [ -z "$git_rev" ]; then
  # strings: only accept a resolved rev (hex), not the printf format %s
  git_rev=$(strings "$path" 2>/dev/null \
    | sed -n 's/.*git_rev=\([0-9a-f]\{7,\}(-dirty)\?\).*/\1/p' \
    | head -1 || true)
fi

md5=$(md5sum "$path" | awk '{print $1}')
echo "daemon_stamp path=$path md5=$md5 mode=$mode ver_line=${ver_line:-}"

if [ -z "$git_rev" ]; then
  if [ "$mode" = "allow-matrix-pin" ]; then
    echo "MATRIX_PIN_OK reason=historical_md5_pin_no_git_rev md5=$md5"
    echo "NOTE: content-md5 pin only; not source-traceable via --version"
    exit 0
  fi
  echo "STAMP_FAIL reason=no_git_rev_string md5=$md5"
  echo "ACTION: rebuild daemon after d44d5d1c so --version prints misterplexd git_rev=<rev>"
  exit 2
fi

if [ "$git_rev" = "unknown" ] || [ "$git_rev" = "UNKNOWN" ]; then
  if [ "$mode" = "allow-matrix-pin" ]; then
    echo "MATRIX_PIN_OK reason=historical_md5_pin_git_rev_unknown md5=$md5"
    exit 0
  fi
  echo "STAMP_FAIL reason=git_rev_unknown md5=$md5 git_rev=$git_rev"
  exit 3
fi

echo "STAMP_OK git_rev=$git_rev md5=$md5"
exit 0
