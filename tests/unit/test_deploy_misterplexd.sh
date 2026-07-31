#!/usr/bin/env bash
# Host-only red/green for scripts/deploy_misterplexd.sh policy.
# Proves the three parent-measured defect classes fail closed:
#   1) install root != live root
#   2) n_daemon != 1 after deploy
#   3) /proc/PID/exe md5 != host artifact
# Never touches 192.168.1.183 — pure helpers + injected DEPLOY_SSHM/SCPM.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/deploy_misterplexd_lib.sh"
SCRIPT="$ROOT/scripts/deploy_misterplexd.sh"
WORK="$ROOT/build/test-deploy-misterplexd"
rm -rf "$WORK"
mkdir -p "$WORK"
chmod +x "$SCRIPT"
bash -n "$SCRIPT"
bash -n "$ROOT/scripts/deploy_misterplexd_lib.sh"

pass=0
fail=0
ok() { echo "PASS $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1" >&2; fail=$((fail + 1)); }

# --- pure policy: RED cross-root ---------------------------------------------
echo "=== RED: force v1 while live is v2 ==="
if out=$(deploy_resolve_target_root "/media/fat/misterplex_v2" "/media/fat/misterplex" 2>&1); then
  bad "cross-root-resolve-should-fail got='$out'"
else
  rc=$?
  [[ "$rc" -eq 2 ]] && ok "cross-root-resolve-rc=2" || bad "cross-root-resolve-rc=$rc want=2"
fi
if deploy_install_root_matches_live "/media/fat/misterplex" "/media/fat/misterplex_v2" 2>/dev/null; then
  bad "install-root-mismatch-should-fail"
else
  ok "install-root-mismatch-rc=1"
fi

# --- pure policy: GREEN live root --------------------------------------------
echo "=== GREEN: resolve follows live v2 ==="
got=$(deploy_resolve_target_root "/media/fat/misterplex_v2" "")
[[ "$got" == "/media/fat/misterplex_v2" ]] && ok "resolve-live-v2" || bad "resolve-live-v2 got=$got"
deploy_install_root_matches_live "/media/fat/misterplex_v2" "/media/fat/misterplex_v2" \
  && ok "install-root-match" || bad "install-root-match"

# --- pure policy: RED dual daemon / md5 / conf -------------------------------
echo "=== RED: n_daemon=2 ==="
if deploy_assert_single_live 2 abc abc \
    "/media/fat/misterplex_v2/misterplex.conf" "/media/fat/misterplex_v2" 2>/dev/null; then
  bad "n_daemon=2 should fail"
else
  [[ $? -eq 3 ]] && ok "n_daemon=2-rc=3" || bad "n_daemon=2 unexpected rc"
fi

echo "=== RED: live md5 != host md5 ==="
if deploy_assert_single_live 1 deadbeef cafebabe \
    "/media/fat/misterplex_v2/misterplex.conf" "/media/fat/misterplex_v2" 2>/dev/null; then
  bad "md5-mismatch should fail"
else
  [[ $? -eq 5 ]] && ok "md5-mismatch-rc=5" || bad "md5-mismatch unexpected rc"
fi

echo "=== RED: conf under wrong root (v1 conf, v2 target) ==="
if deploy_assert_single_live 1 abc abc \
    "/media/fat/misterplex/misterplex.conf" "/media/fat/misterplex_v2" 2>/dev/null; then
  bad "wrong-conf-root should fail"
else
  [[ $? -eq 6 ]] && ok "wrong-conf-root-rc=6" || bad "wrong-conf-root unexpected rc"
fi

echo "=== GREEN: single live matching host md5 under v2 ==="
deploy_assert_single_live 1 abcabc abcabc \
  "/media/fat/misterplex_v2/misterplex.conf" "/media/fat/misterplex_v2" \
  && ok "single-live-ok" || bad "single-live-ok"

# --- integration: injected transport (no real SSH) ---------------------------
# Fake binary with known md5
printf 'fake-misterplexd-artifact\n' >"$WORK/fake.bin"
chmod +x "$WORK/fake.bin"
HOST_MD5=$(md5sum "$WORK/fake.bin" | awk '{print $1}')

# State for the fake device
STATE="$WORK/state"
mkdir -p "$STATE"
echo "v2" >"$STATE/live_root"          # live daemon root key
echo "0" >"$STATE/n_after"             # overridden per case
echo "$HOST_MD5" >"$STATE/live_md5"
echo "200" >"$STATE/http"

