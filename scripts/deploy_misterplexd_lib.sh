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

# --- conf safety (USER-OWNED bytes; assert only, never rewrite) -----------------
# PRESENT=fb0 freezes idle (initPresent skips fpga_.open unless fpga|both).
# Args: conf body or file path. Returns 0 OK, 7 bad PRESENT, 4 NO-DATA.
deploy_assert_present_fpga() {
  local src="${1:-}" body
  if [[ -z "$src" ]]; then
    echo "FAIL PRESENT NO-DATA (empty conf)" >&2
    return 4
  fi
  if [[ -f "$src" ]]; then body=$(cat "$src"); else body="$src"; fi
  local val
  val=$(printf '%s\n' "$body" | sed -n 's/^[[:space:]]*PRESENT=//p' | head -1 | tr -d '\r' | awk '{print $1}')
  val=$(printf '%s' "$val" | tr 'A-Z' 'a-z')
  if [[ -z "$val" ]]; then
    echo "FAIL PRESENT missing (need fpga|both; fb0 freezes idle)" >&2
    return 7
  fi
  case "$val" in
    fpga|both)
      echo "OK PRESENT=$val"
      return 0
      ;;
    fb0)
      echo "FAIL PRESENT=fb0 freezes idle (initPresent skips fpga_.open)" >&2
      return 7
      ;;
    *)
      echo "FAIL PRESENT=$val want=fpga|both" >&2
      return 7
      ;;
  esac
}

# Promotion capture hygiene: static logo, not bouncing screensaver.
# Assert only — never rewrite user conf. Returns 0 OK, 7 warn-as-fail when required.
deploy_assert_idle_logo() {
  local src="${1:-}" body val
  if [[ -z "$src" ]]; then
    echo "FAIL IDLE_SCREEN NO-DATA" >&2
    return 4
  fi
  if [[ -f "$src" ]]; then body=$(cat "$src"); else body="$src"; fi
  val=$(printf '%s\n' "$body" | sed -n 's/^[[:space:]]*IDLE_SCREEN=//p' | head -1 | tr -d '\r' | awk '{print $1}')
  val=$(printf '%s' "$val" | tr 'A-Z' 'a-z')
  if [[ -z "$val" ]]; then
    echo "FAIL IDLE_SCREEN missing (want logo for promotion captures)" >&2
    return 7
  fi
  if [[ "$val" == "logo" ]]; then
    echo "OK IDLE_SCREEN=logo"
    return 0
  fi
  echo "FAIL IDLE_SCREEN=$val want=logo (screensaver contaminates captures; user rule)" >&2
  return 7
}

# --- liveness HTTP without head/pipe $? clobber (parent gate-liveness :73-74) ---
# Args: http_code (already captured WITHOUT piping the health command through head)
# Returns 0 if 200|204; 7 otherwise; 4 if empty (NO-DATA).
deploy_assert_resources_http() {
  local code="${1:-}"
  if [[ -z "$code" ]]; then
    echo "FAIL /resources HTTP NO-DATA (empty code — probe discarded or never ran)" >&2
    return 4
  fi
  if [[ "$code" == "200" || "$code" == "204" ]]; then
    echo "OK /resources HTTP $code"
    return 0
  fi
  echo "FAIL /resources HTTP $code (want 200|204; dead daemon class)" >&2
  return 7
}

# LEGACY BROKEN pattern (gate-liveness deploy :73-74):
#   ps | grep || true
#   wget .../resources | head -c 300; echo
# $? after head is head's rc (0), even when wget fails / connection refused.
# This function documents and *reproduces* that lie for mutation tests.
# Args: wget_rc head_rc  → prints "legacy_true_rc=N" where N is what the old
# script would have seen after the pipe (always head_rc). Returns 0 always
# (the bug: deploy continued as success).
deploy_legacy_liveness_pipe_lie() {
  local wget_rc="${1:-1}"
  local head_rc="${2:-0}"
  # Old script: discarded ps; then pipe to head; then echo Deployed.
  echo "LEGACY_LIVENESS wget_rc=$wget_rc head_rc=$head_rc (ps|grep discarded with || true)"
  echo "legacy_true_rc=$head_rc"
  # Always "success" from the script's perspective after `| head`.
  return 0
}

