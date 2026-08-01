#!/usr/bin/env bash
# Pure policy helpers for deploy_misterplexd.sh (host-testable; no device I/O).
# Sourced by the deploy script and by tests/unit/test_deploy_misterplexd.sh.

# Resolve install root.
# Args: live_root force_root
# Prints target root on stdout. Returns:
#   0 ok
#   2 cross-root refusal (live != force)
#   3 empty
deploy_resolve_target_root() {
  local live_root="${1:-}"
  local force_root="${2:-}"
  if [[ -n "$force_root" ]]; then
    if [[ -n "$live_root" && "$live_root" != "$force_root" ]]; then
      echo "CROSS_ROOT live=$live_root force=$force_root" >&2
      return 2
    fi
    echo "$force_root"
    return 0
  fi
  if [[ -n "$live_root" ]]; then
    echo "$live_root"
    return 0
  fi
  # Caller supplies default when no live daemon.
  return 3
}

# Post-deploy invariants.
# Args: n_daemon live_md5 host_md5 live_conf target_root
# Returns 0 on OK; non-zero with message on stderr.
deploy_assert_single_live() {
  local n="${1:-0}"
  local live_md5="${2:-}"
  local host_md5="${3:-}"
  local live_conf="${4:-}"
  local target_root="${5:-}"

  if [[ "$n" -ne 1 ]]; then
    echo "FAIL n_daemon=$n want=1" >&2
    return 3
  fi
  if [[ -z "$live_md5" ]]; then
    echo "FAIL empty live exe md5" >&2
    return 4
  fi
  if [[ -z "$host_md5" ]]; then
    echo "FAIL empty host md5" >&2
    return 4
  fi
  if [[ "$live_md5" != "$host_md5" ]]; then
    echo "FAIL live exe md5 $live_md5 != host artifact $host_md5" >&2
    return 5
  fi
  if [[ -z "$target_root" || -z "$live_conf" ]]; then
    echo "FAIL missing conf/root live_conf='$live_conf' target_root='$target_root'" >&2
    return 6
  fi
  case "$live_conf" in
    "$target_root"/*) ;;
    *)
      echo "FAIL live --conf '$live_conf' not under target root $target_root" >&2
      return 6
      ;;
  esac
  return 0
}

# Would this install path target the live root?
# Args: install_root live_root
# Returns 0 if same or live empty; 1 if mismatch (RED deploy class).
deploy_install_root_matches_live() {
  local install_root="${1:-}"
  local live_root="${2:-}"
  if [[ -z "$live_root" ]]; then
    return 0
  fi
  if [[ "$install_root" == "$live_root" ]]; then
    return 0
  fi
  echo "FAIL install_root=$install_root != live_root=$live_root" >&2
  return 1
}

# Conf is USER-OWNED. Deploy must not rewrite/normalise it.
# Args: pre_md5 post_md5
# pre/post may be "MISSING" if conf absent both sides (bootstrap only).
# Returns 0 if equal; 7 if mutated; 4 if NO-DATA empty.
deploy_assert_conf_unchanged() {
  local pre="${1:-}"
  local post="${2:-}"
  if [[ -z "$pre" || -z "$post" ]]; then
    echo "FAIL conf md5 NO-DATA pre='$pre' post='$post'" >&2
    return 4
  fi
  if [[ "$pre" != "$post" ]]; then
    echo "FAIL conf mutated by deploy pre=$pre post=$post (USER-OWNED; never normalise)" >&2
    return 7
  fi
  return 0
}

# Full post-deploy gate (host-side after remote POST_* lines).
# Args: n live_md5 host_md5 live_conf target_root http_code conf_pre conf_post
# Returns first failing deploy_assert_* code.
deploy_assert_postconditions() {
  local n="${1:-0}"
  local live_md5="${2:-}"
  local host_md5="${3:-}"
  local live_conf="${4:-}"
  local target_root="${5:-}"
  local http="${6:-}"
  local conf_pre="${7:-}"
  local conf_post="${8:-}"

  deploy_assert_single_live "$n" "$live_md5" "$host_md5" "$live_conf" "$target_root" || return $?
  if [[ -z "$http" ]]; then
    echo "FAIL empty HTTP code for /resources" >&2
    return 4
  fi
  if [[ "$http" != "200" && "$http" != "204" ]]; then
    echo "FAIL /resources HTTP $http (want 200)" >&2
    return 7
  fi
  # Conf gate: skip only when both MISSING and create allowed (caller decides).
  if [[ "$conf_pre" != "SKIP" ]]; then
    deploy_assert_conf_unchanged "$conf_pre" "$conf_post" || return $?
  fi
  return 0
}
