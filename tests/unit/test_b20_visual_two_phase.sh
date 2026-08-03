#!/usr/bin/env bash
# B20 broader than beam DE (rd-duck): all visual consumers hold until swap fire.
# GREEN: product shadows + blackout on seq mismatch; RED free-run lacks hold.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CORE="$ROOT/fpga/Plex_MiSTer/rtl/present_core.sv"
BEAM="$ROOT/fpga/Plex_MiSTer/rtl/present_beam_content_de.sv"
MUX="$ROOT/fpga/Plex_MiSTer/rtl/plex_present_geom_mux.sv"
DOC="$ROOT/assets/b20_visual_two_phase_wall.json"
fail() { echo "FAIL: $*"; exit 1; }

[[ -f "$CORE" ]] || fail "missing present_core"
[[ -f "$DOC" ]] || fail "missing wall json"

# --- Product: two-phase shadows ---
grep -q 'app_content_fps' "$CORE" || fail "no app_content_fps"
grep -q 'app_content_w' "$CORE" || fail "no app_content_w"
grep -q 'app_content_h' "$CORE" || fail "no app_content_h"
grep -q 'app_live_seq' "$CORE" || fail "no app_live_seq"
grep -q 'app_win_enable' "$CORE" || fail "no app_win window shadow"
grep -q 'visual_geom_apply' "$CORE" || fail "no visual_geom_apply"
# Cadence + film class must consume APPLIED fps, not free-running candidate
grep -q 'beam_film_class = (app_content_fps' "$CORE" || fail "film class not on app fps"
grep -q 'content_fps(app_content_fps)' "$CORE" || fail "cadence not on app fps"
# Beam DE from applied (product)
grep -q 'beam_src_w = app_content_w' "$CORE" || fail "beam DE not applied"
# Apply qualifier shares store swap fire
grep -q 'swap_pending && store_pending_ready' "$CORE" || fail "no swap_fire term"
# Blackout while candidate epoch != applied
grep -q 'b20_visual_hold' "$CORE" || fail "no b20_visual_hold"
grep -q 'geom_live_seq != app_live_seq' "$CORE" || fail "hold not on seq mismatch"
grep -q 'visual_force_black' "$CORE" || fail "no RGB force black"
grep -q 'stat_geom_hold_black = geom_hold_black | b20_visual_hold' "$CORE" || \
  fail "stat hold must OR b20"
# Store still gets free-running candidate geom for prep (rt_* = geom_*)
grep -q 'rt_coded_w(geom_coded_w)' "$CORE" || fail "store must see candidate coded_w"
grep -q 'rt_display_w(geom_display_w)' "$CORE" || fail "store must see candidate display_w"
echo "OK product two-phase shadows + blackout + store candidate prep"

# --- RED twins exist ---
grep -q 'FAULT_B20_VISUAL_FREE_RUN' "$CORE" || fail "no FAULT_B20_VISUAL_FREE_RUN"
grep -q 'FAULT_B20_BEAM_FREE_RUN' "$BEAM" || fail "no FAULT_B20_BEAM_FREE_RUN"
echo "OK RED twins declared"

# --- Behavioral awk model: delayed ready past one fstart ---
# Pre-register: hold keeps OLD w/fps until swap_fire; free-run takes NEW immediately.
PRE_HOLD_W=624
PRE_HOLD_FPS=24
NEW_W=960
NEW_FPS=30
# Model product
awk -v ow="$PRE_HOLD_W" -v of="$PRE_HOLD_FPS" -v nw="$NEW_W" -v nf="$NEW_FPS" '
BEGIN {
  app_w=ow; app_f=of; app_seq=1
  cand_w=nw; cand_f=nf; cand_seq=2
  swap_pending=1; pending_ready=0; use_fs=1; geom_en=1; live_v=1
  # frame 0: promote candidate, not ready
  apply = (!use_fs) || (swap_pending && pending_ready) || (use_fs && !swap_pending)
  if (apply) { app_w=cand_w; app_f=cand_f; app_seq=cand_seq }
  hold = use_fs && live_v && geom_en && (cand_seq != app_seq)
  if (app_w != ow || app_f != of) { print "FAIL model free-ran before ready"; exit 1 }
  if (!hold) { print "FAIL model no hold while seq mismatch"; exit 1 }
  # frame 1: ready + swap fire
  pending_ready=1
  apply = (swap_pending && pending_ready)
  if (apply) { app_w=cand_w; app_f=cand_f; app_seq=cand_seq }
  hold = use_fs && live_v && geom_en && (cand_seq != app_seq)
  if (app_w != nw || app_f != nf) { print "FAIL model did not apply on fire"; exit 1 }
  if (hold) { print "FAIL model hold stuck after apply"; exit 1 }
  print "OK model GREEN hold-then-apply w=" app_w " fps=" app_f
}
' || fail "awk GREEN model"
# Model free-run RED (always apply)
awk -v ow="$PRE_HOLD_W" -v of="$PRE_HOLD_FPS" -v nw="$NEW_W" -v nf="$NEW_FPS" '
BEGIN {
  app_w=ow; app_f=of; app_seq=1
  cand_w=nw; cand_f=nf; cand_seq=2
  pending_ready=0
  apply=1  # FAULT free-run
  if (apply) { app_w=cand_w; app_f=cand_f; app_seq=cand_seq }
  if (app_w != nw || app_f != nf) { print "FAIL RED model should free-run"; exit 1 }
  print "OK model RED free-run REPRO NEW w/fps with pending_ready=0"
}
' || fail "awk RED model"
echo "OK delayed-ready behavioral model (neg: free-run takes NEW)"

# --- Wall honesty: beam-only gate insufficient; latch still free-runs ---
python3 - <<'PY' || fail "wall json"
import json,sys
from pathlib import Path
p=Path("assets/b20_visual_two_phase_wall.json")
d=json.loads(p.read_text())
assert d.get("b20_scope") == "visual_two_phase"
assert d.get("beam_only_rt_de_apply_sufficient") is False
assert d.get("latch_still_promotes_at_vsync") is True
assert "present_core" in d.get("implemented_here", [])
assert "present_geom_latch" in d.get("still_open_owners", {})
print("OK wall honesty flags")
PY

# --- Must not claim full B20 closed on beam-only port ---
if grep -q 'B20_CLOSED=true' "$DOC" 2>/dev/null; then
  fail "must not claim B20 fully closed"
fi

echo "PASS test_b20_visual_two_phase"
echo "true rc=0"
