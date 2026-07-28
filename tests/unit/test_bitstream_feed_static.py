#!/usr/bin/env python3
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
MEDIA = ROOT / "arm" / "misterplexd" / "media_player.cpp"
HEADER = ROOT / "arm" / "misterplexd" / "media_player.hpp"
MAIN = ROOT / "arm" / "misterplexd" / "main.cpp"

checks: list[tuple[str, bool]] = []


def check(name: str, ok: bool) -> None:
    checks.append((name, ok))


media = MEDIA.read_text()
header = HEADER.read_text()
main = MAIN.read_text()

check("main parses BITSTREAM_FEED", 'loadConf(confPath, "BITSTREAM_FEED")' in main)
check("main applies setBitstreamFeedEnabled", "player.setBitstreamFeedEnabled" in main)
check("header exposes bitstreamFeedPump", "void bitstreamFeedPump(int sfd);" in header)
check("header extends spawnFfmpeg fd4", "int bitstreamWriteFd = -1" in header)
check("STREAM0 feed defaults enabled", "bool bitstreamFeedEnabled_ = true" in header)
check("copy-safe H264 guard exists", "canCopyH264ElementaryForFpga" in media)
check("STREAM0 feed excludes STREAM=1", "bitstreamFeedEnabled_ && !streamEnabled_" in media)
check("single ffmpeg uses pipe4 for elementary stream", 'args.push_back("pipe:4")' in media)
check("compressed output uses copy codec", 'args.push_back("-c:v");' in media and 'args.push_back("copy");' in media)
check("mp4/container output converts to Annex-B", "h264_mp4toannexb" in media)
check("spawnFfmpeg dup2s bitstream fd4", "dup2(bitstreamWriteFd, 4)" in media)
check("spawnFfmpeg keeps fd4 only when enabled", "bitstreamWriteFd >= 0 && fd == 4" in media)
check("product path starts feed pump thread", "bitstreamFeedPump(sfd)" in media)
check("feed pump uses AnnexBFramer", "h264stream::AnnexBFramer framer" in media)
check("feed pump drains after fatal", "draining pipe so raw present does not block" in media)
check("feed logs bytes per VCL", "bytes_per_vcl=" in media)
check("feed logs CPU cost per VCL", "feed_cpu_us_per_vcl=" in media)

print(f"Scope: {len(checks)}", flush=True)
if not checks:
    print("FAIL bitstream_feed_static: Scope: 0 cannot claim PASS", file=sys.stderr)
    sys.exit(1)

failed = [name for name, ok in checks if not ok]
if failed:
    for name in failed:
        print(f"FAIL bitstream_feed_static: {name}", file=sys.stderr)
    sys.exit(1)

print("test_bitstream_feed_static: PASS")
