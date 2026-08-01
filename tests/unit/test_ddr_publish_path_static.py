#!/usr/bin/env python3
from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[2]
MEDIA = ROOT / "arm" / "misterplexd" / "media_player.cpp"


def fail(msg: str) -> None:
    print(f"FAIL ddr_publish_path_static: {msg}", file=sys.stderr)
    sys.exit(1)


src = MEDIA.read_text()

if re.search(r"ddrBank_\s*\^=", src):
    fail("found direct ddrBank_ ^= outside the centralized publishDdrFrame helper")

if len(re.findall(r"bool\s+MediaPlayer::publishDdrFrame\s*\(", src)) != 1:
    fail("expected exactly one MediaPlayer::publishDdrFrame definition")

contexts = re.findall(r'publishDdrFrame\(frame,\s*"([^"]+)"', src)
want_contexts = ["pause overlay DDR", "idle DDR", "recon DDR", "playback DDR"]
if contexts != want_contexts:
    fail(f"expected publish contexts {want_contexts}, saw {contexts}")

if src.count("nextDdrPresentBank(") != 1:
    fail("central publish helper must be the only place that advances ddrBank_")
if "lastPublishedBank()" not in src:
    fail("publishDdrFrame must advance ddrBank_ from lastPublishedBank() (PLXD may override hint)")

# Product cast path (STREAM=0): FFmpeg rawvideo → "playback DDR" every frame.
# Must not be gated behind STREAM=1 host recon only.
if 'log("media: STREAM=0 rawvideo("' not in src and "media: STREAM=0 rawvideo(" not in src:
    fail("STREAM=0 path must log rawvideo→F1 (cast product present path)")
if "const bool reconOwnsF1 = streamEnabled_ && reconPresentOk_.load();" not in src:
    fail("playback DDR must be gated by reconOwnsF1 so STREAM=0 always presents")
if "packYuv420pCenteredIntoCodedBank" not in src:
    fail("recon DDR path must center-pack into silicon coded bank")
# STREAM=1 skip-RGB: no "playback DDR" frames; F1 only via recon (keyframe rate).
if "wantSkipRgbVideo" not in src:
    fail("STREAM_SKIP_RGB path must exist (skip RGB → recon-only F1)")

print(
    "test_ddr_publish_path_static: OK "
    f"publish_call_sites={len(contexts)} contexts={','.join(contexts)} "
    "use centralized publishDdrFrame + lastPublishedBank; "
    "STREAM0=playback DDR STREAM1=recon DDR idle=idle DDR pause=pause overlay DDR"
)
