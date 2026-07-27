#!/usr/bin/env bash
# Refuse to run Verilator-heavy tests when memory pressure can make results unreliable.
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $(basename "$0") [context]

Checks MemAvailable and SwapFree before make unit / make rtl-sim.
Override only with explicit parent approval:
  MISTERPLEX_ALLOW_LOW_MEMORY_TESTS=1
Tuning / test hooks:
  MISTERPLEX_TEST_MIN_MEM_MB       default: 4096
  MISTERPLEX_TEST_MIN_SWAP_FREE_MB default: 512
  MISTERPLEX_TEST_PREFLIGHT_MEMINFO path to meminfo-compatible file
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

context="${1:-test}"
# Basis: measured heaviest single Verilator bench peak was 420 MiB
# (test_p3_intra_frame_verilator.py). The default keeps roughly 9x that available
# and separately rejects the observed bad state: full swap.
min_mem_mb="${MISTERPLEX_TEST_MIN_MEM_MB:-4096}"
min_swap_free_mb="${MISTERPLEX_TEST_MIN_SWAP_FREE_MB:-512}"
meminfo="${MISTERPLEX_TEST_PREFLIGHT_MEMINFO:-/proc/meminfo}"

if [[ ! "$min_mem_mb" =~ ^[0-9]+$ || ! "$min_swap_free_mb" =~ ^[0-9]+$ ]]; then
  echo "RESOURCE PREFLIGHT ERROR: thresholds must be integer MiB" >&2
  exit 2
fi
if [[ ! -r "$meminfo" ]]; then
  echo "RESOURCE PREFLIGHT ERROR: cannot read meminfo: $meminfo" >&2
  exit 2
fi

read_kb() {
  local key="$1"
  awk -v k="$key" '$1 == k ":" {print $2; found=1} END {if (!found) print ""}' "$meminfo"
}

mem_avail_kb="$(read_kb MemAvailable)"
# Some minimal meminfo fixtures/systems may omit MemAvailable. Fall back to MemFree+Cached+Buffers.
if [[ -z "$mem_avail_kb" ]]; then
  mem_free_kb="$(read_kb MemFree)"
  cached_kb="$(read_kb Cached)"
  buffers_kb="$(read_kb Buffers)"
  mem_avail_kb=$(( ${mem_free_kb:-0} + ${cached_kb:-0} + ${buffers_kb:-0} ))
fi
swap_free_kb="$(read_kb SwapFree)"
swap_total_kb="$(read_kb SwapTotal)"
mem_total_kb="$(read_kb MemTotal)"

mem_avail_mb=$(( mem_avail_kb / 1024 ))
swap_free_mb=$(( ${swap_free_kb:-0} / 1024 ))
swap_total_mb=$(( ${swap_total_kb:-0} / 1024 ))
mem_total_mb=$(( ${mem_total_kb:-0} / 1024 ))

if [[ "${MISTERPLEX_ALLOW_LOW_MEMORY_TESTS:-0}" == "1" ]]; then
  echo "RESOURCE PREFLIGHT OVERRIDE: ${context} running despite MemAvailable=${mem_avail_mb}MiB SwapFree=${swap_free_mb}/${swap_total_mb}MiB" >&2
  exit 0
fi

fail=0
if (( mem_avail_mb < min_mem_mb )); then
  fail=1
fi
if (( swap_total_mb > 0 && swap_free_mb < min_swap_free_mb )); then
  fail=1
fi

if (( fail )); then
  if [[ "$context" == "unit" || "$context" == "rtl-sim" || "$context" == "rtl-lint" ]]; then
    override_hint="MISTERPLEX_ALLOW_LOW_MEMORY_TESTS=1 make ${context}"
  else
    override_hint="MISTERPLEX_ALLOW_LOW_MEMORY_TESTS=1 <rerun the explicit command>"
  fi
  cat >&2 <<FAIL
RESOURCE PREFLIGHT FAIL: refusing to run ${context}; results would be unreliable under current memory pressure.
  MemAvailable: ${mem_avail_mb} MiB (required >= ${min_mem_mb} MiB; MemTotal=${mem_total_mb} MiB)
  SwapFree:     ${swap_free_mb} MiB (required >= ${min_swap_free_mb} MiB when swap exists; SwapTotal=${swap_total_mb} MiB)

This project has observed Verilator simulations produce wrong answers (not OOM errors) when local Quartus fills memory/swap.
Wait for local Quartus/heavy jobs to stop, or use remote fits. To bypass deliberately with parent approval only:
  ${override_hint}
FAIL
  exit 75
fi

echo "RESOURCE PREFLIGHT OK: ${context} MemAvailable=${mem_avail_mb}MiB SwapFree=${swap_free_mb}/${swap_total_mb}MiB" >&2
