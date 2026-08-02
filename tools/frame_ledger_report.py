#!/usr/bin/env python3
"""Single-session frame ledger report (host-side).

WHY
---
`drops` alone under-states loss: it counts ONLY deliberate A/V-pacer skips
(media_player present loop). It never counts frames ffmpeg failed to produce
or failed DDR publishes. Session counters reset per stream.

Full identity (host/libmisterplex/frame_ledger.hpp):
  residual_arm = frames - presents - drops
  residual_unexplained = frames - presents - drops - publish_misses
  when every non-present is pacedrop or publish-miss:
      residual_arm == publish_misses  and  residual_unexplained == 0
  residual_unexplained != 0 is the user finding (uninstrumented gap).
  Historical name "unaccounted" meant residual_arm (not unexplained).

session_epoch = process_epoch.stream_seq changes on daemon start AND every new
stream. A soak that spans two session_epoch values is NOT single-session (P4).
rc=79 SESSION_INVALID aligns tools/frame_accounting_close.py + daemon_media_ledger.

This tool prints the FULL ledger for ONE session (last session_end by default)
with an explicit single-session assertion so a soak number is defensible.
Prefer tools/frame_accounting_close.py for per-round d_frames/d_wall + soak.

Inputs (parent pulls from device; this tool never SSHes):
  --ledger PATH   misterplexd.frame_ledger (append-only file on device confDir)
  --log PATH      daemon stderr/log containing "media: session end ..." and/or
                  "misterplexd: FRAME_LEDGER event=session_end ..."

Exit codes
----------
  0   LEDGER_OK — identity holds for the selected session
  2   LEDGER_FAIL — residual mismatch / unexplained gap / multi-epoch window
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
from typing import List, Optional, Sequence, Set, Tuple

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
# publish_misses=M unaccounted=U residual=R reason=...
RE_LEDGER = re.compile(
    r"event=session_end\b(?P<body>.*)"
)
# media: session end ...
RE_MEDIA_END = re.compile(
    r"media:\s+session end\b(?P<body>.*)"
)
# misterplexd: FRAME_LEDGER event=session_end ...
RE_STDERR = re.compile(
    r"FRAME_LEDGER\s+event=session_end\b(?P<body>.*)"
)
# 1 Hz live line (frames= may appear inside ledger fragment)
RE_LIVE = re.compile(
    r"media:\s+(?!session end)(?P<body>.*\bpresents=\d+.*\bdrops=\d+.*)"
)
RE_SESSION_EPOCH = re.compile(r"session_epoch=([0-9]+\.[0-9]+)")
RE_PROCESS_EPOCH = re.compile(r"process_epoch=([0-9]+)")


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
    unaccounted_logged: Optional[int]
    session_epoch: Optional[str]
    process_epoch: Optional[int]
    stream_seq: Optional[int]
    reason: str
    raw: str

    @property
    def residual_calc(self) -> int:
        return self.frames - self.presents - self.drops

    @property
    def unaccounted_calc(self) -> int:
        return self.residual_calc

    @property
    def identity_ok(self) -> bool:
        if self.residual_logged is not None and self.residual_logged != self.residual_calc:
            return False
        if (
            self.unaccounted_logged is not None
            and self.unaccounted_logged != self.unaccounted_calc
        ):
            return False
        return True

    @property
    def explained_ok(self) -> bool:
        # unaccounted == publish_misses when only pace-drops + publish misses
        return self.unaccounted_calc == self.publish_misses


def parse_session_epochs(text: str) -> Set[str]:
    """All session_epoch values seen on live media: lines (P4 continuity)."""
    out: Set[str] = set()
    for line in text.splitlines():
        if "media:" not in line:
            continue
        m = RE_SESSION_EPOCH.search(line)
        if m:
            out.add(m.group(1))
    return out


def parse_text(text: str, source: str) -> List[SessionRow]:
    rows: List[SessionRow] = []
    for line in text.splitlines():
        body = None
        kind = None
        if "event=session_end" in line:
            m = RE_LEDGER.search(line) or RE_STDERR.search(line)
            if m:
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
        unacc = _i(kv, "unaccounted")
        if unacc is None:
            unacc = resid
        se = kv.get("session_epoch")
        pe = _i(kv, "process_epoch")
        ss = _i(kv, "stream_seq")
        rows.append(
            SessionRow(
                source=f"{source}:{kind}",
                session=_i(kv, "session"),
                frames=frames,
                presents=presents,
                drops=drops,
                publish_misses=pub,
                residual_logged=resid,
                unaccounted_logged=unacc,
                session_epoch=str(se) if se is not None else None,
                process_epoch=pe,
                stream_seq=ss,
                reason=str(kv.get("reason", "?")),
                raw=line.strip(),
            )
        )
    return rows


def print_row(
    row: SessionRow,
    *,
    require_explained: bool,
    epochs_in_log: Optional[Set[str]] = None,
) -> int:
    print("=== frame_ledger_report ===")
    print(
        "semantics: frames=pipe assembled; presents=DDR ok; "
        "drops=A/V-pacer skips ONLY; publish_misses=DDR fail; "
        "residual_arm=frames-presents-drops; "
        "residual_unexplained=frames-presents-drops-publish_misses tag=measured"
    )
    print(
        "CANNOT_CLAIM: drops alone is full loss — ffmpeg non-produce is invisible here"
    )
    print(
        f"residual_unexplained_calc={row.frames - row.presents - row.drops - row.publish_misses} "
        f"src=measured"
    )
    print(f"source={row.source} src=measured")
    print(f"session={row.session} src=measured")
    print(
        f"session_epoch={row.session_epoch} src="
        f"{PROVENANCE_MEASURED if row.session_epoch else PROVENANCE_NO_DATA}"
    )
    print(
        f"process_epoch={row.process_epoch} src="
        f"{PROVENANCE_MEASURED if row.process_epoch is not None else PROVENANCE_NO_DATA}"
    )
    print(f"frames={row.frames} src=measured")
    print(f"presents={row.presents} src=measured")
    print(f"drops={row.drops} src=measured")
    print(f"publish_misses={row.publish_misses} src=measured")
    print(f"unaccounted_calc={row.unaccounted_calc} src=measured")
    print(f"residual_calc={row.residual_calc} src=measured")
    if row.unaccounted_logged is not None:
        print(f"unaccounted_logged={row.unaccounted_logged} src=measured")
    else:
        print(f"unaccounted_logged=None src={PROVENANCE_NO_DATA}")
    if row.residual_logged is not None:
        print(f"residual_logged={row.residual_logged} src=measured")
    else:
        print(f"residual_logged=None src={PROVENANCE_NO_DATA}")
    print(f"reason={row.reason} src=measured")
    print(f"identity_ok={row.identity_ok} src=measured")
    print(f"unaccounted_eq_publish_misses={row.explained_ok} src=measured")

    multi_epoch = False
    if epochs_in_log is not None:
        print(
            f"session_epochs_in_log={sorted(epochs_in_log)} src=measured "
            f"n={len(epochs_in_log)}"
        )
        if len(epochs_in_log) > 1:
            multi_epoch = True
            print(
                "single_session_assertion=0 src=measured "
                "reason=multiple_session_epoch_in_window"
            )
        elif len(epochs_in_log) == 1:
            print("single_session_assertion=1 src=measured")
        else:
            print(
                f"single_session_assertion=NO-DATA src={PROVENANCE_NO_DATA} "
                "(no session_epoch on live lines — upgrade daemon)"
            )
    else:
        print("single_session_assertion=1 src=DEFAULT_ASSUMED (no --log epoch scan)")
    print(f"raw={row.raw}")

    if multi_epoch:
        print(
            f"VERDICT=LEDGER_FAIL rc={RC_FAIL} "
            f"reason=multi_session_epoch_window n={len(epochs_in_log or [])}"
        )
        return RC_FAIL
    if not row.identity_ok:
        print(f"VERDICT=LEDGER_FAIL rc={RC_FAIL} reason=residual_or_unaccounted_mismatch")
        return RC_FAIL
    if require_explained and not row.explained_ok:
        print(
            f"VERDICT=LEDGER_FAIL rc={RC_FAIL} "
            f"reason=unaccounted_not_explained_by_publish_misses "
            f"unaccounted={row.unaccounted_calc} publish_misses={row.publish_misses}"
        )
        return RC_FAIL
    print(f"VERDICT=LEDGER_OK rc={RC_OK}")
    return RC_OK


def _self_test() -> int:
    sample = """
