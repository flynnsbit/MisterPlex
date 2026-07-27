#!/usr/bin/env bash
# Refuse to run Verilator-heavy tests when current memory pressure can make results unreliable.
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $(basename "$0") [context]

Checks MemAvailable and active swap traffic before make unit / make rtl-sim.
Override only with explicit parent approval:
  MISTERPLEX_ALLOW_LOW_MEMORY_TESTS=1
Tuning / test hooks:
  MISTERPLEX_TEST_MIN_MEM_MB           default: 3584
  MISTERPLEX_TEST_MAX_SWAP_PAGES_SEC  default: 16
  MISTERPLEX_TEST_SWAP_SAMPLE_SECONDS default: 2
  MISTERPLEX_TEST_PREFLIGHT_MEMINFO   path to meminfo-compatible file
  MISTERPLEX_TEST_PREFLIGHT_VMSTAT    path with two pswpin/pswpout samples
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

context="${1:-test}"
# Basis: measured heaviest single Verilator bench peak was 420 MiB
# (test_p3_intra_frame_verilator.py). The default keeps more than 8x that available while still rejecting the observed ~3GiB fault state.
min_mem_mb="${MISTERPLEX_TEST_MIN_MEM_MB:-3584}"
max_swap_pages_sec="${MISTERPLEX_TEST_MAX_SWAP_PAGES_SEC:-16}"
sample_seconds="${MISTERPLEX_TEST_SWAP_SAMPLE_SECONDS:-2}"
meminfo="${MISTERPLEX_TEST_PREFLIGHT_MEMINFO:-/proc/meminfo}"
vmstat_file="${MISTERPLEX_TEST_PREFLIGHT_VMSTAT:-/proc/vmstat}"

for value_name in min_mem_mb max_swap_pages_sec sample_seconds; do
  value="${!value_name}"
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    echo "RESOURCE PREFLIGHT ERROR: $value_name must be an integer (got '$value')" >&2
    exit 2
  fi
done
if (( sample_seconds < 1 )); then
  echo "RESOURCE PREFLIGHT ERROR: MISTERPLEX_TEST_SWAP_SAMPLE_SECONDS must be >= 1" >&2
  exit 2
fi
if [[ ! -r "$meminfo" ]]; then
  echo "RESOURCE PREFLIGHT ERROR: cannot read meminfo: $meminfo" >&2
  exit 2
fi
if [[ ! -r "$vmstat_file" ]]; then
  echo "RESOURCE PREFLIGHT ERROR: cannot read vmstat: $vmstat_file" >&2
  exit 2
fi

read_kb() {
  local key="$1"
  awk -v k="$key" '$1 == k ":" {print $2; found=1} END {if (!found) print ""}' "$meminfo"
}

read_vmstat_sample() {
  local sample="$1"
  local in_key="pswpin"
  local out_key="pswpout"
  awk -v sample="$sample" -v in_key="$in_key" -v out_key="$out_key" '
    $1 == in_key {++in_seen; if (in_seen == sample) in_val=$2}
    $1 == out_key {++out_seen; if (out_seen == sample) out_val=$2}
    END {
      if (in_val == "" || out_val == "") exit 1
      printf "%s %s\n", in_val, out_val
    }' "$vmstat_file"
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

if [[ -n "${MISTERPLEX_TEST_PREFLIGHT_VMSTAT:-}" ]]; then
  read -r pswpin_a pswpout_a < <(read_vmstat_sample 1) || {
    echo "RESOURCE PREFLIGHT ERROR: vmstat fixture needs first pswpin/pswpout sample" >&2
    exit 2
  }
  read -r pswpin_b pswpout_b < <(read_vmstat_sample 2) || {
    echo "RESOURCE PREFLIGHT ERROR: vmstat fixture needs second pswpin/pswpout sample" >&2
    exit 2
  }
else
  read -r pswpin_a pswpout_a < <(read_vmstat_sample 1) || {
    echo "RESOURCE PREFLIGHT ERROR: /proc/vmstat missing pswpin/pswpout" >&2
    exit 2
  }
  sleep "$sample_seconds"
  read -r pswpin_b pswpout_b < <(read_vmstat_sample 1) || {
    echo "RESOURCE PREFLIGHT ERROR: /proc/vmstat missing pswpin/pswpout" >&2
    exit 2
  }
fi

if (( pswpin_b < pswpin_a || pswpout_b < pswpout_a )); then
  echo "RESOURCE PREFLIGHT ERROR: swap counters moved backwards" >&2
  exit 2
fi
swap_pages_delta=$(( (pswpin_b - pswpin_a) + (pswpout_b - pswpout_a) ))
swap_pages_sec=$(( (swap_pages_delta + sample_seconds - 1) / sample_seconds ))

if [[ "${MISTERPLEX_ALLOW_LOW_MEMORY_TESTS:-0}" == "1" ]]; then
  echo "RESOURCE PREFLIGHT OVERRIDE: ${context} running despite MemAvailable=${mem_avail_mb}MiB SwapFree=${swap_free_mb}/${swap_total_mb}MiB SwapTraffic=${swap_pages_sec} pages/s" >&2
  exit 0
fi

fail=0
if (( mem_avail_mb < min_mem_mb )); then
  fail=1
fi
if (( swap_pages_sec > max_swap_pages_sec )); then
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
  SwapFree:     ${swap_free_mb} MiB (informational only; SwapTotal=${swap_total_mb} MiB)
  SwapTraffic:  ${swap_pages_sec} pages/s (required <= ${max_swap_pages_sec} pages/s over ${sample_seconds}s)

This project has observed Verilator simulations produce wrong answers (not OOM errors) under active paging.
Wait for local Quartus/heavy jobs to stop, or use remote fits. To bypass deliberately with parent approval only:
  ${override_hint}
FAIL
  exit 75
fi

echo "RESOURCE PREFLIGHT OK: ${context} MemAvailable=${mem_avail_mb}MiB SwapFree=${swap_free_mb}/${swap_total_mb}MiB SwapTraffic=${swap_pages_sec}pages/s" >&2