# Geometry soft-skip (rc=77) is NEVER a deploy pass.
# Args: geo_rc require_geometry(0|1)
# Returns: 0 if geo_rc==0; 78 if geo_rc==77 (skip-not-pass elevated);
#          geo_rc if hard fail; when require=0 and geo_rc==77 → return 77
#          (caller must NOT print DEPLOY_OK; must not treat as overall 0).
deploy_geometry_gate_rc() {
  local geo_rc="${1:-1}"
  local require="${2:-0}"
  case "$geo_rc" in
    0)
      echo "OK core_conf_geometry PASS"
      return 0
      ;;
    77)
      echo "core_conf_geometry SKIP-NOT-PASS (rc=77) — not deploy success evidence" >&2
      if [[ "$require" == "1" ]]; then
        echo "FAIL geometry required for this deploy (DEPLOY_REQUIRE_GEOMETRY=1)" >&2
        return 78
      fi
      return 77
      ;;
    *)
      echo "FAIL core_conf_geometry rc=$geo_rc" >&2
      return "$geo_rc"
      ;;
  esac
}

# --- restore post-conditions (rd-review: restore had md5sum || true) ---------
# Args: n_daemon live_md5 expect_daemon_md5 http conf_live_md5 conf_expect_md5
#       core_disk_md5 core_expect_md5 [ini_live_md5 ini_expect_md5]
# Returns 0 only if all HARD green. Empty expect_* that is required → fail.
restore_assert_postconditions() {
  local n="${1:-0}"
  local live_md5="${2:-}"
  local expect_daemon="${3:-}"
  local http="${4:-}"
  local conf_live="${5:-}"
  local conf_expect="${6:-}"
  local core_live="${7:-}"
  local core_expect="${8:-}"
  local ini_live="${9:-}"
  local ini_expect="${10:-}"

  if [[ "$n" -ne 1 ]]; then
    echo "FAIL restore H1 n_daemon=$n want=1" >&2
    return 3
  fi
  if [[ -z "$live_md5" || -z "$expect_daemon" ]]; then
    echo "FAIL restore H2 NO-DATA live='$live_md5' expect='$expect_daemon'" >&2
    return 4
  fi
  if [[ "$live_md5" != "$expect_daemon" ]]; then
    echo "FAIL restore H2 live_md5=$live_md5 != expect=$expect_daemon" >&2
    return 5
  fi
  deploy_assert_resources_http "$http" || return $?
  if [[ -z "$conf_expect" || "$conf_expect" == "SKIP" ]]; then
    echo "NOTE restore H6 conf expect SKIP (caller opted out — not for daily driver)"
  else
    if [[ -z "$conf_live" ]]; then
      echo "FAIL restore H6 conf live NO-DATA" >&2
      return 4
    fi
    if [[ "$conf_live" != "$conf_expect" ]]; then
      echo "FAIL restore H6 conf mutated live=$conf_live expect=$conf_expect (USER-OWNED byte-exact)" >&2
      return 7
    fi
    echo "OK restore H6 conf byte-exact $conf_live"
  fi
  if [[ -n "$core_expect" && "$core_expect" != "SKIP" ]]; then
    if [[ -z "$core_live" ]]; then
      echo "FAIL restore H3 core md5 NO-DATA" >&2
      return 4
    fi
    if [[ "$core_live" != "$core_expect" ]]; then
      echo "FAIL restore H3 core_md5=$core_live != expect=$core_expect" >&2
      return 5
    fi
    echo "OK restore H3 core $core_live"
  fi
  # MiSTer.ini USER-OWNED — when expect set, must match byte-exact.
  if [[ -n "$ini_expect" && "$ini_expect" != "SKIP" ]]; then
    if [[ -z "$ini_live" ]]; then
      echo "FAIL restore ini NO-DATA (USER-OWNED MiSTer.ini)" >&2
      return 4
    fi
    if [[ "$ini_live" != "$ini_expect" ]]; then
      echo "FAIL restore ini mutated live=$ini_live expect=$ini_expect (never normalise)" >&2
      return 7
    fi
    echo "OK restore ini byte-exact $ini_live"
  fi
  echo "OK restore_assert_postconditions"
  return 0
}

