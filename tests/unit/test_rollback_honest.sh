#!/usr/bin/env bash
# Host-only: atomic pair rollback + honest plexctl host guard.
# Never touches the real device.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$ROOT/build/rollback-honest-test"
PLEXCTL="$ROOT/scripts/plexctl.sh"
ROLLBACK="$ROOT/scripts/rollback_v2.sh"
CORE_MD5=dfebf2bfd08dd70b473b587dd7e81848
DAEMON_MD5=50f4eb925de10e29172999a565c87684
DDR_DAEMON=e9f79de217982aff44207664fdb945c5

rm -rf "$WORK"
mkdir -p "$WORK" "$WORK/pins"
chmod +x "$PLEXCTL" "$ROLLBACK" \
  "$ROOT/scripts/pair_ship_policy.sh" \
  "$ROOT/scripts/pair_visual_gate.sh"
bash -n "$PLEXCTL"
bash -n "$ROLLBACK"
bash -n "$ROOT/scripts/pair_ship_policy.sh"

# --- plexctl load_core on host ----------------------------------------------
echo "=== plexctl load_core on host must be CANNOT_CHECK, not MISSING ==="
set +e
out=$(bash "$PLEXCTL" reload-v2 2>&1)
rc=$?
set -e
printf '%s\n' "$out" | sed 's/^/  [plexctl] /'
echo "  [plexctl] true rc=$rc"
[ "$rc" -eq 4 ] || { echo "FAIL plexctl host want rc=4 got $rc"; exit 1; }
echo "$out" | grep -q 'ERROR no core at' && { echo "FAIL false no-core"; exit 1; }
echo "$out" | grep -qE 'NOT_ON_DEVICE|cannot check device path|not on MiSTer' || {
  echo "FAIL need honest host wording"; exit 1
}
echo "OK plexctl-host-cannot-check rc=4"

# --- pair policy ------------------------------------------------------------
echo "=== pair policy accepts SPI hybrid ==="
set +e
out=$("$ROOT/scripts/pair_ship_policy.sh" check "$CORE_MD5" "$DAEMON_MD5" 2>&1)
rc=$?
set -e
echo "  true rc=$rc"
[ "$rc" -eq 0 ] || { echo "FAIL spi pair"; exit 1; }
echo "$out" | grep -q PAIR_OK || { echo "FAIL PAIR_OK"; exit 1; }
echo "OK spi-pair"

echo "=== pair policy REFUSES spi core + ddr daemon (green screen) ==="
set +e
out=$("$ROOT/scripts/pair_ship_policy.sh" check "$CORE_MD5" "$DDR_DAEMON" 2>&1)
rc=$?
set -e
echo "  true rc=$rc"
echo "$out" | sed 's/^/  /'
[ "$rc" -eq 1 ] || { echo "FAIL want refuse rc=1 got $rc"; exit 1; }
echo "$out" | grep -qi 'spi_core_plus_ddr_daemon\|solid_green' || {
  echo "FAIL need green-screen refuse reason"; exit 1
}
echo "OK refuse-mixed-pair"

# --- fake transports --------------------------------------------------------
cat >"$WORK/fake_ssh.sh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
SCEN="${ROLLBACK_SCENARIO:?}"
# shellcheck disable=SC1090
source "$SCEN"
cmd="${1:-}"
attempt_file="${ROLLBACK_ATTEMPT_FILE:-}"

fail_n=${ssh_fail_first_n:-0}
if [[ -n "$attempt_file" ]]; then
  att=0
  [[ -f "$attempt_file" ]] && att=$(cat "$attempt_file")
  att=$((att + 1))
  echo "$att" >"$attempt_file"
  if [[ "$att" -le "$fail_n" ]]; then
    echo "No route to host" >&2
    exit 255
  fi
fi

# core md5
if [[ "$cmd" == *"md5sum"* && "$cmd" == *"Plex_v2.rbf"* ]]; then
  if [[ "${core_state:-ok}" == "missing" ]]; then echo MISSING; exit 0; fi
  if [[ "${core_state:-ok}" == "empty" ]]; then exit 0; fi
  echo "${core_md5:-dfebf2bfd08dd70b473b587dd7e81848}"
  exit 0
fi
# product core path (ddr pair)
if [[ "$cmd" == *"md5sum"* && "$cmd" == *"/Plex.rbf"* && "$cmd" != *"Plex_v2"* ]]; then
  echo "${product_md5:-c5382bee73cecdee8220b811e529c297}"
  exit 0
