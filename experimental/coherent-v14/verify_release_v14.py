#!/usr/bin/env python3
"""Independently check the frozen V14 archives, source delta and patch replay."""
import ctypes
import datetime
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import subprocess
import tarfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]
RELEASE = HERE / "release-v14"
BASE = HERE.parent / "cavlc-timing-v13-5754/release-v13"
SOURCE = "df9edd2c2c283ca574706401c1d253a5ca976394d8d33acf9456c18f2bb1ec59"
OWNER = "ce6e3c70-35d0-47b7-a3b9-c1704c76e2be"
CHANGED = ["rtl/h264_deblock.sv", "rtl/h264_deblock_frame.sv",
           "rtl/h264_intra_pred.sv", "rtl/h264_mb_ctrl.sv"]


def digest(data):
    return hashlib.sha256(data).hexdigest()


def file_hash(path):
    return digest(path.read_bytes())


def load(path):
    return json.loads(path.read_text())


def members(path):
    content = {}
    with tarfile.open(path, "r") as archive:
        for member in archive.getmembers():
            name = PurePosixPath(member.name)
            assert member.isfile() and not name.is_absolute() and ".." not in name.parts
            assert member.name not in content and member.mode == 0o444
            assert member.uid == member.gid == member.mtime == 0
            content[member.name] = archive.extractfile(member).read()
    return content


def mapping(content):
    return {name: digest(value) for name, value in content.items()}


assert not (HERE / "evidence/final-verification.json").exists(), "Never overwrite a verification"
manifest, meta, outcome = load(RELEASE / "manifest.json"), load(RELEASE / "inputs.json"), load(HERE / "owner-result.json")
assert manifest["source_sha256"] == meta["source_sha256"] == outcome["source_sha256"] == SOURCE
assert manifest["owner"] == OWNER and manifest["grant"] == "v14-real-critical-cones-5754"
assert manifest["fit_grant"] is None and manifest["physical_tool_owner"] is None
assert manifest["Quartus_or_hardware_invoked"] is False and not manifest["running_commands"]
assert stat.S_IMODE(RELEASE.stat().st_mode) == 0o555
assert set(manifest["artifacts_sha256"]) == {p.name for p in RELEASE.iterdir()} - {"manifest.json"}
for name, expected in outcome["files_sha256"].items():
    assert PurePosixPath(name).parent == PurePosixPath(".")
    assert file_hash(RELEASE / name) == expected
    assert stat.S_IMODE((RELEASE / name).stat().st_mode) == 0o444
for name, expected in manifest["artifacts_sha256"].items():
    assert file_hash(RELEASE / name) == expected
assert file_hash(BASE / "manifest.json") == manifest["base_release_manifest_sha256"]
base_meta = load(BASE / "inputs.json")
before, source, inputs = members(BASE / "source.tar"), members(RELEASE / "source.tar"), members(RELEASE / "inputs.tar")
base_inputs = members(BASE / "inputs.tar")
assert len(source) == 149 and len(inputs) == 150 and set(source) == set(before)
assert mapping(source) == meta["source_files"] == load(RELEASE / "source-map.json")
assert mapping(inputs) == meta["input_files"] == load(RELEASE / "effective-input-map.json")
assert digest(json.dumps(mapping(source), sort_keys=True).encode()) == SOURCE
assert digest(json.dumps(mapping(inputs), sort_keys=True).encode()) == meta["input_sha256"]
assert sorted(name for name in source if source[name] != before[name]) == CHANGED
assert sorted(name for name in inputs if inputs[name] != base_inputs[name]) == ["Plex.qsf"] + CHANGED
for name, data in source.items():
    assert (HERE / "project/fpga/Plex_MiSTer" / name).read_bytes() == data
assert inputs["Plex.qsf"] == source["Plex.qsf"] + (
    f'\nset_global_assignment -name VERILOG_MACRO "FPGA_VIDEO_BUILD_ID=32\'h{SOURCE[:8]}"\n').encode()
assert inputs["build_id.v"] == base_inputs["build_id.v"]
assert meta["legacy_build_date"] == "260906"
assert source["rtl/h264_cavlc_residual.sv"] == before["rtl/h264_cavlc_residual.sv"]
assert source["rtl/h264_dpb.sv"] == before["rtl/h264_dpb.sv"]
assert source["rtl/decode_stub.sv"] == before["rtl/decode_stub.sv"]
assert meta["source_archive_sha256"] == file_hash(RELEASE / "source.tar")
assert meta["archive_sha256"] == file_hash(RELEASE / "inputs.tar")
assert meta["driver_sha256"] == file_hash(HERE / "freeze_release_v14.py")

validation = members(RELEASE / "validation-code.tar")
validation_map = load(RELEASE / "validation-source-map.json")
assert len(validation) == 61 and mapping(validation) == validation_map["new_members"]
for name, data in validation.items():
    assert (HERE / name).read_bytes() == data
assert mapping(members(RELEASE / "original-added-benches.tar")) == validation_map["original_added_benches"]
fixtures = load(RELEASE / "fixture-preservation.json")
assert len(fixtures) == 95
for name, expected in fixtures.items():
    assert file_hash(HERE / name) == expected
