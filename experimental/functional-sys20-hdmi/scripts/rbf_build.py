#!/usr/bin/env python3
"""Serial, snapshot-only Quartus transactions shared by both build entrypoints."""
from __future__ import annotations

import argparse
import contextlib
import ctypes
from datetime import datetime, timezone
import errno
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import uuid

ROOT = Path(__file__).resolve().parents[1] if "__file__" in globals() else Path.cwd()
IMAGE = "ghcr.io/raetro/quartus:mister"
GENERATED = {"db", "incremental_db", "output_files", "remote_out", "local_out",
             "greybox_tmp", "build", ".git"}
SOURCE_SUFFIXES = {".qpf", ".qsf", ".qip", ".qsys", ".ip", ".sip", ".sdc", ".tcl",
                   ".v", ".sv", ".vh", ".svh", ".vhd", ".vhdl", ".mif", ".hex",
                   ".mem", ".dat", ".inc", ".srf"}
ARTIFACTS = ("Plex.rbf", "Plex.sta.rpt", "Plex.fit.rpt", "Plex.map.rpt")
DIAGNOSTIC_FILES = 128
DIAGNOSTIC_ENTRIES = 4096
DIAGNOSTIC_FILE_BYTES = 32 * 1024**2
DIAGNOSTIC_TOTAL_BYTES = 128 * 1024**2
DISK_RESERVE = 8 * 1024**3
BUILD_DATE_EXPRESSION = "[clock format [ clock seconds ] -format %y%m%d]"
CONTROLLER_KEY = 0x4D505843  # MPXC, fixed across clones and backend choices.
EXECUTION_KEY = 0x4D505845   # MPXE, fixed across SSH users and Docker daemons.
LIBC = ctypes.CDLL(None, use_errno=True)
TIMING_FILE_BYTES = 8 * 1024**2
TIMING_TOTAL_BYTES = 128 * 1024**2
TIMING_RUNNER = """#!/bin/sh
set -u
reporter=$1
destination=$2
quartus_sh --flow compile Plex.qpf
compile_rc=$?
printf '%s\\n' "$compile_rc" >"$destination/compile.exit"
status_rc=$?
if [ "$compile_rc" -ne 0 ]; then exit "$compile_rc"; fi
if [ "$status_rc" -ne 0 ]; then exit "$status_rc"; fi
sha256sum output_files/Plex.rbf >"$destination/rbf.before.sha256" || exit 1
quartus_sta -t "$reporter" "$destination"
report_rc=$?
printf '%s\\n' "$report_rc" >"$destination/reporter.exit"
status_rc=$?
if [ "$report_rc" -ne 0 ]; then exit "$report_rc"; fi
if [ "$status_rc" -ne 0 ]; then exit "$status_rc"; fi
sha256sum output_files/Plex.rbf >"$destination/rbf.after.sha256" || exit 1
if ! cmp -s "$destination/rbf.before.sha256" "$destination/rbf.after.sha256"; then
    echo "REFUSED: timing reporter changed Plex.rbf" >&2
    exit 1
fi
"""


class UnresolvedBuild(RuntimeError):
    """Ownership and input files must survive an unconfirmed execution outcome."""


class Lease:
    def __init__(self, fd=None, owner=None):
        self.fd, self.owner, self.safe = fd, owner, True

    def retain(self, reason):
        self.safe = False
        if self.owner:
            write_json(self.owner, {"pid": os.getpid(), "host": os.uname().nodename,
                                    "unresolved": str(reason)})
            with self.owner.open() as stream:
                os.fsync(stream.fileno())

    def confirmed(self):
        self.safe = True
        if self.owner:
            write_json(self.owner, {"pid": os.getpid(), "host": os.uname().nodename,
                                    "safe_to_release": True})


class SemOperation(ctypes.Structure):
    _fields_ = [("number", ctypes.c_ushort), ("operation", ctypes.c_short), ("flags", ctypes.c_short)]


def semaphore_id(key):
    sem = LIBC.semget(key, 1, 0o1000 | 0o2000 | 0o666)  # IPC_CREAT | IPC_EXCL
    if sem >= 0:
        if LIBC.semctl(sem, 0, 16, 1) < 0:  # SETVAL; crash before this stays locked.
            raise OSError(ctypes.get_errno(), "cannot initialize host fit semaphore")
        return sem
    if ctypes.get_errno() != errno.EEXIST:
        raise OSError(ctypes.get_errno(), "cannot create host fit semaphore")
    sem = LIBC.semget(key, 1, 0o666)
    if sem < 0:
        raise OSError(ctypes.get_errno(), "cannot access host fit semaphore")
    return sem


@contextlib.contextmanager
def host_lock(key):
    sem = semaphore_id(key)
    operation = SemOperation(0, -1, 0o4000)  # IPC_NOWAIT, deliberately NO SEM_UNDO.
    if LIBC.semop(sem, ctypes.byref(operation), 1) < 0:
        error = ctypes.get_errno()
        if error == errno.EAGAIN:
            raise RuntimeError(f"REFUSED: host single-fit lease busy/unresolved: key={key:#x} semid={sem}")
        raise OSError(error, "cannot acquire host fit semaphore")
    lease = Lease()
    try:
        yield lease
    finally:
        if lease.safe:
            operation.operation = 1
            if LIBC.semop(sem, ctypes.byref(operation), 1) < 0:
                raise OSError(ctypes.get_errno(), "cannot release host fit semaphore")


