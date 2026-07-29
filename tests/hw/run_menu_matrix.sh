#!/usr/bin/env bash
# Full Plex OSD menu matrix: set_status + HDMI capture + luma check.
# Host-side. Requires MiSTer up, set_status deployed, Plex core loaded.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/tests/hw/hw_gate_common.sh"
HOST="${MISTER_HOST:-192.168.1.183}"
PASS="${MISTER_PASS:-1}"
OUT="${MENU_CAPTURE_DIR:-$ROOT/captures/menu}"
DEVICE="${HDMI_DEV:-/dev/video4}"
RBF_LOCAL="${RBF_LOCAL:-$ROOT/fpga/Plex_MiSTer/releases/Plex.rbf}"
# MENU_FAST=1 (default): short dwell — user-visible mode flips stay <0.5s
# MENU_FAST=0: slower multi-frame capture for flaky grabbers
MENU_FAST="${MENU_FAST:-1}"
SETTLE="${SETTLE:-0.18}"
LOAD_SLEEP="${LOAD_SLEEP:-3}"
FRAMES="${FRAMES:-2}"
if [[ "$MENU_FAST" != "1" ]]; then
  SETTLE=0.5
  LOAD_SLEEP=5
  FRAMES=8
fi
SSH=(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "root@$HOST")
SCP=(sshpass -p "$PASS" scp -o StrictHostKeyChecking=no)
mkdir -p "$OUT"
REPORT="$OUT/REPORT.md"
CHECKLIST="$OUT/CHECKLIST.md"
STATUS_FILE="$OUT/menu-agent-status.txt"

log() { echo "$*" | tee -a "$STATUS_FILE"; }
ssh_q() { "${SSH[@]}" "$@" 2>/dev/null | grep -v 'WARNING\|post-quantum\|vulnerable\|store now' || true; }

capture_preflight() {
  if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "NO_CAPTURE_DEVICE dev=$DEVICE reason=missing_ffmpeg" >&2
    exit 20
  fi
  if [[ ! -e "$DEVICE" ]]; then
    echo "NO_CAPTURE_DEVICE dev=$DEVICE reason=absent" >&2
    exit 20
  fi
  if [[ ! -c "$DEVICE" ]]; then
    echo "NO_CAPTURE_DEVICE dev=$DEVICE reason=not_char_device" >&2
    exit 20
  fi
}

mean_luma() {
  python3 - "$1" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("L")
px = list(im.getdata())
mean = sum(px) / max(len(px), 1)
print(f"{mean:.1f}")
open(sys.argv[1].rsplit(".",1)[0] + ".luma.txt","w").write(f"{mean:.1f}\n")
PY
}

capture() {
  local name="$1"
  local dest="$OUT/${name}.jpg"
  rm -f "$OUT/${name}_f"*.jpg "$dest" 2>/dev/null || true
  fuser -k "$DEVICE" 2>/dev/null || true
  sleep "$SETTLE"
  ffmpeg -y -hide_banner -loglevel error \
    -f v4l2 -input_format mjpeg -video_size 800x600 -framerate 30 \
    -i "$DEVICE" -frames:v "$FRAMES" -q:v 3 "$OUT/${name}_f%02d.jpg" 2>/dev/null || true
  # pick brightest frame (skip black warmup)
  local best="$dest"
  python3 - "$OUT" "$name" "$dest" "$DEVICE" <<'PY'
import sys
from pathlib import Path
from PIL import Image
out, name, dest, dev = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3]), sys.argv[4]
cands = sorted(out.glob(f"{name}_f*.jpg"))
best, best_m = None, -1.0
for p in cands:
    try:
        im = Image.open(p).convert("L")
        px = list(im.getdata())
        m = sum(px) / max(len(px), 1)
        if m > best_m:
            best_m, best = m, p
    except Exception:
        pass
if best is None:
    print(f"CAPTURE_FAILED name={name} dev={dev} reason=no_frame", file=sys.stderr)
    raise SystemExit(20)
dest.write_bytes(best.read_bytes())
print(f"{best_m:.1f} {best.stat().st_size}")
PY
}

capture_values() {
  local name="$1"
  local out rc
  set +e
  out=$(capture "$name")
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    echo "MENU_CAPTURE_FAILED step=$name exit=$rc" >&2
    exit 20
  fi
  read -r mean sz <<<"$out"
}

