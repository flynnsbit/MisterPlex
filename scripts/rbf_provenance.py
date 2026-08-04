#!/usr/bin/env python3
"""RBF provenance binding — unforgeable link from bitstream bytes to source tree.

Named defect: parent reasoned about current RTL from deployed Plex.rbf md5
dfebf2bf (G-VID1 / FPGA commit 0139f2c5) where ddr_frame_store.sv did not yet
exist. Nothing mechanically bound RBF bytes → git commit + QIP file list.

This tool:
  emit     — write Plex.rbf.provenance.json next to an RBF + registry copy
  verify   — require manifest matches RBF md5 (+ optional tree/qip check)
  lookup   — answer "what commit built this md5/RBF?"
  device   — read on-device md5 (ssh) and lookup (parent runs HW; agents may dry-run)
  selftest — RED/GREEN twins (no network, no Quartus)

Manifest fields (schema misterplex.rbf_provenance.v1):
  rbf_md5, git_commit, git_dirty, qip_files[], qip_list_sha256, files_qip_sha256

Exit codes (soft-skip 77 is NEVER a pass):
  0  PASS / found
  1  mismatch / missing critical binding
  2  bad args / missing inputs (cannot determine → fail, not pass)
  8  deploy-class: no matching manifest for RBF (distinct refuse)
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

SCHEMA = "misterplex.rbf_provenance.v1"
ROOT_DEFAULT = Path(__file__).resolve().parents[1]
# Under release_artifacts/ (tracked via !release_artifacts/**) — not gitignored artifacts/.
REGISTRY_REL = Path("release_artifacts/rbf-manifests")
SIDECAR_SUFFIX = ".provenance.json"
_QIP_SV = re.compile(
    r"set_global_assignment\s+-name\s+(?:SYSTEMVERILOG_FILE|VERILOG_FILE|VHDL_FILE|SDC_FILE)\s+(\S+)",
    re.I,
)


def _utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _md5_file(path: Path) -> str:
    h = hashlib.md5()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()


def _sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _run_git(root: Path, *args: str) -> tuple[int, str]:
    try:
        p = subprocess.run(
            ["git", "-C", str(root), *args],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError as e:
        return 127, str(e)
    out = (p.stdout or "").strip()
    if p.returncode != 0 and p.stderr:
        out = (out + "\n" + p.stderr).strip()
    return p.returncode, out


def git_identity(root: Path) -> dict:
    rc, commit = _run_git(root, "rev-parse", "HEAD")
    if rc != 0 or not re.fullmatch(r"[0-9a-f]{40}", commit):
        return {
            "git_commit": "",
            "git_commit_short": "",
            "git_dirty": True,
            "git_describe": "",
            "error": f"rev-parse failed rc={rc} out={commit!r}",
        }
    rc_d, dirty_out = _run_git(root, "status", "--porcelain")
    dirty = rc_d != 0 or bool(dirty_out.strip())
    rc_g, describe = _run_git(root, "describe", "--tags", "--always", "--dirty")
    if rc_g != 0:
        describe = commit[:12] + ("-dirty" if dirty else "")
    return {
        "git_commit": commit,
        "git_commit_short": commit[:12],
        "git_dirty": dirty,
        "git_describe": describe,
        "error": "",
    }


def parse_qip_files(qip: Path) -> list[str]:
    """Active (non-comment) design file entries from files.qip, relative paths."""
    if not qip.is_file():
        return []
    out: list[str] = []
    for line in qip.read_text(errors="replace").splitlines():
        s = line.strip()
        if not s or s.startswith("//") or s.startswith("#"):
            continue
        m = _QIP_SV.search(s)
        if not m:
            continue
        rel = m.group(1).strip().strip('"')
        if rel.startswith("["):
            continue
        out.append(rel)
    return out


def qip_list_digest(files: list[str]) -> str:
    payload = "\n".join(files) + ("\n" if files else "")
    return _sha256_text(payload)


def build_manifest(
    *,
    rbf: Path,
    root: Path,
    builder: str = "emit",
    extra: dict | None = None,
) -> dict:
    if not rbf.is_file():
        raise FileNotFoundError(f"RBF not found: {rbf}")
    plex_dir = root / "fpga" / "Plex_MiSTer"
    qip = plex_dir / "files.qip"
    qip_files = parse_qip_files(qip)
    ident = git_identity(root)
    if ident.get("error") and not ident.get("git_commit"):
        raise RuntimeError(ident["error"])
    man = {
        "schema": SCHEMA,
        "rbf_md5": _md5_file(rbf),
        "rbf_basename": rbf.name,
        "git_commit": ident["git_commit"],
        "git_commit_short": ident["git_commit_short"],
        "git_dirty": bool(ident["git_dirty"]),
        "git_describe": ident["git_describe"],
        "qip_files": qip_files,
        "qip_file_count": len(qip_files),
        "qip_list_sha256": qip_list_digest(qip_files),
        "files_qip_sha256": _sha256_file(qip) if qip.is_file() else "",
        "created_utc": _utc_now(),
        "builder": builder,
        "root_note": str(root),
    }
    if extra:
        man.update(extra)
    return man


def sidecar_path(rbf: Path) -> Path:
    return Path(str(rbf) + SIDECAR_SUFFIX)


def registry_path(root: Path, rbf_md5: str) -> Path:
    return root / REGISTRY_REL / f"{rbf_md5.lower()}.json"


def write_manifest(man: dict, rbf: Path, root: Path) -> tuple[Path, Path]:
    side = sidecar_path(rbf)
    side.write_text(json.dumps(man, indent=2, sort_keys=True) + "\n")
    reg = registry_path(root, man["rbf_md5"])
    reg.parent.mkdir(parents=True, exist_ok=True)
    reg.write_text(json.dumps(man, indent=2, sort_keys=True) + "\n")
    return side, reg


def load_json(path: Path) -> dict:
    return json.loads(path.read_text())


def find_manifest_for_md5(root: Path, rbf_md5: str, rbf: Path | None = None) -> Path | None:
    md = rbf_md5.lower()
    candidates: list[Path] = []
    if rbf is not None:
        candidates.append(sidecar_path(rbf))
        candidates.append(rbf.with_suffix(rbf.suffix + ".provenance.json"))
    candidates.append(registry_path(root, md))
    # Also scan registry dir for prefix8 hits only if full md5 file missing — no.
    for c in candidates:
        if c.is_file():
            try:
                man = load_json(c)
            except (OSError, json.JSONDecodeError):
                continue
            if str(man.get("rbf_md5", "")).lower() == md:
                return c
    return None


def verify_manifest(
    man: dict,
    *,
    rbf: Path | None,
    root: Path | None,
    require_clean: bool = False,
    check_tree_qip: bool = False,
) -> list[str]:
    errs: list[str] = []
    if man.get("schema") != SCHEMA:
        errs.append(f"bad_schema got={man.get('schema')!r} want={SCHEMA}")
    md = str(man.get("rbf_md5", "")).lower()
    if not re.fullmatch(r"[0-9a-f]{32}", md):
        errs.append(f"bad_rbf_md5={md!r}")
    commit = str(man.get("git_commit", ""))
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        errs.append(f"bad_git_commit={commit!r}")
    qip_files = man.get("qip_files")
    if not isinstance(qip_files, list) or not qip_files:
        errs.append("qip_files missing_or_empty")
    else:
        want = qip_list_digest([str(x) for x in qip_files])
        got = str(man.get("qip_list_sha256", ""))
        if got != want:
            errs.append(f"qip_list_sha256_mismatch got={got} want={want}")
    if rbf is not None:
        if not rbf.is_file():
            errs.append(f"rbf_missing={rbf}")
        else:
            actual = _md5_file(rbf)
            if actual != md:
                errs.append(f"rbf_md5_mismatch file={actual} manifest={md}")
    if require_clean and man.get("git_dirty") is True:
        errs.append("git_dirty=true refused")
    if check_tree_qip and root is not None:
        qip = root / "fpga" / "Plex_MiSTer" / "files.qip"
        live = parse_qip_files(qip)
        live_d = qip_list_digest(live)
        man_d = str(man.get("qip_list_sha256", ""))
        if live_d != man_d:
            errs.append(
                f"tree_qip_mismatch live={live_d[:12]} man={man_d[:12]} "
                f"live_count={len(live)} man_count={man.get('qip_file_count')}"
            )
        ident = git_identity(root)
        if ident.get("git_commit") and ident["git_commit"] != commit:
            # Informational mismatch when verifying historical RBF against live tree.
            errs.append(
                f"tree_commit_mismatch live={ident['git_commit'][:12]} "
                f"man={commit[:12]}"
            )
    return errs


def cmd_emit(args: argparse.Namespace) -> int:
    root = Path(args.root).resolve()
    rbf = Path(args.rbf).resolve()
    try:
        man = build_manifest(rbf=rbf, root=root, builder=args.builder)
    except (OSError, RuntimeError) as e:
        print(f"RBF_PROVENANCE_FAIL emit: {e}", file=sys.stderr)
        print("true rc=2")
        return 2
    if args.require_clean and man["git_dirty"]:
        print("RBF_PROVENANCE_FAIL emit git_dirty=1 (require_clean)", file=sys.stderr)
        print("true rc=1")
        return 1
    side, reg = write_manifest(man, rbf, root)
    print(f"RBF_PROVENANCE_OK emit md5={man['rbf_md5']}")
    print(f"  git_commit={man['git_commit']}")
    print(f"  git_dirty={int(man['git_dirty'])} describe={man['git_describe']}")
    print(f"  qip_file_count={man['qip_file_count']} qip_list_sha256={man['qip_list_sha256'][:16]}…")
    print(f"  sidecar={side}")
    print(f"  registry={reg}")
    print("EXECUTED emit=1")
    print("true rc=0")
    return 0


def cmd_verify(args: argparse.Namespace) -> int:
    root = Path(args.root).resolve()
    rbf = Path(args.rbf).resolve() if args.rbf else None
    man_path = Path(args.manifest).resolve() if args.manifest else None
    if man_path is None:
        if rbf is None:
            print("RBF_PROVENANCE_FAIL verify needs --rbf or --manifest", file=sys.stderr)
            print("true rc=2")
            return 2
        md = _md5_file(rbf) if rbf.is_file() else ""
        found = find_manifest_for_md5(root, md, rbf) if md else None
        if found is None:
            print(
                f"RBF_PROVENANCE_NO_MANIFEST md5={md or 'unknown'} "
                f"(sidecar/registry missing) — cannot bind RBF to source",
                file=sys.stderr,
            )
            print("EXECUTED verify=1 no_manifest=1")
            print("true rc=8")
            return 8
        man_path = found
    if not man_path.is_file():
        print(f"RBF_PROVENANCE_FAIL missing manifest {man_path}", file=sys.stderr)
        print("true rc=8")
        return 8
    try:
        man = load_json(man_path)
    except (OSError, json.JSONDecodeError) as e:
        print(f"RBF_PROVENANCE_FAIL bad_json {man_path}: {e}", file=sys.stderr)
        print("true rc=1")
        return 1
    errs = verify_manifest(
        man,
        rbf=rbf,
        root=root if args.check_tree else None,
        require_clean=args.require_clean,
        check_tree_qip=args.check_tree,
    )
    if errs:
        print(f"RBF_PROVENANCE_FAIL verify path={man_path}", file=sys.stderr)
        for e in errs:
            print(f"  ERR {e}", file=sys.stderr)
        print("EXECUTED verify=1")
        print("true rc=1")
        return 1
    print(f"RBF_PROVENANCE_OK verify path={man_path}")
    print(f"  rbf_md5={man.get('rbf_md5')}")
    print(f"  git_commit={man.get('git_commit')}")
    print(f"  git_dirty={man.get('git_dirty')} qip_file_count={man.get('qip_file_count')}")
    print("EXECUTED verify=1")
    print("true rc=0")
    return 0


def cmd_lookup(args: argparse.Namespace) -> int:
    root = Path(args.root).resolve()
    md = (args.md5 or "").lower().strip()
    rbf = Path(args.rbf).resolve() if args.rbf else None
    if not md and rbf is not None and rbf.is_file():
        md = _md5_file(rbf)
    if not re.fullmatch(r"[0-9a-f]{8,32}", md or ""):
        print("RBF_PROVENANCE_FAIL lookup needs --md5 or --rbf", file=sys.stderr)
        print("true rc=2")
        return 2
    # Prefer full 32; allow prefix search in registry.
    found: Path | None = None
    if len(md) == 32:
        found = find_manifest_for_md5(root, md, rbf)
    else:
        reg_dir = root / REGISTRY_REL
        if reg_dir.is_dir():
            hits = sorted(reg_dir.glob(f"{md}*.json"))
            if len(hits) == 1:
                found = hits[0]
            elif len(hits) > 1:
                print(
                    f"RBF_PROVENANCE_FAIL ambiguous prefix md5={md} hits={len(hits)}",
                    file=sys.stderr,
                )
                for h in hits[:8]:
                    print(f"  {h.name}", file=sys.stderr)
                print("true rc=1")
                return 1
    if found is None:
        print(f"RBF_PROVENANCE_UNKNOWN md5={md} — no registry/sidecar manifest")
        print("EXECUTED lookup=1")
        print("true rc=8")
        return 8
    man = load_json(found)
    # One-command answer for parent
    print("RBF_WHAT_BUILT")
    print(f"  rbf_md5={man.get('rbf_md5')}")
    print(f"  git_commit={man.get('git_commit')}")
    print(f"  git_commit_short={man.get('git_commit_short')}")
    print(f"  git_dirty={man.get('git_dirty')}")
    print(f"  git_describe={man.get('git_describe')}")
    print(f"  qip_file_count={man.get('qip_file_count')}")
    print(f"  qip_list_sha256={man.get('qip_list_sha256')}")
    print(f"  files_qip_sha256={man.get('files_qip_sha256')}")
    print(f"  created_utc={man.get('created_utc')}")
    print(f"  builder={man.get('builder')}")
    print(f"  manifest={found}")
    note = man.get("historical_note")
    if note:
        print(f"  historical_note={note}")
    # Show whether key modules were in that QIP (ddr_frame_store class)
    qip = man.get("qip_files") or []
    for needle in (
        "rtl/ddr_frame_store.sv",
        "rtl/ddram_frame_rd.sv",
        "rtl/h264_decode_top.sv",
        "rtl/decode_stub.sv",
    ):
        present = any(str(x).endswith(needle) or str(x) == needle for x in qip)
        print(f"  qip_has_{Path(needle).stem}={int(present)}")
    print("EXECUTED lookup=1")
    print("true rc=0")
    return 0


def cmd_device(args: argparse.Namespace) -> int:
    """SSH to device, md5 /media/fat/_Utility/Plex.rbf, then lookup."""
    root = Path(args.root).resolve()
    host = args.host or os.environ.get("MISTER_HOST", "192.168.1.183")
    user = args.user or os.environ.get("MISTER_USER", "root")
    password = args.password or os.environ.get("MISTER_PASS", "1")
    remote = args.remote_rbf or "/media/fat/_Utility/Plex.rbf"
    if args.md5:
        md = args.md5.lower().strip()
    else:
        cmd = [
            "sshpass",
            "-p",
            password,
            "ssh",
            "-o",
            "StrictHostKeyChecking=no",
            "-o",
            "ConnectTimeout=12",
            f"{user}@{host}",
            f"md5sum {remote}",
        ]
        try:
            p = subprocess.run(cmd, capture_output=True, text=True, check=False)
        except OSError as e:
            print(f"RBF_PROVENANCE_FAIL device ssh: {e}", file=sys.stderr)
            print("true rc=2")
            return 2
        if p.returncode != 0:
            print(
                f"RBF_PROVENANCE_FAIL device md5 rc={p.returncode} "
                f"stderr={(p.stderr or '').strip()}",
                file=sys.stderr,
            )
            print("true rc=2")
            return 2
        m = re.search(r"\b([0-9a-fA-F]{32})\b", p.stdout or "")
        if not m:
            print(f"RBF_PROVENANCE_FAIL parse md5 from: {p.stdout!r}", file=sys.stderr)
            print("true rc=2")
            return 2
        md = m.group(1).lower()
        print(f"device_rbf={remote} md5={md} host={user}@{host}")
    # reuse lookup
    ns = argparse.Namespace(root=str(root), md5=md, rbf=None)
    return cmd_lookup(ns)


def _selftest(root: Path) -> int:
    """RED/GREEN twins. No Quartus. No device."""
    print("RBF_PROVENANCE_SELFTEST start")
    failures = 0
    with tempfile.TemporaryDirectory(prefix="rbf-prov-") as td:
        td_path = Path(td)
        # Minimal fake tree with files.qip
        plex = td_path / "fpga" / "Plex_MiSTer"
        (plex / "rtl").mkdir(parents=True)
        qip_body = (
            "set_global_assignment -name SYSTEMVERILOG_FILE rtl/decode_stub.sv\n"
            "set_global_assignment -name SYSTEMVERILOG_FILE rtl/ddr_frame_store.sv\n"
            "#set_global_assignment -name SYSTEMVERILOG_FILE rtl/commented_out.sv\n"
        )
        (plex / "files.qip").write_text(qip_body)
        (plex / "rtl" / "decode_stub.sv").write_text("module decode_stub; endmodule\n")
        (plex / "rtl" / "ddr_frame_store.sv").write_text(
            "module ddr_frame_store; endmodule\n"
        )
        # Init git so commit binds
        subprocess.run(["git", "init"], cwd=td_path, check=True, capture_output=True)
        subprocess.run(
            ["git", "config", "user.email", "fitgate@test"],
            cwd=td_path,
            check=True,
            capture_output=True,
        )
        subprocess.run(
            ["git", "config", "user.name", "fitgate"],
            cwd=td_path,
            check=True,
            capture_output=True,
        )
        subprocess.run(["git", "add", "-A"], cwd=td_path, check=True, capture_output=True)
        subprocess.run(
            ["git", "commit", "-m", "prov selftest"],
            cwd=td_path,
            check=True,
            capture_output=True,
        )
        rbf = td_path / "Plex.rbf"
        rbf.write_bytes(b"FAKE_RBF_BYTES_FOR_PROVENANCE_SELFTEST_v1\n")

        # GREEN: emit + verify
        man = build_manifest(rbf=rbf, root=td_path, builder="selftest")
        side, reg = write_manifest(man, rbf, td_path)
        errs = verify_manifest(man, rbf=rbf, root=td_path, check_tree_qip=True)
        if errs:
            print(f"SELFTEST_FAIL green_verify errs={errs}")
            failures += 1
        else:
            print("SELFTEST_OK green_emit_verify EXECUTED=1")
        if "rtl/commented_out.sv" in man["qip_files"]:
            print("SELFTEST_FAIL commented_qip_treated_active")
            failures += 1
        else:
            print("SELFTEST_OK commented_qip_absent")

        # RED: no manifest
        orphan = td_path / "orphan.rbf"
        orphan.write_bytes(b"ORPHAN_RBF_NO_MANIFEST\n")
        found = find_manifest_for_md5(td_path, _md5_file(orphan), orphan)
        if found is not None:
            print("SELFTEST_FAIL orphan_should_have_no_manifest")
            failures += 1
        else:
            print("SELFTEST_OK no_manifest_red EXECUTED=1")

        # RED: md5 mismatch
        bad = dict(man)
        bad["rbf_md5"] = "0" * 32
        errs = verify_manifest(bad, rbf=rbf, root=None)
        if not any("rbf_md5_mismatch" in e for e in errs):
            print(f"SELFTEST_FAIL expected md5 mismatch got={errs}")
            failures += 1
        else:
            print("SELFTEST_OK md5_mismatch_red EXECUTED=1")

        # RED: empty qip_files
        bad2 = dict(man)
        bad2["qip_files"] = []
        bad2["qip_list_sha256"] = qip_list_digest([])
        errs = verify_manifest(bad2, rbf=rbf, root=None)
        if not any("qip_files" in e for e in errs):
            print(f"SELFTEST_FAIL expected empty qip fail got={errs}")
            failures += 1
        else:
            print("SELFTEST_OK empty_qip_red EXECUTED=1")

        # RED: qip digest tamper
        bad3 = dict(man)
        bad3["qip_list_sha256"] = "deadbeef" * 8
        errs = verify_manifest(bad3, rbf=rbf, root=None)
        if not any("qip_list_sha256_mismatch" in e for e in errs):
            print(f"SELFTEST_FAIL expected qip digest fail got={errs}")
            failures += 1
        else:
            print("SELFTEST_OK qip_digest_tamper_red EXECUTED=1")

        # RED: tree qip drift (add file to live qip without updating man)
        (plex / "files.qip").write_text(
            qip_body + "set_global_assignment -name SYSTEMVERILOG_FILE rtl/extra.sv\n"
        )
        errs = verify_manifest(man, rbf=rbf, root=td_path, check_tree_qip=True)
        if not any("tree_qip_mismatch" in e for e in errs):
            print(f"SELFTEST_FAIL expected tree_qip_mismatch got={errs}")
            failures += 1
        else:
            print("SELFTEST_OK tree_qip_drift_red EXECUTED=1")

        # Lookup GREEN via registry
        ns = argparse.Namespace(root=str(td_path), md5=man["rbf_md5"], rbf=None)
        # capture lookup by calling internals
        found2 = find_manifest_for_md5(td_path, man["rbf_md5"], None)
        if found2 is None or found2 != reg:
            print(f"SELFTEST_FAIL registry_lookup got={found2}")
            failures += 1
        else:
            print("SELFTEST_OK registry_lookup EXECUTED=1")

        _ = side  # silence lint
        print(f"sidecar_bytes={side.stat().st_size} registry={reg.name}")

    # Historical seed must exist for G-VID1 class (dfebf2bf) in real repo
    hist = root / REGISTRY_REL / "dfebf2bfd08dd70b473b587dd7e81848.json"
    if not hist.is_file() and (root / REGISTRY_REL).is_dir():
        hits = sorted((root / REGISTRY_REL).glob("dfebf2bf*.json"))
        hist = hits[0] if hits else hist
    if not hist.is_file():
        print(
            "SELFTEST_FAIL missing historical G-VID1 manifest "
            "release_artifacts/rbf-manifests/dfebf2bf….json"
        )
        failures += 1
    else:
        hman = load_json(hist)
        c = str(hman.get("git_commit", ""))
        if not c.startswith("0139f2c5"):
            print(f"SELFTEST_FAIL G-VID1 commit want 0139f2c5* got={c}")
            failures += 1
        else:
            print(f"SELFTEST_OK historical_gvid1_commit={c[:12]}")
        qip = hman.get("qip_files") or []
        has_store = any("ddr_frame_store" in str(x) for x in qip)
        has_rd = any("ddram_frame_rd" in str(x) for x in qip)
        if has_store:
            print("SELFTEST_FAIL G-VID1 must NOT list ddr_frame_store (added later)")
            failures += 1
        elif not has_rd:
            print("SELFTEST_FAIL G-VID1 must list ddram_frame_rd")
            failures += 1
        else:
            print(
                "SELFTEST_OK historical_gvid1_qip "
                f"ddr_frame_store=0 ddram_frame_rd=1 count={len(qip)}"
            )

    print(f"RBF_PROVENANCE_SELFTEST failures={failures}")
    print("EXECUTED selftest=1")
    rc = 0 if failures == 0 else 1
    print(f"true rc={rc}")
    return rc


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", default=str(ROOT_DEFAULT), help="repo root")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_em = sub.add_parser("emit", help="Write sidecar + registry manifest for an RBF")
    p_em.add_argument("--rbf", required=True)
    p_em.add_argument("--builder", default="emit")
    p_em.add_argument(
        "--require-clean",
        action="store_true",
        help="Refuse emit when git worktree is dirty",
    )

    p_v = sub.add_parser("verify", help="Verify RBF against sidecar/registry manifest")
    p_v.add_argument("--rbf", default="")
    p_v.add_argument("--manifest", default="")
    p_v.add_argument("--require-clean", action="store_true")
    p_v.add_argument(
        "--check-tree",
        action="store_true",
        help="Also require live files.qip list digest matches manifest",
    )

    p_l = sub.add_parser("lookup", help="What commit built this RBF md5?")
    p_l.add_argument("--md5", default="")
    p_l.add_argument("--rbf", default="")

    p_d = sub.add_parser(
        "device",
        help="md5 on-device Plex.rbf then lookup (needs sshpass; parent HW)",
    )
    p_d.add_argument("--host", default="")
    p_d.add_argument("--user", default="")
    p_d.add_argument("--password", default="")
    p_d.add_argument("--remote-rbf", default="/media/fat/_Utility/Plex.rbf")
    p_d.add_argument(
        "--md5",
        default="",
        help="Skip SSH; lookup this md5 (agent-safe dry path)",
    )

    sub.add_parser("selftest", help="RED/GREEN twins")

    args = ap.parse_args(argv)
    if args.cmd == "emit":
        return cmd_emit(args)
    if args.cmd == "verify":
        return cmd_verify(args)
    if args.cmd == "lookup":
        return cmd_lookup(args)
    if args.cmd == "device":
        return cmd_device(args)
    if args.cmd == "selftest":
        return _selftest(Path(args.root).resolve())
    print(f"unknown cmd {args.cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