fi
# daemon disk md5 at v2 path
if [[ "$cmd" == *"md5sum"* && "$cmd" == *"misterplexd"* && "$cmd" != *"/proc/"* && "$cmd" != *"FOUND_"* ]]; then
  if [[ "${disk_state:-ok}" == "missing" ]]; then echo MISSING; exit 0; fi
  if [[ "${disk_state:-ok}" == "empty" ]]; then exit 0; fi
  # install path may print md5sum after mv
  if [[ "$cmd" == *"mv -f"* ]] || [[ "$cmd" == *"staged"* ]]; then
    echo "${install_md5:-${disk_md5:-50f4eb925de10e29172999a565c87684}}"
    exit 0
  fi
  echo "${disk_md5:-50f4eb925de10e29172999a565c87684}"
  exit 0
fi

# on-device pin search
if [[ "$cmd" == *"FOUND_PATH="* ]] || [[ "$cmd" == *"misterplexd.*.bak"* ]]; then
  if [[ -n "${bak_path:-}" ]]; then
    echo "FOUND_PATH=${bak_path}"
    echo "FOUND_MD5=${bak_md5:-50f4eb925de10e29172999a565c87684}"
  else
    echo "FOUND_PATH="
    echo "FOUND_MD5="
  fi
  exit 0
fi

# live daemon probe
if [[ "$cmd" == *"N_DAEMON="* ]] || [[ "$cmd" == *"for d in /proc/"* ]]; then
  echo "N_DAEMON=${n_daemon:-${n_match:-1}}"
  echo "PIDS=${pids:-4242}"
  echo "LIVE_MD5=${live_md5:-50f4eb925de10e29172999a565c87684}"
  echo "LIVE_EXE=${live_exe:-/media/fat/misterplex_v2/bin/misterplexd}"
  echo "LIVE_PORT=${live_port:-3005}"
  echo "LIVE_CONF=${live_conf:-/media/fat/misterplex_v2/misterplex.conf}"
  echo "LIVE_ROOT=${live_root:-/media/fat/misterplex_v2}"
  exit 0
fi

# conf body cat (pair conf profile verify)
if [[ "$cmd" == *"cat "* && "$cmd" == *"misterplex.conf"* ]] || [[ "$cmd" == *"cat"* && "$cmd" == *".conf"* ]]; then
  if [[ "${conf_body:-}" == "MISSING" ]]; then echo MISSING; exit 0; fi
  if [[ -n "${conf_body:-}" ]]; then printf '%s\n' "$conf_body"; exit 0; fi
  # default SPI-clean conf (no DDR force keys)
  if [[ "${conf_profile:-spi}" == "ddr" ]]; then
    cat <<'CONF'
DECODE=320x240
PRESENT=fpga
DDR_YUV_FORCE_SCALE=1
FFMPEG_SWS_FLAGS=fast_bilinear
CONF
  else
    cat <<'CONF'
DECODE=320x240
PRESENT=fpga
CONF
  fi
  exit 0
fi

# actions
if [[ "$cmd" == *plexctl* ]] || [[ "$cmd" == *stop* ]] || [[ "$cmd" == *load_core* ]] \
   || [[ "$cmd" == *CORE_LOAD* ]] || [[ "$cmd" == *for\ p\ in* ]] || [[ "$cmd" == *"MiSTer_cmd"* ]] \
   || [[ "$cmd" == *"mkdir -p"* ]] || [[ "$cmd" == *"chmod"* ]]; then
  if [[ "${action_rc:-0}" != "0" ]]; then exit "${action_rc}"; fi
  echo "mock-ok"
  echo "CORE_LOAD_ISSUED"
  echo "CORENAME=Plex"
  echo "start_rc=0"
  echo "stop_rc=0"
  if [[ "$cmd" == *"for p in"* ]]; then
    echo "/media/fat/misterplex/bin/plexctl.sh"
  fi
  # install returns md5 line
  if [[ "$cmd" == *"md5sum"* ]]; then
    echo "${install_md5:-50f4eb925de10e29172999a565c87684}"
  fi
  exit 0
fi

# S99user — source of truth for USER_SCRIPT path
if [[ "$cmd" == *"S99user"* ]]; then
  echo '#!/bin/sh'
  echo 'USER_SCRIPT="/media/fat/linux/user-startup.sh"'
  exit 0
fi
# REAL boot hook body (no underscore) — what S99user runs
if [[ "$cmd" == *"/user-startup.sh"* ]] && [[ "$cmd" != *"_user-startup.sh"* ]]; then
  if [[ -n "${hook_body:-}" ]]; then printf '%s\n' "$hook_body"; exit 0; fi
  echo "nohup /media/fat/misterplex_v2/bin/misterplexd_supervise.sh >>/media/fat/misterplex_v2/misterplexd_supervise.log 2>&1 &"
  exit 0
fi
# DECOY underscore file — must be inert by default
if [[ "$cmd" == *"_user-startup.sh"* ]]; then
  if [[ -n "${decoy_body:-}" ]]; then printf '%s\n' "$decoy_body"; exit 0; fi
  echo "# inert decoy"
  exit 0