base_fixtures = load(BASE / "fixture-preservation.json")
assert len(base_fixtures) == 92 and all(fixtures[name] == value for name, value in base_fixtures.items())

results = load(RELEASE / "results.json")
assert results["source_sha256"] == SOURCE and results["compiler_workers"] == 1
assert results["totals"] == load(BASE / "results.json")["totals"]
assert len(results["cases"]) == 11 and results["totals"]["pictures"] == 38
assert len(results["controller_cases"]) == 14 and results["complete_coded_picture_comparisons"] == 52
assert results["original_budgets"]["composed_event_budget_seconds"] == 1
assert results["original_budgets"]["controller_picture_cycles"] == 12000000
assert results["original_budgets"]["frame_filter_cycles"] == 4000000
curated = members(RELEASE / "results.tar")
for label, item in results["transactions"].items():
    path = HERE / "evidence/jobs" / f"{label}.json"
    assert file_hash(path) == item["receipt_sha256"]
    receipt = load(path)
    assert receipt == item["receipt"] and curated[f"transactions/{label}.json"] == path.read_bytes()
    assert receipt["source_sha256"] == SOURCE and receipt["owned_child_group_settled"]
    assert receipt["exit_code"] == (1 if label == "v14-frame-r1" else 0)
    assert digest(curated[f"transactions/{label}.log"]) == receipt["output_sha256"]
for case in results["cases"]:
    shifted = Path(case["case"]).parts[1] in ("full240-joint", "legacy-full240", "active-filter-recovery")
    assert all(delta["display_cycle"] == (2005872 if shifted else 0)
               and delta["display_interval"] == 0 for delta in case["V13_deltas_SYS_cycles"])

workspace = HERE / "evidence/patch-replay"
assert not workspace.exists(), "Never reuse an unfinished patch replay"
workspace.mkdir()
for name, data in before.items():
    path = workspace / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
environment = os.environ.copy()
for name in ("TMPDIR", "TMP", "TEMP"):
    environment[name] = str(HERE / "evidence/compiler-scratch")
command = ["patch", "--batch", "--forward", "--fuzz=0", "-p1", "--directory", str(workspace),
           "--input", str(RELEASE / "critical-cones.patch")]
replay = subprocess.run(command, check=True, capture_output=True, text=True, env=environment)
assert {str(p.relative_to(workspace)) for p in workspace.rglob("*") if p.is_file()} == set(source)
assert all((workspace / name).read_bytes() == data for name, data in source.items())
shutil.rmtree(workspace)

libc = ctypes.CDLL(None, use_errno=True)
guards = {}
for name, key in (("controller", 0x4D505843), ("execution", 0x4D505845)):
    sid = libc.semget(key, 1, 0)
    assert sid >= 0, "Do not create missing guards"
    value, pid = libc.semctl(sid, 0, 12), libc.semctl(sid, 0, 11)
    assert value == 1, "Actual guard is not free; do not clear it"
    guards[name] = {"id": sid, "value": value, "last_pid": pid}
processes = subprocess.check_output(["ps", "-eo", "pid=,ppid=,comm="], text=True).splitlines()
heavy = [line.strip() for line in processes if line.split()[-1].startswith(
    ("quartus", "verilator", "Vh264", "Vfpga", "Vp2_", "Vgop12"))]
assert not heavy, "Actual physical/RTL process remains"
lock = ROOT / ".git/misterplex-build/single-fit.lock"
info = lock.stat()
device_inode = f"{os.major(info.st_dev):02x}:{os.minor(info.st_dev):02x}:{info.st_ino}"
lock_rows = [line for line in Path("/proc/locks").read_text().splitlines() if device_inode in line]
assert not lock_rows, "Existing repository lock is still held"
verification = {
    "owner": OWNER, "grant": "v14-real-critical-cones-5754",
    "source_sha256": SOURCE, "result": "PASS_COMPLETE_ARCHIVES_PATCH_AND_SEMANTIC_EVIDENCE",
    "verified_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "source_members": 149, "effective_input_members": 150, "validation_members": 61,
    "fixture_members": 95, "original_fixture_members_unchanged": 92,
    "source_delta": CHANGED, "patch_command": command, "patch_output": replay.stdout.splitlines(),
    "patch_replay_exact": True, "patch_workspace_removed": True,
    "release_files_sha256": outcome["files_sha256"],
    "original_composed_pictures": 38, "additional_controller_pictures": 14,
    "latency_cost_retained": True, "actual_guards": guards, "repository_lock_rows": lock_rows,
    "physical_or_RTL_processes": heavy, "running_owned_jobs": [],
    "physical_or_playback_acceptance": False, "publication": "LOCAL_ONLY",
}
(HERE / "evidence/final-verification.json").write_text(json.dumps(verification, indent=2, sort_keys=True) + "\n")
print(json.dumps({"source_sha256": SOURCE, "verification_sha256": file_hash(HERE / "evidence/final-verification.json"),
                  "result": verification["result"], "running_owned_jobs": []}, indent=2))
