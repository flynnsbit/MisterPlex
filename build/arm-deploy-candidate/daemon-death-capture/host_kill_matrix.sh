#!/usr/bin/env bash
# Host-only deliberate kill matrix for death capture.
# Does NOT touch the device. Writes RESULT under this directory.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# script is build/arm-deploy-candidate/daemon-death-capture → root is 3 up? 
# dirname = .../daemon-death-capture, ../ = arm-deploy-candidate, ../../ = build, ../../../ = ROOT
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="$(cd "$(dirname "$0")" && pwd)"
BIN="${ROOT}/build/misterplexd"
WORKDIR="${OUT}/run_$$"
mkdir -p "$WORKDIR"
CONF="${WORKDIR}/misterplex.conf"
LOG="${WORKDIR}/misterplexd.log"
SUPLOG="${WORKDIR}/supervise.log"
LAST="${WORKDIR}/misterplexd.last"
DEATH="${WORKDIR}/misterplexd.death"
RESULT="${OUT}/KILL_MATRIX_RESULT.txt"

# Minimal conf — no private data; PRESENT=none avoids FPGA/SPI on host.
cat >"$CONF" <<'EOF'
PRESENT=none
DECODE=320x240
STREAM=0
OSD_CONTROL=0
PROFILE=0
PRESENT_PROFILE=0
EOF

if [[ ! -x "$BIN" ]]; then
  echo "FAIL missing $BIN — build plexd first" | tee "$RESULT"
  exit 2
fi

sig_name() {
  case "$1" in
    6) echo SIGABRT ;;
    9) echo SIGKILL ;;
    11) echo SIGSEGV ;;
    15) echo SIGTERM ;;
    0) echo EXIT0 ;;
    *) echo "SIG_$1" ;;
  esac
}

run_one() {
  local label="$1" mode="$2" # mode: term|segv|kill|clean
  local port=$((19000 + RANDOM % 1000))
  rm -f "$LAST" "$DEATH"
  : >"$LOG"
  # one-shot supervise: spawn, wait, log once (no respawn loop)
  (
    "$BIN" --name MiSTerPlex --id misterplex-dev --port "$port" --conf "$CONF" >>"$LOG" 2>&1 &
    child=$!
    echo "CHILD pid=$child label=$label" >>"$SUPLOG"
    # wait until .last exists (boot breadcrumb) or 5s
    for _ in $(seq 1 50); do
      [[ -f "$LAST" ]] && break
      kill -0 "$child" 2>/dev/null || break
      sleep 0.1
    done
    case "$mode" in
      term) kill -TERM "$child" 2>/dev/null || true ;;
      segv) kill -SEGV "$child" 2>/dev/null || true ;;
      kill) kill -KILL "$child" 2>/dev/null || true ;;
      clean)
        # SIGTERM then wait for orderly path (same as product)
        kill -TERM "$child" 2>/dev/null || true
        ;;
    esac
    set +e
    wait "$child"
    st=$?
    set -e
    if [[ "$st" -ge 128 ]]; then
      sig=$((st - 128))
      sname=$(sig_name "$sig")
      echo "SUPERVISE_EXIT label=$label wait_rc=$st WIFSIGNALED=1 signal=$sig signal_name=$sname" >>"$SUPLOG"
    else
      echo "SUPERVISE_EXIT label=$label wait_rc=$st WIFSIGNALED=0 exit_status=$st" >>"$SUPLOG"
    fi
    echo "---LAST label=$label---" >>"$SUPLOG"
    if [[ -f "$LAST" ]]; then cat "$LAST" >>"$SUPLOG"; else echo "(none)" >>"$SUPLOG"; fi
    echo "---DEATH label=$label---" >>"$SUPLOG"
    if [[ -f "$DEATH" ]]; then cat "$DEATH" >>"$SUPLOG"; else echo "(none)" >>"$SUPLOG"; fi
    echo "ST=$st" >"${WORKDIR}/st_${label}.txt"
  )
}

: >"$SUPLOG"
echo "=== host kill matrix start $(date -u +%Y-%m-%dT%H:%M:%SZ) ===" | tee "$RESULT"
echo "BIN=$BIN" | tee -a "$RESULT"
echo "WORKDIR=$WORKDIR" | tee -a "$RESULT"

run_one TERM term
run_one SEGV segv
run_one KILL kill
run_one CLEAN clean

{
  echo
  echo "=== SUPLOG ==="
  cat "$SUPLOG"
  echo
  echo "=== VERDICT vs PREREGISTER ==="
} >>"$RESULT"

# Parse outcomes
term_line=$(grep 'label=TERM ' "$SUPLOG" | grep SUPERVISE_EXIT | tail -1 || true)
segv_line=$(grep 'label=SEGV ' "$SUPLOG" | grep SUPERVISE_EXIT | tail -1 || true)
kill_line=$(grep 'label=KILL ' "$SUPLOG" | grep SUPERVISE_EXIT | tail -1 || true)
clean_line=$(grep 'label=CLEAN ' "$SUPLOG" | grep SUPERVISE_EXIT | tail -1 || true)

score() {
  local name="$1" line="$2" want="$3"
  if echo "$line" | grep -q "$want"; then
    echo "HIT $name: $line"
  else
    echo "MISS $name: got=[$line] want~=$want"
  fi
}

{
  score TERM "$term_line" 'WIFSIGNALED=0 exit_status=0'
  score SEGV "$segv_line" 'signal=11'
  score KILL "$kill_line" 'signal=9'
  score CLEAN "$clean_line" 'WIFSIGNALED=0 exit_status=0'
  echo
  echo "DEATH file checks:"
  # After SEGV we re-ran later tests which overwrite DEATH — re-extract from SUPLOG sections
  awk '/---DEATH label=SEGV---/{getline; print "SEGV_DEATH="$0}' "$SUPLOG"
  awk '/---DEATH label=KILL---/{getline; print "KILL_DEATH="$0}' "$SUPLOG"
  awk '/---DEATH label=TERM---/{getline; print "TERM_DEATH="$0}' "$SUPLOG"
  awk '/---DEATH label=CLEAN---/{getline; print "CLEAN_DEATH="$0}' "$SUPLOG"
} | tee -a "$RESULT"

# SEGV death must contain signal=11; KILL must be (none) or stale without signal=9 write
segv_death=$(awk '/---DEATH label=SEGV---/{getline; print}' "$SUPLOG")
kill_death=$(awk '/---DEATH label=KILL---/{getline; print}' "$SUPLOG")
term_death=$(awk '/---DEATH label=TERM---/{getline; print}' "$SUPLOG")

{
  echo
  if echo "$segv_death" | grep -q 'signal=11'; then
    echo "HIT SEGV_DEATH contains signal=11: $segv_death"
  else
    echo "MISS SEGV_DEATH: $segv_death"
  fi
  if echo "$kill_death" | grep -q 'signal=9'; then
    echo "MISS KILL_DEATH unexpectedly has signal=9 (handler cannot run): $kill_death"
  else
    echo "HIT KILL_DEATH no handler write (none/stale): $kill_death"
  fi
  if echo "$term_death" | grep -qE 'exit_code=0|why='; then
    echo "HIT TERM_DEATH orderly: $term_death"
  else
    echo "MISS TERM_DEATH orderly expected: $term_death"
  fi
  echo
  echo "INDISTINGUISHABLE confirmed if TERM and CLEAN both exit_status=0 (expected)."
  echo "OOM: INSUFFICIENT on host (no dmesg path)."
} | tee -a "$RESULT"

echo "DONE result=$RESULT"
cat "$RESULT"
true; echo "true rc=$?"
