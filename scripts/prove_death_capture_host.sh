#!/usr/bin/env bash
# Host-side proof that death_capture_supervisor records four death classes.
# No device access. Evidence under docs/evidence/daemon-deaths/<SOURCE_SHA>/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SOURCE_SHA="$(git rev-parse HEAD)"
EVDIR="$ROOT/docs/evidence/daemon-deaths/${SOURCE_SHA}"
mkdir -p "$EVDIR" "$ROOT/build"
RUN="$EVDIR/run"
rm -rf "$RUN"
mkdir -p "$RUN"

echo "SOURCE_SHA=$SOURCE_SHA" | tee "$EVDIR/SOURCE_SHA.txt"
date -u +%Y-%m-%dT%H:%M:%SZ | tee "$EVDIR/started_utc.txt"

# --- pre-register predictions (rule 0) ---
cat >"$EVDIR/PREREGISTER.txt" <<'EOF'
PREDICTIONS (before measure):
1) clean exit 0  → WIFEXITED=1 WEXITSTATUS=0; death file why=clean-exit; death_freshness=n/a
2) SIGTERM path  → victim handles SIGTERM → WIFEXITED=1 WEXITSTATUS=0 why=signal-g_stop; NOT WTERMSIG=15
3) SIGSEGV       → WIFSIGNALED=1 WTERMSIG=11; death has si_code/si_addr; death_freshness=present
4) SIGKILL       → WIFSIGNALED=1 WTERMSIG=9; death ABSENT or stale (handler never ran);
                   death_freshness=stale_or_absent_expected; last proc sample present
EOF

CC="${CC:-gcc}"
$CC -O2 -Wall -o "$ROOT/build/death_capture_supervisor" "$ROOT/tools/death_capture_supervisor.c"
$CC -O2 -Wall -o "$ROOT/build/death_capture_victim" "$ROOT/tools/death_capture_victim.c"
echo "built supervisor+victim" | tee "$EVDIR/build.txt"
file "$ROOT/build/death_capture_supervisor" "$ROOT/build/death_capture_victim" | tee -a "$EVDIR/build.txt"

SUP="$ROOT/build/death_capture_supervisor"
VIC="$ROOT/build/death_capture_victim"
OUT="$EVDIR/CAPTURED_OUTPUT.txt"
: >"$OUT"

run_case() {
  local label="$1"; shift
  local cdir="$RUN/$label"
  mkdir -p "$cdir"
  local clog="$cdir/child.log"
  : >"$clog"
  echo "===== CASE $label =====" | tee -a "$OUT"
  set +e
  "$SUP" --once --dir "$cdir" --log "$clog" --label "$label" \
    --death "$cdir/misterplexd.death" --last "$cdir/misterplexd.last" \
    -- "$VIC" --death "$cdir/misterplexd.death" --last "$cdir/misterplexd.last" "$@" \
    >"$cdir/sup.stdout" 2>"$cdir/sup.stderr"
  local rc=$?
  set -e
  echo "supervisor_true_rc=$rc" | tee -a "$OUT"
  echo "--- SUPERVISE_EXIT line ---" | tee -a "$OUT"
  grep SUPERVISE_EXIT "$cdir/sup.stdout" | tee -a "$OUT" || echo "(missing SUPERVISE_EXIT)" | tee -a "$OUT"
  echo "--- death file ---" | tee -a "$OUT"
  if [[ -f "$cdir/misterplexd.death" ]]; then cat "$cdir/misterplexd.death" | tee -a "$OUT"; else echo "(absent)" | tee -a "$OUT"; fi
  echo "--- last file ---" | tee -a "$OUT"
  if [[ -f "$cdir/misterplexd.last" ]]; then cat "$cdir/misterplexd.last" | tee -a "$OUT"; else echo "(absent)" | tee -a "$OUT"; fi
  echo "--- proc_sample.last ---" | tee -a "$OUT"
  if [[ -f "$cdir/proc_sample.last" ]]; then cat "$cdir/proc_sample.last" | tee -a "$OUT"; else echo "(absent)" | tee -a "$OUT"; fi
  echo "--- jsonl ---" | tee -a "$OUT"
  if [[ -f "$cdir/death_events.jsonl" ]]; then cat "$cdir/death_events.jsonl" | tee -a "$OUT"; else echo "(absent)" | tee -a "$OUT"; fi
  echo | tee -a "$OUT"
}

