#!/usr/bin/env python3
"""Offline red-proof of the capture gate across ALL three screen states.

Parent directive (2026-07-28): while the MiSTer is unreachable, red-prove the
capture gate offline against synthetic no-signal / black / content inputs so
that the moment hardware returns we get a scored answer in one shot.

This drives the REAL CLI of ``scripts/score_idle_screen.py`` end to end with
synthetic frames — not its internal functions — because the exit code is the
contract other workers consume.  Every state is asserted against its exit code:

    0 PASS    valid signal with picture content
    1 FAIL    attributable defect (black with a reachable source; missing chevron)
    2 REFUSE  unscoreable (no signal, frozen, black with a dead source,
              unverifiable provenance)

The trap this exists to prevent: "capture succeeded" and "the screen is black"
are simultaneously true, so a gate that only proves capture worked proves
nothing.  Each REFUSE case below would be a silent false PASS in a naive gate.

Host reachability is exercised with real addresses rather than mocks:
127.0.0.1 is reachable, 192.0.2.1 is TEST-NET-1 (RFC 5737) and is guaranteed
unroutable, which is exactly the powered-off-MiSTer condition.
"""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "score_idle_screen.py"

UNREACHABLE = "192.0.2.1"   # RFC 5737 TEST-NET-1
REACHABLE = "127.0.0.1"

failures: list[str] = []
checks = 0

H, W = 720, 1280


def check(name: str, cond: bool, detail: str = "") -> None:
    global checks
    checks += 1
    if cond:
        print(f"PASS {name}")
    else:
        print(f"FAIL {name} {detail}")
        failures.append(name)


def save(frames: list[np.ndarray], d: Path, tag: str) -> list[str]:
    paths = []
    for i, f in enumerate(frames):
        p = d / f"{tag}_{i:02d}.png"
        Image.fromarray(f.astype(np.uint8)).save(p)
        paths.append(str(p))
    return paths


def flat(value: int, n: int = 4) -> list[np.ndarray]:
    return [np.full((H, W, 3), value, dtype=np.uint8) for _ in range(n)]


def content(n: int = 4, seed: int = 3, chevron: bool = False,
            artifact: bool = False, text_column: bool = False,
            sparse_block: bool = False) -> list[np.ndarray]:
    """Frames with genuine spatial structure and frame-to-frame variation."""
    out = []
    rng = np.random.default_rng(seed)
    base = np.zeros((H, W, 3), dtype=np.float64)
    base[..., 0] = np.linspace(20, 200, W)[None, :]
    base[..., 1] = np.linspace(180, 20, W)[None, :]
    base[..., 2] = np.linspace(60, 140, H)[:, None]
    if chevron:
        # Plex-orange chevron blob, vertically centred, >= CHEVRON_MIN_PX.
        yy, xx = np.mgrid[0:H, 0:W]
        arm = (np.abs((yy - 360)) > 0) & (np.abs(xx - 480 - np.abs(yy - 360)) < 42)
        blob = arm & (np.abs(yy - 360) < 130)
        base[blob] = [244, 163, 2]
    if text_column:
        # REGRESSION: the MiSTer main menu is a full-height column of orange
        # text.  It satisfies colour, pixel count and centroid, and this gate
        # scored it "PLEX_CHEVRON: PRESENT" on a live MENU capture
        # (bbox 119x720, aspect 0.165, fill 0.105).  Shape gates must reject it.
        yy, xx = np.mgrid[0:H, 0:W]
        col = (np.abs(xx - 430) < 60) & (yy % 24 < 11)
        base[col] = [244, 163, 2]
    if sparse_block:
        # Roughly SQUARE, centred block of orange text lines: passes the
        # colour, count, centroid AND aspect gates, and is separated from a
        # solid logo only by fill density.  Without this case the fill gate
        # is unexercised -- mutation testing caught exactly that.
        yy, xx = np.mgrid[0:H, 0:W]
        blk = (np.abs(xx - 640) < 120) & (np.abs(yy - 360) < 120) & (yy % 16 < 2)
        base[blk] = [244, 163, 2]
    for i in range(n):
        f = base + rng.normal(0, 4, base.shape)
        if artifact:
            # Dark ragged streaks confined to the known left-edge band.
            for r in range(30, H - 30, 7):
                w = int(rng.integers(20, 110))
                f[r:r + 3, 84:84 + w] = 0
        out.append(np.clip(f, 0, 255).astype(np.uint8))
    return out


def inputs(paths: list[str]) -> list[str]:
    """--input is action="append": one value per flag."""
    out = []
    for p in paths:
        out += ["--input", p]
    return out