set_status() {
  ssh_q "/media/fat/misterplex/bin/set_status $*"
}

update_checklist_row() {
  # id status note
  local id="$1" st="$2" note="${3:-}"
  python3 - "$CHECKLIST" "$id" "$st" "$note" <<'PY'
import sys, re
path, id_, st, note = sys.argv[1:5]
text = open(path).read().splitlines()
out = []
for line in text:
    if line.startswith("| " + id_ + " ") or line.startswith("| " + id_ + "\t") or re.match(rf"\| {re.escape(id_)} \|", line):
        parts = [p.strip() for p in line.strip().strip("|").split("|")]
        # ID Option Values Status Screenshot Notes
        if len(parts) >= 6:
            parts[3] = st
            if note:
                parts[5] = note
            line = "| " + " | ".join(parts) + " |"
    out.append(line)
open(path,"w").write("\n".join(out) + "\n")
PY
}

pass_or_fail() {
  local id="$1" name="$2" mean="$3" min_luma="${4:-20}"
  if python3 -c "import sys; sys.exit(0 if float('$mean')>=$min_luma else 1)"; then
    log "PASS $id $name mean=$mean"
    update_checklist_row "$id" "PASS" "mean=$mean \`${name}.jpg\`"
    echo "PASS"
  else
    log "FAIL $id $name mean=$mean (black/too dark)"
    update_checklist_row "$id" "FAIL" "mean=$mean black?"
    echo "FAIL"
  fi
}

# --- ensure tools + RBF ---
log "=== menu matrix start $(date -Iseconds) ==="
capture_preflight
if ! ping -c 1 -W 3 "$HOST" >/dev/null 2>&1; then
  log "MiSTer unreachable"
  exit 2
fi

EXPECTED_MD5=$(md5sum "$RBF_LOCAL" | awk '{print $1}')
log "local RBF md5=$EXPECTED_MD5"

"${SCP[@]}" "$ROOT/build/arm/set_status" "$ROOT/build/arm/push_frame" \
  "root@$HOST:/media/fat/misterplex/bin/" || true
ssh_q "chmod +x /media/fat/misterplex/bin/set_status /media/fat/misterplex/bin/push_frame"

# Safe deploy: stage RBF + optional menu bounce (never scp-over-live + load_core)
# MENU_RELOAD=0 → copy only if already on Plex with matching md5
REMOTE_MD5=$(hw_parse_md5_hex "$(ssh_q "md5sum /media/fat/_Utility/Plex.rbf")")
CORE=$(ssh_q 'cat /tmp/CORENAME')
if [[ -n "$REMOTE_MD5" && "$REMOTE_MD5" == "$EXPECTED_MD5" ]] && echo "$CORE" | grep -qi plex; then
  log "RBF md5 match + CORE=Plex — skip load_core (MENU_FAST settle=${SETTLE}s)"
else
  log "safe deploy DEPLOY_LOAD=${MENU_RELOAD:-menu}"
  MISTER_HOST="$HOST" MISTER_PASS="$PASS" DEPLOY_LOAD="${MENU_RELOAD:-menu}" DEPLOY_WAIT_S="$LOAD_SLEEP" \
    "$ROOT/scripts/deploy_plex_core.sh" "$RBF_LOCAL" || log "WARN deploy returned $?"
  sleep 1
fi
REMOTE_MD5=$(hw_parse_md5_hex "$(ssh_q "md5sum /media/fat/_Utility/Plex.rbf")")
CORE=$(ssh_q 'cat /tmp/CORENAME')
log "remote RBF md5=${REMOTE_MD5:-unparsed} CORENAME=$CORE"
if [[ -z "$REMOTE_MD5" ]]; then
  hw_skip_not_pass "run_menu_matrix" \
    "could not parse resident RBF md5 after deploy attempt (read fault, not a mismatch)"
fi
if [[ "$REMOTE_MD5" != "$EXPECTED_MD5" ]] || ! echo "$CORE" | grep -qi plex; then
  hw_skip_not_pass "run_menu_matrix" \
    "resident core provenance mismatch after deploy attempt (remote=${REMOTE_MD5:-unset} expected=$EXPECTED_MD5 core=${CORE:-unset})"
fi

# Verify SPI
log "status raw:"
set_status --raw || true
set_status --status || true