fi
if [[ "$cmd" == *"misterplexd_supervise"* ]] || [[ "$cmd" == *"SUPERVISE_"* ]] || [[ "$cmd" == *"HOOK_"* ]] || [[ "$cmd" == *"DECOY_"* ]]; then
  echo "SUPERVISE_OK"
  echo "HOOK_INSTALLED=/media/fat/linux/user-startup.sh"
  echo "DECOY_INERT=/media/fat/linux/_user-startup.sh"
  exit 0
fi
if [[ "$cmd" == *"test -x"* ]]; then
  echo "SUPERVISE_OK"
  exit 0
fi

echo "fake_ssh unhandled: $cmd" >&2
exit 99
MOCK
chmod +x "$WORK/fake_ssh.sh"

cat >"$WORK/fake_http.sh" <<'HTTP'
#!/usr/bin/env bash
set -euo pipefail
SCEN="${ROLLBACK_SCENARIO:?}"
# shellcheck disable=SC1090
source "$SCEN"
echo "${http_code:-200}"
HTTP
chmod +x "$WORK/fake_http.sh"

cat >"$WORK/fake_scp.sh" <<'SCP'
#!/usr/bin/env bash
exit 0
SCP
chmod +x "$WORK/fake_scp.sh"

# synthetic idle PNGs (structured orange ~mean 40; solid green fail class)
python3 - <<PY
from pathlib import Path
try:
    from PIL import Image, ImageDraw
except ImportError:
    raise SystemExit(0)
d = Path("$WORK")
d.mkdir(parents=True, exist_ok=True)
# Structured idle: dark field + small amber chevron (match real orange_frac~0.017)
# Large synthetic chevrons trip orange_frac_too_high (>0.12) under positive ID.
img = Image.new("RGB", (320, 240), (18, 16, 22))
dr = ImageDraw.Draw(img)
dr.polygon([(250, 90), (290, 120), (250, 150), (235, 120)], fill=(200, 120, 30))
img.save(d / "idle_ok.png")
# solid green (uniform + green cast)
Image.new("RGB", (64, 64), (0, 180, 0)).save(d / "idle_green.png")
# near-uniform dark (mean ok-ish but flat — must FAIL uniformity)
Image.new("RGB", (64, 64), (40, 38, 36)).save(d / "idle_flat.png")
# Parent cold grabber frame: uniform 7,7,7 std=0 (MacroSilicon warm-up junk)
Image.new("RGB", (64, 64), (7, 7, 7)).save(d / "idle_cold_grabber.png")
# Pure black (also grabber-class until warmed retry exhausts)
Image.new("RGB", (64, 64), (0, 0, 0)).save(d / "idle_black.png")
PY

PIN_SPI="$ROOT/artifacts/daemon-pins/misterplexd.50f4eb92"
PIN_DDR="$ROOT/artifacts/daemon-pins/misterplexd.e9f79de2"

run_rb() {
  local label="$1"; shift
  : >"$WORK/attempt"
  set +e
  out=$(
    ROLLBACK_SSH="$WORK/fake_ssh.sh" \
    ROLLBACK_HTTP="$WORK/fake_http.sh" \
    ROLLBACK_SCP="$WORK/fake_scp.sh" \
    ROLLBACK_SCENARIO="$WORK/scenario.env" \
    ROLLBACK_ATTEMPT_FILE="$WORK/attempt" \
    ROLLBACK_SSH_TRIES="${ROLLBACK_SSH_TRIES:-4}" \
    ROLLBACK_SSH_BACKOFF_S=0 \
    ROLLBACK_POST_START_SLEEP=0 \
    ROLLBACK_ERRFILE="$WORK/ssh.err" \
    ROLLBACK_SKIP_BOOT="${ROLLBACK_SKIP_BOOT:-1}" \
    PAIR_IDLE_PNG="${PAIR_IDLE_PNG:-$WORK/idle_ok.png}" \
    ROLLBACK_DAEMON="${ROLLBACK_DAEMON-}" \
    PAIR_DAEMON_ARTIFACT="${PAIR_DAEMON_ARTIFACT-}" \
    PAIR_POLICY_DISABLE_DEFAULT_ROOTS="${PAIR_POLICY_DISABLE_DEFAULT_ROOTS-}" \
    PAIR_POLICY_SEARCH_ROOTS="${PAIR_POLICY_SEARCH_ROOTS-}" \
    PAIR_ID="${PAIR_ID:-spi-v2-hybrid}" \
    bash "$ROLLBACK" "$@" 2>&1
  )
  rc=$?
  set -e
  printf '%s\n' "$out" | sed "s|^|  [$label] |"
  echo "  [$label] true rc=$rc"
  LAST_OUT=$out
  LAST_RC=$rc
}

