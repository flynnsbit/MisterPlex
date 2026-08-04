#!/usr/bin/env python3
"""Publish-path honesty: centralized DDR publish + product 720p geometry.

POSITIVE:
  - MediaPlayer::publishDdrFrame is the only bank-advance site
  - idle / recon / playback contexts are present
  - idle DDR geometry is productDdrFrameStoreGeometry() (1280×720), not plex480p

NEGATIVE (red twin):
  - Idle paint that binds plex480pDdrFrameGeometry() must fail this gate
    (regresses product doorbell/bank vs RTL CODED_W=1280).
"""
from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MEDIA = ROOT / "arm" / "misterplexd" / "media_player.cpp"
HOST = ROOT / "host" / "libmisterplex" / "ddr_frame_layout.hpp"


def fail(msg: str) -> None:
    print(f"FAIL ddr_publish_path_static: {msg}", file=sys.stderr)
    sys.exit(1)


def check_publish_centralization(src: str) -> None:
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
    if "wantSkipRgbVideo" not in src:
        fail("STREAM_SKIP_RGB path must exist (skip RGB → recon-only F1)")


def idle_geometry_helpers(src: str) -> list[str]:
    """Return geometry helper names used in the idle DDR paint block."""
    # Narrow window: from idle paint branch through first idle publishDdrFrame call.
    m = re.search(
        r"if\s*\(\s*useDdrF1_\s*\)\s*\{(.*?publishDdrFrame\(frame,\s*\"idle DDR\")",
        src,
        flags=re.S,
    )
    if not m:
        return []
    block = m.group(1)
    return re.findall(
        r"\b(productDdrFrameStoreGeometry|plex480pDdrFrameGeometry|"
        r"ddrFrameGeometryForFpgaPresent|plex720pDdrFrameGeometry)\s*\(",
        block,
    )


def check_idle_product_720p_geometry(src: str) -> None:
    helpers = idle_geometry_helpers(src)
    if not helpers:
        fail("could not locate idle DDR geometry helper before publishDdrFrame(\"idle DDR\")")
    if "plex480pDdrFrameGeometry" in helpers:
        fail(
            "idle DDR still uses plex480pDdrFrameGeometry() — product silicon is "
            "1280×720 (productDdrFrameStoreGeometry); 480p idle shears doorbell/bank"
        )
    if "productDdrFrameStoreGeometry" not in helpers and "plex720pDdrFrameGeometry" not in helpers:
        fail(
            f"idle DDR must bind product 720p geometry; saw helpers={helpers}"
        )

    # Host product helper must still alias 720p (publish-path honesty SSOT).
    host = HOST.read_text(encoding="utf-8", errors="replace")
    host_nt = re.sub(r"\s+", "", host)
    if "inlineDdrFrameGeometryproductDdrFrameStoreGeometry(){returnplex720pDdrFrameGeometry();}" not in host_nt:
        fail("productDdrFrameStoreGeometry() must return plex720pDdrFrameGeometry()")
    if "kPlex720pCodedWidth{1280}" not in host_nt:
        fail("host kPlex720pCodedWidth must be 1280")


def red_twin_idle_480p_must_fail(src: str) -> None:
    """Inject legacy 480p idle geometry; positive geometry check must go red."""
    helpers = idle_geometry_helpers(src)
    if "productDdrFrameStoreGeometry" not in helpers and "plex720pDdrFrameGeometry" not in helpers:
        fail("red twin setup requires positive idle product geometry first")

    red = src
    if "productDdrFrameStoreGeometry" in helpers:
        red = red.replace(
            "productDdrFrameStoreGeometry()",
            "plex480pDdrFrameGeometry()",
            1,  # first hit is idle path (recon uses ddrFrameGeometryForFpgaPresent)
        )
    else:
        red = red.replace(
            "plex720pDdrFrameGeometry()",
            "plex480pDdrFrameGeometry()",
            1,
        )

    red_helpers = idle_geometry_helpers(red)
    if "plex480pDdrFrameGeometry" not in red_helpers:
        fail(f"red twin inject failed; helpers={red_helpers}")

    # Simulate the fail-closed predicate without exiting the process.
    would_fail = "plex480pDdrFrameGeometry" in red_helpers
    if not would_fail:
        fail("red twin idle 480p would not fail this gate (vacuous)")
    # Positive source must not already be red.
    if "plex480pDdrFrameGeometry" in helpers:
        fail("positive idle path already red (plex480p)")


def main() -> int:
    src = MEDIA.read_text(encoding="utf-8", errors="replace")
    check_publish_centralization(src)
    check_idle_product_720p_geometry(src)
    red_twin_idle_480p_must_fail(src)

    contexts = re.findall(r'publishDdrFrame\(frame,\s*"([^"]+)"', src)
    helpers = idle_geometry_helpers(src)
    print(
        "test_ddr_publish_path_static: OK "
        f"publish_call_sites={len(contexts)} contexts={','.join(contexts)} "
        f"idle_geom={','.join(helpers)} "
        "use centralized publishDdrFrame + lastPublishedBank; "
        "STREAM0=playback DDR STREAM1=recon DDR idle=idle DDR; "
        "idle productDdr 720p; red twin idle plex480p fails"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
