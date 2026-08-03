#!/usr/bin/env bash
# RED/GREEN: AUDIO_DELAY_MS conf → ffmpeg filter → measured PCM silence head.
#
# Pins the relationship hardware could not see when only conf intent was logged
# (parent: adelay=150 → lipsync Δ=+33.3 ms, 117 ms unaccounted).
#
# GREEN: tip sources use portable adelay=N|N, log predicted shift, measure
#        pcm_silence_head_ms on the pump, and host unit recovers silence==conf.
# RED twins: strip measurement log or revert to :all=1-only / no silence scan.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MP="$ROOT/arm/misterplexd/media_player.cpp"
AD="$ROOT/host/libmisterplex/audio_delay.hpp"
WORK="$ROOT/build/audio-delay-authority-unit"
mkdir -p "$WORK"

green_checks() {
  local mp="$1" ad="$2"
  grep -q 'ffmpegAudioDelayFilter' "$mp" || return 1
  grep -q 'pcm_silence_head_ms=' "$mp" || return 1
  grep -q 'SilenceHeadScan' "$mp" || return 1
  grep -q 'predicted_content_shift_ms=' "$mp" || return 1
  grep -q 'prefill_cancel_ms=' "$mp" || return 1
  grep -q 'adelayCancelledByPrefillMs' "$ad" || return 1
  grep -q 'adelayContentShiftMs' "$ad" || return 1
  # Portable per-channel form must be the builder output contract.
  grep -q 'std::to_string(delayMs) + "|" + std::to_string(delayMs)' "$ad" || return 1
  # Product media_player must not embed raw :all=1 adelay strings.
  if grep -E 'adelay=.*:all=1' "$mp" | grep -v '//' | grep -q .; then
    return 1
  fi
  # Prefill cancel model must be identically zero (single-line contract).
  grep -q 'adelayCancelledByPrefillMs(int /\*confDelayMs\*/, int /\*prefillTargetMs\*/) { return 0; }' "$ad" \
    || grep -q 'adelayCancelledByPrefillMs' "$ad" || return 1
  return 0
}

if ! green_checks "$MP" "$AD"; then
  echo "FAIL: green audio-delay authority wiring checks failed on tip sources" >&2
  exit 1
fi
echo "PASS green: tip sources measure pcm_silence_head + portable adelay filter"

cp "$MP" "$WORK/media_player.cpp"
cp "$AD" "$WORK/audio_delay.hpp"

# RED TWIN A: strip silence-head measurement log (intent-only — the old hole).
sed -i '/pcm_silence_head_ms=/d' "$WORK/media_player.cpp"
sed -i '/SilenceHeadScan/d' "$WORK/media_player.cpp"
set +e
green_checks "$WORK/media_player.cpp" "$WORK/audio_delay.hpp"
RED_A=$?
set -e
echo "audio_delay_red_twin_no_measure true rc=$RED_A"
if [[ "$RED_A" -eq 0 ]]; then
  echo "FAIL: red twin A — green_checks still passed without silence-head measure" >&2
  exit 1
fi
echo "PASS red twin A: green_checks fail without pcm_silence_head measure (rc=$RED_A)"

# RED TWIN B: claim prefill cancels adelay (the killed hypothesis encoded as truth).
cp "$AD" "$WORK/audio_delay.hpp"
python3 - <<'PY'
from pathlib import Path
p = Path("build/audio-delay-authority-unit/audio_delay.hpp")
t = p.read_text()
old = "inline int adelayCancelledByPrefillMs(int /*confDelayMs*/, int /*prefillTargetMs*/) { return 0; }"
new = "inline int adelayCancelledByPrefillMs(int confDelayMs, int prefillTargetMs) {\n    // MUTANT: pretends prefill eats adelay\n    int c = confDelayMs < prefillTargetMs ? confDelayMs : prefillTargetMs;\n    return c > 0 ? c : 0;\n}"
if old not in t:
    raise SystemExit("prefill cancel anchor missing")
p.write_text(t.replace(old, new, 1))
PY
# Functional unit must FAIL on the mutant.
CXX_BIN="${CXX:-g++}"
if [[ -n "${CXXFLAGS:-}" ]]; then
  # shellcheck disable=SC2206
  CXX_FLAGS=(${CXXFLAGS})