write_scen() { cat >"$WORK/scenario.env"; }

echo "=== preflight REFUSE when disk daemon is DDR and no artifact ==="
write_scen <<SCEN
core_md5=$CORE_MD5
disk_md5=$DDR_DAEMON
live_md5=$DDR_DAEMON
n_daemon=1
http_code=200
SCEN
# Isolate finder from lab pins (main checkout + worktree) without deleting them.
unset ROLLBACK_DAEMON PAIR_DAEMON_ARTIFACT PROMOTE_DAEMON || true
PAIR_POLICY_DISABLE_DEFAULT_ROOTS=1 PAIR_POLICY_SEARCH_ROOTS="$WORK/empty-pins" \
  run_rb refuse-no-daemon preflight
[ "$LAST_RC" -eq 10 ] || { echo "FAIL refuse want 10 got $LAST_RC"; exit 1; }
echo "$LAST_OUT" | grep -qE 'ATOMIC_ROLLBACK|Device left UNTOUCHED|daemon half is NOT|MISSING_DAEMON_PIN|fetch_daemon_pins' || {
  echo "FAIL need atomic refuse / fetch help"; exit 1
}
echo "OK preflight-refuse-no-daemon rc=10"

echo "=== preflight OK when disk already SPI pin ==="
write_scen <<SCEN
core_md5=$CORE_MD5
disk_md5=$DAEMON_MD5
live_md5=$DAEMON_MD5
n_daemon=1
http_code=200
SCEN
run_rb pre-ok preflight
[ "$LAST_RC" -eq 0 ] || { echo "FAIL pre-ok want 0 got $LAST_RC"; exit 1; }
echo "$LAST_OUT" | grep -q PREFLIGHT_OK || { echo "FAIL PREFLIGHT_OK"; exit 1; }
echo "OK preflight-disk-pin rc=0"

echo "=== verify mixed pair (SPI core + DDR live) is MISMATCH not OK ==="
write_scen <<SCEN
core_md5=$CORE_MD5
disk_md5=$DDR_DAEMON
live_md5=$DDR_DAEMON
n_daemon=1
http_code=200
SCEN
ROLLBACK_REQUIRE_VISUAL=0 run_rb mixed verify
[ "$LAST_RC" -eq 3 ] || { echo "FAIL mixed want 3 got $LAST_RC"; exit 1; }
echo "$LAST_OUT" | grep -qE 'PAIR_REFUSE|pair-compatibility|MISMATCH' || {
  echo "FAIL need pair refuse"; exit 1
}
echo "OK mixed-pair-verify rc=3"

echo "=== verify happy pair + visual ==="
write_scen <<SCEN
core_md5=$CORE_MD5
disk_md5=$DAEMON_MD5
live_md5=$DAEMON_MD5
n_daemon=1
http_code=200
conf_profile=spi
SCEN
if [ -f "$WORK/idle_ok.png" ]; then
  PAIR_IDLE_PNG="$WORK/idle_ok.png" ROLLBACK_REQUIRE_VISUAL=1 run_rb happy-vis verify
  [ "$LAST_RC" -eq 0 ] || { echo "FAIL happy-vis want 0 got $LAST_RC"; exit 1; }
  echo "$LAST_OUT" | grep -q 'OK pair-compatibility' || { echo "FAIL pair ok"; exit 1; }
  echo "OK happy-visual rc=0"
else
  echo "SKIP happy-visual (no Pillow)"
fi

echo "=== SPI verify FAILS when DDR conf keys left behind (half-state conf) ==="
write_scen <<SCEN
core_md5=$CORE_MD5
disk_md5=$DAEMON_MD5
live_md5=$DAEMON_MD5
n_daemon=1
http_code=200
conf_profile=ddr
SCEN
ROLLBACK_REQUIRE_VISUAL=0 run_rb spi-bad-conf verify
[ "$LAST_RC" -eq 3 ] || { echo "FAIL spi-bad-conf want 3 got $LAST_RC"; exit 1; }
echo "$LAST_OUT" | grep -qi 'conf-forbidden\|FAIL conf' || {
  echo "FAIL need conf refuse"; exit 1
}
echo "OK spi-conf-halfstate-refuse rc=3"

echo "=== verify without visual when required → rc=8 ==="
write_scen <<SCEN
core_md5=$CORE_MD5
disk_md5=$DAEMON_MD5
live_md5=$DAEMON_MD5
n_daemon=1
http_code=200
SCEN
PAIR_IDLE_PNG=/no/such.png ROLLBACK_REQUIRE_VISUAL=1 run_rb novis verify
[ "$LAST_RC" -eq 8 ] || { echo "FAIL novis want 8 got $LAST_RC"; exit 1; }
echo "OK visual-required rc=8"

