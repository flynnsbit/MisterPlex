#!/usr/bin/env python3
"""Separately verify coherent R3 archives, component replay and functional evidence."""
import argparse
import csv
import ctypes
import datetime
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import tarfile

from freeze_coherent_r3 import BASE, BASE_MANIFEST, BASE_SOURCE, CENTRAL, GRANT, HERE
from freeze_coherent_r3 import OUT, OWNER, PROJECT, R3, R3_RTL, ROOT, SOURCE
from freeze_functional import digest, file_hash, identity, load, mapping, members


def restore(directory, content):
    for name, data in content.items():
        path = directory / name
        path.parent.mkdir(parents=True, exist_ok=True)
        assert not path.exists()
        path.write_bytes(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release", default="release-coherent-r3")
    args = parser.parse_args()
    release = HERE / args.release
    assert release.parent == HERE
    report_path = HERE / "evidence/coherent-r3-final-verification.json"
    assert not report_path.exists()
    manifest, meta = load(release / "manifest.json"), load(release / "inputs.json")
    outcome = load(HERE / "coherent-r3-owner-result.json")
    results = load(release / "results.json")
    assert manifest["scope"] == outcome["scope"] == "COHERENT_CENTRAL_PLUS_EXACT_PICTURE_R3"
    assert manifest["owner"] == OWNER and manifest["grant"] == GRANT
    assert manifest["source_sha256"] == meta["source_sha256"] == outcome["source_sha256"] == SOURCE
    assert manifest["base_source_sha256"] == BASE_SOURCE
    assert file_hash(BASE / "manifest.json") == manifest["base_release_manifest_sha256"] == BASE_MANIFEST
    assert file_hash(CENTRAL / "manifest.json") == manifest["central_release_manifest_sha256"]
    assert file_hash(R3 / "manifest.json") == manifest["picture_release_manifest_sha256"] == \
        "c5d2ce5623c5298e4bb48903ba815aa8070129d28ffd71d03c0429f403c223a9"
    assert manifest["source_or_hardware_approval"] is False
    assert manifest["Quartus_or_hardware_invoked"] is False
    assert manifest["fit_grant"] is None and manifest["physical_tool_owner"] is None
    assert manifest["running_commands"] == outcome["running_commands"] == []
    assert manifest["capability"] == 0xe1ff and manifest["tier_bits_9_12"] == 0
    assert (manifest["max_width"], manifest["max_height"], manifest["max_au_bytes"]) == (320, 240, 8192)
    assert manifest["clock_profile"] == "SYS120/DDR90/native20"
    assert manifest["seed"] == 6 and manifest["processors"] == 2
    assert stat.S_IMODE(release.stat().st_mode) == 0o555
    assert set(manifest["artifacts_sha256"]) == {p.name for p in release.iterdir()} - {"manifest.json"}
    for name, expected in outcome["files_sha256"].items():
        assert PurePosixPath(name).parent == PurePosixPath(".")
        assert file_hash(release / name) == expected
        assert stat.S_IMODE((release / name).stat().st_mode) == 0o444
    for name, expected in manifest["artifacts_sha256"].items():
        assert file_hash(release / name) == expected
    for name in ("source.tar", "inputs.tar", "validation-code.tar", "results.tar"):
        with tarfile.open(release / name) as archive:
            assert all(member.mode == 0o444 and
                       member.uid == member.gid == member.mtime == 0 for member in archive)
    before, source = members(BASE / "source.tar"), members(release / "source.tar")
    old_inputs, inputs = members(BASE / "inputs.tar"), members(release / "inputs.tar")
    assert len(source) == 149 and len(inputs) == 150 and set(source) == set(before)
    assert mapping(source) == meta["source_files"] == load(release / "source-map.json")
    assert mapping(inputs) == meta["input_files"] == load(release / "effective-input-map.json")
    assert identity(mapping(source)) == SOURCE
    assert identity(mapping(inputs)) == meta["input_sha256"] == outcome["input_sha256"]
    changed = ["Plex.qsf", "Plex.sv", "rtl/ddr_frame_store.sv"]
    assert sorted(name for name in source if source[name] != before[name]) == changed
    assert sorted(name for name in inputs if inputs[name] != old_inputs[name]) == changed
    assert manifest["source_delta"] == manifest["input_delta"] == changed
    for name, data in source.items():
        assert (PROJECT / name).read_bytes() == data
        assert stat.S_IMODE((PROJECT / name).stat().st_mode) == 0o444
    for name in ("rtl/present_core.sv", "rtl/fpga_video_publish.sv"):
        assert source[name] == before[name]
    assert digest(source["rtl/ddr_frame_store.sv"]) == R3_RTL
    central_source = members(CENTRAL / "source.tar")
    assert sorted(name for name in source if source[name] != central_source[name]) == ["rtl/ddr_frame_store.sv"]
    assert inputs["Plex.qsf"] == source["Plex.qsf"] + (
        f'\nset_global_assignment -name VERILOG_MACRO "FPGA_VIDEO_BUILD_ID=32\'h{SOURCE[:8]}"\n').encode()
    assert inputs["build_id.v"] == old_inputs["build_id.v"] and meta["legacy_build_date"] == "260906"
    assert inputs["sys/build_id.tcl"] == old_inputs["sys/build_id.tcl"]
    assert all(source[name] == before[name] for name in source if name.endswith(".sdc"))
    assert meta["source_archive_sha256"] == file_hash(release / "source.tar")
    assert meta["archive_sha256"] == file_hash(release / "inputs.tar")
    assert meta["driver_sha256"] == file_hash(HERE / "freeze_coherent_r3.py")
    validation = members(release / "validation-code.tar")
    validation_map = load(release / "validation-source-map.json")
    validation_modes = load(release / "validation-execution-modes.json")
    assert mapping(validation) == validation_map["new_members"]
    assert len(validation) == manifest["validation_source_members"]
    assert set(validation_modes) == set(validation)
    for name, data in validation.items():
        path = HERE / name
        assert path.read_bytes() == data, name
        assert oct(stat.S_IMODE(path.stat().st_mode)) == validation_modes[name]
    assert validation_modes["coherent-r3/project/scripts/run_verilator.sh"] == "0o544"
    fixtures = load(release / "fixture-preservation.json")
    assert fixtures == load(BASE / "fixture-preservation.json") and len(fixtures) == 96
    for name, expected in fixtures.items():
        assert file_hash(OUT / name) == expected, name
    curated = members(release / "results.tar")
    assert len(curated) == manifest["curated_evidence_members"]
    for label, item in results["transactions"].items():
        path = OUT / "evidence/jobs" / (label + ".json")
        assert file_hash(path) == item["receipt_sha256"]
        receipt = load(path)
        assert receipt == item["receipt"] and receipt["owned_child_group_settled"]
        assert receipt["state"] != "running"
        assert curated["transactions/" + path.name] == path.read_bytes()
        if "output_sha256" in receipt:
            assert digest(curated["transactions/" + Path(receipt["output"]).name]) == receipt["output_sha256"]
    final = results["transactions"][results["final_job"]]["receipt"]
    assert results["source_sha256"] == final["source_sha256"] == SOURCE
    assert final["state"] == "passed" and final["exit_code"] == 0
    assert mapping(source) == final["source_map"]
    assert results["actual_production_bindings"]["source_sha256"] == SOURCE
    assert results["actual_production_bindings"]["modes"]["fpga320"]["build_id"] == int(SOURCE[:8], 16)
    baseline = load(BASE / "results.json")
    assert results["totals"] == baseline["totals"] and results["totals"]["pictures"] == 38
    assert len(results["cases"]) == 11
    assert sum(len(case["metrics_SYS_cycles"]) for case in results["cases"]) == 35
    pictures = 0
    for case, old_case in zip(results["cases"], baseline["cases"]):
        assert case["case"] == old_case["case"]
        directory = OUT / "project/build/verilator" / case["case"]
        text = (directory / "execution.log").read_text()
        assert digest(text.encode()) == case["execution_sha256"]
        assert case["actual_sha256"] == case["reference_sha256"] == file_hash(directory / "actual.i420")
        pictures += len(re.findall(r"(?m)^(?:FRAME_PASS|FAULT_RECOVERY_PASS) ", text))
        csv_path, = directory.glob("*.csv")
        raw_csv = curated[f"composed/{case['case']}/{csv_path.name}"]
        assert raw_csv == csv_path.read_bytes()
        rows = [{key: int(value) for key, value in row.items()}
                for row in csv.DictReader(io.StringIO(raw_csv.decode()))]
        assert rows == case["metrics_SYS_cycles"]
        assert [{key: row[key] - previous[key] for key in row}
                for previous, row in zip(old_case["metrics_SYS_cycles"], rows)] == case["V15_deltas_SYS_cycles"]
    assert pictures == 38 and results["original_budgets"]["composed_event_budget_seconds"] == 1
    assert outcome["V15_cycle_delta_ranges"] == results["V15_cycle_delta_ranges"]
    if manifest["picture_review_sha256"] is None:
        assert results["picture_review"] is None
    else:
        assert digest(curated["picture-r3/review.json"]) == manifest["picture_review_sha256"]
        assert json.loads(curated["picture-r3/review.json"]) == results["picture_review"]
    assert file_hash(release / "central.patch") == \
        "24702ffde335b64d46f9508058b716801447bbc1fa27bf88df79839e2de1687f"
    assert file_hash(release / "picture-r3-from-v15.patch") == \
        "caaad09faf701f3db712b5354483caf0687305eb8228a410469879b6aa00fd6c"
    assert file_hash(release / "functional.patch") == \
        "8f2a8333806688ced8a484a4035ccc50bbba79441925ffb0a5a49cdddcfa43a4"
    workspace = OUT / "evidence/patch-replay"
    assert not workspace.exists()
    workspace.mkdir()
    scratch = OUT / "evidence/compiler-scratch"
    scratch.mkdir(exist_ok=True)
    env = dict(os.environ, TMPDIR=str(scratch), TMP=str(scratch), TEMP=str(scratch))
    patch_records = []

    def apply(directory, patch):
        command = ["patch", "--batch", "--forward", "--fuzz=0", "-p1",
                   "--directory", str(directory), "--input", str(patch)]
        replay = subprocess.run(command, check=True, capture_output=True, text=True, env=env)
        patch_records.append({"command": command, "output": replay.stdout.splitlines()})

    product = workspace / "product"
    restore(product, before)
    apply(product, release / "functional.patch")
    assert {str(p.relative_to(product)): p.read_bytes() for p in product.rglob("*") if p.is_file()} == source
    components = workspace / "components"
    restore(components / "fpga/Plex_MiSTer", before)
    base_validation = members(BASE / "validation-code.tar")
    restore(components, {name.removeprefix("project/"): data
                         for name, data in base_validation.items() if name.startswith("project/")})
    apply(components, release / "picture-r3-from-v15.patch")
    leaf = load(R3 / "manifest.json")
    descriptions = {**leaf["changed_source_members"], **leaf["validation_setup_member"]}
    for name, description in descriptions.items():
        path = components / name
        assert file_hash(path) == description["sha256"]
        path.chmod(int(description["mode"], 8))
    apply(components / "fpga/Plex_MiSTer", release / "central.patch")
    assert all((components / "fpga/Plex_MiSTer" / name).read_bytes() == data for name, data in source.items())
    for name in leaf["changed_source_members"]:
        if name.startswith("tests/"):
            assert (components / name).read_bytes() == validation["coherent-r3/project/" + name]
    shutil.rmtree(workspace)
    own_pids = set()
    for directory in (HERE / "evidence/jobs", HERE / "central-only/evidence/jobs", OUT / "evidence/jobs"):
        for path in directory.glob("*.json"):
            job = load(path)
            assert job["owned_child_group_settled"] and job["state"] != "running"
            own_pids.add(job["wrapper_pid"])
    libc = ctypes.CDLL(None, use_errno=True)
    guards = {}
    for name, key in (("controller", 0x4D505843), ("execution", 0x4D505845)):
        sid = libc.semget(key, 1, 0)
        assert sid >= 0
        value, pid = libc.semctl(sid, 0, 12), libc.semctl(sid, 0, 11)
        assert value in (0, 1) and not (value == 0 and pid in own_pids)
        guards[name] = {"id": sid, "value": value, "last_pid": pid, "owned_by_this_lane": False}
    locks = Path("/proc/locks").read_text().splitlines()
    lock_rows = {}
    for name in ("build/resource-preflight.lock", ".git/misterplex-build/single-fit.lock"):
        info = (ROOT / name).stat()
        key = f"{os.major(info.st_dev):02x}:{os.minor(info.st_dev):02x}:{info.st_ino}"
        lock_rows[name] = [row for row in locks if key in row]
        for row in lock_rows[name]:
            fields = row.split()
            assert int(fields[fields.index(key) - 1]) not in own_pids
    report = {
        "verified_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "owner": OWNER, "grant": GRANT, "scope": manifest["scope"],
        "source_sha256": SOURCE, "input_sha256": meta["input_sha256"],
        "result": "PASS_COMPLETE_COHERENT_R3_ARCHIVES_COMPONENT_PATCHES_AND_FUNCTIONAL_EVIDENCE",
        "source_members": 149, "effective_input_members": 150,
        "validation_members": len(validation), "fixture_members": 96,
        "source_delta": changed, "unchanged_source_members": 146,
        "frame_store_exact_R3": R3_RTL, "presenter_and_publisher_exact_V15": True,
        "rejected_predecessors_preserved_not_approved": True,
        "combined_and_component_patch_replay_exact": True,
        "patch_commands": patch_records, "patch_workspace_removed": True,
        "actual_guards": guards, "actual_lock_rows": lock_rows,
        "running_owned_jobs": [], "source_or_hardware_approval": False,
        "publication": "LOCAL_ONLY", "release_files_sha256": outcome["files_sha256"],
    }
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"source_sha256": SOURCE, "verification_sha256": file_hash(report_path),
                      "result": report["result"], "running_owned_jobs": []}, indent=2))


if __name__ == "__main__":
    main()