@contextlib.contextmanager
def cleanup_signals():
    handlers = {sig: signal.signal(sig, signal.SIG_IGN)
                for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    try:
        yield
    finally:
        for sig, handler in handlers.items():
            signal.signal(sig, handler)


def run(args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, **kwargs)


def output(args):
    return run(args, stdout=subprocess.PIPE, text=True).stdout.strip()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")


@contextlib.contextmanager
def fit_lock(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError(f"REFUSED: single-fit lock is busy: {path}") from None
        # Never unlink the inode: an older waiter may still have it open.
        owner = path.with_name(path.name + ".owner")
        if owner.exists():
            raise RuntimeError(f"REFUSED: unclean previous transaction; inspect owner and running builds: {owner}")
        write_json(owner, {"pid": os.getpid(), "host": os.uname().nodename})
        lease = Lease(lock.fileno(), owner)
        try:
            yield lease
        finally:
            if lease.safe:
                owner.unlink()


def check_disk(path, source_bytes):
    free = shutil.disk_usage(path).free
    required = DISK_RESERVE + source_bytes * 3
    if free < required:
        raise RuntimeError(f"REFUSED: disk free {free} < required {required} at {path}")


def repository_lock(root):
    common = Path(output(["git", "-C", root, "rev-parse", "--path-format=absolute", "--git-common-dir"]))
    return common / "misterplex-build/single-fit.lock"


def source_files(project):
    names = output(["git", "-C", project, "ls-files", "-z", "--cached", "--others",
                    "--exclude-standard", "--", "."]).split("\0")
    result = {}
    for name in sorted(set(filter(None, names))):
        rel = PurePosixPath(name)
        if name == "build_id.v" or any(part in GENERATED for part in rel.parts) or rel.suffix.lower() not in SOURCE_SUFFIXES:
            continue
        path = project / name
        if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(project):
            raise RuntimeError(f"REFUSED: missing, linked or external source: {path}")
        result[name] = path
    if not {"Plex.qpf", "Plex.qsf"} <= result.keys():
        raise RuntimeError("REFUSED: snapshot requires git-listed Plex.qpf and Plex.qsf")
    return result


def hashes(files):
    return {name: digest(path.read_bytes()) for name, path in files.items()}


def add_source_member(tar, name, data):
    member = tarfile.TarInfo(name)
    member.size, member.mode = len(data), 0o444
    tar.addfile(member, io.BytesIO(data))


def snapshot(project, destination, image, processors="", replay=None, derive_video_build_id=False,
             legacy_build_date=None):
    """Archive only source inputs; no hard links, generated trees or live mounts."""
    destination.mkdir(parents=True, exist_ok=True)
    archive = destination / "inputs.tar"
    original = destination / "source.tar"
    if replay:
        if processors:
            raise RuntimeError("REFUSED: processor override cannot modify a replay snapshot")
        replay = replay.resolve()
        meta = json.loads(replay.with_suffix(".json").read_text())
        check_disk(destination, replay.stat().st_size)
        if meta["image_id"] != image or digest(replay.read_bytes()) != meta["archive_sha256"]:
            raise RuntimeError("REFUSED: replay image or archive hash differs")
        build_id = meta.get("fpga_video_build_id")
        if derive_video_build_id and not build_id:
            raise RuntimeError("REFUSED: replay has no derived video build ID; capture new original sources")
        if build_id and (build_id != meta["source_sha256"][:8] or int(build_id, 16) == 0):
            raise RuntimeError("REFUSED: replay video build ID differs from original source digest")
        if "source_archive_sha256" in meta:
            source = replay.parent / "source.tar"
            if digest(source.read_bytes()) != meta["source_archive_sha256"]:
                raise RuntimeError("REFUSED: replay original-source archive hash differs")
            shutil.copyfile(source, original)
            original.chmod(0o444)
        elif build_id:
            raise RuntimeError("REFUSED: derived video build ID requires the original-source archive")
        shutil.copyfile(replay, archive)
    else:
        files = source_files(project)
        check_disk(destination, sum(path.stat().st_size for path in files.values()))
        before = hashes(files)
        pending = destination / "source.tar.pending"
        try:
            with tarfile.open(pending, "w") as tar:
                for name, path in files.items():
                    data = path.read_bytes()
                    if digest(data) != before[name]:
                        raise RuntimeError(f"REFUSED: source changed while snapshotting: {name}")
                    add_source_member(tar, name, data)
            if hashes(source_files(project)) != before:
                raise RuntimeError("REFUSED: live sources changed while snapshotting; retry after edits stop")
            pending.rename(original)
        finally:
            pending.unlink(missing_ok=True)
        original.chmod(0o444)
        source_sha = digest(json.dumps(before, sort_keys=True).encode())
        build_id = source_sha[:8] if derive_video_build_id else None
        if build_id and int(build_id, 16) == 0:
            raise RuntimeError("REFUSED: derived FPGA_VIDEO_BUILD_ID must be nonzero")
        if "sys/build_id.tcl" in before:
            if legacy_build_date is None:
                legacy_build_date = datetime.now(timezone.utc).strftime("%y%m%d")
            if not re.fullmatch(r"[0-9]{6}", legacy_build_date):
                raise RuntimeError("REFUSED: legacy BUILD_DATE must be YYMMDD")
        else:
            legacy_build_date = None
        effective = {}
        pending = destination / "inputs.tar.pending"
        try:
            with tarfile.open(original) as source, tarfile.open(pending, "w") as tar:
                for member in source:
                    name = member.name
                    data = source.extractfile(member).read()
                    if build_id and Path(name).suffix in (".qsf", ".qip", ".tcl"):
                        if re.search(r'(?m)^\s*set_global_assignment\b[^\n]*\bVERILOG_MACRO\s+["{]?FPGA_VIDEO_BUILD_ID\b',
                                     data.decode()):
                            raise RuntimeError("REFUSED: original source already assigns FPGA_VIDEO_BUILD_ID")
                    if name == "Plex.qsf" and processors:
                        text = data.decode()
                        pattern = r"(?m)^\s*set_global_assignment\s+-name\s+NUM_PARALLEL_PROCESSORS[^\n]*"
                        assignment = f"set_global_assignment -name NUM_PARALLEL_PROCESSORS {processors}"
                        text = re.sub(pattern, assignment, text) if re.search(pattern, text) else text + "\n" + assignment + "\n"
                        data = text.encode()
                    if name == "Plex.qsf" and build_id:
                        data += (f'\nset_global_assignment -name VERILOG_MACRO '
                                 f'"FPGA_VIDEO_BUILD_ID=32\'h{build_id}"\n').encode()
                    if name == "sys/build_id.tcl":
                        text = data.decode()
                        if text.count(BUILD_DATE_EXPRESSION) != 1:
                            raise RuntimeError("REFUSED: unsupported build_id.tcl timestamp generator")
                        data = text.replace(BUILD_DATE_EXPRESSION, legacy_build_date).encode()
                    effective[name] = digest(data)
                    add_source_member(tar, name, data)
                if legacy_build_date:
                    data = f'`define BUILD_DATE "{legacy_build_date}"'.encode()
                    effective["build_id.v"] = digest(data)
                    add_source_member(tar, "build_id.v", data)
            pending.rename(archive)
        finally:
            pending.unlink(missing_ok=True)
        meta = {
            "schema": "misterplex.rbf-inputs.v1", "image_id": image,
            "git_commit": output(["git", "-C", project, "rev-parse", "HEAD"]),
            "source_sha256": source_sha,
            "source_archive_sha256": digest(original.read_bytes()),
            "input_sha256": digest(json.dumps(effective, sort_keys=True).encode()),
            "fpga_video_build_id": build_id,
            "legacy_build_date": legacy_build_date,
            "source_files": before, "input_files": effective,
            "archive_sha256": digest(archive.read_bytes()),
            "driver_sha256": digest(Path(__file__).read_bytes()),
        }
    archive.chmod(0o444)
    write_json(destination / "inputs.json", meta)
    return meta


def unpack(archive, destination, meta):
    destination.mkdir()
    seen = {}
    with tarfile.open(archive) as tar:
        for member in tar:
            rel = PurePosixPath(member.name)
            if not member.isfile() or rel.is_absolute() or ".." in rel.parts or member.name in seen:
                raise RuntimeError("REFUSED: unsafe snapshot member")
            data = tar.extractfile(member).read()
            seen[member.name] = digest(data)
            path = destination / member.name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            path.chmod(0o444)
    if seen != meta["input_files"]:
        raise RuntimeError("REFUSED: snapshot source manifest mismatch")


class DockerEndpoint:
    """One immutable endpoint/daemon binding for the entire execution lease."""

    def __init__(self, endpoint):
        self.socket_path = Path(endpoint[len("unix://"):]).resolve(strict=True)
        self.endpoint = "unix://" + str(self.socket_path)
        self.env = os.environ.copy()
        self.env.pop("DOCKER_CONTEXT", None)
        self.env.pop("DOCKER_HOST", None)
        self.socket_identity = self.socket_signature()
        self.daemon_id = self.read_daemon_id()
        self.check_identity()

    def command(self, args):
        return ["docker", "--host", self.endpoint, *args]

    def socket_signature(self):
        try:
            info = self.socket_path.stat()
            if not stat.S_ISSOCK(info.st_mode):
                raise ValueError("endpoint is not a Unix socket")
            return info.st_dev, info.st_ino
        except (OSError, ValueError) as exc:
            raise UnresolvedBuild(f"Docker socket identity unknown: {self.endpoint}") from exc

    def raw_control(self, args):
        try:
            return subprocess.run(self.command(args), env=self.env, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True, timeout=45)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise UnresolvedBuild(f"Docker control outcome unknown at {self.endpoint}: {args}: {exc}") from exc

    def read_daemon_id(self):
        result = self.raw_control(["info", "--format", "{{.ID}}"])
        identity = result.stdout.strip()
        if result.returncode or not re.fullmatch(r"[A-Za-z0-9:._-]+", identity):
            raise UnresolvedBuild(f"Docker daemon identity unknown at {self.endpoint}")
        return identity

    def check_identity(self):
        if self.socket_signature() != self.socket_identity:
            raise UnresolvedBuild(f"Docker socket changed at pinned endpoint {self.endpoint}")
        if self.read_daemon_id() != self.daemon_id:
            raise UnresolvedBuild(f"Docker daemon changed at pinned endpoint {self.endpoint}")
        if self.socket_signature() != self.socket_identity:
            raise UnresolvedBuild(f"Docker socket changed during daemon query at {self.endpoint}")

    def control(self, args):
        self.check_identity()
        result = self.raw_control(args)
        self.check_identity()
        return result

    def output(self, args):
        result = self.control(args)
        if result.returncode:
            raise subprocess.CalledProcessError(result.returncode, self.command(args), result.stdout, result.stderr)
        return result.stdout.strip()


def image_id(docker, image):
    return docker.output(["image", "inspect", image, "--format", "{{.Id}}"])


def require_local_daemon():
    context = os.environ.get("DOCKER_CONTEXT")
    endpoint = os.environ.get("DOCKER_HOST") if not context else None
    if not endpoint:
        args = ["docker", "context", "inspect"]
        if context:
            args.append(context)
        endpoint = output([*args, "--format", "{{.Endpoints.docker.Host}}"])
    if not endpoint.startswith("unix://"):
        raise RuntimeError("REFUSED: Docker must use a local Unix socket on the lease-owning host; use the SSH backend")
    return DockerEndpoint(endpoint)


def container_build_date(docker, image):
    return docker.output(["run", "--rm", "--entrypoint", "/bin/sh", image, "-c", "date +%y%m%d"])


def container_state(docker, identity):
    result = docker.control(["inspect", "--type", "container", identity, "--format", "{{json .State}}"])
    if result.returncode:
        # Only a successful daemon listing can prove absence. An inspect error
        # (including a broken socket/permission/transport error) is not absence.
        listing = docker.control(["container", "ls", "-a", "--no-trunc", "--filter",
                                  f"id={identity}", "--format", "{{.ID}}"])
        if listing.returncode == 0 and not listing.stdout.strip():
            return None
        raise UnresolvedBuild(f"Cannot establish daemon state for container {identity}")
    try:
        state = json.loads(result.stdout)
        if not isinstance(state["Running"], bool) or state["Status"] not in ("created", "running", "exited"):
            raise ValueError("unrecognized container state")
        return state
    except (ValueError, KeyError, TypeError) as exc:
        raise UnresolvedBuild(f"Invalid daemon state for container {identity}") from exc


def reconcile_container(docker, identity, abnormal):
    state = container_state(docker, identity)
    completed = state is not None and not state["Running"] and state["Status"] == "exited"
    exit_code = state.get("ExitCode") if completed else None
    if state is not None:
        if abnormal or state["Running"]:
            # Stop even if the CLI has already exited. Remove the exact ID after
            # stopping so a delayed start request cannot resurrect it.
            docker.control(["stop", "--time", "30", identity])
            state = container_state(docker, identity)
            if state is not None and state["Running"]:
                raise UnresolvedBuild(f"Owned container still running after stop: {identity}")
        if state is not None:
            docker.control(["rm", identity])
            if container_state(docker, identity) is not None:
                raise UnresolvedBuild(f"Owned container removal not confirmed: {identity}")
    return completed and not abnormal and exit_code == 0


def prepare_reporting(work, meta):
    directory = work / "reporter"
    directory.mkdir()
    files = {"run.sh": TIMING_RUNNER.encode(),
             "timing.tcl": Path(__file__).with_name("quartus_timing_paths.tcl").read_bytes()}
    for name in ("check_quartus_timing.py", "quartus_sta_report.py"):
        files[name] = Path(__file__).with_name(name).read_bytes()
    for name, data in files.items():
        (directory / name).write_bytes(data)
        (directory / name).chmod(0o444)
    write_json(directory / "provenance.json", {
        "schema": "misterplex.timing-reporter.v2",
        "files": {name: digest(data) for name, data in files.items()},
        "driver_sha256": digest(Path(__file__).read_bytes()),
        "image_id": meta["image_id"], "input_sha256": meta["input_sha256"],
        "command": ["quartus_sta", "-t", "/misterplex-reporter/timing.tcl", "/misterplex-timing"],
    })
    (directory / "provenance.json").chmod(0o444)


def verify_reporter(work, meta):
    directory = work / "reporter"
    if directory.is_symlink() or (directory / "provenance.json").is_symlink():
        raise RuntimeError("REFUSED: linked timing reporter")
    provenance = json.loads((directory / "provenance.json").read_text())
    if provenance["image_id"] != meta["image_id"] or provenance["input_sha256"] != meta["input_sha256"]:
        raise RuntimeError("REFUSED: timing reporter provenance belongs to different inputs/image")
    expected_files = {"run.sh", "timing.tcl"}
    if provenance["schema"] == "misterplex.timing-reporter.v2":
        expected_files.update(("check_quartus_timing.py", "quartus_sta_report.py"))
    elif provenance["schema"] != "misterplex.timing-reporter.v1":
        raise RuntimeError("REFUSED: unknown timing reporter schema")
    if set(provenance["files"]) != expected_files:
        raise RuntimeError("REFUSED: unexpected timing reporter files")
    for name, expected in provenance["files"].items():
        path = directory / name
        if path.is_symlink() or not path.is_file() or digest(path.read_bytes()) != expected:
            raise RuntimeError(f"REFUSED: timing reporter hash mismatch: {name}")
    return provenance


def verify_timing_reports(work, meta, expected_reporter):
    provenance = verify_reporter(work, meta)
    if provenance != expected_reporter:
        raise RuntimeError("REFUSED: timing reporter provenance changed during execution")
    directory = work / "timing"
    if directory.is_symlink():
        raise RuntimeError("REFUSED: linked timing diagnostics")

    def small_text(name, limit=2048):
        path = directory / name
        if path.is_symlink() or not path.is_file() or path.stat().st_size > limit:
            raise RuntimeError(f"REFUSED: invalid timing metadata: {name}")
        return path.read_text()

    if small_text("compile.exit").strip() != "0" or small_text("reporter.exit").strip() != "0":
        raise RuntimeError("REFUSED: compile/timing reporter did not succeed")
    before, after = small_text("rbf.before.sha256").split()[0], small_text("rbf.after.sha256").split()[0]
    if before != after or before != digest((work / "project/output_files/Plex.rbf").read_bytes()):
        raise RuntimeError("REFUSED: timing reporter changed Plex.rbf")
    lines = small_text("index.tsv", 2 * 1024**2).splitlines()
    if not lines or lines[0] != "corner\tclock_index\tcondition\tclock\tperiod_ns\tcheck\tfile":
        raise RuntimeError("REFUSED: missing detailed timing index")
    records, pairs, total = [], {}, 0
    for line in lines[1:]:
        fields = line.split("\t")
        if len(fields) != 7:
            raise RuntimeError("REFUSED: malformed detailed timing index")
        corner, clock_index, condition, clock, period, check, filename = fields
        ci, ki = int(corner), int(clock_index)
        if not 0 <= ci < 8 or not 0 <= ki < 64 or check not in ("setup", "hold") or float(period) <= 0:
            raise RuntimeError("REFUSED: invalid detailed timing clock/check")
        if filename != f"Plex.corner-{ci:02d}.clock-{ki:02d}.{check}.rpt":
            raise RuntimeError("REFUSED: unsafe detailed timing filename")
        key = (ci, ki, condition, clock, period)
        checks = pairs.setdefault(key, set())
        if check in checks or len(records) >= 1024:
            raise RuntimeError("REFUSED: duplicate/excess timing reports")
        checks.add(check)
        path = directory / filename
        if path.is_symlink() or not path.is_file() or path.stat().st_size > TIMING_FILE_BYTES:
            raise RuntimeError(f"REFUSED: invalid/oversized timing report: {filename}")
        data = path.read_bytes()
        total += len(data)
        if total > TIMING_TOTAL_BYTES:
            raise RuntimeError("REFUSED: detailed timing report budget exceeded")
        records.append({"corner": ci, "clock": clock, "period_ns": period, "check": check,
                        "file": filename, "bytes": len(data), "sha256": digest(data)})
    if not pairs or any(checks != {"setup", "hold"} for checks in pairs.values()):
        raise RuntimeError("REFUSED: detailed timing requires setup AND hold for every clock/corner")
    summary = dict(line.split("=", 1) for line in small_text("complete.summary").splitlines())
    if int(summary["reports"]) != len(records) or int(summary["bytes"]) != total:
        raise RuntimeError("REFUSED: incomplete detailed timing reports")
    if int(summary["corners"]) != len({key[0] for key in pairs}):
        raise RuntimeError("REFUSED: incomplete detailed timing corners")
    manifest = {"schema": "misterplex.timing-paths.v1", "reporter": provenance,
                "rbf_sha256": after, "reports": records, "timing_acceptance": "NOT_GRANTED"}
    if (directory / "extended.summary").exists():
        if provenance["schema"] != "misterplex.timing-reporter.v2":
            raise RuntimeError("REFUSED: extended evidence needs the bound Python collector")
        # The SSH worker is standalone; use only its hash-bound sidecar modules,
        # not the host's working-tree imports or an inherited PYTHONPATH.
        collector = (
            "import json,sys; from pathlib import Path; "
            "sys.path.insert(0,sys.argv[1]); "
            "from check_quartus_timing import collect_extended_evidence; "
            "request=json.load(sys.stdin); "
            "print(json.dumps(collect_extended_evidence(Path(sys.argv[2]), "
            "{tuple(pair) for pair in request['pairs']}, request['global_bytes'])))")
        try:
            result = run([sys.executable, "-I", "-c", collector, work / "reporter", directory],
                         input=json.dumps({"pairs": list(pairs), "global_bytes": total}),
                         text=True, capture_output=True)
        except subprocess.CalledProcessError as exc:
            raise RuntimeError(f"REFUSED: bound timing collector failed: {exc.stderr.strip()}") from exc
        try:
            manifest["extended"] = json.loads(result.stdout)
        except ValueError as exc:
            raise RuntimeError("REFUSED: malformed bound timing collector result") from exc
        manifest["schema"] = "misterplex.timing-paths.v2"
    write_json(directory / "manifest.json", manifest)


def preserve_failed_diagnostics(work):
    """Best-effort bounded reports only; never follow links or collect an RBF."""
    directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    with contextlib.ExitStack() as stack:
        def open_directory(name, parent=None, create=False):
            if create:
                try:
                    os.mkdir(name, mode=0o700, dir_fd=parent)
                except FileExistsError:
                    pass
            fd = os.open(name, directory_flags, dir_fd=parent)
            stack.callback(os.close, fd)
            return fd

        work_fd = open_directory(work)
        try:
            project_fd = open_directory("project", work_fd)
        except FileNotFoundError:
            return
        diagnostics_fd = open_directory("diagnostics", work_fd, create=True)
        sources = [("", project_fd)]
        skipped = 0
        try:
            sources.append(("output_files", open_directory("output_files", project_fd)))
        except FileNotFoundError:
            pass
        except OSError:
            skipped += 1
        copied, scanned, total = [], 0, 0
        for relative, source_fd in sources:
            target_fd = diagnostics_fd
            if relative:
                target_fd = open_directory(relative, diagnostics_fd, create=True)
            with os.scandir(source_fd) as entries:
                for entry in entries:
                    if scanned >= DIAGNOSTIC_ENTRIES or len(copied) >= DIAGNOSTIC_FILES or total >= DIAGNOSTIC_TOTAL_BYTES:
                        break
                    scanned += 1
                    if Path(entry.name).suffix.lower() not in (".rpt", ".summary"):
                        continue
                    info = os.stat(entry.name, dir_fd=source_fd, follow_symlinks=False)
                    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                        skipped += 1
                        continue
                    source = os.open(entry.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=source_fd)
                    with os.fdopen(source, "rb") as reader:
                        before = os.fstat(reader.fileno())
                        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
                            skipped += 1
                            continue
                        allowance = min(DIAGNOSTIC_FILE_BYTES, DIAGNOSTIC_TOTAL_BYTES - total)
                        target = os.open(entry.name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                                         0o600, dir_fd=target_fd)
                        size, sha = 0, hashlib.sha256()
                        with os.fdopen(target, "wb") as writer:
                            while size < allowance:
                                data = reader.read(min(64 * 1024, allowance - size))
                                if not data:
                                    break
                                writer.write(data)
                                sha.update(data)
                                size += len(data)
                        after = os.fstat(reader.fileno())
                    copied.append({
                        "source": str(PurePosixPath(relative) / entry.name),
                        "bytes": size, "source_bytes": before.st_size, "sha256": sha.hexdigest(),
                        "truncated": after.st_size > size,
                        "changed_during_copy": (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns),
                    })
                    total += size
        manifest = {
            "schema": "misterplex.failed-diagnostics.v1", "build_status": "FAILED",
            "copied": copied, "skipped": skipped, "scanned_entries": scanned, "total_bytes": total,
            "limit_reached": (scanned >= DIAGNOSTIC_ENTRIES or len(copied) >= DIAGNOSTIC_FILES
                              or total >= DIAGNOSTIC_TOTAL_BYTES),
            "limits": {"files": DIAGNOSTIC_FILES, "entries": DIAGNOSTIC_ENTRIES,
                       "file_bytes": DIAGNOSTIC_FILE_BYTES, "total_bytes": DIAGNOSTIC_TOTAL_BYTES},
        }
        fd = os.open("manifest.json", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                     0o600, dir_fd=diagnostics_fd)
        with os.fdopen(fd, "w") as stream:
            json.dump(manifest, stream, sort_keys=True, indent=2)
            stream.write("\n")


def compile_snapshot(work, meta, lease, docker):
    completed = False
    try:
        _compile_snapshot(work, meta, lease, docker)
        completed = True
    finally:
        if not completed:
            # Expected diagnostic I/O errors must not replace the build failure.
            try:
                preserve_failed_diagnostics(work)
            except OSError as diagnostic_error:
                print(f"Warning: failed-build diagnostics incomplete: {diagnostic_error}", file=sys.stderr)


def _compile_snapshot(work, meta, lease, docker):
    reporter = verify_reporter(work, meta)
    (work / "timing").mkdir(exist_ok=True)
    project = work / "project"
    unpack(work / "inputs.tar", project, meta)
    active = docker.output(["ps", "--filter", "label=misterplex.single-fit=1", "--format", "{{.Names}}"])
    if active:
        raise RuntimeError(f"REFUSED: managed container still running: {active}")
    if re.search(r"(?m)^\s*quartus_(?:sh|map|fit|asm|sta)\s*$", output(["ps", "-eo", "comm="])):
        raise RuntimeError("REFUSED: an existing Quartus process is running on the build host")
    name = "mplex-fit-" + uuid.uuid4().hex
    qsf = (project / "Plex.qsf").read_text()
    config = {
        "image_id": meta["image_id"], "container": name,
        "docker_endpoint": docker.endpoint, "docker_daemon_id": docker.daemon_id,
        "docker_socket_identity": docker.socket_identity,
        "command": ["quartus_sh", "--flow", "compile", "Plex.qpf"],
        "container_command": ["/bin/sh", "/misterplex-reporter/run.sh",
                              "/misterplex-reporter/timing.tcl", "/misterplex-timing"],
        "timing_reporter": reporter,
        "mount": "/build",
        "fpga_video_build_id": meta.get("fpga_video_build_id"),
        "legacy_build_date": meta.get("legacy_build_date"),
        "qsf_configuration": [line for line in qsf.splitlines()
                              if re.match(r"^\s*set_global_assignment\s+-name\s+(SEED|NUM_PARALLEL_PROCESSORS)\s", line)],
    }
    write_json(work / "tool.json", config)
    args = ["create", "--name", name, "--label", "misterplex.single-fit=1",
            "-v", f"{project}:/build", "-v", f"{work / 'reporter'}:/misterplex-reporter:ro",
            "-v", f"{work / 'timing'}:/misterplex-timing",
            "-w", "/build", "-u", f"{os.getuid()}:{os.getgid()}",
            meta["image_id"], *config["container_command"]]
    lease.retain(f"container creation/launch pending: {name}; inputs={project}")
    created = docker.control(args)
    identity = created.stdout.strip()
    if created.returncode or not re.fullmatch(r"[0-9a-f]{64}", identity):
        raise UnresolvedBuild(f"Container creation unresolved: name={name}; inputs={project}")
    config["container_id"] = identity
    write_json(work / "tool.json", config)
    with (work / "compile.log").open("w") as log:
        child, rc = None, None
        try:
            docker.check_identity()
            child = subprocess.Popen(docker.command(["start", "--attach", identity]),
                                     env=docker.env, stdout=log, stderr=subprocess.STDOUT,
                                     pass_fds=(() if lease.fd is None else (lease.fd,)))
            rc = child.wait()
        finally:
            with cleanup_signals():
                success = reconcile_container(docker, identity, abnormal=rc != 0)
                if child is not None and child.poll() is None:
                    try:
                        child.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        child.terminate()
                        child.wait(timeout=10)
                lease.confirmed()
    if not success:
        raise RuntimeError(f"Quartus/container client failed ({rc}); see {work / 'compile.log'}")
    verify_timing_reports(work, meta, reporter)
    if hashes({name: project / name for name in meta["input_files"]}) != meta["input_files"]:
        raise RuntimeError("REFUSED: compiler changed snapshot inputs")
    for name in ARTIFACTS:
        shutil.copyfile(project / "output_files" / name, work / name)


def send(stream, value):
    stream.write(json.dumps(value) + "\n")
    stream.flush()


def receive(stream):
    line = stream.readline()
    if not line:
        raise RuntimeError("Remote build transaction disconnected")
    value = json.loads(line)
    if "error" in value:
        raise RuntimeError(value["error"])
    return value


def remote_worker(config):
    # One SSH worker owns the host lock from READY through collection ACK.
    os.chdir(Path.home())
    with host_lock(EXECUTION_KEY) as lease:
        home = Path.cwd()
        base = Path(config.get("base") or home / "mplex-builds").resolve()
        dev = Path(config.get("dev") or home / "misterfpga-dev").resolve()
        image = output(["bash", "-c", 'set -euo pipefail; source "$1/scripts/lib.sh"; load_env; printf "%s" "$QUARTUS_IMAGE"',
                        "bash", dev])
        docker = require_local_daemon()
        image = image_id(docker, image)
        work = base / config["slot"] / config["run"]
        work.mkdir(parents=True)
        lease.owner = work / "execution-owner.json"
        send(sys.stdout, {"ready": True, "work": str(work), "image_id": image, "transaction": config["run"],
                          "legacy_build_date": container_build_date(docker, image)})
        try:
            request = receive(sys.stdin)
            check_disk(work, request["bytes"])
            send(sys.stdout, {"sync": True})
            if receive(sys.stdin) != {"build": True}:
                raise RuntimeError("Invalid build transaction request")
            meta = json.loads((work / "inputs.json").read_text())
            if meta["image_id"] != image or digest((work / "inputs.tar").read_bytes()) != meta["archive_sha256"]:
                raise RuntimeError("REFUSED: remote snapshot/image mismatch")
            if "source_archive_sha256" in meta:
                if digest((work / "source.tar").read_bytes()) != meta["source_archive_sha256"]:
                    raise RuntimeError("REFUSED: remote original-source archive hash differs")
            try:
                compile_snapshot(work, meta, lease, docker)
            except UnresolvedBuild:
                raise
            except (OSError, RuntimeError, subprocess.CalledProcessError) as exc:
                if not lease.safe:
                    raise UnresolvedBuild(str(exc)) from exc
                send(sys.stdout, {"built": False, "reason": str(exc)})
            else:
                send(sys.stdout, {"built": True})
            if receive(sys.stdin) != {"collected": True}:
                raise RuntimeError("Invalid collection acknowledgement")
        finally:
            if lease.safe:
                shutil.rmtree(work / "project", ignore_errors=True)
    send(sys.stdout, {"complete": True, "transaction": config["run"]})


class RemoteSession:
    def __init__(self, child, ready):
        self.child, self.ready = child, ready
        self.started, self.completed = False, False

    def start(self):
        self.started = True  # A failed write may still have reached the worker.
        send(self.child.stdin, {"build": True})

    def collected(self):
        send(self.child.stdin, {"collected": True})
        ack = receive(self.child.stdout)
        if ack != {"complete": True, "transaction": self.ready["transaction"]}:
            raise UnresolvedBuild("Missing/mismatched terminal remote completion acknowledgement")
        self.completed = True


@contextlib.contextmanager
def remote_transaction(host, slot, leases):
    config = {"slot": slot, "run": uuid.uuid4().hex,
              "base": os.environ.get("MISTER_REMOTE_BASE"),
              "dev": os.environ.get("MISTER_REMOTE_DEV")}
    # Sending the worker as an argument avoids modifying remote scripts outside
    # the lease and keeps the worker version tied to this invocation.
    command = shlex.join(["python3", "-u", "-c", Path(__file__).read_text(),
                          "--worker", json.dumps(config)])
    child = subprocess.Popen(["ssh", "-o", "BatchMode=yes", host, command],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
                             pass_fds=tuple(lease.fd for lease in leases if lease.fd is not None))
    session = None
    try:
        ready = receive(child.stdout)
        if ready.get("transaction") != config["run"]:
            raise RuntimeError("Remote transaction identity mismatch before dispatch")
        session = RemoteSession(child, ready)
        yield session
    finally:
        unresolved = session is not None and session.started and not session.completed
        if unresolved:
            reason = f"remote outcome unresolved: host={host}; transaction={config['run']}; work={session.ready['work']}"
            for lease in leases:
                lease.retain(reason)
        with cleanup_signals():
            try:
                child.stdin.close()
            except BrokenPipeError:
                pass
            try:
                child.wait(timeout=30)
            except subprocess.TimeoutExpired:
                child.terminate()  # Only the exact local SSH client; ownership stays retained.
                child.wait(timeout=10)
            finally:
                child.stdout.close()
        if unresolved:
            raise UnresolvedBuild(reason)


def validate(root, work, reference):
    project = work / "project"
    extra = []
    if re.search(r'(?m)^\s*set_global_assignment\s+-name\s+VERILOG_MACRO\s+"PLEX_PRESENT_720P_L4=1"',
                 (project / "Plex.qsf").read_text()):
        extra = ["--allow-missing", "stream_path", "--allow-missing", "ddr_bitstream_reader"]
    run([sys.executable, root / "scripts/check_quartus_fit_hierarchy.py",
         "--fit-rpt", work / "Plex.fit.rpt", "--map-rpt", work / "Plex.map.rpt",
         "--log", work / "compile.log", "--qsf", project / "Plex.qsf",
         "--input-manifest", work / "inputs.json", *extra])
    sdcs = [arg for path in sorted(project.rglob("*.sdc")) for arg in ("--sdc", str(path))]
    if not sdcs:
        raise RuntimeError("REFUSED: snapshot has no SDC files for exclusion validation")
    gates = [
        [sys.executable, root / "scripts/check_quartus_timing.py", "--sta-rpt", work / "Plex.sta.rpt",
         "--paths-dir", work / "timing", "--require-scoped"],
        [sys.executable, root / "scripts/check_timing_exclusions.py",
         "--sta-rpt", work / "Plex.sta.rpt", "--effective-dir", work / "timing",
         "--project", project, *sdcs],
    ]
    failures = []
    for command in gates:
        try:
            run(command)
        except subprocess.CalledProcessError as exc:
            failures.append(exc)
    if failures:
        raise failures[0]
    data = (work / "Plex.rbf").read_bytes()
    sha, md5 = digest(data), hashlib.md5(data).hexdigest()
    ban = root / "tests/unit/test_phase1a_rbf_ban.sh"
    if ban.exists():
        for value in (sha, md5):
            run(["bash", ban, value])
    if reference and reference.read_bytes() != data:
        raise RuntimeError("REFUSED: RBF is not bit-identical to frozen reference")
    write_json(work / "result.json", {"rbf_sha256": sha, "rbf_md5": md5,
                                    "bit_identity": "PASS" if reference else "UNVERIFIED",
                                    "promotion": "NOT_AUTHORIZED"})


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, epilog=(
        "Remote environment retains MISTER_REMOTE_{HOST,BASE,DEV,COPY_BACK,REFERENCE_RBF,"
        "ALLOW_UNVERIFIED,PROCESSORS,ALLOW_PROCESSOR_OVERRIDE}. Local uses "
        "MISTERPLEX_BUILD_{REFERENCE_RBF,ALLOW_UNVERIFIED}, MISTERPLEX_QUARTUS_IMAGE. "
        "--snapshot replays inputs.tar with adjacent inputs.json/source.tar using the identical image."))
    ap.add_argument("backend", choices=("remote", "local-container"))
    ap.add_argument("slot")
    ap.add_argument("project", nargs="?", type=Path, default=ROOT / "fpga/Plex_MiSTer")
    ap.add_argument("--snapshot", type=Path)
    ap.add_argument("--derive-video-build-id", action="store_true",
                    help="render nonzero FPGA_VIDEO_BUILD_ID from original source SHA-256 into the snapshot only")
    args = ap.parse_args(argv)
    if not re.fullmatch(r"[A-Za-z0-9_-][A-Za-z0-9._-]*", args.slot):
        ap.error("slot must start with a letter, digit, underscore or hyphen; no path components")
    local = args.backend == "local-container"
    if local and os.environ.get("MISTERPLEX_ALLOW_LOCAL_FIT") != "1":
        raise RuntimeError("REFUSED: local fit requires MISTERPLEX_ALLOW_LOCAL_FIT=1")
    project = args.project.resolve()
    prefix = "MISTERPLEX_BUILD_" if local else "MISTER_REMOTE_"
    allow = os.environ.get(prefix + "ALLOW_UNVERIFIED", "0")
    copy_back = "1" if local else os.environ.get("MISTER_REMOTE_COPY_BACK", "1")
    if allow not in ("0", "1") or copy_back not in ("0", "1"):
        ap.error("ALLOW_UNVERIFIED and COPY_BACK must be 0 or 1")
    reference = os.environ.get(prefix + "REFERENCE_RBF")
    if not reference and (project / "output_files/Plex.rbf").is_file():
        reference = str(project / "output_files/Plex.rbf")
    reference = Path(reference).resolve() if reference else None
    if reference and not reference.is_file():
        ap.error("reference RBF does not exist")
    if not reference and allow != "1":
        print("REFUSED: no reference RBF; explicit ALLOW_UNVERIFIED=1 is candidate-only.", file=sys.stderr)
        return 4
    if reference and copy_back == "0":
        ap.error("COPY_BACK=0 cannot perform reference comparison; enable copy-back")
    processors = "" if local else os.environ.get("MISTER_REMOTE_PROCESSORS", "")
    if processors and (os.environ.get("MISTER_REMOTE_ALLOW_PROCESSOR_OVERRIDE") != "1"
                       or not processors.isdigit() or int(processors) < 1):
        ap.error("processor changes require MISTER_REMOTE_ALLOW_PROCESSOR_OVERRIDE=1 and a positive integer")
    with host_lock(CONTROLLER_KEY) as controller, fit_lock(repository_lock(ROOT)) as repository:
        out = project / ("local_out" if local else "remote_out") / args.slot
        if out.exists():
            raise RuntimeError(f"REFUSED: use a fresh slot; artifacts already exist: {out}")
        out.mkdir(parents=True)
        controller.owner = out / "controller-owner.json"
        write_json(controller.owner, {"pid": os.getpid(), "host": os.uname().nodename,
                                      "backend": args.backend, "phase": "transaction-started"})
        frozen_reference = None
        execution = None
        try:
            if reference:
                frozen_reference = out / "reference.rbf"
                shutil.copyfile(reference, frozen_reference)
            if local:
                with host_lock(EXECUTION_KEY) as execution:
                    execution.owner = out / "execution-owner.json"
                    docker = require_local_daemon()
                    image = image_id(docker, os.environ.get("MISTERPLEX_QUARTUS_IMAGE", IMAGE))
                    date = container_build_date(docker, image) if not args.snapshot and (project / "sys/build_id.tcl").is_file() else None
                    meta = snapshot(project, out, image, processors, args.snapshot, args.derive_video_build_id, date)
                    prepare_reporting(out, meta)
                    compile_snapshot(out, meta, execution, docker)
                    validate(ROOT, out, frozen_reference)
            else:
                host = os.environ.get("MISTER_REMOTE_HOST", "docker")
                if host.startswith("-"):
                    ap.error("invalid remote SSH host")
                with remote_transaction(host, args.slot, (controller, repository)) as session:
                    worker, ready = session.child, session.ready
                    meta = snapshot(project, out, ready["image_id"], processors, args.snapshot,
                                    args.derive_video_build_id, ready["legacy_build_date"])
                    prepare_reporting(out, meta)
                    send(worker.stdin, {"bytes": (out / "inputs.tar").stat().st_size})
                    receive(worker.stdout)
                    remote = f"{host}:{ready['work']}/"
                    sources = ([out / "source.tar"] if (out / "source.tar").exists() else []) + [out / "reporter"]
                    run(["rsync", "-a", "--protect-args", out / "inputs.tar", out / "inputs.json", *sources, remote])
                    session.start()
                    built = receive(worker.stdout)
                    run(["rsync", "-a", "--protect-args", "--exclude", "project", remote, str(out) + "/"])
                    session.collected()
                    if not built["built"]:
                        raise RuntimeError(built["reason"])
                    unpack(out / "inputs.tar", out / "project", meta)
                    validate(ROOT, out, frozen_reference)
            if copy_back == "0":
                for name in ARTIFACTS:
                    (out / name).unlink()
            print(f"Artifacts: {out}")
            print("Build only: no promotion/deploy authorized; UNVERIFIED candidates require a serial replay.")
        finally:
            if execution is not None and not execution.safe:
                controller.retain(f"execution unresolved; preserve {out}")
                repository.retain(f"execution unresolved; preserve {out}")
            if controller.safe and repository.safe:
                shutil.rmtree(out / "project", ignore_errors=True)
                if frozen_reference:
                    frozen_reference.unlink(missing_ok=True)
                controller.confirmed()
    return 0


def interrupted(signum, _frame):
    raise RuntimeError(f"Build interrupted by signal {signum}")


if __name__ == "__main__":
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, interrupted)
    try:
        if len(sys.argv) > 1 and sys.argv[1] == "--worker":
            remote_worker(json.loads(sys.argv[2]))
        else:
            sys.exit(main())
    except (OSError, RuntimeError, ValueError, subprocess.CalledProcessError) as exc:
        if len(sys.argv) > 1 and sys.argv[1] == "--worker":
            send(sys.stdout, {"error": str(exc)})
        else:
            print(str(exc), file=sys.stderr)
        sys.exit(1)