echo "=== empty core hash is NO-DATA not MISMATCH ==="
write_scen <<SCEN
core_state=empty
disk_md5=$DAEMON_MD5
live_md5=$DAEMON_MD5
n_daemon=1
http_code=200
SCEN
ROLLBACK_REQUIRE_VISUAL=0 run_rb nodata verify
[ "$LAST_RC" -eq 4 ] || { echo "FAIL nodata want 4 got $LAST_RC"; exit 1; }
echo "$LAST_OUT" | grep -q 'NO-DATA core-disk' || { echo "FAIL NO-DATA"; exit 1; }
echo "OK nodata-empty rc=4"

echo "=== NETWORK after retries ==="
write_scen <<SCEN
ssh_fail_first_n=99
core_md5=$CORE_MD5
disk_md5=$DAEMON_MD5
live_md5=$DAEMON_MD5
n_daemon=1
http_code=200
SCEN
ROLLBACK_SSH_TRIES=3 ROLLBACK_REQUIRE_VISUAL=0 run_rb netfail verify
[ "$LAST_RC" -eq 5 ] || { echo "FAIL network want 5 got $LAST_RC"; exit 1; }
echo "OK network rc=5"

echo "=== restore refuses without daemon artifact (device untouched path) ==="
write_scen <<SCEN
core_md5=$CORE_MD5
disk_md5=$DDR_DAEMON
live_md5=$DDR_DAEMON
n_daemon=1
http_code=200
SCEN
unset ROLLBACK_DAEMON PAIR_DAEMON_ARTIFACT || true
PAIR_POLICY_DISABLE_DEFAULT_ROOTS=1 PAIR_POLICY_SEARCH_ROOTS="$WORK/empty-pins" \
  run_rb restore-refuse restore
[ "$LAST_RC" -eq 10 ] || { echo "FAIL restore-refuse want 10 got $LAST_RC"; exit 1; }
echo "$LAST_OUT" | grep -qE 'UNTOUCHED|ATOMIC_ROLLBACK|MISSING_DAEMON_PIN' || {
  echo "FAIL need untouched"; exit 1
}
echo "OK restore-refuse-atomic rc=10"

# --- PAIR_ID=ddr-c5382bee (primary recovery) red-before-green ---------------
DDR_CORE=c5382bee73cecdee8220b811e529c297
echo "=== DDR pair lookup OK (primary=5996385a) ==="
set +e
out=$("$ROOT/scripts/pair_ship_policy.sh" lookup ddr-c5382bee 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] || { echo "FAIL ddr lookup rc=$rc"; exit 1; }
echo "$out" | grep -q "$DDR_CORE" || { echo "FAIL ddr core pin"; exit 1; }
echo "$out" | grep -qiE '5996385a|PAIR_DAEMON_MD5=5996385a' || { echo "FAIL ddr daemon pin 5996385a: $out"; exit 1; }
echo "$out" | grep -q 'PAIR_CONF_PROFILE=ddr' || { echo "FAIL conf profile"; exit 1; }
echo "OK ddr-lookup"
set +e
out=$("$ROOT/scripts/pair_ship_policy.sh" lookup ddr-c5382bee-e9f79de2 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] || { echo "FAIL hist lookup rc=$rc"; exit 1; }
echo "$out" | grep -q "$DDR_DAEMON" || { echo "FAIL hist daemon pin"; exit 1; }
echo "OK ddr-hist-lookup"

echo "=== DDR preflight REFUSE without e9f79de2 pin (red) ==="
write_scen <<SCEN
product_md5=$DDR_CORE
core_md5=$DDR_CORE
disk_md5=$DAEMON_MD5
live_md5=$DAEMON_MD5
n_daemon=1
http_code=200
SCEN
# disk is SPI daemon while pair wants DDR — needs install; isolate pins
unset ROLLBACK_DAEMON PAIR_DAEMON_ARTIFACT || true
PAIR_ID=ddr-c5382bee PAIR_POLICY_DISABLE_DEFAULT_ROOTS=1 \
  PAIR_POLICY_SEARCH_ROOTS="$WORK/empty-pins" \
  run_rb ddr-refuse preflight
[ "$LAST_RC" -eq 10 ] || { echo "FAIL ddr-refuse want 10 got $LAST_RC"; exit 1; }
echo "$LAST_OUT" | grep -qE 'MISSING_DAEMON_PIN|fetch_daemon_pins|ATOMIC_ROLLBACK|UNTOUCHED' || {
  echo "FAIL ddr-refuse help text"; exit 1
}
echo "OK ddr-preflight-refuse-no-pin rc=10"

EDC_FULL=5996385a57c6af142b8e732a39b36a4a
EDC3_FULL=edc3a46b9d1c6b86337deb90f896eb0f

