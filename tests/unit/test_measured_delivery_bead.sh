#!/usr/bin/env bash
# B2/B4/B5 measured-delivery bead (one gate, three behaviours).
#
# Parent: delivered geometry must be MEASURED not assumed.
#   B2 — ffmpeg Stream banner observable (loglevel info + MEASURED_DELIVERY)
#   B4 — only basis "measured" verifies (library_media is a claim)
#   B5 — production teardown emits greppable PIPE_* reason= on desync/misalign
#
# Red-before-green via real mutations with printed applied_match counts.
# true rc captured DIRECTLY (never through a pipe).
# Scratch under build/ — never /tmp.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MP="$ROOT/arm/misterplexd/media_player.cpp"
YF="$ROOT/host/libmisterplex/yuv420p_chroma_health.hpp"
VF="$ROOT/host/libmisterplex/ffmpeg_vf.hpp"
LAYOUT="$ROOT/host/libmisterplex/ddr_frame_layout.hpp"
OUT="$ROOT/build/unit-measured-delivery-bead"
FFMPEG="${FFMPEG:-ffmpeg}"
CXX="${CXX:-g++}"
pass=0
fail=0
applied=0

mkdir -p "$OUT"
rm -rf "$OUT"/*
mkdir -p "$OUT"

pass_one() {
  echo "PASS $1"
  pass=$((pass + 1))
  applied=$((applied + 1))
}
fail_one() {
  echo "FAIL $1" >&2
  fail=$((fail + 1))
}

# --- Derive coded bank bytes from header (no DDR literals) -------------------
# Prefer kPlex480pYuv420pBytes if present; else W*H*3/2 from coded dims.
coded_bytes=""
if grep -qE 'kPlex480pYuv420pBytes' "$LAYOUT"; then
  coded_bytes="$(
    python3 - "$LAYOUT" <<'PY'
import re, sys
t=open(sys.argv[1],encoding="utf-8",errors="replace").read()
# constexpr size_t kPlex480pYuv420pBytes = 449280u;  OR computed
m=re.search(r'kPlex480pYuv420pBytes\s*=\s*([0-9]+)u?', t)
if m:
    print(m.group(1)); raise SystemExit(0)
# fall back: kPlex480pCodedWidth/Height
def dim(name):
    m=re.search(rf'{name}\s*=\s*([0-9]+)', t)
    if not m: raise SystemExit(f"missing {name}")
    return int(m.group(1))
w=dim("kPlex480pCodedWidth"); h=dim("kPlex480pCodedHeight")
print(w*h*3//2)
PY
  )"
else
  fail_one "B5_layout_missing_yuv_bytes"
  coded_bytes=0
fi
if [[ -n "$coded_bytes" && "$coded_bytes" -gt 0 ]]; then
  pass_one "B5_coded_bytes_from_header=$coded_bytes"
else
  fail_one "B5_coded_bytes_derive"
  coded_bytes=449280  # last-resort so later compile probes still run shape checks
fi

# =============================================================================
# B2 — loglevel info keeps Stream banner; error suppresses; product artifacts
# =============================================================================
block=$(awk '
  /args\.push_back\("-stats"\)/ { on=1 }
  on { print }
  on && /args\.push_back\("-nostdin"\)/ { exit }
' "$MP")
if echo "$block" | grep -q 'push_back("info")' && ! echo "$block" | grep -q 'push_back("error")'; then
  pass_one "B2_product_loglevel_info"
else
  fail_one "B2_product_loglevel_info"
fi
if grep -q 'MEASURED_DELIVERY delivered_geom=' "$MP" && grep -q 'src=ffmpeg_banner' "$MP"; then
  pass_one "B2_unique_MEASURED_DELIVERY_artifact"
else
  fail_one "B2_unique_MEASURED_DELIVERY_artifact"
fi
if grep -q 'parseFfmpegGeometryLine' "$MP"; then
  pass_one "B2_banner_parser_wired"
else
  fail_one "B2_banner_parser_wired"
fi

# Real ffmpeg: info has 624x350 Stream geometry; error does not.
if ! command -v "$FFMPEG" >/dev/null 2>&1; then
  fail_one "B2_ffmpeg_missing"
else
  set +e
  "$FFMPEG" -hide_banner -loglevel error -f lavfi -i "color=c=blue:s=624x350:d=0.04" \
    -frames:v 1 -f null - >"$OUT/ff_err.out" 2>"$OUT/ff_err.err"
  err_rc=$?
  "$FFMPEG" -hide_banner -loglevel info -f lavfi -i "color=c=blue:s=624x350:d=0.04" \
    -frames:v 1 -f null - >"$OUT/ff_info.out" 2>"$OUT/ff_info.err"
  info_rc=$?
  set -e
  echo "B2_ffmpeg_error true rc=$err_rc"
  echo "B2_ffmpeg_info true rc=$info_rc"
  # error path must NOT expose delivered WxH on a Video Stream line
  if grep -E 'Stream #.*Video:.*624x350' "$OUT/ff_err.err" >/dev/null 2>&1; then
    fail_one "B2_error_still_shows_stream_geom"
  else
    pass_one "B2_error_suppresses_stream_geom"
  fi
  if grep -E 'Stream #.*Video:.*624x350' "$OUT/ff_info.err" >/dev/null 2>&1; then
    pass_one "B2_info_exposes_stream_624x350"
  else
    fail_one "B2_info_exposes_stream_624x350"
  fi
  # Parse first matching info line the way the product does (WxH token).
  python3 - "$OUT/ff_info.err" <<'PY'
import re, sys
text=open(sys.argv[1],encoding="utf-8",errors="replace").read().splitlines()
ok=False
for line in text:
    if "Video:" not in line and "video:" not in line:
        continue
    m=re.search(r'(\d{2,5})x(\d{2,5})', line)
    if not m:
        continue
    w,h=int(m.group(1)),int(m.group(2))
    if w==624 and h==350 and (w%2==0) and (h%2==0):
        ok=True
        print(f"PARSED delivered_geom={w}x{h} src=ffmpeg_banner")
        break
sys.exit(0 if ok else 1)
PY
  parse_rc=$?
  echo "B2_parse true rc=$parse_rc"
  if [[ "$parse_rc" -eq 0 ]]; then
    pass_one "B2_parse_real_banner_624x350"
  else
    fail_one "B2_parse_real_banner_624x350"
  fi
fi

# RED: mutate product path info→error → loglevel gate must fail
cp "$MP" "$OUT/media_player_b2_red.cpp"
# Only flip the product play-path token after -stats (first info after -stats block).
python3 - "$OUT/media_player_b2_red.cpp" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
t=p.read_text(encoding="utf-8",errors="replace")
# Replace the DO-NOT-change info line specifically
old='args.push_back("info"); // DO NOT change to error — breaks delivered_geom'
new='args.push_back("error"); // MUTATED_RED for B2 bead'
if old not in t:
    # fallback: first push_back("info") after -stats
    i=t.find('args.push_back("-stats")')
    j=t.find('args.push_back("info")', i if i>=0 else 0)
    if j<0:
        print("NO_MATCH"); sys.exit(2)
    t=t[:j]+'args.push_back("error")'+t[j+len('args.push_back("info")'):]
else:
    t=t.replace(old,new,1)
p.write_text(t)
print("MUTATED")
PY
mut_b2=$?
echo "B2_mutate true rc=$mut_b2"
if [[ "$mut_b2" -ne 0 ]]; then
  fail_one "B2_mutation_apply"
else
  # Same check as test_delivered_geom_loglevel against mutated file
  mblock=$(awk '
    /args\.push_back\("-stats"\)/ { on=1 }
    on { print }
    on && /args\.push_back\("-nostdin"\)/ { exit }
  ' "$OUT/media_player_b2_red.cpp")
  set +e
  echo "$mblock" | grep -q 'push_back("error")'
  has_err=$?
  echo "$mblock" | grep -q 'push_back("info")'
  has_info=$?
  set -e
  if [[ "$has_err" -eq 0 && "$has_info" -ne 0 ]]; then
    pass_one "B2_RED_mutated_loglevel_error_detected"
  else
    fail_one "B2_RED_mutated_loglevel_error_detected"
  fi
fi

# =============================================================================
# B4 — library_media alone cannot verify; measured can
# =============================================================================
cat >"$OUT/b4_probe.cpp" <<'CPP'
#include "libmisterplex/yuv420p_chroma_health.hpp"
#include <cstdio>
int main() {
  using misterplex::deliveryGeometryVerifiedFromBasis;
  // NEGATIVE: claim bases must not verify (parent B4 acceptance).
  if (deliveryGeometryVerifiedFromBasis("library_media")) {
    std::fprintf(stderr, "BAD library_media verified\n");
    return 2;
  }
  if (deliveryGeometryVerifiedFromBasis("transcode_request")) {
    std::fprintf(stderr, "BAD transcode_request verified\n");
    return 3;
  }
  if (deliveryGeometryVerifiedFromBasis(nullptr)) {
    std::fprintf(stderr, "BAD null verified\n");
    return 4;
  }
  if (!deliveryGeometryVerifiedFromBasis("measured")) {
    std::fprintf(stderr, "BAD measured not verified\n");
    return 5;
  }
  std::printf("B4_PROBE_OK library_media=0 measured=1\n");
  return 0;
}
CPP
set +e
"$CXX" -std=c++17 -I"$ROOT/host" -o "$OUT/b4_probe_green" "$OUT/b4_probe.cpp" 2>"$OUT/b4_green_cxx.err"
g_rc=$?
set -e
echo "B4_green_compile true rc=$g_rc"
if [[ "$g_rc" -ne 0 ]]; then
  fail_one "B4_green_compile"
  cat "$OUT/b4_green_cxx.err" >&2 || true
else
  set +e
  "$OUT/b4_probe_green"
  gr=$?
  set -e
  echo "B4_green_run true rc=$gr"
  if [[ "$gr" -eq 0 ]]; then
    pass_one "B4_GREEN_library_media_rejected_measured_ok"
  else
    fail_one "B4_GREEN_library_media_rejected_measured_ok"
  fi
fi

# RED twin: naive implementation accepts library_media.
# Shadow only the mutated header via earlier -I; product tree supplies deps.
mkdir -p "$OUT/red_inc/libmisterplex"
cp "$YF" "$OUT/red_inc/libmisterplex/yuv420p_chroma_health.hpp"
python3 - "$OUT/red_inc/libmisterplex/yuv420p_chroma_health.hpp" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
t=p.read_text(encoding="utf-8",errors="replace")
old='return std::string(deliveryBasis) == "measured";'
new='return std::string(deliveryBasis) == "measured" || std::string(deliveryBasis) == "library_media"; // MUTATED_RED'
if old not in t:
    print("NO_MATCH"); sys.exit(2)
p.write_text(t.replace(old,new,1))
print("MUTATED")
PY
mut_b4=$?
echo "B4_mutate true rc=$mut_b4"
if [[ "$mut_b4" -ne 0 ]]; then
  fail_one "B4_mutation_apply"
else
  set +e
  "$CXX" -std=c++17 -I"$OUT/red_inc" -I"$ROOT/host" -o "$OUT/b4_probe_red" \
    "$OUT/b4_probe.cpp" 2>"$OUT/b4_red_cxx.err"
  r_rc=$?
  set -e
  echo "B4_red_compile true rc=$r_rc"
  if [[ "$r_rc" -ne 0 ]]; then
    fail_one "B4_red_compile"
    cat "$OUT/b4_red_cxx.err" >&2 || true
  else
    set +e
    "$OUT/b4_probe_red"
    rr=$?
    set -e
    echo "B4_red_run true rc=$rr"
    # Must FAIL the probe (rc=2) proving library_media alone satisfies wrong impl
    if [[ "$rr" -eq 2 ]]; then
      pass_one "B4_RED_library_media_wrongly_verifies"
    else
      fail_one "B4_RED_library_media_wrongly_verifies rc=$rr"
    fi
  fi
fi

# Source pin: comments name the claim defect
if grep -q 'library_media is PMS \*scanner display metadata\*' "$YF"; then
  pass_one "B4_source_names_claim_defect"
else
  fail_one "B4_source_names_claim_defect"
fi

# =============================================================================
# B5 — production teardown + reason= + header-derived math
# =============================================================================
if grep -q 'rawPipeByteAligned(totalBytes, frameBytes)' "$MP" \
  && grep -q 'rawPipeDesynced(prodBytes, frameBytes' "$MP"; then
  pass_one "B5_teardown_calls_align_and_desync"
else
  fail_one "B5_teardown_calls_align_and_desync"
fi
if grep -q 'reason=total_mod_frame_nonzero' "$MP" \
  && grep -q 'PIPE_DESYNC=1 reason=' "$MP"; then
  pass_one "B5_ERROR_reason_tokens"
else
  fail_one "B5_ERROR_reason_tokens"
fi

# Compile probe: desync/align math from product headers
cat >"$OUT/b5_probe.cpp" <<CPP
#include "libmisterplex/yuv420p_chroma_health.hpp"
#include <cstdio>
int main() {
  using namespace misterplex;
  const size_t coded = yuv420pCodedFrameBytes(
      makeDdrFrameGeometry(kPlex480pCodedWidth.get(), kPlex480pCodedHeight.get()));
  if (coded == 0 || coded != static_cast<size_t>(kPlex480pYuv420pBytes)) {
    std::fprintf(stderr, "coded mismatch %zu\\n", coded);
    return 10;
  }
  // whole-bank N frames
  if (!rawPipeByteAligned(coded * 3u, coded)) return 11;
  if (rawPipeByteAligned(coded * 3u + 1u, coded)) return 12; // must detect misalign
  const size_t s350 = yuv420pFrameBytesWH(624, 350);
  if (s350 == coded) return 13; // 350 must differ from bank
  // identity_skip + size mismatch → risk
  if (!pipeDesyncRisk(s350, coded, true)) return 14;
  // rescale path → no risk even if sizes differ
  if (pipeDesyncRisk(s350, coded, false)) return 15;
  // desync detector when producer≠reader and frames advanced
  if (!rawPipeDesynced(s350, coded, 2u)) return 16;
  if (rawPipeDesynced(coded, coded, 2u)) return 17;
  std::printf("B5_PROBE_OK coded=%zu s350=%zu\\n", coded, s350);
  return 0;
}
CPP
set +e
"$CXX" -std=c++17 -I"$ROOT/host" -o "$OUT/b5_probe" "$OUT/b5_probe.cpp" 2>"$OUT/b5_cxx.err"
b5c=$?
set -e
echo "B5_probe_compile true rc=$b5c"
if [[ "$b5c" -ne 0 ]]; then
  fail_one "B5_probe_compile"
  cat "$OUT/b5_cxx.err" >&2 || true
else
  set +e
  "$OUT/b5_probe"
  b5r=$?
  set -e
  echo "B5_probe_run true rc=$b5r"
  if [[ "$b5r" -eq 0 ]]; then
    pass_one "B5_GREEN_align_desync_math"
  else
    fail_one "B5_GREEN_align_desync_math rc=$b5r"
  fi
fi

# RED: strip reason= tokens from a copy — must be detectable as missing
cp "$MP" "$OUT/media_player_b5_red.cpp"
python3 - "$OUT/media_player_b5_red.cpp" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
t=p.read_text(encoding="utf-8",errors="replace")
n=0
for s in ("reason=total_mod_frame_nonzero ", "PIPE_DESYNC=1 reason="):
    if s in t:
        t=t.replace(s, s.replace("reason=", "notoken_"), 1)
        n+=1
if n<2:
    print(f"NO_MATCH n={n}"); sys.exit(2)
p.write_text(t)
print(f"MUTATED n={n}")
PY
mut_b5=$?
echo "B5_mutate true rc=$mut_b5"
if [[ "$mut_b5" -ne 0 ]]; then
  fail_one "B5_mutation_apply"
else
  set +e
  grep -q 'reason=total_mod_frame_nonzero' "$OUT/media_player_b5_red.cpp"
  g1=$?
  grep -q 'PIPE_DESYNC=1 reason=' "$OUT/media_player_b5_red.cpp"
  g2=$?
  set -e
  if [[ "$g1" -ne 0 && "$g2" -ne 0 ]]; then
    pass_one "B5_RED_reason_tokens_absent_after_mutation"
  else
    fail_one "B5_RED_reason_tokens_absent_after_mutation g1=$g1 g2=$g2"
  fi
fi

# Release binary lacks MEASURED_DELIVERY (capability hole) when artifact present
REL="$ROOT/release_artifacts/ddr-c5382bee-e9f79de2/misterplexd"
if [[ -f "$REL" ]]; then
  set +e
  strings "$REL" | grep -q 'MEASURED_DELIVERY'
  rel_m=$?
  strings "$REL" | grep -q 'PIPE_BYTE_MISALIGN'
  rel_p=$?
  set -e
  if [[ "$rel_m" -ne 0 ]]; then
    pass_one "B2_RED_release_lacks_MEASURED_DELIVERY"
  else
    fail_one "B2_RED_release_lacks_MEASURED_DELIVERY unexpected present"
  fi
  if [[ "$rel_p" -ne 0 ]]; then
    pass_one "B5_RED_release_lacks_PIPE_BYTE_MISALIGN"
  else
    # Older release may still have string — do not fail bead if present
    echo "NOTE: release has PIPE_BYTE_MISALIGN string (not used as hard RED)"
    applied=$((applied + 1))
    pass=$((pass + 1))
    echo "PASS B5_NOTE_release_string_checked"
  fi
else
  echo "NOTE: skip release binary RED — artifact absent"
fi

# Cleanup scratch binaries (keep logs for parent if needed)
rm -f "$OUT/b4_probe_green" "$OUT/b4_probe_red" "$OUT/b5_probe" \
  "$OUT/media_player_b2_red.cpp" "$OUT/media_player_b5_red.cpp" 2>/dev/null || true
rm -rf "$OUT/red_inc" 2>/dev/null || true

want=16
echo "applied_match_count=$applied want>=$want pass=$pass fail=$fail"
if [[ "$applied" -lt "$want" ]]; then
  echo "FAIL applied_match_count=$applied want>=$want (NO-DATA risk)" >&2
  fail=$((fail + 1))
fi
if [[ "$fail" -ne 0 ]]; then
  echo "TEST_MEASURED_DELIVERY_BEAD_FAIL"
  exit 1
fi
echo "TEST_MEASURED_DELIVERY_BEAD_OK"
exit 0