else
  CXX_FLAGS=(-std=c++17 -O2 -Wall -Wextra)
fi
cp "$ROOT/tests/unit/test_audio_delay.cpp" "$WORK/test_audio_delay.cpp"
# Point include at mutant header via -I"$WORK" first... but include path is libmisterplex/
mkdir -p "$WORK/libmisterplex"
cp "$WORK/audio_delay.hpp" "$WORK/libmisterplex/audio_delay.hpp"
cp "$ROOT/host/libmisterplex/mraudio_status.hpp" "$WORK/libmisterplex/mraudio_status.hpp"
set +e
"$CXX_BIN" "${CXX_FLAGS[@]}" -I"$WORK" -o "$WORK/test_audio_delay_mutant" \
  "$WORK/test_audio_delay.cpp" 2>"$WORK/mutant_build.err"
MUT_BUILD=$?
set -e
if [[ "$MUT_BUILD" -ne 0 ]]; then
  echo "FAIL: mutant failed to build" >&2
  cat "$WORK/mutant_build.err" >&2
  exit 1
fi
set +e
"$WORK/test_audio_delay_mutant" >"$WORK/mutant_run.out" 2>&1
MUT_RC=$?
set -e
echo "audio_delay_red_twin_prefill_cancel true rc=$MUT_RC"
if [[ "$MUT_RC" -eq 0 ]]; then
  echo "FAIL: red twin B — unit still PASSed when prefill-cancel mutant returns non-zero" >&2
  cat "$WORK/mutant_run.out" >&2
  exit 1
fi
echo "PASS red twin B: unit fails when prefill is claimed to cancel adelay (rc=$MUT_RC)"

# GREEN functional on tip headers
set +e
"$CXX_BIN" "${CXX_FLAGS[@]}" -I"$ROOT/host" -o "$WORK/test_audio_delay_tip" \
  "$ROOT/tests/unit/test_audio_delay.cpp" 2>"$WORK/tip_build.err"
TIP_BUILD=$?
set -e
if [[ "$TIP_BUILD" -ne 0 ]]; then
  echo "FAIL: tip test_audio_delay failed to build" >&2
  cat "$WORK/tip_build.err" >&2
  exit 1
fi
set +e
TIP_OUT="$("$WORK/test_audio_delay_tip" 2>&1)"
TIP_RC=$?
set -e
printf '%s\n' "$TIP_OUT"
echo "test_audio_delay_tip true rc=$TIP_RC"
if [[ "$TIP_RC" -ne 0 ]]; then
  echo "FAIL: tip test_audio_delay failed" >&2
  exit 1
fi

# Optional host ffmpeg ladder: conf ms → measured silence head on real filter string
if command -v ffmpeg >/dev/null 2>&1 && [[ -f "$ROOT/assets/avsync/sync_24fps_blip.mp4" ]]; then
  FIX="$ROOT/assets/avsync/sync_24fps_blip.mp4"
  for d in 0 60 150; do
    af="aresample=48000"
    if [[ "$d" -gt 0 ]]; then af="aresample=48000,adelay=${d}|${d}"; fi
    out="$WORK/adelay_${d}.s16"
    ffmpeg -hide_banner -loglevel error -y -i "$FIX" -t 2 -vn -af "$af" \
      -f s16le -ac 2 -ar 48000 "$out"
    python3 - <<PY
import numpy as np, sys
pcm = np.fromfile("$out", dtype=np.int16)
mono = pcm.reshape(-1, 2).mean(axis=1)
idx = next((i for i, x in enumerate(mono) if abs(x) > 500), None)
head = None if idx is None else idx * 1000.0 / 48000.0
conf = $d
print(f"ffmpeg_ladder conf={conf} silence_head_ms={head}")
if head is None:
    sys.exit(2)
if abs(head - conf) > 2.0:
    print(f"FAIL ladder conf={conf} head={head}", file=sys.stderr)
    sys.exit(1)
PY
  done
  echo "PASS host ffmpeg conf→silence_head ladder (0/60/150)"
else
  echo "SKIP host ffmpeg ladder (ffmpeg or fixture missing)"
fi

echo "OK audio delay authority red/green (measure + portable filter + prefill-cancel=0)"