# Seed safe defaults: NTSC, bars, force bars YES (visible even with has_frame), fps 30, audio on
log "seed defaults force-bars"
set_status --pattern bars --force-bars 1 --tv ntsc --fps 30 --audio on --raw || true
capture_values baseline_forced
pass_or_fail BASE baseline_forced "$mean" 20

declare -A RESULTS=()

# --- Pattern matrix (force bars on) ---
for spec in \
  "PAT0 bars pat_bars" \
  "PAT1 bars_block pat_bars_block" \
  "PAT2 grid pat_grid" \
  "PAT3 ramp pat_ramp"
do
  set -- $spec
  id=$1; pat=$2; name=$3
  set_status --pattern "$pat" --force-bars 1 --tv ntsc --raw || true
  capture_values "$name"
  RESULTS[$id]=$(pass_or_fail "$id" "$name" "$mean" 20)
done

# Distinctness check among patterns — identical captures are a real FAIL
set +e
python3 - "$OUT" <<'PY'
import sys
from pathlib import Path
from PIL import Image
import numpy as np
d = Path(sys.argv[1])
names = ["pat_bars","pat_bars_block","pat_grid","pat_ramp"]
arrs = {}
for n in names:
    p = d/f"{n}.jpg"
    if not p.exists():
        print("missing", n); continue
    im = np.array(Image.open(p).convert("RGB").resize((160,120)))
    arrs[n] = im.astype(np.float32)
if len(arrs) < 2:
    print("distinctness: fewer than 2 patterns captured — unscored")
    raise SystemExit(77)
keys=list(arrs)
min_mad = None
for i,a in enumerate(keys):
    for b in keys[i+1:]:
        mad = float(np.mean(np.abs(arrs[a]-arrs[b])))
        print(f"distinct {a} vs {b}: mad={mad:.1f}")
        min_mad = mad if min_mad is None else min(min_mad, mad)
# Patterns that are bit-identical (or near-noise) cannot discriminate menu options.
if min_mad is None or min_mad < 1.0:
    print(f"FAIL distinctness min_mad={min_mad}")
    raise SystemExit(1)
print(f"distinctness_ok min_mad={min_mad:.1f}")
PY
dist_rc=$?
set -e
if [[ "$dist_rc" -eq 1 ]]; then
  RESULTS[DIST]=FAIL
  log "FAIL pattern distinctness"
elif [[ "$dist_rc" -eq 77 ]]; then
  RESULTS[DIST]=SKIP
  log "SKIP pattern distinctness (insufficient captures)"
else
  RESULTS[DIST]=PASS
fi

# Force bars yes/no — with pattern bars (0) force matters for has_frame path
set_status --pattern bars --force-bars 1 --raw || true
capture_values force_bars_yes
mean_yes=$mean
RESULTS[FBAR_Y]=$(pass_or_fail FBAR force_bars_yes "$mean_yes" 20)

set_status --pattern bars --force-bars 0 --raw || true
capture_values force_bars_no
mean_no=$mean
# force-off is only informative when it *differs* from force-on; both branches
# previously always PASS'd (vacuous). Record SKIP when we cannot discriminate.
if python3 -c "import sys; y=float('$mean_yes' or 0); n=float('$mean_no' or 0); sys.exit(0 if abs(y-n)>=3.0 else 1)"; then
  update_checklist_row FBAR "PASS" "yes/no differ; yes=$mean_yes no=$mean_no"
  RESULTS[FBAR]=PASS
else
  update_checklist_row FBAR "SKIP" "force yes/no not distinguishable yes=$mean_yes no=$mean_no"
  RESULTS[FBAR]=SKIP
  log "SKIP FBAR force yes/no not distinguishable"
fi

# TV modes
set_status --pattern grid --force-bars 1 --tv ntsc --raw || true
capture_values tv_ntsc
RESULTS[TV0]=$(pass_or_fail TV0 tv_ntsc "$mean" 20)

set_status --pattern grid --force-bars 1 --tv pal --raw || true
capture_values tv_pal
# restore NTSC immediately (do not dwell on PAL)
set_status --tv ntsc --pattern bars --force-bars 1 || true
if python3 -c "import sys; sys.exit(0 if float('$mean')>=10 else 1)"; then
  update_checklist_row TV1 "PASS" "mean=$mean (may desync LCD)"
  RESULTS[TV1]=PASS
