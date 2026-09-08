#!/usr/bin/env python3
"""Freeze the complete validated functional cohort; never invoke physical tools."""
import argparse
import csv
import difflib
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import re
import tarfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
BASE = HERE.parent / "fpga-coherent-a11/critical-cones-v15-5754/release-v15"
PROJECT = HERE / "project/fpga/Plex_MiSTer"
OWNER = "ce6e3c70-35d0-47b7-a3b9-c1704c76e2be"
GRANT = "complete-existing-fpga-functionality-before-performance-5754"
BASE_SOURCE = "4f09a4176a6b954463e0d6b7484c3d421efdb686421bcf67f7bf254bf34604ef"
BASE_MANIFEST = "b32dd240e54cbafca70262bf4d149b2fb5d5ca877c6b86d4b05cda5b49417a51"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def file_hash(path):
    return digest(path.read_bytes())


def load(path):
    return json.loads(path.read_text())


def encode(value):
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()


def mapping(content):
    return {name: digest(data) for name, data in content.items()}


def identity(values):
    return digest(json.dumps(values, sort_keys=True).encode())


def members(path):
    result = {}
    with tarfile.open(path) as archive:
        for member in archive:
            name = PurePosixPath(member.name)
            assert member.isfile() and not name.is_absolute() and ".." not in name.parts
            assert member.name not in result
            result[member.name] = archive.extractfile(member).read()
    return result


def bundle(path, content):
    with tarfile.open(path, "w") as archive:
        for name, data in sorted(content.items()):
            member = tarfile.TarInfo(name)
            member.mode, member.size = 0o444, len(data)
            archive.addfile(member, io.BytesIO(data))
    assert members(path) == content


