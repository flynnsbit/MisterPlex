#!/usr/bin/env python3
"""Unit coverage for scripts/score_idle_screen.py.

Every green ships with its red.  The chevron detector must reject content that
is merely non-black, and the black verdict must not be attributable to the core
when the source host is down.

Calibration facts measured on the lab rig (534d:2109 -> /dev/video0):
  * The live Plex idle screen produced 14928 px of RGB(244,163,2) (Plex brand
    orange #E5A00D) in a bbox of 484,239..707,479 on a 1280x720 capture.
  * With the MiSTer powered off and unreachable, the capture device still
    delivered frames and they were flat RGB(7,7,7) -- identical to a black
    core.  Luma alone cannot separate those two causes.
"""
from __future__ import annotations

import importlib.util
import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
SCORER = ROOT / "scripts" / "score_idle_screen.py"
WORK = ROOT / "build" / "idle-screen-unit"

spec = importlib.util.spec_from_file_location("score_idle_screen", SCORER)
sis = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(sis)

H, W = 720, 1280


def require(ok: bool, msg: str) -> None:
    if not ok:
        raise AssertionError(msg)


def save(name: str, arr: np.ndarray) -> Path:
    WORK.mkdir(parents=True, exist_ok=True)
    p = WORK / name
    Image.fromarray(arr.astype(np.uint8)).save(p)
    return p


def bg_frame() -> np.ndarray:
    """Non-black textured background, no orange anywhere."""
    rng = np.random.default_rng(7)
    base = np.full((H, W, 3), (34, 40, 42), dtype=np.int64)
    base += rng.integers(0, 60, size=(H, W, 1))
    return np.clip(base, 0, 255)


def chevron_frame() -> np.ndarray:
    """Background plus a centred Plex-orange blob of realistic size."""
    f = bg_frame()
    f[239:480, 484:708] = (244, 163, 2)
    return f


def run(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run([sys.executable, str(SCORER), *args],
                          cwd=ROOT, capture_output=True, text=True, timeout=60)


def main() -> int:
    WORK.mkdir(parents=True, exist_ok=True)

    # Value 2, NOT 7: RGB(7,7,7) is the MS2109's no-lock filler and is now
    # correctly graded NO_SIGNAL/REFUSE rather than "the core paints black".
    black = save("black.png", np.full((H, W, 3), 2))
    plain = save("plain.png", bg_frame())
    chev = save("chevron.png", chevron_frame())
    flood = save("flood.png", np.full((H, W, 3), (244, 163, 2)))

    # GREEN: chevron frame passes with --expect-chevron
    r = run("--input", str(chev), "--expect-chevron", "--out-dir", str(WORK / "g1"))
    require(r.returncode == 0, f"chevron frame should PASS, rc={r.returncode}\n{r.stdout}{r.stderr}")
    require("PLEX_CHEVRON: PRESENT" in r.stdout, f"chevron not detected:\n{r.stdout}")
    print("PASS centred Plex-orange chevron detected -> rc=0")

    # RED: non-black content WITHOUT a chevron must fail --expect-chevron.
    # This is the anti-vacuity check: "not black" must not be enough.
    r = run("--input", str(plain), "--expect-chevron", "--out-dir", str(WORK / "r1"))
    require(r.returncode == 1,
            f"content-without-chevron must FAIL, rc={r.returncode}\n{r.stdout}{r.stderr}")
    require("PLEX_CHEVRON: ABSENT" in r.stdout, f"expected ABSENT chevron:\n{r.stdout}")
    print("PASS non-black content without a chevron rejected -> rc=1 (detector is not vacuous)")

    # Same frame WITHOUT --expect-chevron passes: proves the failure above was
    # caused by the chevron requirement and not by some unrelated refusal.
    r = run("--input", str(plain), "--out-dir", str(WORK / "r1b"))
    require(r.returncode == 0,
            f"content without chevron requirement should PASS, rc={r.returncode}\n{r.stderr}")
    print("PASS same frame passes without --expect-chevron (failure was chevron-specific)")

    # RED: an all-orange flood is not a logo.
    r = run("--input", str(flood), "--expect-chevron", "--out-dir", str(WORK / "r2"))
    require(r.returncode != 0, f"orange flood must not PASS as a chevron, rc={r.returncode}\n{r.stdout}")
    print("PASS full-screen orange flood rejected as a chevron")

    # RED: black frame fails when no host probe is requested.
    r = run("--input", str(black), "--out-dir", str(WORK / "r3"))
    require(r.returncode == 1, f"black frame must FAIL rc=1, got {r.returncode}\n{r.stdout}{r.stderr}")
    require("BLACK" in r.stderr.upper(), f"black not reported:\n{r.stderr}")
    print("PASS black frame -> rc=1 FAIL")

    # RED: black frame with an unreachable source host must REFUSE (UNSCORED),
    # never FAIL -- a powered-off MiSTer is not evidence of a core defect.
    r = run("--input", str(black), "--host", "192.0.2.1", "--out-dir", str(WORK / "r4"))
    require(r.returncode == 2,
            f"black + dead host must REFUSE rc=2, got {r.returncode}\n{r.stdout}{r.stderr}")
    require("UNSCORED" in r.stderr, f"expected UNSCORED refusal:\n{r.stderr}")
    print("PASS black + unreachable source host -> rc=2 REFUSE (not blamed on the core)")

    # Missing input refuses rather than silently passing.
    r = run("--input", str(WORK / "does-not-exist.png"), "--out-dir", str(WORK / "r5"))
    require(r.returncode == 2, f"missing input must REFUSE rc=2, got {r.returncode}")
    print("PASS missing input -> rc=2 REFUSE (never a silent 0)")

    # Left-edge artifact metric: measured, and correctly quiet on a clean frame.
    edge = sis.score_left_edge(chevron_frame().astype(np.uint8))
    require(edge["measurable"] and not edge["present"],
            f"synthetic clean frame should have no left-edge artifact: {edge}")
    dirty = chevron_frame()
    rng = np.random.default_rng(3)
    for y in range(0, H, 3):
        dirty[y, 84:200] = 0
    edge2 = sis.score_left_edge(dirty.astype(np.uint8))
    require(edge2["present"], f"planted left-edge streaks not detected: {edge2}")
    print(f"PASS left-edge artifact metric red/green (clean ratio "
          f"{edge['ratio']} vs planted {edge2['ratio']})")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
