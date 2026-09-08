#!/usr/bin/env python3
"""Run an existing V14 regression under the existing repository/host guards."""
import ctypes
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys

OWN = Path(__file__).resolve().parent
ROOT = OWN.parents[4]
OWNER = "ce6e3c70-35d0-47b7-a3b9-c1704c76e2be"
GRANT = "v14-real-critical-cones-5754"
LAB = ROOT / "Memory/lab/fpga-h264-30ff2997"
LIBC = ctypes.CDLL(None, use_errno=True)
LIBC.semget.argtypes = (ctypes.c_int, ctypes.c_int, ctypes.c_int)
LIBC.semget.restype = ctypes.c_int


class SemOp(ctypes.Structure):
    _fields_ = [("number", ctypes.c_ushort), ("op", ctypes.c_short),
                ("flags", ctypes.c_short)]


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_map():
    tree = OWN / "project/fpga/Plex_MiSTer"
    return {str(p.relative_to(tree)): sha(p)
            for p in sorted(tree.rglob("*")) if p.is_file()}


def sem_status(sid):
    values = [LIBC.semctl(sid, 0, command) for command in (12, 11, 14, 15)]
    if min(values) < 0:
        raise OSError(ctypes.get_errno(), "existing semaphore query failed")
    return dict(zip(("value", "last_pid", "negative_waiters", "zero_waiters"), values))


def sem_change(sid, change):
    # Match the fail-closed build driver: IPC_NOWAIT, deliberately no SEM_UNDO.
    op = SemOp(0, change, 0o4000)
    if LIBC.semop(sid, ctypes.byref(op), 1) != 0:
        raise OSError(ctypes.get_errno(), "existing semaphore acquisition/release failed")


def heavy_processes():
    rows = subprocess.check_output(["ps", "-eo", "pid=,ppid=,comm="], text=True)
    return [line.strip() for line in rows.splitlines()
            if line.split()[-1].startswith(
                ("quartus", "verilator", "Vh264", "Vfpga", "Vp2_", "Vgop12"))]


def group_alive(pid):
    try:
        os.killpg(pid, 0)
        return True
    except ProcessLookupError:
        return False


