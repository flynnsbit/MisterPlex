#!/usr/bin/env bash
# rbf_swap_preflight.sh — capture everything needed to PROVE rollback after an RBF swap.
#
# Parent runs BEFORE deploying a new product core (e.g. w-fit-1 frames_done fix).
# Agents must NOT SSH (PREFLIGHT_EXECUTE defaults 0 = print-only).
#
#   NEW_RBF=/path/to/Plex.rbf ./scripts/rbf_swap_preflight.sh plan
#   PREFLIGHT_EXECUTE=1 OUT=./build/preflight-TS NEW_RBF=... ./scripts/rbf_swap_preflight.sh snapshot
#   PREFLIGHT_EXECUTE=1 SNAP=./build/preflight-TS EXPECT_DAEMON_MD5=... ./scripts/rbf_swap_preflight.sh verify-rollback
#
# Minimum post-condition set (rd-review) — see min-postcond verb.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=rbf_ship_policy.sh
source "$ROOT/scripts/rbf_ship_policy.sh"
# shellcheck source=pair_ship_policy.sh
source "$ROOT/scripts/pair_ship_policy.sh"

HOST="${MISTER_HOST:-192.168.1.183}"
USER="${MISTER_USER:-root}"
PASS="${MISTER_PASS:-1}"
PORT="${MISTERPLEX_PORT:-3005}"
EXECUTE="${PREFLIGHT_EXECUTE:-0}"
OUT="${OUT:-$ROOT/build/rbf-preflight}"
NEW_RBF="${NEW_RBF:-}"
SNAP="${SNAP:-}"
CMD="${1:-plan}"

ssh_m() {
  if [[ -n "${PREFLIGHT_SSHM:-}" ]]; then
    # shellcheck disable=SC2086
    $PREFLIGHT_SSHM "$@"
    return
  fi
  sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 "$USER@$HOST" "$@"
}

die() { echo "FAIL rbf_swap_preflight: $*" >&2; echo "true rc=1"; exit 1; }

check_new_rbf_host() {
  local md pol rc
  if [[ -z "$NEW_RBF" ]]; then
    echo "NOTE NEW_RBF unset — skip host banned check (set NEW_RBF=path for refuse gate)"
    return 0
  fi
  [[ -f "$NEW_RBF" ]] || die "NEW_RBF not a file: $NEW_RBF"
  md=$(md5sum "$NEW_RBF" | awk '{print $1}')
  echo "NEW_RBF_PATH=$NEW_RBF"
  echo "NEW_RBF_MD5=$md"
  set +e
  pol=$(rbf_policy_check_md5 "$md")
  rc=$?
  set -e
  printf '%s\n' "$pol"
  echo "rbf_policy_check_md5 true rc=$rc"
  if [[ "$rc" -ne 0 ]]; then
    echo "REFUSE: NEW_RBF is banned or do-not-ship — do not deploy"
    echo "true rc=$rc"
    exit "$rc"
  fi
  echo "OK new-rbf-ship-policy"
}