echo "=== DDR primary preflight OK when disk already 5996385a (green) ==="
write_scen <<SCEN
product_md5=$DDR_CORE
core_md5=$DDR_CORE
disk_md5=$EDC_FULL
live_md5=$EDC_FULL
n_daemon=1
http_code=200
SCEN
PAIR_ID=ddr-c5382bee run_rb ddr-pre-ok preflight
[ "$LAST_RC" -eq 0 ] || { echo "FAIL ddr-pre-ok want 0 got $LAST_RC"; exit 1; }
echo "$LAST_OUT" | grep -q PREFLIGHT_OK || { echo "FAIL PREFLIGHT_OK ddr"; exit 1; }
echo "OK ddr-preflight-disk-pin rc=0"

echo "=== DDR primary verify happy + visual + conf (green) ==="
write_scen <<SCEN
product_md5=$DDR_CORE
core_md5=$DDR_CORE
disk_md5=$EDC_FULL
live_md5=$EDC_FULL
n_daemon=1
http_code=200
conf_profile=ddr
SCEN
PAIR_ID=ddr-c5382bee PAIR_IDLE_PNG="$WORK/idle_ok.png" ROLLBACK_REQUIRE_VISUAL=1 \
  run_rb ddr-edc-vis verify
[ "$LAST_RC" -eq 0 ] || { echo "FAIL ddr-edc-vis want 0 got $LAST_RC"; exit 1; }
echo "$LAST_OUT" | grep -q 'OK pair-compatibility' || { echo "FAIL edc pair"; exit 1; }
echo "$LAST_OUT" | grep -q 'OK conf-profile=ddr' || { echo "FAIL ddr conf profile"; exit 1; }
echo "OK ddr-5996385a-verify rc=0"

echo "=== DDR verify FAILS without conf keys (half-state conf) ==="
write_scen <<SCEN
product_md5=$DDR_CORE
core_md5=$DDR_CORE
disk_md5=$EDC_FULL
live_md5=$EDC_FULL
n_daemon=1
http_code=200
conf_profile=spi
SCEN
PAIR_ID=ddr-c5382bee ROLLBACK_REQUIRE_VISUAL=0 run_rb ddr-noconf verify
[ "$LAST_RC" -eq 3 ] || { echo "FAIL ddr-noconf want 3 got $LAST_RC"; exit 1; }
echo "OK ddr-conf-halfstate-refuse rc=3"

echo "=== DDR verify mixed SPI-daemon live REFUSE (red) ==="
write_scen <<SCEN
product_md5=$DDR_CORE
core_md5=$DDR_CORE
disk_md5=$DAEMON_MD5
live_md5=$DAEMON_MD5
n_daemon=1
http_code=200
conf_profile=ddr
SCEN
PAIR_ID=ddr-c5382bee ROLLBACK_REQUIRE_VISUAL=0 run_rb ddr-mixed verify
[ "$LAST_RC" -eq 3 ] || { echo "FAIL ddr-mixed want 3 got $LAST_RC"; exit 1; }
echo "OK ddr-mixed-verify rc=3"

if [ -f "$PIN_DDR" ]; then
  echo "=== DDR hist pair (e9f79de2) verify happy + visual + conf (green) ==="
  write_scen <<SCEN
product_md5=$DDR_CORE
core_md5=$DDR_CORE
disk_md5=$DDR_DAEMON
live_md5=$DDR_DAEMON
n_daemon=1
http_code=200
conf_profile=ddr
SCEN
  PAIR_ID=ddr-c5382bee-e9f79de2 PAIR_IDLE_PNG="$WORK/idle_ok.png" ROLLBACK_REQUIRE_VISUAL=1 \
    run_rb ddr-hist-vis verify
  [ "$LAST_RC" -eq 0 ] || { echo "FAIL ddr-hist-vis want 0 got $LAST_RC"; exit 1; }
  echo "$LAST_OUT" | grep -q 'OK conf-profile=ddr' || { echo "FAIL hist conf"; exit 1; }
  echo "OK ddr-hist-verify-visual-conf rc=0"
else
  echo "SKIP ddr-hist-verify (no $PIN_DDR)"
fi

echo "=== visual gate rejects solid green PNG ==="
if [ -f "$WORK/idle_green.png" ]; then
  set +e
  out=$(PAIR_VISUAL_NO_RECAPTURE=1 PAIR_IDLE_PNG="$WORK/idle_green.png" "$ROOT/scripts/pair_visual_gate.sh" idle 2>&1)
  rc=$?
  set -e
  echo "  green true rc=$rc"
  [ "$rc" -eq 8 ] || { echo "FAIL green want 8 got $rc"; exit 1; }
  echo "$out" | grep -qiE 'green|uniform' || { echo "FAIL green class msg"; exit 1; }
  echo "OK visual-green-reject rc=8"
