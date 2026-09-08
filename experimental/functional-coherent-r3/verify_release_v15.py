#!/usr/bin/env python3
"""Separately verify frozen V15 archives, exact patch replay and real quiescence."""
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
RELEASE = HERE / "release-v15"
BASE = HERE.parent / "critical-cones-v14-5754/release-v14"
SOURCE = "4f09a4176a6b954463e0d6b7484c3d421efdb686421bcf67f7bf254bf34604ef"
OWNER = "ce6e3c70-35d0-47b7-a3b9-c1704c76e2be"
GRANT = "v15-measured-hadamard-return-mv-cones-5754"
CHANGED = ["rtl/ddr_frame_store.sv", "rtl/h264_i16_dc_hadamard.sv",
           "rtl/h264_inter_pred.sv", "rtl/h264_mb_ctrl.sv", "rtl/present_core.sv"]


def digest(data):
    return hashlib.sha256(data).hexdigest()


def file_hash(path):
    return digest(path.read_bytes())


def load(path):
    return json.loads(path.read_text())


def members(path):
    content = {}
    with tarfile.open(path) as archive:
        for member in archive:
            name = PurePosixPath(member.name)
            assert member.isfile() and not name.is_absolute() and ".." not in name.parts
            assert member.name not in content and member.mode == 0o444
            assert member.uid == member.gid == member.mtime == 0
            content[member.name] = archive.extractfile(member).read()
    return content


def mapping(content):
    return {name: digest(data) for name, data in content.items()}


assert not (HERE / "evidence/final-verification.json").exists(), "Never overwrite verification"
manifest, meta = load(RELEASE / "manifest.json"), load(RELEASE / "inputs.json")
outcome = load(HERE / "owner-result.json")
assert manifest["source_sha256"] == meta["source_sha256"] == outcome["source_sha256"] == SOURCE
assert manifest["owner"] == OWNER and manifest["grant"] == GRANT
assert manifest["fit_grant"] is None and manifest["physical_tool_owner"] is None
assert manifest["Quartus_or_hardware_invoked"] is False and not manifest["running_commands"]
assert manifest["clock_profile"] == "SYS120/DDR90/native20" and manifest["capability"] == 0
assert manifest["seed"] == 6 and manifest["processors"] == 2
assert stat.S_IMODE(RELEASE.stat().st_mode) == 0o555
assert set(manifest["artifacts_sha256"]) == {p.name for p in RELEASE.iterdir()} - {"manifest.json"}
for name, expected in outcome["files_sha256"].items():
    assert PurePosixPath(name).parent == PurePosixPath(".")
    assert file_hash(RELEASE / name) == expected
    assert stat.S_IMODE((RELEASE / name).stat().st_mode) == 0o444
for name, expected in manifest["artifacts_sha256"].items():
    assert file_hash(RELEASE / name) == expected
assert file_hash(BASE / "manifest.json") == manifest["base_release_manifest_sha256"] == \
    "be4dc86497aab4db2ae9c337d78ce19976b120de1220d07cd07a7b21650677a9"
base_meta = load(BASE / "inputs.json")
before, source = members(BASE / "source.tar"), members(RELEASE / "source.tar")
base_inputs, inputs = members(BASE / "inputs.tar"), members(RELEASE / "inputs.tar")
assert len(source) == 149 and len(inputs) == 150 and set(source) == set(before)
assert mapping(source) == meta["source_files"] == load(RELEASE / "source-map.json")
assert mapping(inputs) == meta["input_files"] == load(RELEASE / "effective-input-map.json")
assert digest(json.dumps(mapping(source), sort_keys=True).encode()) == SOURCE
assert digest(json.dumps(mapping(inputs), sort_keys=True).encode()) == meta["input_sha256"] == outcome["input_sha256"]
assert sorted(name for name in source if source[name] != before[name]) == CHANGED
assert sorted(name for name in inputs if inputs[name] != base_inputs[name]) == ["Plex.qsf"] + CHANGED
for name, data in source.items():
    path = HERE / "project/fpga/Plex_MiSTer" / name
    assert path.read_bytes() == data and stat.S_IMODE(path.stat().st_mode) == 0o444
assert inputs["Plex.qsf"] == source["Plex.qsf"] + (
    f'\nset_global_assignment -name VERILOG_MACRO "FPGA_VIDEO_BUILD_ID=32\'h{SOURCE[:8]}"\n').encode()
assert inputs["build_id.v"] == base_inputs["build_id.v"] and meta["legacy_build_date"] == "260906"
preservation = load(RELEASE / "member-preservation.json")
assert preservation["unchanged_source_members"] == preservation["unchanged_effective_members"] == 144
for name in preservation["protected_members_unchanged"]:
    assert source[name] == before[name]
assert all(source[name] == before[name] for name in source if name.endswith(".sdc"))
assert meta["source_archive_sha256"] == file_hash(RELEASE / "source.tar")
assert meta["archive_sha256"] == file_hash(RELEASE / "inputs.tar")
assert meta["driver_sha256"] == file_hash(HERE / "freeze_release_v15.py")

validation = members(RELEASE / "validation-code.tar")
validation_map = load(RELEASE / "validation-source-map.json")
assert len(validation) == 73 and mapping(validation) == validation_map["new_members"]
for name, data in validation.items():
    assert (HERE / name).read_bytes() == data
assert mapping(members(RELEASE / "original-added-benches.tar")) == validation_map["original_added_benches"]
assert set(validation_map["base_members"]).issubset(validation)
fixtures, base_fixtures = load(RELEASE / "fixture-preservation.json"), load(BASE / "fixture-preservation.json")
assert len(fixtures) == 96 and len(base_fixtures) == 95
assert all(fixtures[name] == expected for name, expected in base_fixtures.items())
for name, expected in fixtures.items():
    assert file_hash(HERE / name) == expected