print_min_postcond() {
  cat <<'POST'
=== MINIMUM ROLLBACK POST-CONDITIONS (trustworthy = all HARD green) ===
HARD (any fail => rollback FAILED, rc!=0):
  H1 n_daemon==1
       enumerate /proc/[0-9]*; identity by comm/argv0 basename misterplexd
       then readlink -f $p/exe — NOT pgrep, NOT cmdline substring (flock trap)
  H2 live_exe_md5 == intended daemon pin
       md5sum "$(readlink -f /proc/$PID/exe)" — never disk path alone (ETXTBSY class)
  H3 core_path_md5 == intended core pin
       md5sum the path you load:
         product DDR: /media/fat/_Utility/Plex.rbf
         SPI undo:    /media/fat/_Utility/Plex_v2.rbf
  H4 pair_policy_check(core_md5, live_daemon_md5) == PAIR_OK
       bank1 SPI 0x30040000 vs DDR 0x30080000 — mixed pair = black/green screen
  H5 HTTP :3005/resources == 200|204
  H6 conf_md5 == pre-swap backup (USER-OWNED byte-exact)
       conf path ONLY from /proc/PID/cmdline --conf (never guess misterplex vs _v2)
  H7 PRESENT=fpga|both (assert only; never rewrite conf)
       PRESENT=fb0 freezes idle (initPresent skips fpga_.open)

SOFT / NOT sufficient alone (record only):
  S1 CORENAME=Plex — USELESS as pair proof (every Plex*.rbf reports Plex)
  S2 disk misterplexd md5 without live /proc/exe
  S3 /resources alone — mixed SPI core+DDR daemon still returns 200

CLAIM (product success):
  C1 VIEWED pixels — visual gate; telemetry is never enough
  C2 frames_done must NOT be the sole liveness proof on c5382bee-class cores
       (vsync counter advances while swaps frozen — STALE cannot fire)
  C3 daily promote BLOCKED on c5382bee until glass re-card breaks 240-row collapse
       (parent fleet 2026-08-01: push_frame --ddr solid-field invert std=0.00)

VOID / WITHDRAWN as promote evidence (fleet 2026-08-01):
  V1 drops=0 — ARM-supply only; unaccounted≡residual≡publish_misses; no FPGA observe
  V2 p_ge50 / "two instruments agree" — UNSCORED / WITHDRAWN (one series; preemption)
  V3 any PLXD[63:48] frames_done derivative on c5382bee — void until new RBF
  V4 horizontal 529-of-640 — arithmetic (clk_sys=20 MHz) NOT pixel-proven

STANDING RULE: publish no field name without its derivation in the same breath.

Parent proposed set vs this answer:
  live md5 == intended     -> H2 HARD (agree)
  exactly one daemon       -> H1 HARD (agree)
  :3005/resources=200      -> H5 HARD (agree, necessary not sufficient)
  conf byte-identical bak  -> H6 HARD (agree)
  CORENAME=Plex            -> S1 SOFT only (disagree as HARD — does not prove path/md5)
  + add H3 core path md5, H4 pair matrix, H7 PRESENT  (required for daily driver)
POST
}

