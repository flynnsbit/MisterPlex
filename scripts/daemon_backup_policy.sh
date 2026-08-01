#!/usr/bin/env bash
# daemon_backup_policy.sh — measured-md5 backup naming + decidable rollback inventory.
#
# Parent 2026-08-01: a rollback you cannot verify is not a rollback. Backups must
# be named from a MEASURED md5 of the bytes they contain, never a human guess.
#
# Canonical names (under $ROOT/bin/):
#   misterplexd.<prefix8>.bak     — content-addressed pin of measured full md5
#   misterplexd.bak.<prefix8>     — alias accepted (parent hand style)
#   misterplexd.stage.<prefix8>   — staged inbound (not a rollback pin)
#
# LEGACY / clutter (do NOT delete automatically — parent executes retention):
#   .bak.osd .bak.breadcrumb .bak.pre-plxd .prev.* .coarm_* .rollback_*
#   .timeline .v020.bak  — inventory as UNVERIFIED until md5 measured
#
# Retention proposal (parent applies on device; this script only prints plan):
#   KEEP: every *.bak / *.bak.<8hex> / *.<8hex>.bak whose md5 prefix matches name
#   KEEP: last 5 content-addressed pins by mtime among verified
#   QUARANTINE (rename to .orphan.<mtime>.unverified, never rm): labels that do
#     not match measured md5, or non-md5 suffixes without inventory stamp
#   NEVER touch: misterplexd (live), misterplexd_supervise.sh, conf files
#
# Usage:
#   source scripts/daemon_backup_policy.sh
#   daemon_bak_canonical_path <bin_dir> <full_or_prefix_md5>
#   daemon_bak_verify_name <path>          # rc 0 if name matches content md5
#   scripts/daemon_backup_policy.sh inventory-plan   # dry-run SSH inventory commands
#   scripts/daemon_backup_policy.sh name-for <md5>

set -euo pipefail

daemon_bak_normalize_md5() {
  printf '%s' "${1:-}" | tr 'A-F' 'a-f' | tr -cd '0-9a-f'
}

daemon_bak_prefix8() {
  local s
  s=$(daemon_bak_normalize_md5 "${1:-}")
  [ "${#s}" -ge 8 ] || { printf ''; return 1; }
  printf '%s' "${s:0:8}"
}

# Preferred content-addressed path (pair rollback find-daemon compatible).
daemon_bak_canonical_path() {
  local dir="${1:-}" md p8
  md=$(daemon_bak_normalize_md5 "${2:-}")
  p8=$(daemon_bak_prefix8 "$md") || return 1
  printf '%s/misterplexd.%s.bak' "$dir" "$p8"
}

# Parent hand-deploy alias.
daemon_bak_alias_path() {
  local dir="${1:-}" md p8
  md=$(daemon_bak_normalize_md5 "${2:-}")
  p8=$(daemon_bak_prefix8 "$md") || return 1
  printf '%s/misterplexd.bak.%s' "$dir" "$p8"
}

daemon_bak_stage_path() {
  local dir="${1:-}" md p8
  md=$(daemon_bak_normalize_md5 "${2:-}")
  p8=$(daemon_bak_prefix8 "$md") || return 1
  printf '%s/misterplexd.stage.%s' "$dir" "$p8"
}

# rc 0 if basename encodes prefix8 that matches file content md5.
daemon_bak_verify_name() {
  local path="${1:-}" base md p8 got
  [ -f "$path" ] || return 2
  base=$(basename "$path")
  md=$(md5sum "$path" | awk '{print $1}')
  p8="${md:0:8}"
  case "$base" in
    misterplexd."$p8".bak|misterplexd.bak."$p8"|misterplexd.stage."$p8")
      echo "BAK_VERIFY_OK path=$path md5=$md"
      return 0
      ;;
    misterplexd.[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f].bak|\
    misterplexd.bak.[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]|\
    misterplexd.stage.[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
      got=$(printf '%s' "$base" | sed -n 's/.*\([0-9a-f]\{8\}\).*/\1/p' | head -1)
      echo "BAK_VERIFY_FAIL path=$path name_prefix=$got content_md5=$md (MISLABEL — not a safe rollback pin)"
      return 1
      ;;
    *)
      echo "BAK_UNVERIFIED path=$path content_md5=$md (legacy label; measure before trust)"
      return 3
      ;;
  esac
}