results = load(RELEASE / "results.json")
assert results["source_sha256"] == SOURCE and results["compiler_workers"] == 1
assert results["totals"] == load(BASE / "results.json")["totals"]
assert len(results["cases"]) == 11 and results["totals"]["pictures"] == 38
assert len(results["controller_cases"]) == 16 and results["complete_coded_picture_comparisons"] == 54
assert results["original_budgets"]["composed_event_budget_seconds"] == 1
assert results["original_budgets"]["controller_picture_cycles"] == 12000000
assert results["original_budgets"]["IQ_Hadamard_cycles"] == 100
assert results["pipeline_cycles"] == {
    "Hadamard": 19, "Hadamard_added_SYS": 3, "limited_colour_return": 3,
    "limited_colour_added_SYS": 1, "motion_request_added_SYS": 0,
}
curated = members(RELEASE / "results.tar")
expected_failures = {"v15-targeted-r1", "v15-legacy-and-composed-r1", "v15-warm-v14-baseline"}
for label, item in results["transactions"].items():
    path = HERE / "evidence/jobs" / f"{label}.json"
    assert file_hash(path) == item["receipt_sha256"]
    receipt = load(path)
    assert receipt == item["receipt"] and curated[f"transactions/{label}.json"] == path.read_bytes()
    assert receipt["source_sha256"] == SOURCE and receipt["owned_child_group_settled"]
    assert receipt["exit_code"] == int(label in expected_failures)
    assert digest(curated[f"transactions/{label}.log"]) == receipt["output_sha256"]
    assert all(value["value"] == 1 for value in receipt["guards_after"].values())
assert results["legacy_baseline_failure"]["baseline_source"] == base_meta["source_sha256"]
warm = list(results["legacy_baseline_failure"]["records"].values())
assert warm[0]["lines"] == warm[1]["lines"] and len(warm[0]["lines"]) == 16
assert "FAIL ddr_frame_store warm-reset: equal-token refresh" in warm[0]["lines"][-1]
for case in results["cases"]:
    assert all(delta["display_cycle"] == delta["display_interval"] ==
               delta["publication_retired_cycle"] == delta["checker_retired_cycle"] == 0
               for delta in case["V14_deltas_SYS_cycles"])
assert sum(len(case["metrics_SYS_cycles"]) for case in results["cases"]) == 35
assert sum(line.startswith("INGRESS_SEEK_PASS") for case in results["cases"] for line in case["checks"]) == 5
assert sum("HADAMARD_CANCEL " in "\n".join(case["checks"]) for case in results["controller_cases"]) == 14
witnesses = load(RELEASE / "witnesses.json")
assert file_hash(ROOT / witnesses["base_physical_summary"]) == witnesses["base_physical_summary_sha256"]
for witness in witnesses["native_setup_paths"]:
    assert file_hash(ROOT / witness["file"]) == witness["sha256"]
    assert file_hash(HERE / witness["first_path"]) == witness["first_path_sha256"]
    assert file_hash(HERE / witness["data_path"]) == witness["data_path_sha256"]

workspace = HERE / "evidence/patch-replay-v15"
assert not workspace.exists(), "Never reuse an unfinished patch replay"
workspace.mkdir()
for name, data in before.items():
    path = workspace / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
scratch = HERE / "evidence/compiler-scratch"
scratch.mkdir(exist_ok=True)
environment = os.environ.copy()
for name in ("TMPDIR", "TMP", "TEMP"):
    environment[name] = str(scratch)
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
    ("quartus", "verilator", "Vh264", "Vfpga", "Vp2_", "Vgop12", "Vddr", "Vpresent", "Vframe_store"))]
assert not heavy, "Actual physical/RTL process remains"
lock = ROOT / ".git/misterplex-build/single-fit.lock"
info = lock.stat()
device_inode = f"{os.major(info.st_dev):02x}:{os.minor(info.st_dev):02x}:{info.st_ino}"
lock_rows = [line for line in Path("/proc/locks").read_text().splitlines() if device_inode in line]
assert not lock_rows, "Existing repository lock is still held"
verification = {
    "owner": OWNER, "grant": GRANT, "source_sha256": SOURCE,
    "result": "PASS_COMPLETE_ARCHIVES_PATCH_AND_EVIDENCE_WITH_MATCHING_LEGACY_BASELINE_FAILURE",
    "verified_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "source_members": 149, "effective_input_members": 150, "validation_members": 73,
    "fixture_members": 96, "original_fixture_members_unchanged": 95,
    "source_delta": CHANGED, "patch_command": command, "patch_output": replay.stdout.splitlines(),
    "patch_replay_exact": True, "patch_workspace_removed": True,
    "release_files_sha256": outcome["files_sha256"],
    "original_composed_pictures": 38, "additional_controller_pictures": 16,
    "baseline_failure_retained": True, "latency_cost_retained": True,
    "actual_guards": guards, "repository_lock_rows": lock_rows,
    "physical_or_RTL_processes": heavy, "running_owned_jobs": [],
    "physical_or_playback_acceptance": False, "publication": "LOCAL_ONLY",
}
(HERE / "evidence/final-verification.json").write_text(json.dumps(verification, indent=2, sort_keys=True) + "\n")
print(json.dumps({"source_sha256": SOURCE, "verification_sha256": file_hash(HERE / "evidence/final-verification.json"),
                  "result": verification["result"], "running_owned_jobs": []}, indent=2))