print_snapshot_remote_script() {
  cat <<'EOS'
set +e
echo PREFLIGHT_SNAPSHOT_BEGIN
n=0
pids=""
last_conf=""
for d in /proc/[0-9]*; do
  [ -d "$d" ] || continue
  p=${d#/proc/}
  is=0
  c=""; [ -r "$d/comm" ] && c=$(cat "$d/comm" 2>/dev/null || true)
  [ "$c" = "misterplexd" ] && is=1
  if [ "$is" -eq 0 ] && [ -r "$d/cmdline" ]; then
    a0=$(tr "\0" "\n" <"$d/cmdline" 2>/dev/null | head -n1)
    case "$a0" in */misterplexd|misterplexd) is=1 ;; esac
  fi
  [ "$is" -eq 1 ] || continue
  n=$((n+1))
  pids="$pids $p"
  exe=$(readlink -f "/proc/$p/exe" 2>/dev/null || true)
  md=""; [ -n "$exe" ] && md=$(md5sum "$exe" 2>/dev/null | awk '{print $1}')
  conf=""
  cmd=$(tr "\0" " " <"$d/cmdline" 2>/dev/null || true)
  set -- $cmd
  while [ $# -gt 0 ]; do
    if [ "$1" = "--conf" ]; then conf="${2:-}"; break; fi
    shift
  done
  last_conf=$conf
  echo "LIVE_PID=$p"
  echo "LIVE_EXE=$exe"
  echo "LIVE_MD5=$md"
  echo "LIVE_CONF=$conf"
done
echo "N_DAEMON=$n"
echo "PIDS=$pids"
for f in /media/fat/_Utility/Plex.rbf /media/fat/_Utility/Plex_v2.rbf /media/fat/menu.rbf; do
  if [ -f "$f" ]; then
    echo "CORE_MD5 $(md5sum "$f")"
  else
    echo "CORE_MISSING $f"
  fi
done
if [ -f /tmp/CORENAME ]; then echo "CORENAME=$(cat /tmp/CORENAME)"; else echo "CORENAME="; fi
if [ -f /tmp/RBFNAME ]; then echo "RBFNAME=$(cat /tmp/RBFNAME)"; else echo "RBFNAME="; fi
conf_path=$last_conf
if [ -z "$conf_path" ]; then
  for c in /media/fat/misterplex_v2/misterplex.conf /media/fat/misterplex/misterplex.conf; do
    [ -f "$c" ] && conf_path=$c && break
  done
  echo "CONF_PATH_GUESSED=$conf_path"
else
  echo "CONF_PATH_FROM_CMDLINE=$conf_path"
fi
if [ -n "$conf_path" ] && [ -f "$conf_path" ]; then
  echo "CONF_MD5=$(md5sum "$conf_path" | awk '{print $1}')"
  echo "CONF_BODY_BEGIN"
  cat "$conf_path"
  echo "CONF_BODY_END"
  present=$(sed -n 's/^[[:space:]]*PRESENT=//p' "$conf_path" | head -1 | tr -d '\r')
  idle=$(sed -n 's/^[[:space:]]*IDLE_SCREEN=//p' "$conf_path" | head -1 | tr -d '\r')
  echo "PRESENT=$present"
  echo "IDLE_SCREEN=$idle"
else
  echo "CONF_MD5="
  echo "PRESENT="
  echo "IDLE_SCREEN="
fi
code=000
if command -v wget >/dev/null 2>&1; then
  code=$(wget -q -O /dev/null -S "http://127.0.0.1:3005/resources" 2>&1 | awk '/HTTP\//{print $2; exit}')
  code=${code:-000}
fi
if [ "$code" != "200" ] && [ "$code" != "204" ] && command -v curl >/dev/null 2>&1; then
  code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 2 "http://127.0.0.1:3005/resources" || echo 000)
fi
echo "HTTP_RESOURCES=$code"
if [ -r /proc/stat ]; then head -1 /proc/stat; fi
echo PREFLIGHT_SNAPSHOT_END
EOS
}

cmd_plan() {
  print_min_postcond
  check_new_rbf_host
  cat <<PLAN

=== PARENT PRE-RBF-SWAP SEQUENCE ===
worktree: $ROOT
OUT: $OUT

1) Host evidence + banned check:
   cd $ROOT && git rev-parse --short HEAD
   NEW_RBF=${NEW_RBF:-/path/to/new_Plex.rbf} $0 plan; echo "true rc=\$?"

2) Device READ-ONLY snapshot (parent):
   PREFLIGHT_EXECUTE=1 OUT=$OUT NEW_RBF=${NEW_RBF:-} \\
     $0 snapshot; echo "true rc=\$?"
   # writes: snapshot.txt conf_pre.conf conf_pre.md5 pins.env rollback_cmds.sh

3) RBF deploy (after snapshot OK) — ONE menu only:
   DEPLOY_LOAD=none ./scripts/deploy_plex_core.sh "\$NEW_RBF"
   DEPLOY_LOAD=menu DEPLOY_SKIP_COPY=1 ./scripts/deploy_plex_core.sh
   # never thrash load_core; never kill -9 storms

4) If bad — atomic SPI undo (core+daemon+conf):
   PAIR_ID=spi-v2-hybrid \\
     ROLLBACK_DAEMON=\${ROLLBACK_DAEMON:-artifacts/daemon-pins/misterplexd.50f4eb92} \\
     PAIR_CONF_RESTORE_FILE=$OUT/conf_pre.conf \\
     PAIR_IDLE_PNG=/path/idle.png \\
     scripts/rollback_v2.sh restore; echo "true rc=\$?"

