#!/usr/bin/env python3
"""Refuse an argument this script does not understand.

The defect this exists to prevent, measured on `w-cast-play-state` `667a237`:

    $ check_rtl_module_instantiations.py --root h264_decode_core \
          --require totally_bogus_module_xyz
    RTL_MODULE_INSTANTIATION_OK ... root=emu
    rc=0

That copy of the gate contains no `argparse` and never reads `sys.argv`, so the
flags were discarded in silence. A module that exists nowhere in the repository
passed, and the transcript shows an ordinary green line. Nothing in the output
says "I ignored what you asked me".

This is worse than a gate that exits 0 without working, because the gate *does*
work -- it just answers a different question than the one it was asked, and the
answer is indistinguishable from a real pass. A reviewer cannot tell the two
apart without re-running with a deliberately bogus argument.

A script that takes no arguments must therefore say so to the caller rather than
ignore them. `refuse_unrecognised_argv()` is the one-line contract for scripts
that do not use argparse; argparse's own `parse_args()` already does this.
"""
from __future__ import annotations

import sys

REFUSED = 2


def refuse_unrecognised_argv(argv: list[str] | None = None,
                             name: str | None = None) -> None:
    """Exit 2 if this script was handed arguments it cannot honour.

    Never returns non-empty argv to the caller: the point is that silence is
    the defect. Called with no arguments, this is a no-op.
    """
    args = list(sys.argv[1:] if argv is None else argv)
    if not args:
        return
    who = name or sys.argv[0].rsplit("/", 1)[-1]
    print(
        f"ARGV_REFUSED {who}: takes no arguments, but was given "
        f"{len(args)}: {' '.join(args)} -- refusing rather than ignoring them, "
        "because a silently discarded flag turns this gate's result into an "
        "answer to a different question",
        file=sys.stderr,
    )
    raise SystemExit(REFUSED)