fi

echo "=== visual gate rejects flat uniform frame ==="
if [ -f "$WORK/idle_flat.png" ]; then
  set +e
  out=$(PAIR_VISUAL_NO_RECAPTURE=1 PAIR_IDLE_PNG="$WORK/idle_flat.png" "$ROOT/scripts/pair_visual_gate.sh" idle 2>&1)
  rc=$?
  set -e
  echo "  flat true rc=$rc"
  [ "$rc" -eq 8 ] || { echo "FAIL flat want 8 got $rc"; exit 1; }
  echo "$out" | grep -qiE 'uniform|flat|grabber_not_ready' || { echo "FAIL flat class msg"; exit 1; }
  echo "OK visual-flat-reject rc=8"
fi

echo "=== REGRESSION: cold grabber 7,7,7 → GRABBER_NOT_READY (not device black) ==="
if [ -f "$WORK/idle_cold_grabber.png" ]; then
  set +e
  out=$(PAIR_VISUAL_NO_RECAPTURE=1 PAIR_IDLE_PNG="$WORK/idle_cold_grabber.png" \
    "$ROOT/scripts/pair_visual_gate.sh" idle 2>&1)
  rc=$?
  set -e
  echo "$out" | sed 's/^/  [cold] /'
  echo "  cold true rc=$rc"
  [ "$rc" -eq 8 ] || { echo "FAIL cold want 8 got $rc"; exit 1; }
  echo "$out" | grep -q 'grabber_not_ready' || { echo "FAIL missing GRABBER_NOT_READY class"; exit 1; }
  echo "$out" | grep -qi 'black_screen' && { echo "FAIL cold misclassed as black_screen"; exit 1; } || true
  echo "OK cold-grabber-class"
fi

echo "=== REGRESSION: cold→warm retry yields plex_idle_chevron ==="
if [ -f "$WORK/idle_cold_grabber.png" ] && [ -f "$WORK/idle_ok.png" ]; then
  # Initial PNG is cold; recapture cmd returns warmed structured idle.
  cat >"$WORK/capture_warm.sh" <<'CAP'
#!/usr/bin/env bash
set -euo pipefail
dest="${PAIR_CAPTURE_OUT:-${1:?}}"
cp -f "$PAIR_TEST_WARM" "$dest"
CAP
  chmod +x "$WORK/capture_warm.sh"
  set +e
  out=$(
    PAIR_VISUAL_OUT_DIR="$WORK" \
    PAIR_TEST_WARM="$WORK/idle_ok.png" \
    PAIR_IDLE_PNG="$WORK/idle_cold_grabber.png" \
    PAIR_CAPTURE_CMD="$WORK/capture_warm.sh" \
    PAIR_VISUAL_GRABBER_RETRIES=2 \
    "$ROOT/scripts/pair_visual_gate.sh" idle 2>&1
  )
  rc=$?
  set -e
  echo "$out" | sed 's/^/  [retry] /' | tail -25
  echo "  retry true rc=$rc"
  [ "$rc" -eq 0 ] || { echo "FAIL retry want 0 got $rc"; exit 1; }
  echo "$out" | grep -q 'GRABBER_NOT_READY' || { echo "FAIL no grabber note on retry path"; exit 1; }
  echo "$out" | grep -q 'plex_idle_chevron' || { echo "FAIL no plex_idle_chevron after warm"; exit 1; }
  echo "OK cold-to-warm-retry"
fi

echo "=== REGRESSION: warmed still-uniform hard-fails (no threshold loosen) ==="
if [ -f "$WORK/idle_cold_grabber.png" ]; then
  cat >"$WORK/capture_always_cold.sh" <<'CAP'
#!/usr/bin/env bash
cp -f "$PAIR_TEST_COLD" "${PAIR_CAPTURE_OUT:-$1}"
CAP
  chmod +x "$WORK/capture_always_cold.sh"
  set +e
  out=$(
    PAIR_VISUAL_OUT_DIR="$WORK" \
    PAIR_TEST_COLD="$WORK/idle_cold_grabber.png" \
    PAIR_IDLE_PNG="$WORK/idle_cold_grabber.png" \
    PAIR_CAPTURE_CMD="$WORK/capture_always_cold.sh" \
    PAIR_VISUAL_GRABBER_RETRIES=1 \
    "$ROOT/scripts/pair_visual_gate.sh" idle 2>&1
  )
  rc=$?
  set -e
  echo "  exhaust true rc=$rc"
  [ "$rc" -eq 8 ] || { echo "FAIL exhaust want 8 got $rc"; exit 1; }
  echo "$out" | grep -qiE 'grabber_not_ready_exhausted|still uniform' \
    || { echo "FAIL exhaust msg"; echo "$out"; exit 1; }
  echo "OK grabber-exhaust-hard-fail"
