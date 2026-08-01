#!/usr/bin/env bash
# RED twin: static geometry contract must FAIL against main's media_player.cpp.
# Proves the gate detects the defect (PresentedSize(DECODE) + Yuv empty break).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$ROOT/.agent-work/w-osd-hires/red-main-gate"
mkdir -p "$TMP"
git -C "$ROOT" show main:arm/misterplexd/media_player.cpp >"$TMP/media_player.cpp"
python3 - "$TMP/media_player.cpp" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
fails = []
if "ddrFrameGeometryForFpgaPresent(outW_, outH_)" not in src:
    fails.append("missing ddrFrameGeometryForFpgaPresent")
if re.search(r"ddrFrameGeometryForPresentedSize\(\s*outW_\s*,\s*outH_\s*\)", src):
    fails.append("PresentedSize(outW_) DECODE identity")
ro = re.search(
    r"auto\s+renderOverlay\s*=\s*\[\&\]\s*\(uint8_t\*\s*data\)\s*\{(.*?)\}\s*;",
    src,
    re.S,
)
if not ro:
    fails.append("missing renderOverlay")
else:
    y = re.search(
        r"case\s+RawVideoFormat::Yuv420p\s*:\s*(.*?)break\s*;", ro.group(1), re.S
    )
    if not y or "renderYuv420p" not in y.group(1):
        fails.append("Yuv420p empty break (no renderYuv420p)")
if not fails:
    print("FAIL red-main: main unexpectedly satisfies post-upscale contract", file=sys.stderr)
    sys.exit(1)
print("RED_OK main fails post-upscale contract:", "; ".join(fails))
sys.exit(0)
PY