# 1) clean exit
run_case clean_exit exit 0

# 2) SIGTERM handled → exit 0
run_case sigterm term

# 3) SIGSEGV
run_case sigsegv segv

# 4) SIGKILL — start sleep victim under supervisor in background? 
#    Supervisor runs child; we need external kill -9 on child.
#    Approach: run victim sleep under supervisor is blocking until death.
#    Use a wrapper: start supervisor with sleep victim; read pid from SUPERVISE_SPAWN; kill -9.
run_sigkill() {
  local label=sigkill
  local cdir="$RUN/$label"
  mkdir -p "$cdir"
  local clog="$cdir/child.log"
  : >"$clog"
  echo "===== CASE $label =====" | tee -a "$OUT"
  set +e
  "$SUP" --once --dir "$cdir" --log "$clog" --label "$label" \
    --death "$cdir/misterplexd.death" --last "$cdir/misterplexd.last" \
    -- "$VIC" --death "$cdir/misterplexd.death" --last "$cdir/misterplexd.last" sleep \
    >"$cdir/sup.stdout" 2>"$cdir/sup.stderr" &
  local sup_pid=$!
  # wait until SUPERVISE_SPAWN appears
  local child_pid=""
  for _ in $(seq 1 50); do
    if grep -q SUPERVISE_SPAWN "$cdir/sup.stderr" 2>/dev/null; then
      child_pid=$(sed -n 's/.*SUPERVISE_SPAWN.*pid=\([0-9]*\).*/\1/p' "$cdir/sup.stderr" | tail -n1)
      [[ -n "$child_pid" ]] && break
    fi
    sleep 0.1
  done
  echo "sigkill_target_child_pid=${child_pid:-UNKNOWN}" | tee -a "$OUT"
  if [[ -n "$child_pid" ]]; then
    # ensure death file is stale (from a prior write of last only — no death signal=9)
    kill -9 "$child_pid" 2>/dev/null || true
  else
    echo "FAIL: could not learn child pid" | tee -a "$OUT"
    kill -9 "$sup_pid" 2>/dev/null || true
    return 1
  fi
  wait "$sup_pid"
  local rc=$?
  set -e
  echo "supervisor_true_rc=$rc" | tee -a "$OUT"
  echo "--- SUPERVISE_EXIT line ---" | tee -a "$OUT"
  grep SUPERVISE_EXIT "$cdir/sup.stdout" | tee -a "$OUT" || echo "(missing SUPERVISE_EXIT)" | tee -a "$OUT"
  echo "--- death file ---" | tee -a "$OUT"
  if [[ -f "$cdir/misterplexd.death" ]]; then cat "$cdir/misterplexd.death" | tee -a "$OUT"; else echo "(absent)" | tee -a "$OUT"; fi
  echo "--- last file ---" | tee -a "$OUT"
  if [[ -f "$cdir/misterplexd.last" ]]; then cat "$cdir/misterplexd.last" | tee -a "$OUT"; else echo "(absent)" | tee -a "$OUT"; fi
  echo "--- proc_sample.last ---" | tee -a "$OUT"
  if [[ -f "$cdir/proc_sample.last" ]]; then cat "$cdir/proc_sample.last" | tee -a "$OUT"; else echo "(absent)" | tee -a "$OUT"; fi
  echo "--- jsonl ---" | tee -a "$OUT"
  if [[ -f "$cdir/death_events.jsonl" ]]; then cat "$cdir/death_events.jsonl" | tee -a "$OUT"; else echo "(absent)" | tee -a "$OUT"; fi
  echo | tee -a "$OUT"
}
run_sigkill

# Score predictions
python3 - <<'PY' | tee "$EVDIR/SCORECARD.txt"
import pathlib, re, json
ev = pathlib.Path("docs/evidence/daemon-deaths")
# latest SOURCE_SHA dir via env-less discovery: parent of run
runs = sorted(ev.glob("*/CAPTURED_OUTPUT.txt"), key=lambda p: p.stat().st_mtime)
text = runs[-1].read_text() if runs else ""
sha = runs[-1].parent.name if runs else "?"

def section(label):
    m = re.search(rf"===== CASE {label} =====(.*?)(?===== CASE |\Z)", text, re.S)
    return m.group(1) if m else ""