# --- two-roots trap (parent: silent v1 DECODE=320x240) -----------------------
# Args: install_root live_conf_path [install_conf_exists 0|1] [foreign_conf_exists 0|1]
# Fails if live conf is under a different root than install_root, or if install
# conf is missing while foreign conf exists (the silent fallback layout).
deploy_assert_two_roots_safe() {
  local install_root="${1:-}"
  local live_conf="${2:-}"
  local install_conf_exists="${3:-1}"
  local foreign_conf_exists="${4:-0}"
  local foreign_root="/media/fat/misterplex"

  if [[ -z "$install_root" ]]; then
    echo "FAIL two-roots: empty install_root" >&2
    return 4
  fi
  # Normalize trailing slash
  install_root="${install_root%/}"
  if [[ -n "$live_conf" ]]; then
    case "$live_conf" in
      "$install_root"/*) ;;
      *)
        echo "FAIL two-roots: live --conf $live_conf not under install_root $install_root" >&2
        return 12
        ;;
    esac
  fi
  if [[ "$install_conf_exists" != "1" && "$foreign_conf_exists" == "1" ]]; then
    echo "FAIL two-roots: install conf MISSING at $install_root/misterplex.conf while $foreign_root conf exists — silent 320x240 trap" >&2
    return 12
  fi
  if [[ "$install_conf_exists" != "1" ]]; then
    echo "FAIL two-roots: install conf missing at $install_root/misterplex.conf (refuse start; no foreign fallback)" >&2
    return 12
  fi
  echo "OK two-roots install_root=$install_root conf_under_root=1"
  return 0
}

# --- user-owned state byte-exact (conf + MiSTer.ini) -------------------------
# Args: label live_md5 bak_md5
user_state_assert_byte_exact() {
  local label="${1:-state}"
  local live="${2:-}"
  local bak="${3:-}"
  if [[ -z "$live" || -z "$bak" ]]; then
    echo "FAIL $label byte-exact NO-DATA live='$live' bak='$bak'" >&2
    return 4
  fi
  if [[ "$live" != "$bak" ]]; then
    echo "FAIL $label byte-exact live=$live bak=$bak (USER-OWNED; never normalise)" >&2
    return 7
  fi
  echo "OK $label byte-exact $live"
  return 0
}

# --- post-promotion session telemetry (cannot pass vacuously) ---------------
# Args: delivery_verified measured_delivery drops unaccounted vfps source_fps
#   session_established 0|1
# Returns: 0 PASS; 77 UNSCORED (no session); 1 FAIL metrics.
promotion_assert_session_telemetry() {
  local delivery_verified="${1:-}"
  local measured_delivery="${2:-}"
  local drops="${3:-}"
  local unaccounted="${4:-}"
  local vfps="${5:-}"
  local source_fps="${6:-}"
  local session_established="${7:-0}"

  if [[ "$session_established" != "1" ]]; then
    echo "UNSCORED promotion session: daemon never established a scored session (not PASS)" >&2
    echo "promotion_session=UNSCORED"
    return 77
  fi
  if [[ "$delivery_verified" != "1" ]]; then
    echo "FAIL delivery_verified=$delivery_verified want=1 (derivation: daemon MEASURED_DELIVERY gate)" >&2
    return 1
  fi
  if [[ -z "$measured_delivery" ]]; then
    echo "FAIL measured_delivery empty" >&2
    return 1
  fi
  # drops/unaccounted: require numeric and zero for promote hard gate.
  # Derivation: ARM ledger fields — parent notes drops≠display proof; still
  # required non-vacuous closed ledger for promote soak.
  if ! [[ "$drops" =~ ^[0-9]+$ ]]; then
    echo "FAIL drops NO-DATA '$drops'" >&2
    return 1
  fi
  if [[ "$drops" -ne 0 ]]; then
    echo "FAIL drops=$drops want=0" >&2
    return 1
  fi
  if ! [[ "$unaccounted" =~ ^[0-9]+$ ]]; then
    echo "FAIL unaccounted NO-DATA '$unaccounted'" >&2
    return 1
  fi
  if [[ "$unaccounted" -ne 0 ]]; then
    echo "FAIL unaccounted=$unaccounted want=0 (derivation: residual≡publish_misses on some builds — still must close)" >&2
    return 1
  fi
  if [[ -z "$vfps" || -z "$source_fps" ]]; then
    echo "FAIL vfps/source_fps NO-DATA vfps='$vfps' source_fps='$source_fps'" >&2
    return 1
  fi
  # Loose numeric compare via awk (|vfps-source| <= 0.05)
  local ok
  ok=$(awk -v v="$vfps" -v s="$source_fps" 'BEGIN{
    if (v+0!=v || s+0!=s) { print "nan"; exit }
    d=v-s; if (d<0) d=-d;
    print (d<=0.05)?"1":"0"
  }')
  if [[ "$ok" != "1" ]]; then
    echo "FAIL vfps=$vfps vs source_fps=$source_fps (tol 0.05)" >&2
    return 1
  fi
  echo "OK promotion_session delivery_verified=1 measured_delivery=$measured_delivery drops=0 unaccounted=0 vfps=$vfps source_fps=$source_fps"
  echo "promotion_session=PASS"
  return 0
}

# Menu bounce command builder — full path only (bare menu.rbf silently no-ops).
# Prints the exact bytes to write to /dev/MiSTer_cmd. Never thrash.
promotion_menu_bounce_cmd() {
  local core_path="${1:-/media/fat/_Utility/Plex.rbf}"
  printf 'load_core /media/fat/menu.rbf\n'
  echo "# sleep ~6s then:"
  printf 'load_core %s\n' "$core_path"
}