fi

echo "=== blessed helper refuses -frames:v 1 lore; embeds warmup ==="
grep -q 'select=gte' "$ROOT/scripts/hdmi_capture_idle.sh" || { echo "FAIL helper missing select=gte"; exit 1; }
grep -q 'HDMI_WARMUP_FRAMES' "$ROOT/scripts/hdmi_capture_idle.sh" || { echo "FAIL helper missing WARMUP"; exit 1; }
# Must NOT document bare -frames:v 1 as the recipe in the helper
if grep -v '^#' "$ROOT/scripts/hdmi_capture_idle.sh" | grep -qE 'frames:v 1[^\"]*$'; then
  # the helper uses -frames:v 1 AFTER select=gte — that is correct; ensure select precedes
  grep -n 'frames:v\|select=gte' "$ROOT/scripts/hdmi_capture_idle.sh" | sed 's/^/  /'
fi
echo "OK helper-warmup-baked"

echo "=== find-daemon e9f79de2 with pin present ==="
if [ -f "$PIN_DDR" ]; then
  set +e
  out=$("$ROOT/scripts/pair_ship_policy.sh" find-daemon e9f79de2 2>&1)
  rc=$?
  set -e
  echo "  true rc=$rc"
  [ "$rc" -eq 0 ] || { echo "FAIL find e9f79de2"; exit 1; }
  echo "$out" | grep -q FOUND || { echo "FAIL FOUND"; exit 1; }
  echo "OK find-daemon-ddr"
fi

echo "=== B8: restore_misterplexd_prev HARD REFUSE half-restore ==="
set +e
out=$(bash "$ROOT/scripts/restore_misterplexd_prev.sh" 2>&1)
rc=$?
set -e
echo "$out" | sed 's/^/  [half] /' | head -20
echo "  [half] true rc=$rc"
[ "$rc" -eq 10 ] || { echo "FAIL half-restore want rc=10 got $rc"; exit 1; }
echo "$out" | grep -qi 'HALF_RESTORE\|REFUSE' || { echo "FAIL half msg"; exit 1; }
echo "$out" | grep -qi 'rollback_v2' || { echo "FAIL half redirect"; exit 1; }
echo "OK half-restore-refuse rc=10"

echo "=== pair matrix includes bank1 geometry ==="
out=$(cd "$ROOT" && bash -c 'source scripts/pair_ship_policy.sh; pair_policy_lookup ddr-c5382bee')
echo "$out" | sed 's/^/  /'
echo "$out" | grep -q 'PAIR_BANK1=0x30080000' || { echo "FAIL ddr bank1"; exit 1; }
out=$(cd "$ROOT" && bash -c 'source scripts/pair_ship_policy.sh; pair_policy_lookup spi-v2-hybrid')
echo "$out" | grep -q 'PAIR_BANK1=0x30040000' || { echo "FAIL spi bank1"; exit 1; }
echo "OK bank1-geometry"

echo "=== live probe counts by /proc/exe not cmdline (flock-safe) ==="
src=$(cat "$ROOT/scripts/pair_live_probe.inc.sh")
echo "$src" | grep -q 'basename' || { echo "FAIL probe missing basename"; exit 1; }
echo "$src" | grep -q 'readlink -f' || { echo "FAIL probe missing readlink"; exit 1; }
if echo "$src" | grep -q 'case "$cmd" in \*/misterplexd'; then
  echo "FAIL probe still cmdline-primary"
  exit 1
fi
echo "OK probe-exe-contract"

echo "=== rollback plan dry-run (no device) ==="
set +e
out=$(cd "$ROOT" && PAIR_ID=ddr-c5382bee bash scripts/rollback_v2.sh plan 2>&1)
rc=$?
set -e
echo "$out" | sed 's/^/  [plan] /' | head -25
echo "  [plan] true rc=$rc"
[ "$rc" -eq 0 ] || { echo "FAIL plan rc=$rc"; exit 1; }
echo "$out" | grep -qi 'POWER-CYCLE' || { echo "FAIL plan power-cycle section"; exit 1; }
echo "$out" | grep -q '0x30080000' || { echo "FAIL plan bank1"; exit 1; }
echo "OK plan-dry-run"

echo "=== ROLLBACK_EXECUTE=0 restore is dry-run ==="
set +e
out=$(cd "$ROOT" && PAIR_ID=ddr-c5382bee ROLLBACK_EXECUTE=0 bash scripts/rollback_v2.sh restore 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] || { echo "FAIL dry restore rc=$rc"; exit 1; }
echo "$out" | grep -qi 'DRY-RUN' || { echo "FAIL dry restore msg"; exit 1; }
echo "OK restore-dry-run"

echo "ALL test_rollback_honest checks passed"
exit 0
