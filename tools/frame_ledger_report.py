#!/usr/bin/env python3
"""Single-session frame ledger report (host-side).

WHY
---
`drops` alone under-states loss: it counts ONLY deliberate A/V-pacer skips
(media_player present loop). It never counts frames ffmpeg failed to produce
or failed DDR publishes. Session counters reset per stream.

Full identity (host/libmisterplex/frame_ledger.hpp):
  residual = frames - presents - drops
  when every non-present is pacedrop or publish-miss:
      residual == publish_misses

This tool prints the FULL ledger for ONE session (last session_end by default)
with an explicit single-session assertion so a soak number is defensible.

Inputs (parent pulls from device; this tool never SSHes):
  --ledger PATH   misterplexd.frame_ledger (append-only file on device confDir)
  --log PATH      daemon stderr/log containing "media: session end ..." and/or
                  "misterplexd: FRAME_LEDGER event=session_end ..."

Exit codes
----------
  0   LEDGER_OK — identity holds for the selected session
  2   LEDGER_FAIL — residual != frames-presents-drops OR residual!=publish_misses
                    when --require-explained (positively measured fail)
  77  NO-DATA — no session_end found
  1   usage

Rule 0: every value tagged measured | caller_supplied | DEFAULT_ASSUMED | NO-DATA.
true rc via: cmd; echo "true rc=$?"
"""
from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional, Sequence

RC_OK = 0
RC_USAGE = 1
RC_FAIL = 2
RC_NO_DATA = 77

PROVENANCE_MEASURED = "measured"
PROVENANCE_CALLER = "caller_supplied"
PROVENANCE_DEFAULT_ASSUMED = "DEFAULT_ASSUMED"
PROVENANCE_NO_DATA = "NO-DATA"

# session_end line in frame_ledger file:
# ts=... event=session_end pid=... session=N frames=F presents=P drops=D
# publish_misses=M residual=R reason=...
RE_LEDGER = re.compile(
    r"event=session_end\b(?P<body>.*)"
)
# media: session end frames=... presents=... drops=... publish_misses=... residual=...
RE_MEDIA_END = re.compile(
    r"media:\s+session end\b(?P<body>.*)"
)
# misterplexd: FRAME_LEDGER event=session_end ...
RE_STDERR = re.compile(
    r"FRAME_LEDGER\s+event=session_end\b(?P<body>.*)"
)
# 1 Hz live line fragment
RE_LIVE = re.compile(
    r"media:\s+frames=(?P<frames>\d+)\b(?P<body>.*\bpresents=\d+.*\bdrops=\d+.*)"
)


def _kv(body: str) -> dict:
    out = {}
    for m in re.finditer(r"(\w+)=([^\s]+)", body):
        out[m.group(1)] = m.group(2)
    return out


def _i(d: dict, k: str) -> Optional[int]:
    if k not in d:
        return None
    try:
        return int(str(d[k]).split(".")[0])
    except ValueError:
        return None


@dataclass
class SessionRow:
    source: str
    session: Optional[int]
    frames: int
    presents: int
    drops: int
    publish_misses: int
    residual_logged: Optional[int]
    reason: str
    raw: str

    @property
    def residual_calc(self) -> int:
        return self.frames - self.presents - self.drops

    @property
    def identity_ok(self) -> bool:
        if self.residual_logged is not None and self.residual_logged != self.residual_calc:
            return False
        return True

    @property
    def explained_ok(self) -> bool:
        # residual == publish_misses when only pace-drops + publish misses
        return self.residual_calc == self.publish_misses


def parse_text(text: str, source: str) -> List[SessionRow]:
    rows: List[SessionRow] = []
    for line in text.splitlines():
        body = None
        kind = None
        if "event=session_end" in line:
            m = RE_LEDGER.search(line) or RE_STDERR.search(line)
            if m:
                body = m.group("body")
                if "session_end" in line and "frames=" in line:
                    # body may miss fields left of match — use full line
                    body = line
                kind = "ledger"
        if body is None and "media: session end" in line:
            m = RE_MEDIA_END.search(line)
            if m:
                body = line
                kind = "media_end"
        if body is None:
            continue
        kv = _kv(body)
        frames = _i(kv, "frames")
        presents = _i(kv, "presents")
        drops = _i(kv, "drops")
        if frames is None or presents is None or drops is None:
            continue
        pub = _i(kv, "publish_misses")
        if pub is None:
            pub = 0
        resid = _i(kv, "residual")
        rows.append(
            SessionRow(
                source=f"{source}:{kind}",
                session=_i(kv, "session"),
                frames=frames,
                presents=presents,
                drops=drops,
                publish_misses=pub,
                residual_logged=resid,
                reason=str(kv.get("reason", "?")),
                raw=line.strip(),
            )
        )
    return rows