def verify_sums(path):
    for line in path.read_text().splitlines():
        expected, name = line.split(maxsplit=1)
        selected = Path(name.lstrip("*"))
        if not selected.is_absolute():
            selected = HERE / "project" / selected
        assert file_hash(selected) == expected, str(selected)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True)
    parser.add_argument("--final-job", required=True)
    parser.add_argument("--picture-review", required=True)
    parser.add_argument("--picture-review-sha256", required=True)
    parser.add_argument("--release", default="release-functional")
    args = parser.parse_args()
    assert re.fullmatch("[0-9a-f]{64}", args.source)
    assert re.fullmatch("[a-z0-9-]+", args.release)
    release = HERE / args.release
    assert not release.exists(), "Never overwrite a release or failed freeze"
    registry_path = ROOT / "Memory/lab/fpga-h264-30ff2997/handoff/registry.json"
    registry = load(registry_path)
    scope = next(item for item in registry["fresh_outcome_scopes"] if item["id"] == GRANT)
    assert scope["owner"] == OWNER and scope["state"].startswith("active")
    assert file_hash(BASE / "manifest.json") == BASE_MANIFEST
    base_manifest, base_meta = load(BASE / "manifest.json"), load(BASE / "inputs.json")
    for name, expected in base_manifest["artifacts_sha256"].items():
        assert file_hash(BASE / name) == expected, name
    before, old_inputs = members(BASE / "source.tar"), members(BASE / "inputs.tar")
    assert len(before) == 149 and len(old_inputs) == 150
    assert mapping(before) == base_meta["source_files"]
    assert identity(mapping(before)) == BASE_SOURCE
    assert mapping(old_inputs) == base_meta["input_files"]
    source = {str(path.relative_to(PROJECT)): path.read_bytes()
              for path in sorted(PROJECT.rglob("*")) if path.is_file()}
    assert set(source) == set(before)
    source_map = mapping(source)
    assert identity(source_map) == args.source
    changed = sorted(name for name in source if source[name] != before[name])
    assert changed == ["Plex.qsf", "Plex.sv", "rtl/ddr_frame_store.sv"]
    semantic_qsf = lambda data: [
        line.split("#", 1)[0].strip() for line in data.decode().splitlines()
        if line.split("#", 1)[0].strip()
    ]
    assert semantic_qsf(source["Plex.qsf"]) == semantic_qsf(before["Plex.qsf"])
    protected = sorted(set(source) - set(changed))
    assert all(source[name] == before[name] for name in protected)
    assert "32'h0000e19f" in source["Plex.sv"].decode()
    assert ".VIDEO_FEATURES(VIDEO_FUNCTIONAL_FEATURES)" in source["Plex.sv"].decode()

    integration = load(HERE / "evidence/picture-r2-integration-result.json")
    assert integration["source_sha256"] == args.source
    for name, expected in integration["expected_postimages_verified"].items():
        assert file_hash(HERE / "project" / name) == expected, name
    review_path = ROOT / args.picture_review
    assert review_path.is_relative_to(ROOT)
    assert file_hash(review_path) == args.picture_review_sha256
    review = load(review_path)
    assert review.get("verdict") in {
        "READY", "READY_FOR_INTEGRATION", "READY_FOR_SOURCE_INTEGRATION",
        "READY_FOR_SOURCE_PUBLICATION", "APPROVED", "PASS",
    }, "A rejected or pending picture review cannot become a coherent release"
    assert "f081ea3a3b1211b441b5786870e1d356b549aa324451be26616e76e879e57dad" in review_path.read_text()

    final_path = HERE / "evidence/jobs" / (args.final_job + ".json")
    final = load(final_path)
    assert final["state"] == "passed" and final["exit_code"] == 0
    assert final["source_map"] == source_map and final["owned_child_group_settled"]
    assert final["owner"] == OWNER and final["grant"] == GRANT
    assert all(item["value"] == 1 for item in final["guards_after"].values())
    final_text = Path(final["output"]).read_text()
    for marker in ("host video admission=1", "RETURN_STREAM returns=4096 latency=3",
                   "equal_token_refresh_after_accept", "sample_r=217",
                   "supersession_before_pending_vsync", "supersession_on_pending_vsync",
                   "supersession_after_pending_vsync"):
        assert marker in final_text, marker
    bindings_path = HERE / "project/build/verilator/fpga_audio_routing/bindings.json"
    bindings = load(bindings_path)
    assert bindings["source_map"] == source_map
    product = bindings["modes"]["fpga320"]
    assert product == {
        "features": 0xe1ff, "build_id": int(args.source[:8], 16),
        "max_width": 320, "max_height": 240, "max_au_bytes": 8192,
        "idr_only": 0, "deblock": 1,
    }
    assert bindings["modes"]["baseline"]["features"] == 0
    assert len(bindings["modes"]) == 5
    curated = {
        "actual-emu/bindings.json": bindings_path.read_bytes(),
        "picture/review.json": review_path.read_bytes(),
    }
    transactions = {}
    for path in sorted((HERE / "evidence/jobs").glob("*.json")):
        job = load(path)
        assert job["owned_child_group_settled"] and job["ended_at"]
        assert job["state"] != "running"
        transactions[path.stem] = {"receipt_sha256": file_hash(path), "receipt": job}
        curated["transactions/" + path.name] = path.read_bytes()
        output = Path(job["output"])
        if output.exists():
            assert file_hash(output) == job["output_sha256"]
            curated["transactions/" + output.name] = output.read_bytes()

    old_results = load(BASE / "results.json")
    cases, totals = [], dict.fromkeys(old_results["totals"], 0)
    for old_case in old_results["cases"]:
        relative = Path(old_case["case"])
        directory = HERE / "project/build/verilator" / relative
        text = (directory / "execution.log").read_text()
        assert text.splitlines()[-1].startswith("PASS ")
        for name in ("inputs.sha256", "binary.sha256", "actual.sha256"):
            verify_sums(directory / name)
        reference = HERE / "project/tests/fixtures" / directory.name / "reference.yuv"
        assert (directory / "actual.i420").read_bytes() == reference.read_bytes()
        frames = re.findall(r"(?m)^FRAME_PASS .*native_bytes=(\d+).*coded_bytes=(\d+)", text)
        recovery = re.findall(r"(?m)^FAULT_RECOVERY_PASS .*coded_bytes=(\d+) visible_bytes=(\d+)", text)
        counts = {
            "pictures": len(frames) + len(recovery),
            "coded_samples": sum(int(c) for _, c in frames) + sum(int(c) for c, _ in recovery),
            "visible_samples": sum(int(v) for v, _ in frames) + sum(int(v) for _, v in recovery),
            "native_RGB_samples": sum(map(int, re.findall(r"(?m)^NATIVE_PASS .*RGB_samples=(\d+)", text))),
            "counted_legacy_RGB565_pixels": sum(map(int, re.findall(r"(?m)^LEGACY_RGB_PASS .*pixels=(\d+)", text))),
        }
        for key, value in counts.items():
            assert value == old_case[key], (relative, key)
            totals[key] += value
        csv_paths = list(directory.glob("*.csv"))
        assert len(csv_paths) == 1
        with csv_paths[0].open() as stream:
            rows = [{key: int(value) for key, value in row.items()} for row in csv.DictReader(stream)]
        assert len(rows) == len(old_case["metrics_SYS_cycles"])
        deltas = []
        for old_row, row in zip(old_case["metrics_SYS_cycles"], rows):
            assert set(old_row) == set(row)
            for key in ("SYS_Hz", "DDR_Hz", "base_Hz", "native_divisor",
                        "prediction_fetches", "fractional_fetches", "nonzero_P_blocks", "filter_writes"):
                assert row[key] == old_row[key], (relative, key)
            deltas.append({key: row[key] - old_row[key] for key in row})
        checks = [line for line in text.splitlines() if re.match(
            r"^(?:FRAME_PASS|NATIVE_PASS|LEGACY_RGB_PASS|BANK_REUSE_PASS|FILTER_ACTIVE_FAULT|"
            r"FILTER_METADATA_FAULT|FAULT_RECOVERY_PASS|CODEC_ERROR_PASS|INGRESS_SEEK_PASS|METRIC|PASS )", line)]
        cases.append({
            "case": str(relative), "pass": True, **counts, "metrics_SYS_cycles": rows,
            "V15_deltas_SYS_cycles": deltas, "checks": checks,
            "execution_sha256": file_hash(directory / "execution.log"),
            "actual_sha256": file_hash(directory / "actual.i420"),
            "reference_sha256": file_hash(reference),
        })
        curated[f"composed/{relative}/checks.log"] = ("\n".join(checks) + "\n").encode()
        for name in (csv_paths[0].name, "inputs.sha256", "binary.sha256", "actual.sha256",
                     "clock-binding.json"):
            curated[f"composed/{relative}/{name}"] = (directory / name).read_bytes()
    assert len(cases) == 11 and totals == old_results["totals"] and totals["pictures"] == 38
    assert sum(len(case["metrics_SYS_cycles"]) for case in cases) == 35
    assert sum(line.startswith("INGRESS_SEEK_PASS") for case in cases for line in case["checks"]) == 5

    fixtures = load(BASE / "fixture-preservation.json")
    assert len(fixtures) == 96
    for name, expected in fixtures.items():
        assert file_hash(HERE / name) == expected, name
    base_validation = members(BASE / "validation-code.tar")
    assert len(base_validation) == 73
    validation_names = set(base_validation)
    imports = load(HERE / "evidence/functional-validation-imports.json")
    validation_names.update("project/" + name for name in imports["files"])
    validation_names.update(("freeze_functional.py", "verify_functional.py"))
    validation = {name: (HERE / name).read_bytes() for name in sorted(validation_names)}
    for name, data in validation.items():
        relative = name.removeprefix("project/")
        if name.startswith("project/") and relative in final["validation_map"]:
            assert digest(data) == final["validation_map"][relative], name
    assert validation["project/tests/unit/test_ingress_frozen_pair.sh"] == \
        base_validation["project/tests/unit/test_ingress_frozen_pair.sh"]
    for path in sorted((HERE / "evidence").glob("*.json")):
        curated["provenance/" + path.name] = path.read_bytes()
    for path in sorted((HERE / "project/build").rglob("*__verFiles.dat")):
        curated["compiler/" + str(path.relative_to(HERE))] = path.read_bytes()
    for path in sorted((HERE / "evidence/validation-revisions").glob("*.tar")):
        curated["validation-revisions/" + path.name] = path.read_bytes()
    for path in sorted((HERE / "evidence/prior-builds").rglob("*__verFiles.dat")):
        curated["compiler/" + str(path.relative_to(HERE))] = path.read_bytes()

    inputs = dict(old_inputs)
    for name in changed:
        inputs[name] = source[name]
    macro = '\nset_global_assignment -name VERILOG_MACRO "FPGA_VIDEO_BUILD_ID=32\'h{}"\n'
    assert old_inputs["Plex.qsf"] == before["Plex.qsf"] + macro.format(base_meta["fpga_video_build_id"]).encode()
    inputs["Plex.qsf"] = source["Plex.qsf"] + macro.format(args.source[:8]).encode()
    assert len(inputs) == 150
    input_map = mapping(inputs)
    input_delta = sorted(name for name in inputs if inputs[name] != old_inputs[name])
    assert input_delta == changed
    patch = "".join("".join(difflib.unified_diff(
        before[name].decode().splitlines(True), source[name].decode().splitlines(True),
        fromfile="a/" + name, tofile="b/" + name)) for name in changed)
    limits = [
        "Source correctness only: independent whole-cohort review/publication, safe matched fit and actual LAN Web/cast/HDMI/audio remain.",
        "V15 physical setup failed -0.452/-1.746/-12.462/-12.243ns; its RBF86fb3556 is unapproved. This cohort has no physical timing/area result.",
        "No FPS/Fmax/tier/clock/constraint/seed/profile/default8KiB or optional-overlay change; no Quartus/STA/ARM/device operation.",
        "R1 is rejected and preserved. R2's retained negative is an R1-behavior fault macro, not an execution of frozen R1.",
        "V14 full240 +68340 SYS and one-native-period startup cost, plus V15 +3 full240 IDR SYS, remain historical baseline costs.",
        "Per-picture new compute/startup/display-boundary/cadence differences are recorded separately as V15 deltas; none proves physical24fps.",
    ]
    result = {
        "owner": OWNER, "grant": GRANT, "source_sha256": args.source,
        "status": "COHERENT_FUNCTIONAL_SOURCE_VALIDATED_PENDING_INDEPENDENT_COHORT_REVIEW",
        "compiler_workers": 1, "transactions": transactions, "final_job": args.final_job,
        "cases": cases, "totals": totals, "actual_production_bindings": bindings,
        "focused_checks": [line for line in final_text.splitlines() if line.startswith((
            "PASS ", "OK ", "EXPECTED RED", "RETURN_STREAM", "ddr_frame_store warm-reset raw:"))],
        "picture_integration": integration, "picture_review": review,
        "original_budgets": {"composed_event_budget_seconds": 1},
        "fixture_timing": old_results["fixture_timing"], "remaining_limits": limits,
        "running_commands": [], "physical_or_playback_acceptance": False,
    }
    release.mkdir()
    bundle(release / "source.tar", source)
    bundle(release / "inputs.tar", inputs)
    bundle(release / "validation-code.tar", validation)
    bundle(release / "results.tar", curated)
    (release / "functional.patch").write_text(patch)
    json_files = {
        "source-map.json": source_map, "effective-input-map.json": input_map,
        "fixture-preservation.json": fixtures, "results.json": result,
        "validation-source-map.json": {
            "base_validation_archive_sha256": file_hash(BASE / "validation-code.tar"),
            "base_members": mapping(base_validation), "new_members": mapping(validation),
            "changed_existing_members": sorted(name for name in base_validation
                                               if base_validation[name] != validation[name]),
            "added_existing_bench_origins": imports,
            "historical_drivers_are_not_execution_authority": True,
        },
        "member-preservation.json": {
            "source_members": 149, "effective_input_members": 150,
            "source_delta": changed, "input_delta": input_delta,
            "protected_members_unchanged": protected,
            "all_other_members_byte_identical": True, "original_fixture_members_unchanged": 96,
            "QSF_semantics_and_all_SDC_bytes_unchanged": True,
        },
        "inputs.json": {
            **base_meta, "source_sha256": args.source, "source_files": source_map,
            "input_files": input_map, "input_sha256": identity(input_map),
            "source_archive_sha256": file_hash(release / "source.tar"),
            "archive_sha256": file_hash(release / "inputs.tar"),
            "fpga_video_build_id": args.source[:8], "driver_sha256": file_hash(Path(__file__)),
            "generation": "Complete immutable V15 derivation plus reviewed picture fix and connected functional claims.",
            "git_commit_role": "Inherited ancestry only; full archives/maps are authoritative.",
            "future_physical_tool_binding": "Unassigned; parent requires a fresh reviewed safe physical scope.",
        },
    }
    for name, value in json_files.items():
        (release / name).write_bytes(encode(value))
    manifest = {
        "owner": OWNER, "grant": GRANT, "lane": "coherent-fpga-integration",
        "authority_registry_sha256_at_freeze": file_hash(registry_path),
        "source_sha256": args.source, "input_sha256": identity(input_map),
        "base_source_sha256": BASE_SOURCE, "base_release_manifest_sha256": BASE_MANIFEST,
        "source_members": 149, "effective_input_members": 150,
        "source_delta": changed, "input_delta": input_delta,
        "clock_profile": "SYS120/DDR90/native20", "capability": 0xe1ff,
        "max_width": 320, "max_height": 240, "max_au_bytes": 8192,
        "tier_bits_9_12": 0, "seed": 6, "processors": 2,
        "legacy_build_date": "260906", "proposed_build_id": args.source[:8],
        "source_generator_sha256": file_hash(Path(__file__)),
        "validation_source_members": len(validation), "curated_evidence_members": len(curated),
        "actual_test_results": totals, "picture_review_sha256": args.picture_review_sha256,
        "artifacts_sha256": {path.name: file_hash(path) for path in sorted(release.iterdir())},
        "remaining_physical_witnesses": limits, "fit_grant": None, "physical_tool_owner": None,
        "Quartus_or_hardware_invoked": False, "running_commands": [],
        "publication": "LOCAL_FROZEN_CANDIDATE; parent assigns whole-cohort review/publication and physical/lab owners.",
        "media_policy": "Source, maps and simulation provenance only; no media/oracle bytes, raw physical/runtime/browser/config data.",
    }
    (release / "manifest.json").write_bytes(encode(manifest))
    for path in release.iterdir():
        path.chmod(0o444)
    release.chmod(0o555)
    for path in PROJECT.rglob("*"):
        if path.is_file():
            path.chmod(0o444)
    outcome = {
        "owner": OWNER, "grant": GRANT, "source_sha256": args.source,
        "input_sha256": identity(input_map), "release": args.release,
        "status": result["status"],
        "files_sha256": {path.name: file_hash(path) for path in sorted(release.iterdir())},
        "running_commands": [], "source_or_hardware_approval": False,
    }
    (HERE / "owner-result.json").write_bytes(encode(outcome))
    print(json.dumps(outcome, indent=2))


if __name__ == "__main__":
    main()
