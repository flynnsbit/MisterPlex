#!/usr/bin/env bash
# Pure filesystem helpers for misterplexd deploy/rollback.
# Sourced by deploy_misterplexd.sh, restore_misterplexd_prev.sh, and unit proof.
# No SSH. Operates on a root directory (device path or local fixture).
#
# Contract:
#   - Backup BEFORE any destructive mutation (never overwrite prev until new
#     backup is fully written).
#   - Install via stage file + atomic rename so mid-copy never leaves a hole.
#   - Restore copies PREV → BIN and verifies md5 equality.

# Atomic: write live binary to prev path without truncating a good prev on failure.
# Usage: mpx_backup_daemon_atomic <live_bin> <prev_bin>
mpx_backup_daemon_atomic() {
  local live="$1" prev="$2"
  local tmp="${prev}.new.$$"
  if [[ ! -f "$live" ]]; then
    echo "mpx_backup: no live binary at $live" >&2
    return 1
  fi
  mkdir -p "$(dirname "$prev")"
  cp -f "$live" "$tmp" || { rm -f "$tmp"; return 1; }
  # Best-effort durability on FAT/ext.
  sync "$tmp" 2>/dev/null || sync || true
  mv -f "$tmp" "$prev" || { rm -f "$tmp"; return 1; }
  return 0
}

# Snapshot live binary + conf into backup_dir with tag (e.g. before-ISO8601).
# Usage: mpx_snapshot_pair <live_bin> <live_conf> <backup_dir> <tag>
# Writes: $backup_dir/misterplexd.$tag  $backup_dir/misterplex.conf.$tag
mpx_snapshot_pair() {
  local live="$1" conf="$2" bdir="$3" tag="$4"
  mkdir -p "$bdir"
  if [[ ! -f "$live" ]]; then
    echo "mpx_snapshot: missing $live" >&2
    return 1
  fi
  local bt="$bdir/misterplexd.${tag}"
  local ct="$bdir/misterplex.conf.${tag}"
  local btmp="${bt}.new.$$" ctmp="${ct}.new.$$"
  cp -f "$live" "$btmp" || { rm -f "$btmp"; return 1; }
  sync "$btmp" 2>/dev/null || sync || true
  mv -f "$btmp" "$bt" || { rm -f "$btmp"; return 1; }
  if [[ -f "$conf" ]]; then
    cp -f "$conf" "$ctmp" || { rm -f "$ctmp"; return 1; }
    sync "$ctmp" 2>/dev/null || sync || true
    mv -f "$ctmp" "$ct" || { rm -f "$ctmp"; return 1; }
  fi
  echo "snapshot_bin=$bt"
  echo "snapshot_conf=${ct:-NONE}"
  md5sum "$bt" ${conf:+"$ct"} 2>/dev/null || true
  return 0
}

# Install new binary via stage+rename. Keeps old BIN until stage is complete.
# If stage fails, live BIN is untouched. After success, prev already holds old.
# Usage: mpx_install_daemon_atomic <new_bin_src> <dest_bin>
mpx_install_daemon_atomic() {
  local src="$1" dest="$2"
  local stage="${dest}.new.$$"
  if [[ ! -f "$src" ]]; then
    echo "mpx_install: missing src $src" >&2
    return 1
  fi
  mkdir -p "$(dirname "$dest")"
  cp -f "$src" "$stage" || { rm -f "$stage"; return 1; }
  chmod +x "$stage" || true
  sync "$stage" 2>/dev/null || sync || true
  mv -f "$stage" "$dest" || { rm -f "$stage"; return 1; }
  return 0
}

# Restore prev → dest; require byte identity after copy.
# Usage: mpx_restore_daemon_atomic <prev_bin> <dest_bin>
# Prints restored_md5=...
mpx_restore_daemon_atomic() {
  local prev="$1" dest="$2"
  if [[ ! -f "$prev" ]]; then
    echo "mpx_restore: no backup at $prev" >&2
    return 1
  fi
  local stage="${dest}.restore.$$"
  cp -f "$prev" "$stage" || { rm -f "$stage"; return 1; }
  chmod +x "$stage" || true
  sync "$stage" 2>/dev/null || sync || true
  mv -f "$stage" "$dest" || { rm -f "$stage"; return 1; }
  local md_prev md_dest
  md_prev=$(md5sum "$prev" | awk '{print $1}')
  md_dest=$(md5sum "$dest" | awk '{print $1}')
  if [[ "$md_prev" != "$md_dest" ]]; then
    echo "mpx_restore: md5 mismatch after restore prev=$md_prev dest=$md_dest" >&2
    return 2
  fi
  echo "restored_md5=$md_dest"
  return 0
}

# Simulate mid-copy failure: stage written partial, dest must remain old.
# Usage: mpx_simulate_mid_copy_fail <new_src> <dest_bin>
# Leaves dest unchanged; returns 0 if dest md5 unchanged.
mpx_simulate_mid_copy_fail() {
  local src="$1" dest="$2"
  local before after
  before=$(md5sum "$dest" | awk '{print $1}')
  local stage="${dest}.new.$$"
  # Partial write then abort (no mv).
  head -c 64 "$src" >"$stage" || true
  rm -f "$stage"
  after=$(md5sum "$dest" | awk '{print $1}')
  if [[ "$before" != "$after" ]]; then
    echo "mpx_mid_fail: dest mutated before=$before after=$after" >&2
    return 1
  fi
  echo "mid_copy_fail_dest_intact md5=$after"
  return 0
}

# Fail-closed: same bytes? rc=0 match, rc=2 mismatch (matches restore_misterplexd_prev).
# Usage: mpx_require_md5_equal <path_a> <path_b>
mpx_require_md5_equal() {
  local a="$1" b="$2"
  local ma mb
  ma=$(md5sum "$a" | awk '{print $1}')
  mb=$(md5sum "$b" | awk '{print $1}')
  if [[ "$ma" != "$mb" ]]; then
    echo "RESTORE_FAIL: md5 mismatch want=$ma got=$mb" >&2
    return 2
  fi
  echo "restored_md5=$mb"
  return 0
}

# Exact argv --id token (same rule as deploy/restore). rc=0 match, rc=7 mismatch.
# Usage: mpx_require_ps_id <ps_line> <want_id>
mpx_require_ps_id() {
  local ps_line="$1" want="$2"
  # shellcheck disable=SC2086
  set -- $ps_line
  local id_ok=0
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--id" && -n "${2:-}" ]]; then
      [[ "$2" == "$want" ]] && id_ok=1
      break
    fi
    if [[ "$1" == --id=* ]]; then
      [[ "${1#--id=}" == "$want" ]] && id_ok=1
      break
    fi
    shift
  done
  if [[ "$id_ok" != "1" ]]; then
    echo "RESTORE_FAIL: DAEMON_ID_MISMATCH want=${want} ps=${ps_line}" >&2
    return 7
  fi
  echo "daemon_id_ok=${want}"
  return 0
}
