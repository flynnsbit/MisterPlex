#!/usr/bin/env python3
from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[2]
MEDIA = ROOT / "arm" / "misterplexd" / "media_player.cpp"
FPGA_SPI = ROOT / "arm" / "misterplexd" / "fpga_spi.cpp"


def fail(msg: str) -> None:
    print(f"FAIL ddr_publish_path_static: {msg}", file=sys.stderr)
    sys.exit(1)


src = MEDIA.read_text()

if re.search(r"ddrBank_\s*\^=", src):
    fail("found direct ddrBank_ ^= outside the centralized publishDdrFrame helper")

if len(re.findall(r"bool\s+MediaPlayer::publishDdrFrame\s*\(", src)) != 1:
    fail("expected exactly one MediaPlayer::publishDdrFrame definition")

contexts = re.findall(r'publishDdrFrame\(frame,\s*"([^"]+)"', src)
want_contexts = ["idle DDR", "recon DDR", "playback DDR"]
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

# rd-duck: plan.plxg_q must reach writePlxgRecord on the sendDdrFrame hot path
# (not plan-only / helper-only). Hollow 1465a7ea class: fields filled, never read.
spi = FPGA_SPI.read_text()
if not re.search(r"writePlxgRecord\s*\(\s*plan\.plxg_q", spi):
    fail("sendDdrFrame must call writePlxgRecord(plan.plxg_q, ...) before kick")
# writePlxgQ5 body must be pending-only (no wire store at doorbell+0x828).
m_q5 = re.search(r"bool\s+FpgaSpi::writePlxgQ5\s*\([\s\S]*?\n\}", spi)
if not m_q5 or "plxgQ5Pending_" not in m_q5.group(0):
    fail("writePlxgQ5 must be pending-only (inject on publish), not wire poke")
if "attachLabPublishMaps" not in spi:
    fail("lab publish maps hook required for host FpgaSpi::publishDdrFrame integration")

print(
    "test_ddr_publish_path_static: OK "
    f"publish_call_sites={len(contexts)} contexts={','.join(contexts)} "
    "use centralized publishDdrFrame + lastPublishedBank; "
    "STREAM0=playback DDR STREAM1=recon DDR idle=idle DDR; "
    "sendDdrFrame=writePlxgRecord(plan.plxg_q)"
)
