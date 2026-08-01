#!/usr/bin/env python3
"""Artifact-pair stamp (fleet rule) — RBF md5 + daemon md5 required.

Fleet rule (parent 2026-08-01): PUBLISH NO MEASUREMENT WITHOUT THE ARTIFACT
PAIR (RBF md5 + daemon md5). Same family as:
  - no field name without derivation
  - no gate result without coverage

Also partition by decode_src. Never pool across decode_src values.

Resolution rules (quoted from scripts/lib/live_daemon_enum.sh):
  - Daemon identity via /proc/<pid>/exe (md5sum of that inode).
  - Match *misterplexd* including " (deleted)" after rename-deploy.
  - NEVER resolve by process-name / cmdline substring alone (flock trap;
    two install roots).

This module does not invent numbers. Missing pair => scoreable=False and
callers MUST emit UNSCORED (rc=77). Empty = NO-DATA, never zero md5.

Usage as library:
  from artifact_stamp import require_stamp, add_stamp_args, header_line

CLI:
  python3 tools/artifact_stamp.py --self-test
  python3 tools/artifact_stamp.py --from-json stamp.json
  # parent device collect (optional ssh wrapper):
  tools/avsync_stamp_artifacts.sh > stamp.json
  python3 tools/artifact_stamp.py --from-json stamp.json --require

Exit: 0 OK pair, 77 UNSCORED/missing, 1 usage, 2 self-test fail.
true rc: cmd; echo "true rc=$?"  — never through a pipe.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Optional

RC_OK = 0
RC_USAGE = 1
RC_FAIL = 2
RC_UNSCORED = 77

MD5_RE = re.compile(r"^[0-9a-fA-F]{32}$")
SHORT_RE = re.compile(r"^[0-9a-fA-F]{8}$")


@dataclass
class ArtifactStamp:
    rbf_md5: str = "NO-DATA"
    rbf_md5_src: str = "NO-DATA"
    daemon_md5: str = "NO-DATA"
    daemon_md5_src: str = "NO-DATA"
    daemon_pid: str = "NO-DATA"
    daemon_exe: str = "NO-DATA"
    decode_src: str = "NO-DATA"
    decode_src_src: str = "NO-DATA"
    decode: str = "NO-DATA"
    decode_src_note: str = ""
    extra: dict[str, Any] = field(default_factory=dict)

    @property
    def pair_ok(self) -> bool:
        return bool(MD5_RE.match(self.rbf_md5 or "") and MD5_RE.match(self.daemon_md5 or ""))

    @property
    def artifact_pair(self) -> str:
        if not self.pair_ok:
            return "UNSCORED_NO_PAIR"
        return f"{self.rbf_md5}+{self.daemon_md5}"

    @property
    def rbf_short(self) -> str:
        return (self.rbf_md5 or "")[:8] if MD5_RE.match(self.rbf_md5 or "") else "NO-DATA"

    @property
    def daemon_short(self) -> str:
        return (self.daemon_md5 or "")[:8] if MD5_RE.match(self.daemon_md5 or "") else "NO-DATA"

    def header_kv(self) -> str:
        """Single line: every field name + derivation (standing rule)."""
        return (
            f"artifact_pair={self.artifact_pair} "
            f"artifact_pair_der=rbf_md5+daemon_md5 "
            f"rbf_md5={self.rbf_md5} rbf_md5_src={self.rbf_md5_src} "
            f"rbf_md5_der=md5(/media/fat/_Utility/Plex.rbf_or_caller) "
            f"daemon_md5={self.daemon_md5} daemon_md5_src={self.daemon_md5_src} "
            f"daemon_md5_der=md5(/proc/pid/exe)_NOT_cmdline "
            f"daemon_pid={self.daemon_pid} daemon_exe={self.daemon_exe} "
            f"decode={self.decode} decode_src={self.decode_src} "
            f"decode_src_src={self.decode_src_src} "
            f"pair_scoreable={'1' if self.pair_ok else '0'} "
            f"fleet_rule=no_measurement_without_rbf_plus_daemon_md5"
        )

    def to_dict(self) -> dict[str, Any]:
        d = asdict(self)
        d["artifact_pair"] = self.artifact_pair
        d["pair_scoreable"] = self.pair_ok
        d["rbf_md5_short"] = self.rbf_short
        d["daemon_md5_short"] = self.daemon_short
        return d


def _norm_md5(v: Optional[str]) -> str:
    if v is None:
        return "NO-DATA"
    s = str(v).strip().lower()
    if s in ("", "none", "no-data", "unknown", "0", "00000000"):
        return "NO-DATA"
    if MD5_RE.match(s):
        return s
    if SHORT_RE.match(s):
        # short is NOT a full pair member — refuse to expand with zeros
        return "NO-DATA"
    return "NO-DATA"


def stamp_from_args(
    *,
    rbf_md5: Optional[str] = None,
    daemon_md5: Optional[str] = None,
    decode_src: Optional[str] = None,
    decode: Optional[str] = None,
    stamp_json: Optional[Path] = None,
    rbf_file: Optional[Path] = None,
    daemon_file: Optional[Path] = None,
    rbf_src: str = "caller_supplied",
    daemon_src: str = "caller_supplied",
) -> ArtifactStamp:
    st = ArtifactStamp()

    if stamp_json is not None:
        raw = json.loads(Path(stamp_json).read_text())
        st.rbf_md5 = _norm_md5(raw.get("rbf_md5"))
        st.rbf_md5_src = str(raw.get("rbf_md5_src") or "caller_supplied_json")
        st.daemon_md5 = _norm_md5(raw.get("daemon_md5"))
        st.daemon_md5_src = str(raw.get("daemon_md5_src") or "caller_supplied_json")
        st.daemon_pid = str(raw.get("daemon_pid") or "NO-DATA")
        st.daemon_exe = str(raw.get("daemon_exe") or "NO-DATA")
        st.decode_src = str(raw.get("decode_src") or "NO-DATA")
        st.decode_src_src = str(raw.get("decode_src_src") or raw.get("decode_src_note") or "json")
        st.decode = str(raw.get("decode") or "NO-DATA")

    if rbf_file is not None and Path(rbf_file).is_file():
        h = hashlib.md5(Path(rbf_file).read_bytes()).hexdigest()
        st.rbf_md5 = h
        st.rbf_md5_src = "measured_local_file"

    if daemon_file is not None and Path(daemon_file).is_file():
        h = hashlib.md5(Path(daemon_file).read_bytes()).hexdigest()
        st.daemon_md5 = h
        st.daemon_md5_src = "measured_local_file"

    if rbf_md5:
        st.rbf_md5 = _norm_md5(rbf_md5)
        st.rbf_md5_src = rbf_src
    if daemon_md5:
        st.daemon_md5 = _norm_md5(daemon_md5)
        st.daemon_md5_src = daemon_src
    if decode_src:
        st.decode_src = str(decode_src)
        st.decode_src_src = "caller_supplied"
    if decode:
        st.decode = str(decode)

    # Env fallbacks (parent session)
    if st.rbf_md5 == "NO-DATA":
        st.rbf_md5 = _norm_md5(os.environ.get("MISTERPLEX_RBF_MD5"))
        if st.rbf_md5 != "NO-DATA":
            st.rbf_md5_src = "env_MISTERPLEX_RBF_MD5"
    if st.daemon_md5 == "NO-DATA":
        st.daemon_md5 = _norm_md5(os.environ.get("MISTERPLEX_DAEMON_MD5"))
        if st.daemon_md5 != "NO-DATA":
            st.daemon_md5_src = "env_MISTERPLEX_DAEMON_MD5"
    if st.decode_src == "NO-DATA":
        env_ds = os.environ.get("MISTERPLEX_DECODE_SRC")
        if env_ds:
            st.decode_src = env_ds
            st.decode_src_src = "env_MISTERPLEX_DECODE_SRC"

    return st


def require_stamp(st: ArtifactStamp) -> tuple[bool, str, int]:
    """Return (ok, reason, rc). ok False => caller must UNSCORED."""
    if not st.pair_ok:
        return (
            False,
            "UNSCORED_NO_ARTIFACT_PAIR — need full 32-hex rbf_md5 AND daemon_md5 "
            "(tools/avsync_stamp_artifacts.sh or --rbf-md5/--daemon-md5). "
            "Empty is NO-DATA not zero.",
            RC_UNSCORED,
        )
    return True, "pair_ok", RC_OK


def refuse_pool_decode_src(a: str, b: str) -> bool:
    """True if pooling must be refused."""
    if a in ("", "NO-DATA", None) or b in ("", "NO-DATA", None):
        # unknown vs known: refuse pool (cannot prove same class)
        return str(a) != str(b)
    return str(a) != str(b)


def add_stamp_args(ap: argparse.ArgumentParser) -> None:
    g = ap.add_argument_group("artifact pair (fleet rule — required to score)")
    g.add_argument("--rbf-md5", default=None, help="32-hex md5 of live Plex.rbf")
    g.add_argument("--daemon-md5", default=None, help="32-hex md5 of /proc/<pid>/exe")
    g.add_argument("--stamp-json", type=Path, default=None, help="from avsync_stamp_artifacts.sh")
    g.add_argument("--rbf-file", type=Path, default=None, help="local Plex.rbf copy to hash")
    g.add_argument("--daemon-file", type=Path, default=None, help="local misterplexd copy to hash")
    g.add_argument(
        "--decode-src",
        default=None,
        help="caller_supplied|conf|default|… — partition key; do not pool across",
    )
    g.add_argument("--decode", default=None, help="e.g. 624x480 (label only)")
    g.add_argument(
        "--allow-unstamped",
        action="store_true",
        help="FORBIDDEN for product claims — forces UNSCORED path still prints numbers as forensic",
    )


def stamp_from_namespace(ns: argparse.Namespace) -> ArtifactStamp:
    return stamp_from_args(
        rbf_md5=getattr(ns, "rbf_md5", None),
        daemon_md5=getattr(ns, "daemon_md5", None),
        decode_src=getattr(ns, "decode_src", None),
        decode=getattr(ns, "decode", None),
        stamp_json=getattr(ns, "stamp_json", None),
        rbf_file=getattr(ns, "rbf_file", None),
        daemon_file=getattr(ns, "daemon_file", None),
    )


def parse_decode_src_from_log_line(line: str) -> tuple[str, str]:
    """Return (decode, decode_src) from a daemon log line."""
    dec = "NO-DATA"
    src = "NO-DATA"
    m = re.search(r"\bdecode=([^\s]+)", line)
    if m:
        dec = m.group(1)
    m = re.search(r"\bdecode_src=([^\s]+)", line)
    if m:
        src = m.group(1)
    return dec, src


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    add_stamp_args(ap)
    ap.add_argument("--require", action="store_true", help="rc=77 if pair missing")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--from-json", type=Path, dest="from_json")
    args = ap.parse_args()

    if args.self_test:
        print("PRE-REGISTER artifact_stamp fleet rule")
        ok = True
        bad = stamp_from_args()
        if bad.pair_ok:
            print("FAIL empty pair_ok"); ok = False
        else:
            print("PASS empty => not pair_ok")
        o, reason, rc = require_stamp(bad)
        if o or rc != RC_UNSCORED:
            print("FAIL require empty"); ok = False
        else:
            print("PASS require empty UNSCORED")
        # short md5 refused
        short = stamp_from_args(rbf_md5="c5382bee", daemon_md5="7c991e47")
        if short.pair_ok:
            print("FAIL short accepted"); ok = False
        else:
            print("PASS short md5 refused (need 32 hex)")
        good = stamp_from_args(
            rbf_md5="c5382bee73cecdee8220b811e529c297",
            daemon_md5="7c991e47aaaaaaaaaaaaaaaaaaaaaaaa",
            decode_src="caller_supplied",
            decode="624x480",
        )
        if not good.pair_ok:
            print("FAIL good pair"); ok = False
        else:
            print("PASS good pair", good.artifact_pair)
        print(good.header_kv())
        if refuse_pool_decode_src("caller_supplied", "conf:/x"):
            print("PASS refuse pool decode_src")
        else:
            print("FAIL pool"); ok = False
        # local file hash
        p = Path(__file__).resolve()
        local = stamp_from_args(rbf_file=p, daemon_file=p)
        if not local.pair_ok or local.rbf_md5 != local.daemon_md5:
            print("FAIL local file hash"); ok = False
        else:
            print("PASS local file hash")
        print("SELF_TEST_OK" if ok else "SELF_TEST_FAIL")
        return RC_OK if ok else RC_FAIL

    if args.from_json:
        args.stamp_json = args.from_json
    st = stamp_from_namespace(args)
    print(st.header_kv())
    print(json.dumps(st.to_dict(), sort_keys=True))
    if args.require or True:
        # default: reporting mode; --require sets rc
        if args.require:
            o, reason, rc = require_stamp(st)
            if not o:
                print(f"verdict=UNSCORED reason={reason}")
                return rc
            print("verdict=PAIR_OK")
            return RC_OK
    return RC_OK if st.pair_ok else RC_UNSCORED


if __name__ == "__main__":
    # Make importable as tools.artifact_stamp or plain when run from tools/
    sys.exit(main())