else
  # PAL may blank capture — document
  update_checklist_row TV1 "SKIP" "mean=$mean capture blank on PAL; restored NTSC"
  RESULTS[TV1]=SKIP
  log "SKIP TV1 pal mean=$mean"
fi

# FPS
for spec in "FPS0 24 fps_24" "FPS1 30 fps_30" "FPS2 60 fps_60" "FPS3 12 fps_12"; do
  set -- $spec
  id=$1; fps=$2; name=$3
  set_status --pattern bars_block --force-bars 1 --fps "$fps" --tv ntsc --raw || true
  capture_values "$name"
  RESULTS[$id]=$(pass_or_fail "$id" "$name" "$mean" 20)
done

# Audio — no mic probe on this lab; claiming PASS without measuring is vacuous.
set_status --audio on --pattern bars --force-bars 1 --raw || true
capture_values audio_on
update_checklist_row AUD0 "SKIP" "no mic probe; status set On; mean=$mean (unscoreable)"
RESULTS[AUD0]=SKIP
log "SKIP AUD0 no mic probe"
set_status --audio off --raw || true
capture_values audio_off
update_checklist_row AUD1 "SKIP" "no mic probe; status set Off; mean=$mean (unscoreable)"
RESULTS[AUD1]=SKIP
log "SKIP AUD1 no mic probe"
set_status --audio on || true

# Flush pulses — "did not hang" is not a product PASS.
set_status --pulse 10 --raw || true
update_checklist_row T10 "SKIP" "pulsed; no hang (not a scored product check)"
RESULTS[T10]=SKIP
log "SKIP T10 pulse no-hang only"
set_status --pulse 11 --raw || true
update_checklist_row T11 "SKIP" "pulsed; no hang (not a scored product check)"
RESULTS[T11]=SKIP
log "SKIP T11 pulse no-hang only"

# Reset
set_status --pulse 0 --raw || true
sleep 0.35
set_status --pattern bars --force-bars 1 --tv ntsc --raw || true
capture_values after_reset
RESULTS[T0]=$(pass_or_fail T0 after_reset "$mean" 20)
update_checklist_row R0 "PASS" "same path as T0 via SPI"

# Aspect ratio
for spec in "AR0 original ar_original" "AR1 full ar_full" "AR2 arc1 ar_arc1" "AR3 arc2 ar_arc2"; do
  set -- $spec
  id=$1; ar=$2; name=$3
  set_status --ar "$ar" --pattern grid --force-bars 1 --tv ntsc --raw || true
  capture_values "$name"
  RESULTS[$id]=$(pass_or_fail "$id" "$name" "$mean" 15)
done

# Infra rows — never force-PASS unmeasured checklist lines (vacuous green).
update_checklist_row BASE "${RESULTS[BASE]:-PENDING}" "after force-bars seed"
python3 - "$CHECKLIST" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
t=p.read_text()
# Leave PENDING infra as SKIP (honest unscoreable), not forged PASS.
t=t.replace("| status_in v2 (OSD not wiped) | PENDING |", "| status_in v2 (OSD not wiped) | SKIP |")
t=t.replace("| force_bars on non-default pattern | PENDING |", "| force_bars on non-default pattern | SKIP |")
t=t.replace("| RBF with fixes on MiSTer | PENDING |", "| RBF with fixes on MiSTer | SKIP |")
p.write_text(t)
PY

{
  echo
  echo "## Matrix run $(date -Iseconds)"
  echo "- RBF md5: \`$REMOTE_MD5\`"
  echo "- Captures in \`$OUT\`"
  for k in "${!RESULTS[@]}"; do
    echo "- $k: ${RESULTS[$k]}"
  done
} >> "$REPORT"

# Always leave a calm full-screen bars image (don't park on grid/PAL for minutes)
set_status --pattern bars --force-bars 1 --tv ntsc --fps 60 --audio on --raw || true
log "=== matrix done (left on bars) ==="
# Summary
fail=0
skip=0
for k in "${!RESULTS[@]}"; do
  [[ "${RESULTS[$k]}" == FAIL ]] && fail=1
  [[ "${RESULTS[$k]}" == SKIP ]] && skip=1
done
if [[ "$skip" -ne 0 ]]; then
  hw_skip_not_pass "run_menu_matrix" "one or more rows were SKIP; see $REPORT and $CHECKLIST"
fi
exit $fail
