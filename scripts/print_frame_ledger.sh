#!/usr/bin/env bash
# One-shot soak ledger print + residual (P5). Parent/on-device:
#   ssh root@$MISTER_HOST 'bash -s' < scripts/print_frame_ledger.sh
# Or on device:
#   /media/fat/misterplex/print_frame_ledger.sh
#   LEDGER=/media/fat/misterplex_v2/misterplexd.frame_ledger ./print_frame_ledger.sh
set -euo pipefail
LEDGER="${LEDGER:-}"
if [[ -z "$LEDGER" ]]; then
  for c in /media/fat/misterplex/misterplexd.frame_ledger \
           /media/fat/misterplex_v2/misterplexd.frame_ledger \
           ./misterplexd.frame_ledger; do
    [[ -f "$c" ]] && LEDGER=$c && break
  done
fi
if [[ -z "${LEDGER}" || ! -f "$LEDGER" ]]; then
  echo "FAIL LEDGER_MISSING path=${LEDGER:-unset}"
  echo "NOTE: deploy daemon with frame_ledger; file lives beside misterplex.conf"
  exit 1
fi

echo "LEDGER_PATH=$LEDGER"
echo "----- tail (last 20 events) -----"
tail -n 20 "$LEDGER" || true
echo "----- sum (session_end rows) -----"
python3 - <<'PY' "$LEDGER"
import sys, re
path = sys.argv[1]
starts = exits = sessions = 0
frames = presents = drops = fails = residual = 0
pids = set()
for line in open(path, errors="replace"):
    if "event=process_start" in line:
        starts += 1
        m = re.search(r"pid=(\d+)", line)
        if m: pids.add(m.group(1))
    elif "event=process_exit" in line:
        exits += 1
        m = re.search(r"pid=(\d+)", line)
        if m: pids.add(m.group(1))
    elif "event=session_end" in line:
        sessions += 1
        def g(k):
            m = re.search(rf"{k}=(-?\d+)", line)
            return int(m.group(1)) if m else 0
        frames += g("frames")
        presents += g("presents")
        drops += g("drops")
        fails += g("present_fails")
        residual += g("residual")
ident = frames - presents - drops - fails
print(f"process_starts={starts} process_exits={exits} session_ends={sessions} unique_pids={len(pids)}")
print(f"sum_frames={frames} sum_presents={presents} sum_drops={drops} sum_present_fails={fails}")
print(f"sum_residual_field={residual} identity_residual={ident} closed={1 if ident==0 else 0}")
if starts > 1 or len(pids) > 1:
    print("RESTART_VISIBLE=1  (do not treat drops= from log tail as whole-soak)")
else:
    print("RESTART_VISIBLE=0")
if sessions == 0:
    print("FAIL no session_end rows yet")
    sys.exit(1)
if ident != 0:
    print(f"FAIL LEDGER_OPEN residual={ident}")
    sys.exit(1)
print("LEDGER_OK residual=0 across all session_end rows")
sys.exit(0)
PY