5) Score rollback against snapshot:
   PREFLIGHT_EXECUTE=1 SNAP=$OUT \\
     EXPECT_DAEMON_MD5=<spi_or_bak_pin> EXPECT_CORE_MD5=dfebf2bfd08dd70b473b587dd7e81848 \\
     $0 verify-rollback; echo "true rc=\$?"

c5382bee: frames_done==vsync — STALE blind; viewed pixels + rollback ready before swap.
PLAN
  echo "true rc=0"
}

cmd_snapshot() {
  check_new_rbf_host
  if [[ "$EXECUTE" != "1" ]]; then
    echo "DRY-RUN snapshot (PREFLIGHT_EXECUTE=0)"
    print_snapshot_remote_script
    echo "true rc=0"
    return 0
  fi
  mkdir -p "$OUT"
  local blob rc
  set +e
  blob=$(ssh_m bash -s <<EOS
$(print_snapshot_remote_script)
EOS
)
  rc=$?
  set -e
  printf '%s\n' "$blob" | tee "$OUT/snapshot.txt"
  echo "snapshot_ssh true rc=$rc"
  [[ "$rc" -eq 0 ]] || die "snapshot ssh failed rc=$rc"

  if grep -q 'CONF_BODY_BEGIN' "$OUT/snapshot.txt"; then
    sed -n '/CONF_BODY_BEGIN/,/CONF_BODY_END/{/CONF_BODY_BEGIN/d;/CONF_BODY_END/d;p;}' \
      "$OUT/snapshot.txt" >"$OUT/conf_pre.conf"
    md5sum "$OUT/conf_pre.conf" | awk '{print $1}' | tee "$OUT/conf_pre.md5"
  fi

  {
    echo "SNAP_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    sed -n 's/^LIVE_MD5=/PRE_LIVE_DAEMON_MD5=/p' "$OUT/snapshot.txt" | head -1
    sed -n 's/^N_DAEMON=/PRE_N_DAEMON=/p' "$OUT/snapshot.txt" | head -1
    sed -n 's/^HTTP_RESOURCES=/PRE_HTTP=/p' "$OUT/snapshot.txt" | head -1
    sed -n 's/^PRESENT=/PRE_PRESENT=/p' "$OUT/snapshot.txt" | head -1
    sed -n 's/^IDLE_SCREEN=/PRE_IDLE_SCREEN=/p' "$OUT/snapshot.txt" | head -1
    grep '^CORE_MD5 ' "$OUT/snapshot.txt" | while read -r _ path md _; do
      base=$(basename "$path")
      safe=${base//./_}
      echo "PRE_CORE_${safe}_MD5=$md"
      echo "PRE_CORE_${safe}_PATH=$path"
    done
    if [[ -f "$OUT/conf_pre.md5" ]]; then
      echo "PRE_CONF_MD5=$(cat "$OUT/conf_pre.md5")"
    fi
    sed -n 's/^LIVE_CONF=/PRE_CONF_PATH=/p' "$OUT/snapshot.txt" | head -1
    sed -n 's/^CONF_PATH_FROM_CMDLINE=/PRE_CONF_PATH=/p' "$OUT/snapshot.txt" | head -1
  } >"$OUT/pins.env"

  cat >"$OUT/rollback_cmds.sh" <<RBOUT
#!/usr/bin/env bash
set -euo pipefail
ROOT="$ROOT"
OUT="$OUT"
PAIR_ID=spi-v2-hybrid \\
  PAIR_CONF_RESTORE_FILE="\$OUT/conf_pre.conf" \\
  PAIR_IDLE_PNG="\${PAIR_IDLE_PNG:?set idle png}" \\
  "\$ROOT/scripts/rollback_v2.sh" restore
echo "true rc=\$?"
RBOUT
  chmod +x "$OUT/rollback_cmds.sh"
  print_min_postcond
  echo "SNAPSHOT_OK out=$OUT"
  echo "true rc=0"
}

cmd_verify_rollback() {
  [[ -n "$SNAP" && -d "$SNAP" ]] || die "SNAP=dir required"
  [[ -f "$SNAP/pins.env" ]] || die "missing $SNAP/pins.env"
  # shellcheck disable=SC1090
  source "$SNAP/pins.env"
  print_min_postcond
  if [[ "$EXECUTE" != "1" ]]; then
    echo "DRY-RUN verify-rollback vs $SNAP/pins.env"
    echo "true rc=0"
    return 0
  fi
  local blob n live http conf_md5 present rc fail=0 gotc
  set +e
  blob=$(ssh_m bash -s <<EOS
$(print_snapshot_remote_script)
EOS
)
  rc=$?
  set -e
  printf '%s\n' "$blob" | tee "$SNAP/post_rollback_snapshot.txt"
  [[ "$rc" -eq 0 ]] || die "verify ssh failed"

  n=$(printf '%s\n' "$blob" | sed -n 's/^N_DAEMON=//p' | head -1)
  live=$(printf '%s\n' "$blob" | sed -n 's/^LIVE_MD5=//p' | head -1)
  http=$(printf '%s\n' "$blob" | sed -n 's/^HTTP_RESOURCES=//p' | head -1)
  present=$(printf '%s\n' "$blob" | sed -n 's/^PRESENT=//p' | head -1 | tr 'A-Z' 'a-z')
  conf_md5=$(printf '%s\n' "$blob" | sed -n 's/^CONF_MD5=//p' | head -1)

  echo "CHECK H1 n_daemon got=$n want=1"
  [[ "$n" == "1" ]] || { echo "FAIL H1"; fail=1; }
  echo "CHECK H5 http got=$http"
  [[ "$http" == "200" || "$http" == "204" ]] || { echo "FAIL H5"; fail=1; }
  echo "CHECK H7 PRESENT got=$present"
  case "$present" in fpga|both) ;; *) echo "FAIL H7"; fail=1 ;; esac
  if [[ -n "${PRE_CONF_MD5:-}" ]]; then
    echo "CHECK H6 conf got=$conf_md5 want=$PRE_CONF_MD5"
    [[ "$conf_md5" == "$PRE_CONF_MD5" ]] || { echo "FAIL H6"; fail=1; }
  fi
  if [[ -n "${EXPECT_DAEMON_MD5:-}" ]]; then
    echo "CHECK H2 live got=$live want=$EXPECT_DAEMON_MD5"
    if [[ "$live" != "$EXPECT_DAEMON_MD5" && "${live:0:8}" != "${EXPECT_DAEMON_MD5:0:8}" ]]; then
      echo "FAIL H2"; fail=1
    fi
  else
    echo "NOTE H2 set EXPECT_DAEMON_MD5 to enforce"
  fi
  if [[ -n "${EXPECT_CORE_MD5:-}" ]]; then
    gotc=$(printf '%s\n' "$blob" | grep '^CORE_MD5 ' | awk '{print $3}' | head -1)
    echo "CHECK H3 core md5s in blob (want $EXPECT_CORE_MD5); first=$gotc"
    if ! printf '%s\n' "$blob" | grep -q "$EXPECT_CORE_MD5"; then
      echo "FAIL H3 expected core md5 not on device paths"; fail=1
    fi
  fi
  echo "SOFT S1 CORENAME=$(printf '%s\n' "$blob" | sed -n 's/^CORENAME=//p' | head -1) (not scored)"

  if [[ "$fail" -ne 0 ]]; then
    echo "VERIFY_ROLLBACK_FAIL"
    echo "true rc=9"
    exit 9
  fi
  echo "VERIFY_ROLLBACK_OK"
  echo "true rc=0"
}

case "$CMD" in
  plan) cmd_plan ;;
  snapshot) cmd_snapshot ;;
  verify-rollback) cmd_verify_rollback ;;
  min-postcond) print_min_postcond; echo "true rc=0" ;;
  *)
    echo "usage: $0 {plan|snapshot|verify-rollback|min-postcond}" >&2
    echo "true rc=9"
    exit 9
    ;;
esac