daemon_bak_print_retention_policy() {
  cat <<'POL'
RETENTION_POLICY (proposal — parent executes; agents never delete on device)
1. LIVE never touched: misterplexd, misterplexd_supervise.sh, *.conf
2. VERIFIED pins: name prefix8 == content md5 prefix8
   KEEP indefinitely while listed in pair_ship_policy / video_regression accepted set
   KEEP last 5 other verified pins by mtime
3. MISLABEL (name prefix != content md5): QUARANTINE rename only
   misterplexd.orphan.<UTC>.<content_prefix8>.unverified
   never rm; never use as ROLLBACK_DAEMON until re-labelled from content md5
4. LEGACY suffixes (.bak.osd, .breadcrumb, .pre-plxd, .prev.*, .coarm_*, .rollback_*,
   .timeline, .v020.bak): inventory with measured md5; if unique content not already
   in a verified pin, copy once to misterplexd.<content_prefix8>.bak then quarantine
   legacy name (rename, not rm)
5. Rollback answer must be machine-checkable:
   "roll back to PREFIX" => path whose content md5 starts with PREFIX AND
   daemon_bak_verify_name OK AND pair_policy accepts with core pin
POL
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  cmd="${1:-}"
  case "$cmd" in
    name-for)
      md=$(daemon_bak_normalize_md5 "${2:-}")
      [ "${#md}" -ge 8 ] || { echo "usage: $0 name-for <md5>"; exit 3; }
      echo "CANONICAL=misterplexd.$(daemon_bak_prefix8 "$md").bak"
      echo "ALIAS=misterplexd.bak.$(daemon_bak_prefix8 "$md")"
      echo "STAGE=misterplexd.stage.$(daemon_bak_prefix8 "$md")"
      echo "FULL_MD5=$md"
      ;;
    retention-policy)
      daemon_bak_print_retention_policy
      ;;
    inventory-plan)
      # Exact commands for parent — no SSH from agent.
      cat <<'PLAN'
# --- PARENT DRY-RUN: daemon backup inventory (device) ---
# Expect: each line PATH MD5 PREFIX8 VERDICT
ROOT=/media/fat/misterplex_v2/bin
cd "$ROOT" || exit 1
for f in misterplexd misterplexd.* misterplexd.bak* 2>/dev/null; do
  [ -f "$f" ] || continue
  case "$f" in
    misterplexd_supervise.sh|*.sh|*.log) continue ;;
  esac
  md=$(md5sum "$f" | awk '{print $1}')
  p8=${md:0:8}
  base=$(basename "$f")
  verdict=UNVERIFIED
  case "$base" in
    misterplexd) verdict=LIVE ;;
    misterplexd."$p8".bak|misterplexd.bak."$p8") verdict=VERIFIED_PIN ;;
    misterplexd.stage."$p8") verdict=STAGE_OK ;;
    misterplexd.[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f].bak|\
    misterplexd.bak.[0-9a-f]*)
      verdict=MISLABEL
      ;;
  esac
  echo "INV path=$f md5=$md prefix8=$p8 verdict=$verdict"
done
echo "true rc=$?"

# Host-side after scp inventory out:
#   Prefer ROLLBACK_DAEMON= path with verdict=VERIFIED_PIN and wanted prefix8.
#   Never ROLLBACK_DAEMON= a MISLABEL or UNVERIFIED without re-pin from content md5.
PLAN
      daemon_bak_print_retention_policy
      ;;
    verify)
      daemon_bak_verify_name "${2:-}"
      ;;
    *)
      echo "usage: $0 {name-for <md5>|retention-policy|inventory-plan|verify <path>}" >&2
      exit 3
      ;;
  esac
fi