def field(sec, key):
    m = re.search(rf"{key}=([^\s]+)", sec)
    return m.group(1) if m else None

rows = []
# 1 clean
s = section("clean_exit")
rows.append(("clean_exit", {
    "WIFEXITED": field(s, "WIFEXITED"),
    "WEXITSTATUS": field(s, "WEXITSTATUS"),
    "WIFSIGNALED": field(s, "WIFSIGNALED"),
    "death_has_clean": "clean-exit" in s or "exit_code=0" in s,
}))
# 2 term
s = section("sigterm")
rows.append(("sigterm", {
    "WIFEXITED": field(s, "WIFEXITED"),
    "WEXITSTATUS": field(s, "WEXITSTATUS"),
    "WTERMSIG": field(s, "WTERMSIG"),
    "why_signal_g_stop": "signal-g_stop" in s,
}))
# 3 segv
s = section("sigsegv")
rows.append(("sigsegv", {
    "WIFSIGNALED": field(s, "WIFSIGNALED"),
    "WTERMSIG": field(s, "WTERMSIG"),
    "signal_name": field(s, "signal_name"),
    "si_code_present": "si_code=" in s,
    "death_freshness": field(s, "death_freshness"),
}))
# 4 kill
s = section("sigkill")
rows.append(("sigkill", {
    "WIFSIGNALED": field(s, "WIFSIGNALED"),
    "WTERMSIG": field(s, "WTERMSIG"),
    "signal_name": field(s, "signal_name"),
    "death_freshness": field(s, "death_freshness"),
    "death_absent_or_stale": "(absent)" in s.split("--- death file ---")[-1].split("---")[0] if "--- death file ---" in s else "death signal=9" not in s,
}))

print(f"SOURCE_SHA={sha}")
ok = True
checks = []
def check(name, cond, detail):
    global ok
    status = "HIT" if cond else "MISS"
    if not cond: ok = False
    checks.append((name, status, detail))
    print(f"{status:4} {name}: {detail}")

c = dict(rows[0][1])
check("P1 clean WIFEXITED=1", c.get("WIFEXITED")=="1", c)
check("P1 clean WEXITSTATUS=0", c.get("WEXITSTATUS")=="0", c)
c = dict(rows[1][1])
check("P2 term exits 0 (not WTERMSIG=15)", c.get("WIFEXITED")=="1" and c.get("WEXITSTATUS")=="0", c)
check("P2 term death why=signal-g_stop", c.get("why_signal_g_stop") is True, c)
c = dict(rows[2][1])
check("P3 segv WTERMSIG=11", c.get("WTERMSIG")=="11" and c.get("WIFSIGNALED")=="1", c)
check("P3 segv si_code in death", c.get("si_code_present") is True, c)
c = dict(rows[3][1])
check("P4 kill WTERMSIG=9", c.get("WTERMSIG")=="9" and c.get("WIFSIGNALED")=="1", c)
check("P4 kill death_freshness stale_or_absent_expected", c.get("death_freshness")=="stale_or_absent_expected", c)
print("OVERALL", "PASS" if ok else "FAIL")
pathlib.Path(runs[-1].parent/"SCORE_RC.txt").write_text("0\n" if ok else "1\n")
raise SystemExit(0 if ok else 1)
PY
score_rc=$?
echo "score_true_rc=$score_rc" | tee "$EVDIR/score_true_rc.txt"

# unit breadcrumb binary (if built later) — also dump limits
cat >"$EVDIR/LIMITS.txt" <<'EOF'
HARD LIMITS (not defects of the harness):
- SIGKILL: no handler runs → misterplexd.death will not show signal=9 from the victim.
  Parent waitpid still reports WIFSIGNALED=1 WTERMSIG=9. death_freshness=stale_or_absent_expected.
- OOM killer: equivalent to SIGKILL from the kernel. Parent sees signal=9.
  Correlate with dmesg: grep -iE 'killed process|out of memory|oom-kill'
  Positive: "Out of memory: Killed process <pid> (misterplexd)"
- Shell wait path (no cap binary): WIF* is approximate (rc>=128 ⇒ signal rc-128); WCOREDUMP unknown.
EOF

cp -a "$OUT" "$EVDIR/" 2>/dev/null || true
ls -la "$EVDIR" | tee "$EVDIR/listing.txt"
echo "EVIDENCE_DIR=$EVDIR"
exit "$score_rc"