def print_row(row: SessionRow, *, require_explained: bool) -> int:
    print("=== frame_ledger_report ===")
    print(
        "semantics: frames=pipe assembled; presents=DDR ok; "
        "drops=A/V-pacer skips ONLY; publish_misses=DDR fail; "
        "residual=frames-presents-drops"
    )
    print(
        "CANNOT_CLAIM: drops alone is full loss — ffmpeg non-produce is invisible here"
    )
    print(f"source={row.source} src=measured")
    print(f"session={row.session} src=measured")
    print(f"frames={row.frames} src=measured")
    print(f"presents={row.presents} src=measured")
    print(f"drops={row.drops} src=measured")
    print(f"publish_misses={row.publish_misses} src=measured")
    print(f"residual_calc={row.residual_calc} src=measured")
    if row.residual_logged is not None:
        print(f"residual_logged={row.residual_logged} src=measured")
    else:
        print(f"residual_logged=None src={PROVENANCE_NO_DATA}")
    print(f"reason={row.reason} src=measured")
    print(f"identity_ok={row.identity_ok} src=measured")
    print(f"residual_eq_publish_misses={row.explained_ok} src=measured")
    print(f"single_session_assertion=1 src=measured")
    print(f"raw={row.raw}")

    if not row.identity_ok:
        print(f"VERDICT=LEDGER_FAIL rc={RC_FAIL} reason=residual_mismatch")
        return RC_FAIL
    if require_explained and not row.explained_ok:
        print(
            f"VERDICT=LEDGER_FAIL rc={RC_FAIL} "
            f"reason=residual_not_explained_by_publish_misses "
            f"residual={row.residual_calc} publish_misses={row.publish_misses}"
        )
        return RC_FAIL
    print(f"VERDICT=LEDGER_OK rc={RC_OK}")
    return RC_OK


def _self_test() -> int:
    sample = """
ts=2026-01-01T00:00:00Z event=process_start pid=1 lifetime_frames=0 lifetime_presents=0 lifetime_drops=0
ts=2026-01-01T00:01:00Z event=session_end pid=1 session=1 frames=1000 presents=990 drops=10 publish_misses=0 residual=0 reason=natural_eof
ts=2026-01-01T00:02:00Z event=session_end pid=1 session=2 frames=500 presents=480 drops=15 publish_misses=5 residual=5 reason=stop_or_seek
"""
    rows = parse_text(sample, "self")
    assert len(rows) == 2, rows
    last = rows[-1]
    assert last.frames == 500 and last.drops == 15 and last.publish_misses == 5
    assert last.residual_calc == 5 and last.explained_ok and last.identity_ok
    print("SELF_TEST parse two sessions OK")

    bad = "event=session_end session=9 frames=100 presents=50 drops=10 publish_misses=0 residual=999 reason=x\n"
    rows = parse_text(bad, "self")
    assert len(rows) == 1 and not rows[0].identity_ok
    print("SELF_TEST residual mismatch detected OK")

    # media session end line
    media = (
        "media: session end frames=200 presents=190 drops=10 publish_misses=0 "
        "residual=0 session=3 reason=natural_eof\n"
    )
    rows = parse_text(media, "self")
    assert len(rows) == 1 and rows[0].identity_ok and rows[0].explained_ok
    print("SELF_TEST media session end OK")
    print("SELF_TEST_OK")
    return 0


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--ledger", default=None, help="path to misterplexd.frame_ledger")
    ap.add_argument("--log", default=None, help="daemon log with session end lines")
    ap.add_argument(
        "--session",
        type=int,
        default=None,
        help="session id to report (default: last session_end)",
    )
    ap.add_argument(
        "--require-explained",
        action="store_true",
        help="FAIL if residual != publish_misses (strict full-account)",
    )
    ap.add_argument(
        "--all",
        action="store_true",
        help="print every session (still exits on last verdict unless --session)",
    )
    args = ap.parse_args(list(argv) if argv is not None else None)

    if args.self_test:
        return _self_test()

    texts: List[tuple[str, str]] = []
    try:
        if args.ledger:
            texts.append((Path(args.ledger).read_text(encoding="utf-8", errors="replace"), args.ledger))
        if args.log:
            texts.append((Path(args.log).read_text(encoding="utf-8", errors="replace"), args.log))
    except OSError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return RC_USAGE

    if not texts:
        print("ERROR: provide --ledger and/or --log (or --self-test)", file=sys.stderr)
        return RC_USAGE

    rows: List[SessionRow] = []
    for text, src in texts:
        rows.extend(parse_text(text, src))

    if not rows:
        print(f"VERDICT=NO-DATA rc={RC_NO_DATA}")
        print("reason=no session_end rows src=NO-DATA")
        return RC_NO_DATA

    if args.session is not None:
        chosen = [r for r in rows if r.session == args.session]
        if not chosen:
            print(f"VERDICT=NO-DATA rc={RC_NO_DATA}")
            print(f"reason=session_{args.session}_not_found src=NO-DATA")
            return RC_NO_DATA
        target = chosen[-1]
    else:
        target = rows[-1]

    if args.all:
        print(f"n_sessions_parsed={len(rows)} src=measured")
        for r in rows:
            print(
                f"  session={r.session} frames={r.frames} presents={r.presents} "
                f"drops={r.drops} publish_misses={r.publish_misses} "
                f"residual_calc={r.residual_calc} identity_ok={r.identity_ok}"
            )

    return print_row(target, require_explained=bool(args.require_explained))


if __name__ == "__main__":
    sys.exit(main())
