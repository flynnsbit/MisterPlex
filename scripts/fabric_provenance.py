#!/usr/bin/env python3
"""Bind a claim to the bitstream the user is actually looking at.

Parent's fleet-wide rule (2026-07-28), from `w-arm-o5`'s
`check_fitted_line_buffer.py`: every gate that reads a fit report must bind that
report to the resident RBF md5, and an unbound report must print ``UNBOUND``
rather than pass.  The reason is measured: 40 fit reports exist on this host and
35 describe builds nobody is running.

**This module implements that rule and then extends it, because md5 binding is
necessary but NOT sufficient.**

``md5(/media/fat/_Utility/Plex.rbf)`` identifies the *file on the SD card*.  It
does not identify the *fabric*.  `scripts/deploy_plex_core.sh` defaults to
``DEPLOY_LOAD=none``, which copies the RBF and deliberately does not call
``load_core``.  After a default deploy the file carries the new md5 while the
previous bitstream is still configured and painting every pixel.  So a gate can
be perfectly ``BOUND`` -- report matches file md5, exactly as the rule demands --
and still describe a build nobody is running.  That is the same failure the
binding rule was introduced to prevent, moved one level down.

There is no way to close it by readback: this part offers no bitstream readback,
and there is no fabric-published build ID (the DDR mailbox words survive
reconfiguration, so they cannot identify the fabric either).

So identity is established by ORDERING.  ``/tmp/CORENAME`` is rewritten by the
Main binary when a core is loaded, therefore::

    mtime(Plex.rbf) <= mtime(/tmp/CORENAME)  =>  the load read these bytes

Verdicts (only BOUND is a pass)::

    BOUND          file md5 matches AND the core was loaded after it was written
    UNBOUND        caller supplied no expected md5 -- a claim with no subject
    UNREACHABLE    device did not answer; state is unseen, NOT absent
    MD5_MISMATCH   the file is not the build claimed
    STALE_FABRIC   md5 matches the FILE but the fabric predates it
    ORDER_UNKNOWN  mtimes unavailable; ordering cannot be established

"When you cannot see something, report it as unseen -- never as absent."
UNREACHABLE and ORDER_UNKNOWN exist so that a missing measurement can never be
laundered into a pass.

Exit codes: 0 BOUND, 2 everything else.  There is deliberately no exit 1: this
tool never reports a product defect, only whether a claim has a subject.
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys

EXIT_BOUND, EXIT_REFUSE = 0, 2

PROBE = (
    "echo \"CORENAME=$(cat /tmp/CORENAME 2>/dev/null)\"; "
    "echo \"RBFMD5=$(md5sum /media/fat/_Utility/Plex.rbf 2>/dev/null | cut -d' ' -f1)\"; "
    "echo \"RBFMTIME=$(date -r /media/fat/_Utility/Plex.rbf +%s 2>/dev/null)\"; "
    "echo \"LOADMTIME=$(date -r /tmp/CORENAME +%s 2>/dev/null)\"; "
    "echo \"FPGASTATE=$(cat /sys/class/fpga_manager/fpga0/state 2>/dev/null)\"; "
    "echo \"UPTIME=$(cut -d. -f1 /proc/uptime 2>/dev/null)\""
)


def compute_load_after_write(rbf_mtime: int, load_mtime: int) -> bool | None:
    """The load-bearing ordering decision, isolated so it can be tested directly.

    Kept as its own function because the self-test previously built fixtures with
    ``load_after_write`` pre-set, which meant this comparison was never executed
    by any test: mutation testing inverted it and every check stayed green.
    """
    if rbf_mtime < 0 or load_mtime < 0:
        return None
    return load_mtime >= rbf_mtime


def probe(host: str, timeout_s: int = 10) -> dict:
    """Read device identity.  Never raises."""
    info = {"ok": False, "corename": "", "rbf_md5": "", "uptime_s": -1,
            "rbf_mtime": -1, "load_mtime": -1, "load_after_write": None,
            "fpga_state": "", "error": ""}
    try:
        r = subprocess.run(
            ["sshpass", "-p", os.environ.get("MISTER_PASS", "1"), "ssh",
             "-o", "StrictHostKeyChecking=no", "-o", f"ConnectTimeout={timeout_s}",
             f"root@{host}", PROBE],
            capture_output=True, text=True, timeout=timeout_s + 10)
        if r.returncode != 0:
            info["error"] = (r.stderr or "ssh failed").strip()[:200]
            return info
        fields = {"CORENAME": "corename", "RBFMD5": "rbf_md5", "FPGASTATE": "fpga_state"}
        ints = {"RBFMTIME": "rbf_mtime", "LOADMTIME": "load_mtime", "UPTIME": "uptime_s"}
        for line in r.stdout.splitlines():
            if "=" not in line:
                continue
            k, v = line.split("=", 1)
            v = v.strip()
            if k in fields:
                info[fields[k]] = v
            elif k in ints:
                try:
                    info[ints[k]] = int(v)
                except ValueError:
                    pass
        if info["rbf_mtime"] >= 0 and info["load_mtime"] >= 0:
            info["load_after_write"] = compute_load_after_write(
                info["rbf_mtime"], info["load_mtime"])
        info["ok"] = bool(info["corename"])
        if not info["ok"]:
            info["error"] = "device returned no CORENAME"
    except Exception as e:  # noqa: BLE001
        info["error"] = f"{type(e).__name__}: {e}"[:200]
    return info


def classify(ident: dict, expect_md5: str | None,
             expect_corename: str | None = None) -> tuple[str, str]:
    """Return (verdict, human explanation).  Pure function of the probe."""
    if not expect_md5:
        return ("UNBOUND",
                "no --expect-rbf-md5 given: this claim has no subject. 40 fit "
                "reports exist on this host and 35 describe builds nobody runs.")
    if not ident["ok"]:
        return ("UNREACHABLE",
                f"device did not answer ({ident['error'] or 'no response'}). "
                "The bitstream is UNSEEN, not absent.")
    if expect_corename and ident["corename"] != expect_corename:
        return ("MD5_MISMATCH",
                f"loaded core is {ident['corename']!r}, expected {expect_corename!r}")
    if not ident["rbf_md5"].startswith(expect_md5):
        return ("MD5_MISMATCH",
                f"resident RBF md5 {ident['rbf_md5'][:8]} != expected {expect_md5[:8]}")
    if ident["load_after_write"] is None:
        return ("ORDER_UNKNOWN",
                "RBF/CORENAME mtimes unavailable, so the md5 binds the FILE only "
                "and the fabric cannot be established")
    if not ident["load_after_write"]:
        gap = ident["rbf_mtime"] - ident["load_mtime"]
        return ("STALE_FABRIC",
                f"RBF file was written {gap}s AFTER the core was loaded, so the "
                f"fabric is running a DIFFERENT bitstream than {expect_md5[:8]} "
                f"(classic DEPLOY_LOAD=none divergence: the file is new, the "
                f"fabric is old). Load the core, then re-measure.")
    gap = ident["load_mtime"] - ident["rbf_mtime"]
    return ("BOUND",
            f"core loaded {gap}s after the RBF was written, so the fabric was "
            f"configured from these bytes")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default=os.environ.get("MISTER_HOST", "192.168.1.183"))
    ap.add_argument("--expect-rbf-md5", default=None,
                    help="Build the caller claims to be describing. Omitting it "
                         "yields UNBOUND, never a pass.")
    ap.add_argument("--expect-corename", default=None)
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args(argv)

    if args.self_test:
        return self_test()

    ident = probe(args.host)
    verdict, why = classify(ident, args.expect_rbf_md5, args.expect_corename)
    print(f"FABRIC_PROVENANCE: {verdict}")
    print(f"  host={args.host} corename={ident['corename']!r} "
          f"rbf_md5={ident['rbf_md5'][:8] or '?'} fpga_state={ident['fpga_state'] or '?'} "
          f"load_after_write={ident['load_after_write']}")
    print(f"  {why}")
    if verdict != "BOUND":
        print(f"REFUSE: {verdict} — any claim about the resident bitstream is "
              f"UNSCORED (not a pass, not a skip).", file=sys.stderr)
        return EXIT_REFUSE
    return EXIT_BOUND


def self_test() -> int:
    """Red-prove every verdict.  Pure classify() cases plus a live probe path."""
    MD5 = "3b1e8435" + "0" * 24
    good = {"ok": True, "corename": "Plex", "rbf_md5": MD5, "uptime_s": 1,
            "rbf_mtime": 1000, "load_mtime": 2000, "load_after_write": True,
            "fpga_state": "operating", "error": ""}
    stale = dict(good, rbf_mtime=2000, load_mtime=1000, load_after_write=False)
    unk = dict(good, rbf_mtime=-1, load_mtime=-1, load_after_write=None)
    dead = dict(good, ok=False, error="No route to host")

    cases = [
        ("happy path binds", classify(good, "3b1e8435")[0], "BOUND"),
        ("no expected md5 is UNBOUND, not a pass",
         classify(good, None)[0], "UNBOUND"),
        ("unreachable device is UNREACHABLE, not absent",
         classify(dead, "3b1e8435")[0], "UNREACHABLE"),
        ("wrong md5 is MD5_MISMATCH", classify(good, "deadbeef")[0], "MD5_MISMATCH"),
        ("wrong corename is caught",
         classify(good, "3b1e8435", "MENU")[0], "MD5_MISMATCH"),
        # The load-bearing case: md5 matches the FILE and it is still not the fabric.
        ("matching md5 with a stale fabric is STALE_FABRIC, NOT bound",
         classify(stale, "3b1e8435")[0], "STALE_FABRIC"),
        ("missing mtimes are ORDER_UNKNOWN, never assumed good",
         classify(unk, "3b1e8435")[0], "ORDER_UNKNOWN"),
    ]
    ok = 0
    for name, got, want in cases:
        good_case = got == want
        ok += good_case
        print(f"{'PASS' if good_case else 'FAIL'} {name}"
              + ("" if good_case else f"  [got {got}, want {want}]"))

    # Differential control: the ONLY difference between these two inputs is the
    # ordering, and the verdict must flip.  Without this the STALE_FABRIC case
    # could be passing for some unrelated reason.
    flip = classify(good, "3b1e8435")[0] != classify(stale, "3b1e8435")[0]
    ok += flip
    print(f"{'PASS' if flip else 'FAIL'} ordering alone flips the verdict "
          f"(identical md5, identical corename)")

    # The ordering computation itself, exercised directly.  The fixtures above
    # pre-set load_after_write, so without these the load-bearing comparison was
    # never executed by any test -- mutation testing inverted it and every check
    # above stayed green.
    order_cases = [
        ("load after write -> True", compute_load_after_write(1000, 2000), True),
        ("load before write -> False", compute_load_after_write(2000, 1000), False),
        ("equal mtimes -> True (load read those bytes)",
         compute_load_after_write(1500, 1500), True),
        ("missing rbf mtime -> None", compute_load_after_write(-1, 2000), None),
        ("missing load mtime -> None", compute_load_after_write(1000, -1), None),
    ]
    for name, got, want in order_cases:
        good_case = got is want
        ok += good_case
        print(f"{'PASS' if good_case else 'FAIL'} {name}"
              + ("" if good_case else f"  [got {got}, want {want}]"))

    # Exit-code contract: only BOUND may be 0.
    unreachable_rc = main(["--host", "192.0.2.1", "--expect-rbf-md5", "3b1e8435"])
    rc_ok = unreachable_rc == EXIT_REFUSE
    ok += rc_ok
    print(f"{'PASS' if rc_ok else 'FAIL'} unreachable host exits 2, never 0 "
          f"(rc={unreachable_rc})")

    total = len(cases) + len(order_cases) + 2
    print(f"\n{ok}/{total} self-test checks passed")
    return 0 if ok == total else 1


if __name__ == "__main__":
    raise SystemExit(main())
