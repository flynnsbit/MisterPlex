#!/bin/sh
# Resolve the LIVE misterplexd install root from /proc/*/exe (ERROR 14 / two-roots).
# Source this file; do not exec.
#
# Contract:
#   resolve_live_misterplex_root
#     prints absolute root dir on stdout
#     prints one provenance line on stderr: root_source=live_exe|caller_supplied|FALLBACK_ASSUMED|NO-DATA
#     returns 0 on print, 1 on NO-DATA
#
# Rules:
#   - Prefer ROOT= if set and is a directory (caller_supplied).
#   - Else scan /proc/[pid]/exe via readlink -f; match basename misterplexd
#     (not cmdline — flock/supervise substrings are ERROR 14).
#   - Install layouts: $ROOT/misterplexd or $ROOT/bin/misterplexd.
#   - Fallback paths only if no live process: misterplex_v2 then misterplex.
#     Fallback is FALLBACK_ASSUMED — never claim live.
#   - Absence is NO-DATA (rc=1), never a silent wrong root.

resolve_live_misterplex_root() {
  if [ -n "${ROOT:-}" ] && [ -d "$ROOT" ]; then
    printf '%s\n' "$ROOT"
    echo "root_source=caller_supplied path=$ROOT" >&2
    return 0
  fi

  best=""
  best_rank=99
  for d in /proc/[0-9]*; do
    [ -d "$d" ] || continue
    exe=$(readlink -f "$d/exe" 2>/dev/null || true)
    [ -n "$exe" ] || continue
    base=$(basename "$exe")
    case "$base" in
      misterplexd|misterplexd_*)
        dir=$(dirname "$exe")
        leaf=$(basename "$dir")
        if [ "$leaf" = "bin" ]; then
          root=$(dirname "$dir")
        else
          root=$dir
        fi
        # Prefer v2-looking paths when multiple (dev + lab) — still live_exe.
        rank=1
        case "$root" in
          *misterplex_v2*) rank=0 ;;
        esac
        if [ -z "$best" ] || [ "$rank" -lt "$best_rank" ]; then
          best=$root
          best_rank=$rank
          best_exe=$exe
        fi
        ;;
    esac
  done

  if [ -n "$best" ]; then
    printf '%s\n' "$best"
    echo "root_source=live_exe path=$best exe=$best_exe" >&2
    return 0
  fi

  for c in /media/fat/misterplex_v2 /media/fat/misterplex; do
    if [ -x "$c/bin/misterplexd" ] || [ -x "$c/misterplexd" ]; then
      printf '%s\n' "$c"
      echo "root_source=FALLBACK_ASSUMED path=$c note=no_live_misterplexd_process" >&2
      return 0
    fi
  done

  echo "root_source=NO-DATA reason=no_live_exe_and_no_install" >&2
  return 1
}

# Same resolution for daemon log path preference (live root first).
resolve_live_misterplex_log() {
  hint="${1:-}"
  if [ -n "$hint" ] && [ -f "$hint" ]; then
    printf '%s\n' "$hint"
    echo "log_source=caller_supplied path=$hint" >&2
    return 0
  fi
  root=$(resolve_live_misterplex_root 2>/dev/null) || root=""
  if [ -n "$root" ]; then
    for f in "$root/misterplexd.log" "$root/log/misterplexd.log"; do
      if [ -f "$f" ]; then
        printf '%s\n' "$f"
        echo "log_source=live_root path=$f" >&2
        return 0
      fi
    done
  fi
  for f in /tmp/misterplexd.log /var/log/misterplexd.log \
           /media/fat/misterplex_v2/misterplexd.log \
           /media/fat/misterplex/misterplexd.log; do
    if [ -f "$f" ]; then
      printf '%s\n' "$f"
      echo "log_source=FALLBACK_ASSUMED path=$f" >&2
      return 0
    fi
  done
  echo "log_source=NO-DATA" >&2
  return 1
}
