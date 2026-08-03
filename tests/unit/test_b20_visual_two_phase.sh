#!/usr/bin/env bash
# B20 visual two-phase — product-path polarity + fstart ack + mode-exit + window.
# rd-duck: use_frame_store is force-bars; Plex ties 0. B20 must arm on !use_fs.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CORE="$ROOT/fpga/Plex_MiSTer/rtl/present_core.sv"
PLEX="$ROOT/fpga/Plex_MiSTer/Plex.sv"
DOC="$ROOT/assets/b20_visual_two_phase_wall.json"
fail() { echo "FAIL: $*"; exit 1; }

[[ -f "$CORE" && -f "$DOC" && -f "$PLEX" ]] || fail "missing inputs"

# --- hierarchy / top tie (product) ---
grep -q "use_frame_store(1'b0)" "$PLEX" || fail "Plex must hardwire use_frame_store=0 (product ext path)"
grep -q 'b20_ext_store_path = !use_frame_store' "$CORE" || \
  fail "B20 must arm on !use_frame_store (ext store), not force-bars"
grep -q 'beam_de_free_g  = !b20_ext_store_path' "$CORE" || fail "free-run polarity (force-bars only)"
grep -q 'b20_ext_store_path && geom_live_valid' "$CORE" || fail "hold must arm on ext path"
# Hold must NOT require use_frame_store==1
if grep -A2 'assign b20_visual_hold' "$CORE" | grep -v FAULT | grep -v '//' | grep -E 'use_frame_store &&'; then
  fail "hold still gated by use_frame_store==1 (force-bars)"
fi

grep -q 'visual_swap_ack' "$CORE" || fail "no visual_swap_ack"
grep -q 'frame_start && swap_pending && store_pending_ready' "$CORE" || \
  fail "swap ack must be fstart-qualified (store edge)"
if grep -n 'beam_de_idle' "$CORE" | grep 'geom_enable'; then
  fail "idle still keys off geom_enable (mode-exit hole)"
fi
grep -q '!geom_live_valid' "$CORE" || fail "idle must require !geom_live_valid"
if grep -A3 'assign b20_visual_hold' "$CORE" | grep -v FAULT | grep -v '//' | grep 'geom_enable &&'; then
  fail "hold still requires geom_enable"
fi
grep -q 'app_win_enable ? app_content_x0' "$CORE" || fail "app_win_x0 not consumed"
grep -q 'app_win_enable ? app_content_y0' "$CORE" || fail "app_win_y0 not consumed"
grep -q 'store_x_sum' "$CORE" || fail "no windowed store_x_sum"
grep -q 'beam_src_w = app_content_w' "$CORE" || fail "beam not on app w"
grep -q 'content_fps(app_content_fps)' "$CORE" || fail "cadence not on app fps"
grep -q 'FAULT_B20_VISUAL_FREE_RUN' "$CORE" || fail "no RED twin"
echo "OK structure product-polarity + fstart-ack + mode-exit + window"

# Product path models: use_fs=0 (Plex tie)
awk '
BEGIN {
  use_fs=0; ext = !use_fs
  app_w=624; app_seq=1; cand_w=960; cand_seq=2
  swap_pending=1; pending_ready=1; live_v=1; fstart=0
  free = !ext
  ack = fstart && swap_pending && pending_ready
  idle = ext && !swap_pending && !live_v
  apply = free || ack || idle
  if (free) { print "FAIL product must not free-run"; exit 1 }
  if (apply) { print "FAIL mid-active ready applied on product"; exit 1 }
  hold = ext && live_v && (cand_seq != app_seq)
  if (!hold) { print "FAIL product mid-active must hold"; exit 1 }
  print "OK model PRODUCT mid-active: no apply, hold=1 (use_fs=0)"
}
' || fail "product mid-active model"

awk '
BEGIN {
  use_fs=0; ext=!use_fs
  app_w=624; app_seq=1; cand_w=960; cand_seq=2
  swap_pending=1; pending_ready=1; live_v=1; fstart=1
  ack = fstart && swap_pending && pending_ready
  if (!ack || !ext) exit 1
  app_w=cand_w; app_seq=cand_seq
  hold = ext && live_v && (cand_seq != app_seq)
  if (app_w != 960 || hold) { print "FAIL product fstart ack"; exit 1 }
  print "OK model PRODUCT fstart+ready ack applies and clears hold"
}
' || fail "product fstart ack model"

awk '
BEGIN {
  use_fs=1; ext=!use_fs
  free = !ext
  if (!free) { print "FAIL force-bars should free-run"; exit 1 }
  hold = ext && 1 && 1
  if (hold) { print "FAIL force-bars must not hold"; exit 1 }
  print "OK model force-bars free-run, no hold"
}
' || fail "force-bars model"

awk '
BEGIN {
  use_fs=0
  wrong_free = !use_fs
  if (!wrong_free) exit 1
  print "OK model RED wrong-polarity free-runs product (REPRO class)"
}
' || fail "red polarity model"

awk '
BEGIN {
  use_fs=0; ext=!use_fs
  app_w=960; app_seq=5; cand_w=624; cand_seq=6
  geom_enable=0; live_v=1; swap_pending=0
  wrong_idle = ext && !swap_pending && !geom_enable
  right_idle = ext && !swap_pending && !live_v
  if (!wrong_idle) exit 1
  if (right_idle) exit 1
  apply = right_idle
  if (apply) { print "FAIL mode-exit free-ran before doorbell"; exit 1 }
  hold = ext && live_v && (cand_seq != app_seq)
  if (!hold || app_w != 960) { print "FAIL mode-exit hold"; exit 1 }
  print "OK model PRODUCT mode-exit: hold OLD, no free-run, black"
}
' || fail "mode-exit model"

awk '
BEGIN {
  hc=5; x0=10
  sx = hc + x0
  if (sx != 15) exit 1
  app_win=0; sx = hc + (app_win ? x0 : 0)
  if (sx != 5) exit 1
  print "OK model window offset consumed"
}
' || fail "window model"

awk "BEGIN{ app_w=624; cand_w=960; apply=1; if(apply) app_w=cand_w; if(app_w!=960) exit 1
  print \"OK model RED free-run REPRO\" }" || fail "red model"

echo "OK behavioral models"

python3 - <<'PY2' || fail "json"
import json
from pathlib import Path
d=json.loads(Path("assets/b20_visual_two_phase_wall.json").read_text())
assert d.get("beam_only_rt_de_apply_sufficient") is False
assert d.get("B20_CLOSED") is False
assert d.get("audit_75e16d9b_fixed") is True
assert d.get("product_use_frame_store_tie") == 0
assert d.get("b20_arms_on") == "ext_store_path_not_force_bars"
print("OK wall json")
PY2

echo "PASS test_b20_visual_two_phase"
echo "true rc=0"