def run(args: list[str], d: Path, env: dict | None = None) -> subprocess.CompletedProcess:
    r = subprocess.run(
        [sys.executable, str(GATE), "--out-dir", str(d / "out")] + args,
        capture_output=True, text=True, env=env)
    # argparse exits 2 on a usage error, which collides with EXIT_REFUSE.  A
    # test that accepted rc=2 blindly would go green on a command-line typo --
    # that happened during development of this file.
    if "usage:" in r.stderr and "error:" in r.stderr:
        raise AssertionError(f"gate rejected the command line, not the pixels:\n{r.stderr[:400]}")
    return r


def fake_sshpass(d: Path, corename: str, md5: str, rbf_mtime: int,
                 load_mtime: int) -> dict:
    """PATH shim so the gate's real ssh probe returns controlled identity.

    Stubbing at the process boundary keeps the gate's own parsing and ordering
    logic under test; mocking loaded_core_identity() would test nothing but the
    mock.
    """
    bindir = d / f"bin_{corename}_{load_mtime}"
    bindir.mkdir(parents=True, exist_ok=True)
    shim = bindir / "sshpass"
    shim.write_text(
        "#!/bin/sh\n"
        f"echo 'CORENAME={corename}'\n"
        f"echo 'RBFMD5={md5}'\n"
        f"echo 'RBFMTIME={rbf_mtime}'\n"
        f"echo 'LOADMTIME={load_mtime}'\n"
        "echo 'UPTIME=1234'\n")
    shim.chmod(0o755)
    env = dict(os.environ)
    env["PATH"] = f"{bindir}{os.pathsep}{env.get('PATH', '')}"
    return env


