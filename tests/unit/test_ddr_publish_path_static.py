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
want_contexts = ["idle DDR", "recon DDR", "playback DDR"]
if contexts != want_contexts:
    fail(f"expected publish contexts {want_contexts}, saw {contexts}")

if src.count("nextDdrPresentBank(ddrBank_, ok)") != 1:
    fail("central publish helper must be the only place that advances ddrBank_")

print("test_ddr_publish_path_static: OK 3 DDR call sites use centralized publishDdrFrame")
