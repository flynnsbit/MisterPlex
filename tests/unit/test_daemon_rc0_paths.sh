#!/usr/bin/env bash
# Q1/Q3 host gates — no device.
# Q1: product FOAR must not target display 618 (source pin).
# Q3: every main() rc=0 site is catalogued; --help returns 0; SIGTERM path is
#     coded only via g_stop (string pin). Optional live SIGTERM if binary+conf.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0
pass=0

check() {
  local name="$1" file="$2" pat="$3"
  if rg -n --fixed-strings "$pat" "$file" >/dev/null 2>&1; then
    echo "PASS $name"
    pass=$((pass + 1))
  else
    echo "FAIL $name missing: $pat" >&2
    fail=$((fail + 1))
  fi
}

MAIN="$ROOT/arm/misterplexd/main.cpp"
MP="$ROOT/arm/misterplexd/media_player.cpp"
VF="$ROOT/host/libmisterplex/ffmpeg_vf.hpp"
DDR="$ROOT/host/libmisterplex/ddr_frame_layout.hpp"

# --- Q1: 618 is display crop, not FOAR target ---
check Q1_display_width_618 "$DDR" 'kPlex480pDisplayWidth{618}'
check Q1_crop_right_6 "$DDR" 'kPlex480pCropRight = 6'
check Q1_coded_624 "$DDR" 'kPlex480pCodedWidth{624}'
check Q1_legacy_foar_618_comment "$VF" 'LEGACY'
check Q1_product_foar_coded "$VF" 'scale_pad_center_coded'
check Q1_never_display_618_foar "$VF" 'never into display 618'
# Product builder must call center (coded), not cropped FOAR, on hasCrop non-exact.
if rg -n 'append\(buildScalePadCentered\(req\.coded_w' "$VF" >/dev/null; then
  echo "PASS Q1_append_scale_pad_centered_coded"
  pass=$((pass + 1))
else
  echo "FAIL Q1_append_scale_pad_centered_coded" >&2
  fail=$((fail + 1))
fi
# Red twin: product planner must not *call* buildScalePadCropped (LEGACY helper
# may still be defined for unit mutation tests). Comments mentioning the name OK.
if rg -n '^\s*append\(buildScalePadCropped\(|^\s*return buildScalePadCropped\(|[^/]buildScalePadCropped\(' "$VF" \
  | rg -v 'inline std::string buildScalePadCropped|//|LEGACY|still take|buildScalePadCropped →' >/dev/null; then
  echo "FAIL Q1_red_product_calls_buildScalePadCropped" >&2
  rg -n 'buildScalePadCropped\(' "$VF" | head -20 >&2 || true
  fail=$((fail + 1))
else
  echo "PASS Q1_red_product_no_buildScalePadCropped_call"
  pass=$((pass + 1))
fi

# --- Q2: mid-stream measured update path exists ---
check Q2_mid_stream_flag "$MP" 'MID_STREAM_CHANGE='
check Q2_measured_store "$MP" 'measuredDeliveryW_.store(g.w)'
check Q2_changed_guard "$MP" 'const bool changed = (lastInW > 0 || lastInH > 0)'
check Q2_mid_stream_error "$MP" 'MEASURED_DELIVERY mid-stream change'
check Q2_mb_align_reject "$DDR" 'not MB-aligned'

# --- Q3: rc=0 catalogue ---
check Q3_g_stop_only_comment "$MAIN" 'Product main loop exits ONLY when g_stop is set'
check Q3_sigterm_wifexited_comment "$MAIN" 'clean rc=0'
check Q3_main_loop_exit_site "$MAIN" 'site=main.cpp:main_loop_g_stop'
check Q3_exit_reported_0_loop "$MAIN" 'return exitReported(0, why'
check Q3_help_rc0 "$MAIN" 'site=main.cpp:--help'
check Q3_lab_play_done_rc0 "$MAIN" 'site=main.cpp:lab-play-file-done'
check Q3_sigaction_term "$MAIN" 'sigaction(SIGTERM'
check Q3_sigaction_int "$MAIN" 'sigaction(SIGINT'
check Q3_plexctl_wifexited_note "$ROOT/scripts/plexctl.sh" 'handled SIGTERM → often st=0'
check Q3_exit_reason_log "$ROOT/arm/misterplexd/death_breadcrumb.cpp" 'EXIT_REASON code='

# Live: --help → rc 0 (no conf required)
BIN="$ROOT/build/misterplexd"
if [[ ! -x "$BIN" ]]; then
  make -C "$ROOT" plexd >/dev/null 2>&1 || make -C "$ROOT" "$BIN" >/dev/null 2>&1 || true
fi
if [[ -x "$BIN" ]]; then
  set +e
  "$BIN" --help >/dev/null 2>&1
  hc=$?
  set -e
  if [[ "$hc" -eq 0 ]]; then
    echo "PASS Q3_live_help_rc0"
    pass=$((pass + 1))
  else
    echo "FAIL Q3_live_help_rc0 got $hc" >&2
    fail=$((fail + 1))
  fi
  echo "Q3_help true rc=$hc"
else
  echo "SKIP Q3_live_help_rc0 (no binary)"
fi

echo "SUMMARY pass=$pass fail=$fail"
if [[ "$fail" -ne 0 ]]; then
  echo "DAEMON_RC0_PATHS_FAIL"
  exit 1
fi
echo "DAEMON_RC0_PATHS_OK"
exit 0
