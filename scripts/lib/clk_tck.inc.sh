# clk_tck.inc.sh — never trust empty getconf CLK_TCK as a denominator.
#
# Parent 2026-08-01: busybox getconf CLK_TCK can return EMPTY with exit 0.
# `hz=$(getconf CLK_TCK 2>/dev/null || echo 100)` then leaves hz="" (|| does
# not fire on empty success), and `P=100*dticks/(HZ*dwall)` becomes 0.0 for
# every process — a well-formed table of zeros that looks like "idle".
#
# API:
#   resolve_clk_tck           → prints integer HZ on stdout; 0 on failure
#   require_clk_tck           → echo HZ=N src=...; return 77 if unusable
#   cpu_pct_onecpu DTICKS DWALL_S HZ  → prints pct or refuses empty/zero
#
# shellcheck shell=bash

# Resolve CLK_TCK. Prefer non-empty getconf; else derive from /proc/stat vs wall.
# Prints ONLY the integer on stdout (for capture). Returns 0 on success, 1 on fail.
resolve_clk_tck() {
  local g c0 c1 t0 t1 dticks dwall_ns hz
  g=$(getconf CLK_TCK 2>/dev/null || true)
  if [[ "$g" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s' "$g"
    return 0
  fi
  # Derive from per-CPU jiffies. The aggregate "cpu " line advances at
  # ~ncpu*HZ — using it raw on a 20-core box yields ~2000 and fails the
  # sanity band. Prefer cpu0; else divide aggregate by nproc.
  if [[ ! -r /proc/stat ]]; then
    return 1
  fi
  local stat_re='^cpu0 '
  if ! grep -qE '^cpu0 ' /proc/stat 2>/dev/null; then
    stat_re='^cpu '
  fi
  _clk_sum() {
    awk -v re="$stat_re" '$0 ~ re {s=0; for(i=2;i<=NF;i++) s+=$i; print s; exit}' /proc/stat
  }
  c0=$(_clk_sum)
  if command -v date >/dev/null 2>&1 && date +%s%N >/dev/null 2>&1; then
    t0=$(date +%s%N)
    sleep 0.25
    t1=$(date +%s%N)
    c1=$(_clk_sum)
    dwall_ns=$((t1 - t0))
    dticks=$((c1 - c0))
    if [[ "$dwall_ns" -le 0 || "$dticks" -le 0 ]]; then
      return 1
    fi
    hz=$(( (dticks * 1000000000 + dwall_ns/2) / dwall_ns ))
  else
    t0=$(date +%s)
    sleep 1
    t1=$(date +%s)
    c1=$(_clk_sum)
    dwall_ns=$(( (t1 - t0) * 1000000000 ))
    dticks=$((c1 - c0))
    if [[ "$dwall_ns" -le 0 || "$dticks" -le 0 ]]; then
      return 1
    fi
    hz=$(( (dticks * 1000000000 + dwall_ns/2) / dwall_ns ))
  fi
  # If we had to use aggregate "cpu ", scale by nproc.
  if [[ "$stat_re" == '^cpu ' ]]; then
    local ncpu
    ncpu=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
    if [[ "$ncpu" =~ ^[1-9][0-9]*$ && "$ncpu" -gt 1 ]]; then
      hz=$(( (hz + ncpu/2) / ncpu ))
    fi
  fi
  # Sanity: Linux HZ is typically 100, 250, or 1000 — refuse absurd
  if [[ "$hz" -lt 50 || "$hz" -gt 1500 ]]; then
    return 1
  fi
  printf '%s' "$hz"
  return 0
}

# Require a usable HZ. Prints "HZ=<n> src=getconf|derived" and returns 0,
# or prints verdict=UNSCORED and returns 77.
require_clk_tck() {
  local g hz src
  g=$(getconf CLK_TCK 2>/dev/null || true)
  if [[ "$g" =~ ^[1-9][0-9]*$ ]]; then
    echo "HZ=$g src=getconf"
    return 0
  fi
  echo "CLK_TCK_GETCONF_EMPTY_OR_BAD raw='${g}' — deriving from /proc/stat" >&2
  hz=$(resolve_clk_tck) || {
    echo "verdict=UNSCORED reason=clk_tck_unresolved raw_getconf='${g}'" >&2
    echo "true rc=77"
    return 77
  }
  # If getconf was empty we always label derived even when resolve used getconf path
  # (resolve may succeed via getconf on re-call; stamp derived when g was bad).
  src=derived_proc_stat
  echo "HZ=$hz src=$src"
  return 0
}

# One-CPU percent: 100 * dticks / (hz * dwall_s). Refuses empty/zero denominators.
# Usage: cpu_pct_onecpu DTICKS DWALL_S HZ → prints "pct=N.N" or returns 77.
cpu_pct_onecpu() {
  local dticks="${1:-}" dwall="${2:-}" hz="${3:-}"
  if [[ -z "$dticks" || -z "$dwall" || -z "$hz" ]]; then
    echo "verdict=UNSCORED reason=empty_cpu_denominator dticks='${dticks}' dwall='${dwall}' hz='${hz}'" >&2
    echo "true rc=77"
    return 77
  fi
  if ! [[ "$dticks" =~ ^-?[0-9]+$ && "$dwall" =~ ^[0-9]+([.][0-9]+)?$ && "$hz" =~ ^[1-9][0-9]*$ ]]; then
    echo "verdict=UNSCORED reason=bad_cpu_inputs dticks='${dticks}' dwall='${dwall}' hz='${hz}'" >&2
    echo "true rc=77"
    return 77
  fi
  # dwall must be > 0
  awk -v d="$dticks" -v e="$dwall" -v hz="$hz" 'BEGIN{
    if (e <= 0 || hz <= 0) { exit 77 }
    printf "pct=%.1f\n", (100.0 * d) / (hz * e)
    exit 0
  }'
  local st=$?
  if [[ "$st" -eq 77 ]]; then
    echo "verdict=UNSCORED reason=zero_cpu_denominator" >&2
    echo "true rc=77"
    return 77
  fi
  return "$st"
}
