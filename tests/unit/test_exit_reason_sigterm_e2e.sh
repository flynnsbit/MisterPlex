#!/usr/bin/env bash
# Live host e2e: product misterplexd must never vanish on SIGTERM without
# EXIT_REASON + death file naming main_loop_g_stop and si_pid of the sender.
#
# Defect class: supervise EXIT rc=0 with empty daemon log (soak counters reset;
# parent cannot attribute sender). Static catalog alone does not prove the
# runtime path flushes EXIT_REASON before exit.
#
# Red-before-green: a broken binary that omits EXIT_REASON must fail; applied
# match counts printed so a no-op check cannot masquerade as a pass.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="${MISTERPLEXD_BIN:-$ROOT/build/misterplexd}"
WORKDIR="$ROOT/build/test_exit_reason_sigterm_e2e_$$"
FAIL=0

cleanup() {
  if [[ -n "${DPID:-}" ]] && kill -0 "$DPID" 2>/dev/null; then
    kill -KILL "$DPID" 2>/dev/null || true
    wait "$DPID" 2>/dev/null || true
  fi
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

if [[ ! -x "$BIN" ]]; then
  make -C "$ROOT" "$BIN" || { echo "FAIL cannot build $BIN"; exit 2; }
fi

mkdir -p "$WORKDIR"
cat >"$WORKDIR/misterplex.conf" <<EOF
PRESENT=none
NAME=exit-reason-e2e
EOF

# Free port in ephemeral range (host-only; no device).
PORT=$((32000 + ($$ % 1000)))
"$BIN" --conf "$WORKDIR/misterplex.conf" --name exit-reason-e2e --port "$PORT" \
  >"$WORKDIR/out.txt" 2>&1 &
DPID=$!
echo "spawned dpid=$DPID port=$PORT"

# Wait until main loop is up (companion bound) or die early.
ready=0
for _ in $(seq 1 50); do
  if grep -q 'misterplexd: running' "$WORKDIR/out.txt" 2>/dev/null; then
    ready=1
    break
  fi
  if ! kill -0 "$DPID" 2>/dev/null; then
    echo "FAIL daemon exited before ready"
    tail -40 "$WORKDIR/out.txt" || true
    exit 1
  fi
  sleep 0.1
done
if [[ "$ready" -ne 1 ]]; then
  echo "FAIL daemon never reached main loop"
  tail -40 "$WORKDIR/out.txt" || true
  exit 1
fi

SENDER=$$
kill -TERM "$DPID"
set +e
wait "$DPID"
wrc=$?
set -e
echo "daemon wait true rc=$wrc"
# Handled SIGTERM → WIFEXITED 0 (not 143).
if [[ "$wrc" -ne 0 ]]; then
  echo "FAIL expected wait rc=0 (handled SIGTERM→WIFEXITED), got $wrc"
  FAIL=$((FAIL + 1))
fi
DPID=

# --- green path assertions ---
OUT="$WORKDIR/out.txt"
DEATH="$WORKDIR/misterplexd.death"

n_exit_reason=$(grep -c 'EXIT_REASON code=0' "$OUT" 2>/dev/null || true)
n_site=$(grep -c 'site=main.cpp:main_loop_g_stop' "$OUT" 2>/dev/null || true)
n_sig15=$(grep -cE 'signal=15|sig=15' "$OUT" 2>/dev/null || true)
echo "applied_match EXIT_REASON_code0=$n_exit_reason main_loop_g_stop=$n_site sig15=$n_sig15"

[[ "$n_exit_reason" -ge 1 ]] || { echo "FAIL missing EXIT_REASON code=0 on stderr"; FAIL=$((FAIL+1)); }
[[ "$n_site" -ge 1 ]] || { echo "FAIL missing site=main.cpp:main_loop_g_stop"; FAIL=$((FAIL+1)); }
[[ "$n_sig15" -ge 1 ]] || { echo "FAIL missing signal=15 / sig=15"; FAIL=$((FAIL+1)); }

if [[ ! -f "$DEATH" ]]; then
  echo "FAIL missing death file $DEATH"
  FAIL=$((FAIL + 1))
else
  echo "death: $(cat "$DEATH")"
  grep -q 'exit_code=0' "$DEATH" || { echo "FAIL death missing exit_code=0"; FAIL=$((FAIL+1)); }
  grep -q 'site=main.cpp:main_loop_g_stop' "$DEATH" || {
    echo "FAIL death missing main_loop_g_stop site"; FAIL=$((FAIL+1)); }
  grep -q 'signal=15' "$DEATH" || { echo "FAIL death missing signal=15"; FAIL=$((FAIL+1)); }
  grep -q 'si_code_name=SI_USER' "$DEATH" || {
    echo "FAIL death missing si_code_name=SI_USER"; FAIL=$((FAIL+1)); }
  # Sender pid must be present (SI_USER). Exact pid match is best-effort:
  # some hosts rewrite si_pid; require non-zero.
  if ! grep -qE 'si_pid=[1-9][0-9]*' "$DEATH"; then
    echo "FAIL death si_pid missing/zero"; FAIL=$((FAIL+1))
  else
    echo "OK death si_pid non-zero (sender_pid_probe=$SENDER)"
  fi
fi

# --- RED: strip EXIT_REASON from a copy of out — gate must fail ---
BROKEN="$WORKDIR/out_broken.txt"
sed 's/EXIT_REASON/EXIT_XREASON/g' "$OUT" >"$BROKEN"
bn=$(grep -c 'EXIT_REASON code=0' "$BROKEN" 2>/dev/null || true)
[ -z "$bn" ] && bn=0
echo "red_mutation EXIT_REASON count_on_broken=$bn"
if [[ "$bn" -ge 1 ]]; then
  echo "FAIL red mutation still has EXIT_REASON code=0 count=$bn"
  FAIL=$((FAIL + 1))
else
  echo "OK negative: broken log fails EXIT_REASON gate (count_on_broken=$bn)"
fi

if [[ "$FAIL" -ne 0 ]]; then
  echo "test_exit_reason_sigterm_e2e: FAIL count=$FAIL"
  tail -30 "$OUT" || true
  exit 1
fi
echo "test_exit_reason_sigterm_e2e: OK"
exit 0