cat >"$WORK/fake_sshm.sh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
STATE_DIR="${DEPLOY_FAKE_STATE:?}"
input="$(cat || true)"
args="$*"

# 1) Live probe
if echo "$input" | grep -q 'echo "N_DAEMON='; then
  rootkey=$(cat "$STATE_DIR/live_root")
  if [[ "$rootkey" == "v2" ]]; then root=/media/fat/misterplex_v2
  elif [[ "$rootkey" == "v1" ]]; then root=/media/fat/misterplex
  elif [[ "$rootkey" == "none" ]]; then
    echo "N_DAEMON=0"; echo "ROOT="; exit 0
  else root="$rootkey"; fi
  echo "LIVE_PID=4242 ROOT=$root CONF=$root/misterplex.conf CMD=$root/bin/misterplexd --conf $root/misterplex.conf"
  echo "N_DAEMON=1"
  echo "ROOT=$root"
  exit 0
fi

# 2) Stop
if echo "$input" | grep -q 'STOP_OK'; then
  echo "STOP_OK"
  exit 0
fi

# 3) Start + postcheck (MUST precede mkdir match — start script contains mkdir -p)
if echo "$input" | grep -q 'POST_N_DAEMON\|DEPLOY_OK root='; then
  echo "$args" >"$STATE_DIR/start_env"
  for tok in $args; do
    case "$tok" in
      TARGET_ROOT=*) echo "${tok#TARGET_ROOT=}" >"$STATE_DIR/chosen_root" ;;
      HOST_MD5=*) echo "${tok#HOST_MD5=}" >"$STATE_DIR/host_md5_seen" ;;
    esac
  done
  n=$(cat "$STATE_DIR/n_after")
  md=$(cat "$STATE_DIR/live_md5")
  http=$(cat "$STATE_DIR/http")
  chosen=$(cat "$STATE_DIR/chosen_root" 2>/dev/null || echo "")
  conf="${chosen}/misterplex.conf"
  host=$(cat "$STATE_DIR/host_md5_seen" 2>/dev/null || true)
  echo "POST_N_DAEMON=$n"
  echo "POST_PIDS=99"
  echo "POST_LIVE_MD5=$md"
  echo "POST_LIVE_CONF=$conf"
  echo "POST_HOST_MD5=$host"
  echo "POST_TARGET_ROOT=$chosen"
  echo "POST_HTTP=$http"
  if [[ "$n" -ne 1 ]]; then
    echo "FAIL n_daemon=$n want=1"
    exit 3
  fi
  if [[ "$md" != "$host" ]]; then
    echo "FAIL live exe md5 $md != host artifact $host"
    exit 5
  fi
  case "$conf" in
    "$chosen"/*) ;;
    *) echo "FAIL conf"; exit 6 ;;
  esac
  if [[ "$http" != "200" ]]; then
    echo "FAIL http $http"
    exit 7
  fi
  livekey=$(cat "$STATE_DIR/live_root")
  if [[ "$livekey" == "v2" && "$chosen" == "/media/fat/misterplex" ]]; then
    echo "FAIL install to v1 while live is v2"
    exit 8
  fi
  echo "DEPLOY_OK root=$chosen md5=$md n_daemon=1 http=$http"
  exit 0
fi

# 4) Install prep
if echo "$args" | grep -q 'DEPLOY_INSTALL_PREP' || echo "$input" | grep -q 'DEPLOY_INSTALL_PREP'; then
  echo "$args" >>"$STATE_DIR/ssh_cmds"
  echo "MKDIR_OK"
  exit 0
fi

# 5) Default root when no live daemon
if echo "$args" | grep -q 'misterplex_v2'; then
  echo "/media/fat/misterplex_v2"
  exit 0
fi

echo "FAKE_SSH unhandled args=$args" >&2
echo "input_head=$(echo "$input" | head -c 160)" >&2
exit 99
FAKE
chmod +x "$WORK/fake_sshm.sh"

cat >"$WORK/fake_scpm.sh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
STATE_DIR="${DEPLOY_FAKE_STATE:?}"
src="$1"
dst="$2"
echo "$dst" >>"$STATE_DIR/scp_dests"
cp -f "$src" "$STATE_DIR/last_payload" 2>/dev/null || true
# verify payload md5 matches source
exit 0
FAKE
chmod +x "$WORK/fake_scpm.sh"

run_deploy() {
  local label="$1"
  shift
  set +e
  DEPLOY_FAKE_STATE="$STATE" \
  DEPLOY_SSHM="$WORK/fake_sshm.sh" \
  DEPLOY_SCPM="$WORK/fake_scpm.sh" \
  DEPLOY_BIN="$WORK/fake.bin" \
  DEPLOY_REBUILD=0 \
  DEPLOY_SKIP_GEOMETRY_GATE=1 \
  "$@" \
  "$SCRIPT" >"$WORK/${label}.out" 2>&1
  rc=$?
  set -e
  echo "  [$label] true rc=$rc"
  return "$rc"
}

echo "=== RED integration: MISTERPLEX_ROOT=v1 while live=v2 ==="
: >"$STATE/ssh_cmds"
echo "v2" >"$STATE/live_root"
echo "1" >"$STATE/n_after"
echo "$HOST_MD5" >"$STATE/live_md5"
if run_deploy "cross-root" env MISTERPLEX_ROOT=/media/fat/misterplex; then
  bad "integ-cross-root should fail"
  cat "$WORK/cross-root.out" | tail -20 >&2
else
  grep -q 'refusing cross-root deploy' "$WORK/cross-root.out" \
    && ok "integ-cross-root-msg" || bad "integ-cross-root-msg missing"
fi

echo "=== RED integration: dual daemon after start ==="
echo "v2" >"$STATE/live_root"
echo "2" >"$STATE/n_after"
echo "$HOST_MD5" >"$STATE/live_md5"
: >"$STATE/scp_dests"
if run_deploy "dual" env -u MISTERPLEX_ROOT; then
  bad "integ-dual should fail"
else
  grep -q 'n_daemon=2' "$WORK/dual.out" && ok "integ-dual-msg" || {
    bad "integ-dual-msg"; tail -30 "$WORK/dual.out" >&2
  }
fi

echo "=== RED integration: live md5 mismatch (ETXTBSY class) ==="
echo "v2" >"$STATE/live_root"
echo "1" >"$STATE/n_after"
echo "00000000000000000000000000000000" >"$STATE/live_md5"
if run_deploy "etxtbsy" env -u MISTERPLEX_ROOT; then
  bad "integ-etxtbsy should fail"
else
  grep -q 'live exe md5' "$WORK/etxtbsy.out" && ok "integ-etxtbsy-msg" || {
    bad "integ-etxtbsy-msg"; tail -30 "$WORK/etxtbsy.out" >&2
  }
fi

echo "=== GREEN integration: live v2, n=1, md5 match ==="
echo "v2" >"$STATE/live_root"
echo "1" >"$STATE/n_after"
echo "$HOST_MD5" >"$STATE/live_md5"
: >"$STATE/scp_dests"
if run_deploy "green" env -u MISTERPLEX_ROOT; then
  ok "integ-green-rc0"
else
  bad "integ-green-rc0"
  tail -40 "$WORK/green.out" >&2
fi
if grep -q '/media/fat/misterplex_v2/bin/misterplexd' "$STATE/scp_dests"; then
  ok "integ-green-scp-v2"
else
  bad "integ-green-scp-v2 dests=$(cat "$STATE/scp_dests")"
fi
if grep -q 'misterplex/bin/misterplexd' "$STATE/scp_dests" && \
   ! grep -q 'misterplex_v2/bin/misterplexd' "$STATE/scp_dests"; then
  bad "integ-green-must-not-only-hit-v1"
fi
grep -q "DEPLOY_OK" "$WORK/green.out" && ok "integ-green-deploy-ok" || bad "integ-green-deploy-ok"
grep -q "host_md5=$HOST_MD5" "$WORK/green.out" && ok "integ-green-prints-host-md5" || bad "integ-green-prints-host-md5"

# Guarantee: default path must NOT invoke make/rebuild (no DEPLOY_REBUILD)
if grep -qE 'arm-plexd|make -C' "$WORK/green.out"; then
  bad "integ-green-must-not-rebuild"
else
  ok "integ-green-no-rebuild"
fi

echo "=== summary pass=$pass fail=$fail ==="
[[ "$fail" -eq 0 ]] || exit 1
echo "ALL test_deploy_misterplexd checks passed"