def main():
    label, separator, *command = sys.argv[1:]
    if separator != "--" or not command or not label.replace("-", "").isalnum():
        raise ValueError("expected unique-label -- existing-command arguments")
    jobs = OWN / "evidence/jobs"
    jobs.mkdir(parents=True, exist_ok=True)
    receipt_path, log_path = jobs / f"{label}.json", jobs / f"{label}.log"
    if receipt_path.exists() or log_path.exists():
        raise FileExistsError("never overwrite a previous campaign or failure")
    before = source_map()
    receipt = {
        "owner": OWNER, "grant": GRANT, "shell_handle": label,
        "wrapper_pid": os.getpid(), "started_at": now(), "state": "intent",
        "cwd": str(OWN / "project"), "command": command, "output": str(log_path),
        "source_map": before,
        "source_sha256": hashlib.sha256(json.dumps(before, sort_keys=True).encode()).hexdigest(),
        "base_source_sha256": "439200e0923d1756538825621e7ee5bab1f475bc9ce1287cf2ba3e8c16bcdc01",
        "guard_rule": "existing-only; no create, reset, SETVAL, stale-clear or SEM_UNDO",
        "acquired": [], "physical_tools_executed": False,
    }

    def save():
        receipt_path.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")

    save()
    lock = None
    semaphores = {}
    held = []
    child = None
    exit_code = 1
    try:
        registry_path = LAB / "handoff/registry.json"
        registry = json.loads(registry_path.read_text())
        scope = next(x for x in registry["fresh_outcome_scopes"] if x["id"] == GRANT)
        if scope["owner"] != OWNER or not scope["state"].startswith("active"):
            raise RuntimeError("fresh source scope is not active for this owner")
        resource = registry["heavy_rtl_resource"]
        if resource["owner"] != OWNER or resource["state"] not in ("reserved", "active", "running"):
            raise RuntimeError("sole heavy RTL resource is not reserved for this owner")
        receipt["registry_sha256"] = sha(registry_path)
        receipt["preflight_processes"] = heavy_processes()
        if receipt["preflight_processes"]:
            raise RuntimeError("another actual physical/RTL job exists; do not clear it")
        for name, key in (("controller", 0x4D505843), ("execution", 0x4D505845)):
            sid = LIBC.semget(key, 1, 0)
            if sid < 0:
                raise OSError(ctypes.get_errno(), "existing semaphore missing; do not create it")
            semaphores[name] = sid
        receipt["semaphores"] = {
            name: {"id": sid, "before": sem_status(sid)} for name, sid in semaphores.items()
        }
        lock_path = ROOT / ".git/misterplex-build/single-fit.lock"
        lock = lock_path.open("r")
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        stat = os.fstat(lock.fileno())
        receipt["repository_lock"] = {
            "path": str(lock_path), "inode": stat.st_ino, "device": stat.st_dev,
            "acquired_at": now(), "owner_file_written": False,
        }
        save()
        for name, sid in semaphores.items():
            if sem_status(sid)["value"] != 1:
                raise RuntimeError(f"{name} guard is not exactly free; do not clear it")
            sem_change(sid, -1)
            held.append(name)
            receipt["acquired"].append({"name": name, "at": now(), **sem_status(sid)})
            save()
        scratch = OWN / "evidence/compiler-scratch"
        scratch.mkdir(exist_ok=True)
        env = os.environ.copy()
        env.update(TMPDIR=str(scratch), TMP=str(scratch), TEMP=str(scratch),
                   PYTHONDONTWRITEBYTECODE="1", MAKEFLAGS="-j1")

        def interrupt(signum, _frame):
            if child is not None and child.poll() is None:
                os.killpg(child.pid, signum)
            raise KeyboardInterrupt(f"signal {signum}")

        signal.signal(signal.SIGTERM, interrupt)
        signal.signal(signal.SIGINT, interrupt)
        with log_path.open("w") as log:
            child = subprocess.Popen(command, cwd=OWN / "project", env=env,
                                     stdout=log, stderr=subprocess.STDOUT,
                                     start_new_session=True)
            receipt.update(state="running", child_pid=child.pid, launched_at=now())
            save()
            exit_code = child.wait()
        receipt["command_exit_code"] = exit_code
        if source_map() != before:
            raise RuntimeError("source bytes changed under a validation command")
        if group_alive(child.pid):
            raise RuntimeError("child group remains live; retain fail-closed leases")
        receipt["state"] = "passed" if exit_code == 0 else "failed"
    except BaseException as error:
        receipt.update(state="failed-or-interrupted", error=f"{type(error).__name__}: {error}")
        exit_code = 1
        if child is not None and child.poll() is None:
            os.killpg(child.pid, signal.SIGTERM)
            try:
                child.wait(timeout=60)
            except subprocess.TimeoutExpired:
                receipt["unfinished_child_pid"] = child.pid
    finally:
        settled = child is None or (child.poll() is not None and not group_alive(child.pid))
        if settled:
            for name in reversed(held):
                sid = semaphores[name]
                status = sem_status(sid)
                if status["value"] != 0 or status["last_pid"] != os.getpid():
                    receipt["guard_conflict"] = {name: status}
                    exit_code = 1
                    break
                sem_change(sid, 1)
                receipt.setdefault("released", []).append({"name": name, "at": now()})
            if lock is not None:
                fcntl.flock(lock, fcntl.LOCK_UN)
                lock.close()
        else:
            receipt["fail_closed_leases_require_reconciliation"] = list(held)
        receipt["guards_after"] = {name: sem_status(sid) for name, sid in semaphores.items()}
        receipt["owned_child_group_settled"] = settled
        receipt["ended_at"] = now()
        receipt["exit_code"] = exit_code
        if log_path.exists():
            receipt["output_sha256"] = sha(log_path)
        save()
    if exit_code and log_path.exists():
        print("\n".join(log_path.read_text(errors="replace").splitlines()[-45:]))
    print(json.dumps({"label": label, "exit_code": exit_code, "state": receipt["state"],
                      "receipt": str(receipt_path), "settled": receipt["owned_child_group_settled"]}))
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
