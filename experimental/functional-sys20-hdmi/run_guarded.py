#!/usr/bin/env python3
"""Run the existing selected scaler unittest methods under shared R4 guards."""
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
from datetime import datetime, timezone

ROOT = Path.cwd()
OWN = ROOT / ".worktrees/fpga-h264-fleet-30ff2997/build/hdmi-fractional-closure-5754"
H = ROOT / "Memory/lab/fpga-h264-30ff2997/handoff"
OWNER = "d57727ed-8537-429b-ac32-d83800e6c994"
DRIVER = ROOT / (
    ".worktrees/fpga-h264-fleet-30ff2997/build/coherent-functional-sys20-5754/"
    "staged/timing-tool-r4/source/scripts/rbf_build.py")


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write(path, data):
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")


def main():
    campaign = sys.argv[1]
    selectors = sys.argv[2:] or ["test_ascal_timing_pipeline", "test_ascal_fraction_pipeline"]
    assert all(s in {"test_ascal_timing_pipeline", "test_ascal_fraction_pipeline"} for s in selectors)
    mission = json.loads((H.parent / "clean-resume-5754/hdmi-fractional-closure/mission.json").read_text())
    registry = json.loads((H / "registry.json").read_text())
    assert mission["owner_agent_id"] == OWNER and mission["state"].startswith("active")
    assert any(l["name"] == "hdmi-fractional-closure" and l["agent_id"] == OWNER
               for l in registry["lanes"])
    assert OWNER in registry["heavy_rtl_resource"]["permitted_owners"]
    assert registry["fit_owner"] is None and registry["analysis_owner"] is None
    assert sha(DRIVER) == "0be637ccb53ecb6bd1335b53bec7bdef1a87bbb8671c3e1c055172ca32441e16"
    spec = importlib.util.spec_from_file_location("reviewed_guard_driver", DRIVER)
    r4 = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(r4)
    out = OWN / "results" / campaign
    out.mkdir(parents=True)
    scratch = out / "compiler-scratch"
    scratch.mkdir()
    source = OWN / "source-tree/sys/ascal.vhd"
    inputs = [p for p in (OWN / "source-tree").rglob("*") if p.is_file()]
    inputs += [p for p in (OWN / "validation").rglob("*") if p.is_file() and "__pycache__" not in p.parts]
    inputs += [OWN / "preimages/ascal.vhd", Path(__file__), DRIVER]
    before = {str(p.relative_to(ROOT)): sha(p) for p in sorted(inputs)}
    command = [sys.executable, "-m", "unittest", "discover", "-s", "tests/unit",
               "-p", "test_fpga_sys_top_elaboration.py", "-v"]
    for selector in selectors:
        command += ["-k", selector]
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1", TMPDIR=str(scratch),
               TMP=str(scratch), TEMP=str(scratch), OMP_NUM_THREADS="1", MAKEFLAGS="-j1",
               ASCAL_SOURCE=str(source), ASCAL_REFERENCE_SOURCE=str(OWN / "preimages/ascal.vhd"),
               ASCAL_TEST_OUTPUT=str(out / "timing"), ASCAL_FRACTION_OUTPUT=str(out / "fraction"))
    record = {
        "owner_agent_id": OWNER, "mission": mission, "campaign": campaign,
        "started": datetime.now(timezone.utc).isoformat(), "pid": os.getpid(),
        "cwd": str(OWN / "validation"), "command": command, "inputs": before,
        "environment": {k: env[k] for k in ("PYTHONDONTWRITEBYTECODE", "TMPDIR", "OMP_NUM_THREADS",
                                         "MAKEFLAGS", "ASCAL_SOURCE", "ASCAL_REFERENCE_SOURCE",
                                         "ASCAL_TEST_OUTPUT", "ASCAL_FRACTION_OUTPUT")},
        "grant": "focused source validation only; no fit/STA/SDK/device",
        "outcome": "intent; guards not yet acquired",
    }
    receipt = out / "receipt.json"
    write(receipt, record)
    lockpath = ROOT / "build/resource-preflight.lock"
    repository = r4.repository_lock(ROOT)
    try:
        with lockpath.open("a+") as primary:
            fcntl.flock(primary, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with r4.host_lock(r4.CONTROLLER_KEY), r4.fit_lock(repository), r4.host_lock(r4.EXECUTION_KEY):
                record["acquired"] = {
                    "primary_path": str(lockpath), "primary_fd": primary.fileno(),
                    "primary_inode": os.fstat(primary.fileno()).st_ino,
                    "repository_owner": json.loads(repository.with_name(repository.name + ".owner").read_text()),
                    "controller_value": r4.LIBC.semctl(r4.semaphore_id(r4.CONTROLLER_KEY), 0, 12),
                    "execution_value": r4.LIBC.semctl(r4.semaphore_id(r4.EXECUTION_KEY), 0, 12),
                }
                assert record["acquired"]["controller_value"] == record["acquired"]["execution_value"] == 0
                record["outcome"] = "guards acquired; running existing unittest selectors"
                write(receipt, record)
                with (out / "unittest.log").open("w") as log:
                    child = subprocess.Popen(command, cwd=OWN / "validation", env=env,
                                             stdout=log, stderr=subprocess.STDOUT)
                    record["test_pid"] = child.pid
                    write(receipt, record)
                    result = child.wait()
                record["returncode"] = result
                record["inputs_unchanged"] = before == {str(p.relative_to(ROOT)): sha(p) for p in sorted(inputs)}
                assert record["inputs_unchanged"]
    except BaseException as error:
        record["exception"] = repr(error)
        record["outcome"] = "failed; inspect retained raw evidence"
        raise
    finally:
        record["finished"] = datetime.now(timezone.utc).isoformat()
        record["released"] = {
            "repository_owner_absent": not repository.with_name(repository.name + ".owner").exists(),
            "controller_value": r4.LIBC.semctl(r4.semaphore_id(r4.CONTROLLER_KEY), 0, 12),
            "execution_value": r4.LIBC.semctl(r4.semaphore_id(r4.EXECUTION_KEY), 0, 12),
            "owned_child_terminal": "child" not in locals() or child.poll() is not None,
        }
        if "returncode" in record:
            record["outcome"] = "passed" if record["returncode"] == 0 else "failed"
        write(receipt, record)
    print((out / "unittest.log").read_text())
    print(json.dumps({"campaign": campaign, "outcome": record["outcome"], "released": record["released"]}))
    return result


if __name__ == "__main__":
    sys.exit(main())