ts=2026-01-01T00:00:00Z event=process_start pid=1 lifetime_frames=0 lifetime_presents=0 lifetime_drops=0
ts=2026-01-01T00:01:00Z event=session_end pid=1 session=1 frames=1000 presents=990 drops=10 publish_misses=0 unaccounted=0 residual=0 reason=natural_eof tag=measured
ts=2026-01-01T00:02:00Z event=session_end pid=1 session=2 frames=500 presents=480 drops=15 publish_misses=5 unaccounted=5 residual=5 reason=stop_or_seek tag=measured
"""
    rows = parse_text(sample, "self")
    assert len(rows) == 2, rows
    last = rows[-1]
    assert last.frames == 500 and last.drops == 15 and last.publish_misses == 5
    assert last.unaccounted_calc == 5 and last.explained_ok and last.identity_ok
    print("SELF_TEST parse two sessions OK")

    bad = (
        "event=session_end session=9 frames=100 presents=50 drops=10 "
        "publish_misses=0 unaccounted=999 residual=999 reason=x\n"
    )
    rows = parse_text(bad, "self")
    assert len(rows) == 1 and not rows[0].identity_ok
    print("SELF_TEST residual/unaccounted mismatch RED OK")

    # GREEN: clean identity
    good = (
        "media: session end frames=200 presents=190 drops=10 publish_misses=0 "
        "unaccounted=0 residual=0 session=3 process_epoch=99 stream_seq=1 "
        "session_epoch=99.1 reason=natural_eof tag=measured\n"
    )
    rows = parse_text(good, "self")
    assert len(rows) == 1 and rows[0].identity_ok and rows[0].explained_ok
    assert rows[0].session_epoch == "99.1"
    rc = print_row(rows[0], require_explained=True, epochs_in_log={"99.1"})
    assert rc == RC_OK
    print("SELF_TEST media session end GREEN rc=0 OK")

    # RED: multi epoch in log window
    multi_log = (
        "media: frames=10 presents=10 drops=0 unaccounted=0 session_epoch=1.1 process_epoch=1\n"
        "media: frames=20 presents=20 drops=0 unaccounted=0 session_epoch=1.2 process_epoch=1\n"
        + good
    )
    epochs = parse_session_epochs(multi_log)
    assert epochs == {"1.1", "1.2"} or "99.1" in epochs
    # only the two live epochs if we strip session end... include live only:
    live_only = (
        "media: frames=10 presents=10 drops=0 session_epoch=10.1 process_epoch=10\n"
        "media: frames=20 presents=20 drops=0 session_epoch=99.9 process_epoch=99\n"
    )
    epochs = parse_session_epochs(live_only)
    assert epochs == {"10.1", "99.9"}, epochs
    rows = parse_text(good, "self")
    rc = print_row(rows[0], require_explained=False, epochs_in_log=epochs)
    assert rc == RC_FAIL
    print("SELF_TEST multi session_epoch RED rc=2 OK")

    # RED: unaccounted growing (publish miss path)
    gap = (
        "media: session end frames=100 presents=97 drops=1 publish_misses=2 "
        "unaccounted=2 residual=2 session=1 reason=natural_eof tag=measured\n"
    )
    rows = parse_text(gap, "self")
    assert rows[0].unaccounted_calc == 2 and rows[0].explained_ok
    rc = print_row(rows[0], require_explained=True, epochs_in_log={"1.1"})
    assert rc == RC_OK  # explained by publish_misses
    unexplained = (
        "media: session end frames=100 presents=80 drops=1 publish_misses=0 "
        "unaccounted=19 residual=19 session=1 reason=natural_eof tag=measured\n"
    )
    rows = parse_text(unexplained, "self")
    assert rows[0].unaccounted_calc == 19 and not rows[0].explained_ok
    rc = print_row(rows[0], require_explained=True, epochs_in_log={"1.1"})
    assert rc == RC_FAIL
    print("SELF_TEST unexplained unaccounted RED rc=2 OK")
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
    epochs: Set[str] = set()
    for text, src in texts:
        rows.extend(parse_text(text, src))
        epochs |= parse_session_epochs(text)

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
                f"unaccounted_calc={r.unaccounted_calc} "
                f"session_epoch={r.session_epoch} identity_ok={r.identity_ok}"
            )

    # Epoch scan only when --log provided (live lines). Ledger-only = None.
    epochs_arg: Optional[Set[str]] = epochs if args.log else None
    return print_row(
        target,
        require_explained=bool(args.require_explained),
        epochs_in_log=epochs_arg,
    )


if __name__ == "__main__":
    sys.exit(main())