def main() -> int:
    check("gate exists", GATE.exists(), str(GATE))
    if not GATE.exists():
        print(f"\n{checks - len(failures)}/{checks} checks passed")
        return 1

    # Confirm the reachability oracle itself works, or the host-attribution
    # cases below would be vacuous.
    lo = subprocess.run(["ping", "-c", "1", "-W", "2", REACHABLE],
                        capture_output=True)
    check("loopback is reachable (host probe is live, not mocked)",
          lo.returncode == 0, "ping 127.0.0.1 failed")
    un = subprocess.run(["ping", "-c", "1", "-W", "2", UNREACHABLE],
                        capture_output=True)
    check("TEST-NET-1 is unreachable (dead-source condition is real)",
          un.returncode != 0, "192.0.2.1 unexpectedly answered")

    with tempfile.TemporaryDirectory(dir=str(ROOT / "artifacts")) as td:
        d = Path(td)

        # 1. NO SIGNAL — solid non-black frame.
        p = save(flat(80), d, "nosig")
        r = run(inputs(p), d)
        check("NO_SIGNAL refuses (rc=2)", r.returncode == 2, f"rc={r.returncode}")
        check("NO_SIGNAL names the state", "NO_SIGNAL" in r.stdout)
        check("NO_SIGNAL is explicitly not a pass",
              "not a pass" in (r.stdout + r.stderr).lower())

        # 1b. NO-LOCK FILLER — the MS2109 paints exact RGB(7,7,7) where it has
        # no locked video.  That value is below the black threshold, so before
        # the filler test existed this scored "FAIL: the screen is BLACK ...
        # attributable to the core" on a live capture that was simply mid
        # re-lock after a core load.  It must REFUSE, and must NOT be black.
        p = save(flat(7), d, "filler")
        r = run(inputs(p) + ["--host", REACHABLE], d)
        check("MS2109 no-lock filler REFUSES (rc=2) even with a reachable host",
              r.returncode == 2, f"rc={r.returncode} {r.stdout[-300:]}")
        check("filler is reported as NO_SIGNAL, not BLACK_SIGNAL",
              "NO_SIGNAL" in r.stdout and "BLACK_SIGNAL" not in r.stdout, r.stdout)
        check("filler refusal names the filler explicitly",
              "no-lock filler" in r.stdout, r.stdout)

        # 2. BLACK + dead source — the misdiagnosis this tool exists to prevent.
        # Value 3, NOT 7: 7 is the capture device's filler and is now handled
        # above as a lock failure rather than as a black screen.
        p = save(flat(3), d, "blk")
        r = run(inputs(p) + ["--host", UNREACHABLE], d)
        check("BLACK + unreachable host refuses (rc=2)", r.returncode == 2,
              f"rc={r.returncode}")
        check("BLACK + unreachable host is NOT blamed on the core",
              "NOT evidence of a core defect" in r.stderr, r.stderr[:200])

        # 3. BLACK + live source — now it IS attributable.
        r = run(inputs(p) + ["--host", REACHABLE], d)
        check("BLACK + reachable host FAILS (rc=1)", r.returncode == 1,
              f"rc={r.returncode}")
        check("BLACK + reachable host is attributed to the core",
              "attributable" in r.stdout, r.stdout[-200:])

        # 4. Frozen picture of real content.
        one = content(1)[0]
        p = save([one, one.copy(), one.copy(), one.copy()], d, "stale")
        r = run(inputs(p) + ["--host", REACHABLE], d)
        check("STALE_CAPTURE refuses (rc=2)", r.returncode == 2, f"rc={r.returncode}")
        check("STALE names the state", "STALE_CAPTURE" in r.stdout)

        # 5. Real content.
        p = save(content(), d, "cont")
        r = run(inputs(p) + ["--host", REACHABLE], d)
        check("CONTENT passes (rc=0)", r.returncode == 0,
              f"rc={r.returncode} {r.stdout[-300:]}{r.stderr[-300:]}")
        check("CONTENT names the state", "CONTENT_PRESENT" in r.stdout)

        # 6. Content WITHOUT a chevron must fail --expect-chevron.  This is the
        #    red for case 7: without it, 7 could pass by never checking.
        r = run(inputs(p) + ["--host", REACHABLE, "--expect-chevron"], d)
        check("CONTENT without chevron FAILS --expect-chevron (rc=1)",
              r.returncode == 1, f"rc={r.returncode}")

        # 7. Content WITH a chevron must satisfy --expect-chevron.
        pc = save(content(chevron=True, seed=9), d, "chev")
        r = run(inputs(pc) + ["--host", REACHABLE, "--expect-chevron"], d)
        check("CONTENT with chevron passes --expect-chevron (rc=0)",
              r.returncode == 0, f"rc={r.returncode} {r.stdout[-300:]}")
        check("chevron reported PRESENT", "PLEX_CHEVRON: PRESENT" in r.stdout)

        # 7b. REGRESSION -- a full-height orange text column (the MiSTer main
        # menu) must NOT be mistaken for the Plex chevron.  Measured live:
        # MENU scored PRESENT before the aspect/fill gates were added.
        pt = save(content(chevron=False, text_column=True, seed=11), d, "menucol")
        r = run(inputs(pt) + ["--host", REACHABLE], d)
        check("orange text column is NOT reported as a chevron",
              "PLEX_CHEVRON: ABSENT" in r.stdout, r.stdout.strip().splitlines()[-2:])
        check("text column rejected on shape, not on colour or count",
              "aspect" in r.stdout or "fill" in r.stdout, r.stdout)
        r = run(inputs(pt) + ["--host", REACHABLE, "--expect-chevron"], d)
        check("orange text column FAILS --expect-chevron (rc=1)",
              r.returncode == 1, f"rc={r.returncode}")

        # 7c. A square, centred but SPARSE orange block clears colour, count,
        # centroid and aspect; only fill density separates it from a logo.
        ps = save(content(chevron=False, sparse_block=True, seed=13), d, "sparse")
        r = run(inputs(ps) + ["--host", REACHABLE], d)
        check("sparse square orange block is NOT a chevron",
              "PLEX_CHEVRON: ABSENT" in r.stdout, r.stdout.strip().splitlines()[-2:])
        check("sparse block rejected specifically on fill density",
              "fills only" in r.stdout, r.stdout)

        # 8. Left-edge artifact detection, with its clean control.
        pa = save(content(artifact=True, seed=5), d, "art")
        r = run(inputs(pa) + ["--host", REACHABLE], d)
        check("left-edge artifact detected", "LEFT_EDGE_ARTIFACT: PRESENT" in r.stdout,
              r.stdout[-300:])
        r = run(inputs(p) + ["--host", REACHABLE], d)
        check("clean frames report no left-edge artifact",
              "LEFT_EDGE_ARTIFACT: clean" in r.stdout, r.stdout[-300:])

        # 9. Provenance must be verified BEFORE pixels, and must refuse when it
        #    cannot be. Content frames here would otherwise PASS, so a rc=2
        #    proves provenance gates ahead of grading.
        r = run(inputs(pc) + ["--host", UNREACHABLE,
                 "--expect-corename", "Plex"], d)
        check("unverifiable provenance refuses (rc=2) even with good pixels",
              r.returncode == 2, f"rc={r.returncode}")
        check("provenance refusal says UNSCORED",
              "UNSCORED" in r.stderr, r.stderr[:200])

        # 10. Provenance flags without --host is a usage refusal, not a pass.
        r = run(inputs(pc) + ["--expect-corename", "Plex"], d)
        check("--expect-corename without --host refuses (rc=2)",
              r.returncode == 2, f"rc={r.returncode}")

        # 11. FABRIC vs FILE (w-e2e handoff, 2026-07-28).  `scripts/deploy_plex_core.sh`
        #     defaults to DEPLOY_LOAD=none: it rewrites the RBF and does NOT load it.
        #     The md5 of the FILE then matches the build under test while the fabric
        #     still runs the previous bitstream and paints every pixel we grade.
        #     These frames are CONTENT, so without the ordering check the gate
        #     returns a confident PASS attributed to the wrong build.
        MD5 = "3b1e8435aaaaaaaaaaaaaaaaaaaaaaaa"
        env_bad = fake_sshpass(d, "Plex", MD5, rbf_mtime=2000, load_mtime=1000)
        prov = ["--host", REACHABLE, "--expect-corename", "Plex",
                "--expect-rbf-md5", "3b1e8435"]

        r = run(inputs(pc) + prov, d, env=env_bad)
        check("file-only md5 check PASSES the stale fabric (the bug being fixed)",
              r.returncode == 0, f"rc={r.returncode} {r.stderr[:200]}")

        r = run(inputs(pc) + prov + ["--require-fabric-provenance"], d, env=env_bad)
        check("RBF written AFTER core load refuses (rc=2) despite CONTENT pixels",
              r.returncode == 2, f"rc={r.returncode} {r.stdout[-200:]}")
        check("stale-fabric refusal is reported as UNSCORED",
              "UNSCORED" in r.stderr, r.stderr[:300])
        check("stale-fabric refusal names the DEPLOY_LOAD=none mechanism",
              "DEPLOY_LOAD=none" in r.stderr, r.stderr[:300])

        # Green side: same frames, same flag, load AFTER the write -> PASS.
        # Without this the refusal above could come from anything at all.
        env_ok = fake_sshpass(d, "Plex", MD5, rbf_mtime=1000, load_mtime=2000)
        r = run(inputs(pc) + prov + ["--require-fabric-provenance"], d, env=env_ok)
        check("core loaded AFTER the RBF write passes (rc=0)",
              r.returncode == 0, f"rc={r.returncode} {r.stderr[:300]}")
        check("provenance line reports load_after_write=True",
              "load_after_write=True" in r.stdout, r.stdout[:300])

        # Missing mtimes must REFUSE, not silently fall back to the file-only check.
        # Assert the SPECIFIC message: rc=2 alone is vacuous here, because with
        # this branch deleted `not None` is True and the stale-fabric branch
        # refuses anyway -- while printing a fabricated "written 0s AFTER" delta
        # computed from two -1 sentinels. Mutation testing found this.
        env_unk = fake_sshpass(d, "Plex", MD5, rbf_mtime=-1, load_mtime=-1)
        r = run(inputs(pc) + prov + ["--require-fabric-provenance"], d, env=env_unk)
        check("unknown load-ordering refuses (rc=2) rather than assuming",
              r.returncode == 2, f"rc={r.returncode} {r.stdout[-200:]}")
        check("unknown ordering says it cannot establish ordering, and does NOT "
              "invent a delta from sentinel mtimes",
              "cannot establish load-ordering" in r.stderr
              and "AFTER the core was loaded" not in r.stderr, r.stderr[:300])

        # 12. Fleet exit contract: 0 passed / 1 failed / 77 could not evaluate.
        #     77 is strictly safer than 2, because argparse also exits 2 on a
        #     usage error, so rc=2 conflates "I refused to score" with "I
        #     rejected your command line" -- a collision that already produced a
        #     false green in this very file. Under the 77 contract those two
        #     become separable, and the last check asserts that separation
        #     rather than just the happy path.
        nosig = save(flat(80), d, "contract_nosig")
        r = run(inputs(nosig) + ["--unevaluable-exit", "77"], d)
        check("no-signal refuses as 77 under the fleet contract",
              r.returncode == 77, f"rc={r.returncode}")
        r = run(inputs(nosig), d)
        check("no-signal still refuses as 2 by default (back-compat)",
              r.returncode == 2, f"rc={r.returncode}")
        r = run(inputs(pc) + ["--host", REACHABLE, "--unevaluable-exit", "77"], d)
        check("content still passes as 0 under the 77 contract",
              r.returncode == 0, f"rc={r.returncode}")
        r = subprocess.run(
            [sys.executable, str(GATE), "--bogus-flag", "--unevaluable-exit", "77"],
            capture_output=True, text=True)
        check("argparse usage error stays 2, never 77 — a typo is not an "
              "unevaluable screen", r.returncode == 2, f"rc={r.returncode}")

    print(f"\n{checks - len(failures)}/{checks} checks passed")
    if failures:
        print("FAILURES: " + ", ".join(failures))
        return 1
    print("CAPTURE_GATE_OFFLINE_REDPROOF_OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
