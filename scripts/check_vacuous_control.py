#!/usr/bin/env python3
"""Mechanical guard against vacuous A/B comparisons.

Use this before accepting an experiment as evidence.  Declare which inputs are
supposed to be identical and which independent variable(s) are supposed to vary;
the script hashes the real files/directories in each run directory and fails if
that premise is false.
"""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
from pathlib import Path

DEFAULT_EXCLUDES = (
    ".git/**",
    "db/**",
    "incremental_db/**",
    "output_files/**",
    "simulation/**",
    "build/**",
    "*.bak",
)


def md5_file(path: Path) -> str:
    h = hashlib.md5()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def excluded(rel: str, patterns: tuple[str, ...]) -> bool:
    return any(fnmatch.fnmatch(rel, pat) or fnmatch.fnmatch(Path(rel).name, pat) for pat in patterns)


def digest_path(root: Path, rel: str, excludes: tuple[str, ...]) -> tuple[str, int]:
    path = root / rel
    if not path.exists():
        raise FileNotFoundError(str(path))
    if path.is_file():
        return md5_file(path), 1
    if not path.is_dir():
        raise ValueError(f"not a file or directory: {path}")

    rows: list[str] = []
    for child in sorted(path.rglob("*")):
        if not child.is_file():
            continue
        child_rel = child.relative_to(path).as_posix()
        full_rel = (Path(rel) / child_rel).as_posix()
        if excluded(child_rel, excludes) or (rel in ("", ".") and excluded(full_rel, excludes)):
            continue
        rows.append(f"{child_rel}\0{md5_file(child)}")
    h = hashlib.md5("\n".join(rows).encode()).hexdigest()
    return h, len(rows)


def check_group(label: str, rels: list[str], roots: list[Path], should_differ: bool, excludes: tuple[str, ...]) -> bool:
    ok = True
    for rel in rels:
        print(f"CHECK {label} {rel}")
        digests: list[str] = []
        for root in roots:
            try:
                digest, count = digest_path(root, rel, excludes)
                digests.append(digest)
                print(f"  ROOT {root} digest={digest} files={count}")
            except Exception as e:  # noqa: BLE001 - report all premise failures uniformly.
                ok = False
                digests.append(f"ERROR:{e}")
                print(f"  ROOT {root} ERROR {e}")
        unique = len(set(digests))
        if should_differ:
            passed = unique > 1
            status = "DIFF_OK" if passed else "DIFF_FALSE_VACUOUS"
        else:
            passed = unique == 1
            status = "SAME_OK" if passed else "SAME_FALSE_CONFOUNDED"
        ok = ok and passed
        print(f"  RESULT {status} distinct={unique}")
    return ok


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("roots", nargs="+", type=Path, help="run/source directories to compare")
    ap.add_argument("--same", action="append", default=[], help="relative file/dir that must be identical across roots")
    ap.add_argument("--different", action="append", default=[], help="relative file/dir that must differ across roots")
    ap.add_argument("--exclude", action="append", default=[], help="extra glob to exclude when hashing directories")
    ap.add_argument("--no-default-excludes", action="store_true", help="disable default directory excludes")
    args = ap.parse_args()

    roots = [p.resolve() for p in args.roots]
    if len(roots) < 2:
        ap.error("need at least two roots")
    if not args.same and not args.different:
        ap.error("declare at least one --same or --different premise")

    excludes = tuple(args.exclude) if args.no_default_excludes else tuple(DEFAULT_EXCLUDES) + tuple(args.exclude)
    print("VACUOUS_CONTROL_CHECK")
    for root in roots:
        print(f"ROOT {root}")
    print(f"EXCLUDES {','.join(excludes) if excludes else '<none>'}")

    same_ok = check_group("SAME", args.same, roots, False, excludes)
    diff_ok = check_group("DIFFERENT", args.different, roots, True, excludes)
    passed = same_ok and diff_ok
    print(f"SUMMARY {'PASS' if passed else 'FAIL'}")
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
