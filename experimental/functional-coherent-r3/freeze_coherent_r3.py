#!/usr/bin/env python3
"""Freeze the complete central-plus-R3 source and its exact functional evidence."""
import argparse
import csv
import difflib
import json
from pathlib import Path
import re
import stat

from compose_r3 import BASE, CENTRAL, GRANT, HERE, OUT, OWNER, R3, R3_RTL, ROOT
from freeze_functional import bundle, digest, encode, file_hash, identity, load, mapping, members

SOURCE = "9217adef21e2bf54acd41d80faea9a0fbeb1e03bb69fa325841fcda92688608a"
PROJECT = OUT / "project/fpga/Plex_MiSTer"
BASE_SOURCE = "4f09a4176a6b954463e0d6b7484c3d421efdb686421bcf67f7bf254bf34604ef"
BASE_MANIFEST = "b32dd240e54cbafca70262bf4d149b2fb5d5ca877c6b86d4b05cda5b49417a51"


def verify_sums(path):
    for line in path.read_text().splitlines():
        expected, name = line.split(maxsplit=1)
        selected = Path(name.lstrip("*"))
        if not selected.is_absolute():
            selected = OUT / "project" / selected
        assert file_hash(selected) == expected, str(selected)


def picture_review(path, pin, integration):
    if path is None:
        assert pin is None
        return None, None
    path = ROOT / path
    assert path.is_relative_to(ROOT) and re.fullmatch("[0-9a-f]{64}", pin or "")
    assert file_hash(path) == pin
    review = load(path)
    assert review.get("verdict") in {
        "READY", "READY_FOR_INTEGRATION", "READY_FOR_SOURCE_INTEGRATION",
        "READY_FOR_SOURCE_PUBLICATION", "APPROVED", "PASS",
    }, "Never freeze rejected source as a validated coherent candidate"
    text = path.read_text()
    for expected in (R3_RTL, integration["r3_inputs_sha256"]["manifest.json"],
                     integration["leaf_patch_sha256"]):
        assert expected in text, "The review must bind the exact frozen R3"
    return review, path.read_bytes()


def collect_cases(curated):
    baseline = load(BASE / "results.json")
    cases, totals = [], dict.fromkeys(baseline["totals"], 0)
    for old_case in baseline["cases"]:
        relative = Path(old_case["case"])
        directory = OUT / "project/build/verilator" / relative
        text = (directory / "execution.log").read_text()
        assert text.splitlines()[-1].startswith("PASS ")
        for name in ("inputs.sha256", "binary.sha256", "actual.sha256"):
            verify_sums(directory / name)
        reference = OUT / "project/tests/fixtures" / directory.name / "reference.yuv"
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
            assert value == old_case[key], (str(relative), key)
            totals[key] += value
        csv_paths = list(directory.glob("*.csv"))
        assert len(csv_paths) == 1
        with csv_paths[0].open() as stream:
            rows = [{key: int(value) for key, value in row.items()} for row in csv.DictReader(stream)]
        assert len(rows) == len(old_case["metrics_SYS_cycles"])
        deltas = []
        for old_row, row in zip(old_case["metrics_SYS_cycles"], rows):
            assert set(old_row) == set(row)
            for key in ("frame", "SYS_Hz", "DDR_Hz", "base_Hz", "native_divisor",
                        "prediction_fetches", "fractional_fetches", "nonzero_P_blocks", "filter_writes"):
                assert row[key] == old_row[key], (str(relative), key)
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
        for name in (csv_paths[0].name, "inputs.sha256", "binary.sha256",
                     "actual.sha256", "clock-binding.json"):
            curated[f"composed/{relative}/{name}"] = (directory / name).read_bytes()
    assert len(cases) == 11 and totals == baseline["totals"] and totals["pictures"] == 38
    assert sum(len(case["metrics_SYS_cycles"]) for case in cases) == 35
    assert sum(line.startswith("INGRESS_SEEK_PASS") for case in cases for line in case["checks"]) == 5
    categories = {
        "compute": ("vcl_to_promotion", "controller_busy", "filter_busy", "filter_cycles"),
        "startup": ("promotion_cycle", "copy_accept_cycle", "display_cycle"),
        "display_boundary": ("copy_to_feedback", "publication_retired_cycle", "native_lease_wait"),
        "cadence": ("display_interval",),
    }
    delta_ranges = {
        category: {
            field: {
                "min": min(row[field] for case in cases for row in case["V15_deltas_SYS_cycles"]),
                "max": max(row[field] for case in cases for row in case["V15_deltas_SYS_cycles"]),
            }
            for field in fields
        }
        for category, fields in categories.items()
    }
    return cases, totals, delta_ranges


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--job", default="functional-coherent-r3-a01")
    parser.add_argument("--release", default="release-coherent-r3")
    parser.add_argument("--picture-review")
    parser.add_argument("--picture-review-sha256")
    args = parser.parse_args()
    release = HERE / args.release
    assert release.parent == HERE and not release.exists()
    registry_path = ROOT / "Memory/lab/fpga-h264-30ff2997/handoff/registry.json"
    registry = load(registry_path)
    scope = next(item for item in registry["fresh_outcome_scopes"] if item["id"] == GRANT)
    assert scope["owner"] == OWNER and scope["state"].startswith("active")
    assert "exact frozen direct R3" in scope["allowed"]
    review_directory = ROOT / "Memory/lab/fpga-h264-30ff2997/clean-resume-5754/fpga-picture-review-r3"
    for path in review_directory.glob("*.json"):
        record = load(path)
        if record.get("verdict") in {"NOT_READY", "REJECTED", "FAIL"}:
            assert R3_RTL not in path.read_text(), "Exact R3 was rejected; retain source without validated-candidate freeze"
    assert file_hash(BASE / "manifest.json") == BASE_MANIFEST
    for directory in (BASE, CENTRAL):
        for name, expected in load(directory / "manifest.json")["artifacts_sha256"].items():
            assert file_hash(directory / name) == expected, (str(directory), name)
    before, old_inputs = members(BASE / "source.tar"), members(BASE / "inputs.tar")
    central_source = members(CENTRAL / "source.tar")
    base_meta = load(BASE / "inputs.json")
    assert mapping(before) == base_meta["source_files"] and identity(mapping(before)) == BASE_SOURCE
    assert mapping(old_inputs) == base_meta["input_files"]
    source = {str(path.relative_to(PROJECT)): path.read_bytes()
              for path in sorted(PROJECT.rglob("*")) if path.is_file()}
    assert set(source) == set(before) and len(source) == 149
    source_map = mapping(source)
    assert identity(source_map) == SOURCE
    changed = sorted(name for name in source if source[name] != before[name])
    assert changed == ["Plex.qsf", "Plex.sv", "rtl/ddr_frame_store.sv"]
    assert sorted(name for name in source if source[name] != central_source[name]) == ["rtl/ddr_frame_store.sv"]
    assert digest(source["rtl/ddr_frame_store.sv"]) == R3_RTL
    semantic_qsf = lambda data: [
        line.split("#", 1)[0].strip() for line in data.decode().splitlines()
        if line.split("#", 1)[0].strip()
    ]
    assert semantic_qsf(source["Plex.qsf"]) == semantic_qsf(before["Plex.qsf"])
    integration = load(OUT / "evidence/composition-result.json")
    assert integration["source_sha256"] == SOURCE and integration["source_map"] == source_map
    for name, expected in integration["r3_inputs_sha256"].items():
        assert file_hash(R3 / name) == expected, name
    leaf = load(R3 / "manifest.json")
    for name, description in integration["expected_postimages_verified"].items():
        path = OUT / "project" / name
        assert file_hash(path) == description["sha256"], name
        assert stat.S_IMODE(path.stat().st_mode) == int(description["mode"], 8), name
    review, review_bytes = picture_review(args.picture_review, args.picture_review_sha256, integration)
    job_path = OUT / "evidence/jobs" / (args.job + ".json")
    final = load(job_path)
    assert final["owner"] == OWNER and final["grant"] == GRANT
    assert final["state"] == "passed" and final["exit_code"] == 0
    assert final["source_map"] == source_map and final["source_sha256"] == SOURCE
    assert final["owned_child_group_settled"] and final["ended_at"]
    assert all(item["value"] == 1 for item in final["guards_after"].values())
    assert file_hash(Path(final["output"])) == final["output_sha256"]
    final_text = Path(final["output"]).read_text()
    for marker in (
        "host video admission=1", "RETURN_STREAM returns=4096 latency=3",
        "equal_token_refresh_after_accept", "sample_r=217",
        "supersession_before_pending_vsync", "supersession_on_pending_vsync",
        "supersession_after_pending_vsync",
        "replacement collision source_lead_ddr_edges=17 queued_bank=1",
        "accepted replacement retained frames=3 newest_bank=1 sample_r=173",
        "ddr_period=7 ddr_phase=2", "ddr_period=13 ddr_phase=4",
    ):
        assert marker in final_text, marker
    assert final_text.count("preserved=173 refreshed=217") == 4
    bindings_path = OUT / "project/build/verilator/fpga_audio_routing/bindings.json"
    bindings = load(bindings_path)
    assert bindings["source_map"] == source_map and bindings["source_sha256"] == SOURCE
    assert bindings["modes"]["fpga320"] == {
        "features": 0xe1ff, "build_id": int(SOURCE[:8], 16),
        "max_width": 320, "max_height": 240, "max_au_bytes": 8192,
        "idr_only": 0, "deblock": 1,
    }
    assert {name: fields["features"] for name, fields in bindings["modes"].items()} == {
        "baseline": 0, "fpga320": 0xe1ff, "fpga320-idr": 0xe19f,
        "fpga320-inter-no-filter": 0xe1bf, "fpga320-idr-filter": 0xe1df,
    }
    curated = {
        "actual-emu/bindings.json": bindings_path.read_bytes(),
        "composition/intent.json": (OUT / "intent.json").read_bytes(),
        "composition/result.json": (OUT / "evidence/composition-result.json").read_bytes(),
        "central/manifest.json": (CENTRAL / "manifest.json").read_bytes(),
        "central/results.json": (CENTRAL / "results.json").read_bytes(),
        "central/verification.json": (HERE / "evidence/central-final-verification.json").read_bytes(),
    }
    if review_bytes is not None:
        curated["picture-r3/review.json"] = review_bytes
    for name in integration["r3_inputs_sha256"]:
        curated["picture-r3/" + name] = (R3 / name).read_bytes()
    author_names = {
        "child_result": "child-result.json", "command_log": "command.log",
        "guard_release": "guard-released.json",
    }
    for label, evidence in leaf["validation"].items():
        for field, filename in author_names.items():
            path = R3.parent / "validation" / label / filename
            assert file_hash(path) == evidence[field]["sha256"]
            curated[f"picture-r3/author-validation/{label}/{filename}"] = path.read_bytes()
    for label in ("warm-r3-001", "warm-r3-003"):
        for filename in ("intent.json", "child-result.json", "command.log", "guard-released.json"):
            path = R3.parent / "validation" / label / filename
            curated[f"picture-r3/author-failures/{label}/{filename}"] = path.read_bytes()
    transactions = {}
    for path in sorted((OUT / "evidence/jobs").glob("*.json")):
        job = load(path)
        assert job["owned_child_group_settled"] and job["state"] != "running"
        transactions[path.stem] = {"receipt_sha256": file_hash(path), "receipt": job}
        curated["transactions/" + path.name] = path.read_bytes()
        output = Path(job["output"])
        if output.exists():
            assert file_hash(output) == job["output_sha256"]
            curated["transactions/" + output.name] = output.read_bytes()
    cases, totals, delta_ranges = collect_cases(curated)
    fixtures = load(BASE / "fixture-preservation.json")
    assert fixtures == load(CENTRAL / "fixture-preservation.json") and len(fixtures) == 96
    for name, expected in fixtures.items():
        assert file_hash(OUT / name) == expected, name
    central_validation = members(CENTRAL / "validation-code.tar")
    validation = {
        "coherent-r3/" + name.removeprefix("central-only/"):
            (OUT / name.removeprefix("central-only/")).read_bytes()
        for name in central_validation if name.startswith("central-only/")
    }
    for name in ("compose_r3.py", "freeze_coherent_r3.py", "verify_coherent_r3.py", "freeze_functional.py"):
        validation[name] = (HERE / name).read_bytes()
    validation_modes = {name: oct(stat.S_IMODE((HERE / name).stat().st_mode)) for name in validation}
    for name, data in validation.items():
        prefix = "coherent-r3/project/"
        if name.startswith(prefix) and name[len(prefix):] in final["validation_map"]:
            assert digest(data) == final["validation_map"][name[len(prefix):]], name
    for name in ("test_ingress_frozen_pair.sh", "test_fpga_video_publish.sh"):
        key = "project/tests/unit/" + name
        assert validation["coherent-r3/" + key] == members(BASE / "validation-code.tar")[key]
    assert validation_modes["coherent-r3/project/scripts/run_verilator.sh"] == "0o544"
    for path in sorted((OUT / "evidence").iterdir()):
        if path.is_file():
            curated["provenance/" + path.name] = path.read_bytes()
    for path in sorted((OUT / "project/build").rglob("*__verFiles.dat")):
        curated["compiler/" + str(path.relative_to(OUT))] = path.read_bytes()
    for generation in ("picture-r1", "picture-r2"):
        curated["rejected/" + generation + "-receipt.json"] = \
            (HERE / "rejected" / generation / "receipt.json").read_bytes()
    inputs = dict(old_inputs)
    for name in changed:
        inputs[name] = source[name]
    macro = '\nset_global_assignment -name VERILOG_MACRO "FPGA_VIDEO_BUILD_ID=32\'h{}"\n'
    assert old_inputs["Plex.qsf"] == before["Plex.qsf"] + macro.format(base_meta["fpga_video_build_id"]).encode()
    inputs["Plex.qsf"] = source["Plex.qsf"] + macro.format(SOURCE[:8]).encode()
    input_map = mapping(inputs)
    assert len(inputs) == 150
    assert sorted(name for name in inputs if inputs[name] != old_inputs[name]) == changed
    assert inputs["sys/build_id.tcl"] == old_inputs["sys/build_id.tcl"]
    patch = "".join("".join(difflib.unified_diff(
        before[name].decode().splitlines(True), source[name].decode().splitlines(True),
        fromfile="a/" + name, tofile="b/" + name)) for name in changed)
    assert digest(patch.encode()) == integration["composed_product_patch_sha256"]
    limits = [
        "Coherent source/simulation delivery only. Independent exact central/whole-cohort review/publication, safe matched fit and actual LAN Web/cast/HDMI/audio remain.",
        "R1 and R2 remain independently rejected and preserved. This cohort contains exact corrected R3, not either rejected postimage.",
        "R3 author's complete negatives and actual immutable-R2 failures are retained separately; this composed run repeats all warm-reset positives and new independent-clock/collision orders, not those unchanged negative builds.",
        "The actual source-bound five emu configurations, real-reader/ALSA host admission and original35+3 composed pictures ran here. Other central audio/transport modes remain exact predecessor evidence, not rerun claims.",
        "This cohort has no physical timing/area/cadence result. V15 RBF86fb3556 failed timing and remains unapproved; no existing image can stand in for this source.",
        "No FPS/Fmax/tier/clock/SDC/seed/default8KiB/codec/precision/painter/overlay change and no Quartus/STA/ARM/device/deployment.",
        "V14 +68340 SYS/full240 and one-native-period startup, plus V15 +3 full240 IDR SYS, remain historical. New compute/startup/display-boundary/cadence SYS-cycle deltas are reported separately and do not prove physical24fps.",
    ]
    if review is None:
        limits.insert(0, "Independent frozen picture R3 review remains pending; this package is not source approval.")
    results = {
        "owner": OWNER, "grant": GRANT, "source_sha256": SOURCE,
        "status": "COHERENT_R3_FUNCTIONAL_SOURCE_VALIDATED_PENDING_INDEPENDENT_COHORT_REVIEW",
        "compiler_workers": 1, "transactions": transactions, "final_job": args.job,
        "cases": cases, "totals": totals, "V15_cycle_delta_ranges": delta_ranges,
        "actual_production_bindings": bindings, "picture_integration": integration,
        "picture_review": review, "picture_review_sha256": args.picture_review_sha256,
        "focused_checks": [line for line in final_text.splitlines() if line.startswith((
            "PASS ", "OK ", "EXPECTED RED", "RETURN_STREAM", "ddr_frame_store warm-reset raw:",
            "ddr_frame_store protocol:"))],
        "original_budgets": {"composed_event_budget_seconds": 1},
        "fixture_timing": load(BASE / "results.json")["fixture_timing"],
        "remaining_limits": limits, "running_commands": [],
        "source_or_hardware_approval": False,
    }
    release.mkdir()
    bundle(release / "source.tar", source)
    bundle(release / "inputs.tar", inputs)
    bundle(release / "validation-code.tar", validation)
    bundle(release / "results.tar", curated)
    (release / "functional.patch").write_text(patch)
    (release / "central.patch").write_bytes((CENTRAL / "central.patch").read_bytes())
    (release / "picture-r3-from-v15.patch").write_bytes((R3 / "picture-r3-from-v15.patch").read_bytes())
    documents = {
        "source-map.json": source_map, "effective-input-map.json": input_map,
        "fixture-preservation.json": fixtures, "results.json": results,
        "validation-execution-modes.json": validation_modes,
        "validation-source-map.json": {
            "base_validation_archive_sha256": file_hash(BASE / "validation-code.tar"),
            "central_validation_archive_sha256": file_hash(CENTRAL / "validation-code.tar"),
            "base_members": mapping(members(BASE / "validation-code.tar")),
            "new_members": mapping(validation), "actual_validation_root": "coherent-r3",
            "R3_changes": leaf["changed_source_members"],
            "added_existing_bench_origins": load(HERE / "evidence/functional-validation-imports.json"),
            "execution_modes_restored_explicitly": True,
            "historical_helpers_are_not_execution_authority": True,
        },
        "member-preservation.json": {
            "source_members": 149, "effective_members": 150,
            "source_delta": changed, "input_delta": changed,
            "unchanged_source_members": 146, "unchanged_effective_members": 147,
            "protected_members_unchanged": sorted(set(source) - set(changed)),
            "fixtures_unchanged": 96, "QSF_semantics_and_all_SDC_bytes_unchanged": True,
            "frame_store_exact_R3": R3_RTL,
            "presenter_and_publisher_exact_V15": True,
        },
        "inputs.json": {
            **base_meta, "source_sha256": SOURCE, "source_files": source_map,
            "input_files": input_map, "input_sha256": identity(input_map),
            "source_archive_sha256": file_hash(release / "source.tar"),
            "archive_sha256": file_hash(release / "inputs.tar"),
            "fpga_video_build_id": SOURCE[:8], "driver_sha256": file_hash(Path(__file__)),
            "generation": "Complete immutable V15 plus frozen central capability wiring and exact frozen picture R3.",
            "git_commit_role": "Inherited ancestry only; complete source/effective archives are authoritative.",
            "future_physical_tool_binding": "None. Parent assigns review and a safe matched physical scope.",
        },
    }
    for name, value in documents.items():
        (release / name).write_bytes(encode(value))
    manifest = {
        "owner": OWNER, "grant": GRANT, "lane": "coherent-fpga-integration",
        "scope": "COHERENT_CENTRAL_PLUS_EXACT_PICTURE_R3",
        "authority_registry_sha256_at_freeze": file_hash(registry_path),
        "source_sha256": SOURCE, "input_sha256": identity(input_map),
        "base_source_sha256": BASE_SOURCE, "base_release_manifest_sha256": BASE_MANIFEST,
        "central_release_manifest_sha256": file_hash(CENTRAL / "manifest.json"),
        "picture_release_manifest_sha256": file_hash(R3 / "manifest.json"),
        "picture_review_sha256": args.picture_review_sha256,
        "source_members": 149, "effective_input_members": 150,
        "source_delta": changed, "input_delta": changed,
        "clock_profile": "SYS120/DDR90/native20", "capability": 0xe1ff,
        "max_width": 320, "max_height": 240, "max_au_bytes": 8192,
        "tier_bits_9_12": 0, "seed": 6, "processors": 2, "legacy_build_date": "260906",
        "proposed_build_id": SOURCE[:8], "source_generator_sha256": file_hash(Path(__file__)),
        "validation_source_members": len(validation), "curated_evidence_members": len(curated),
        "artifacts_sha256": {path.name: file_hash(path) for path in sorted(release.iterdir())},
        "actual_test_results": totals, "remaining_limits": limits,
        "fit_grant": None, "physical_tool_owner": None, "Quartus_or_hardware_invoked": False,
        "running_commands": [], "source_or_hardware_approval": False,
        "publication": "LOCAL_FROZEN_CANDIDATE; parent assigns independent whole-cohort review/publication and physical/lab owners.",
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
        "owner": OWNER, "grant": GRANT, "scope": manifest["scope"],
        "status": results["status"], "source_sha256": SOURCE,
        "input_sha256": identity(input_map), "release": args.release,
        "files_sha256": {path.name: file_hash(path) for path in sorted(release.iterdir())},
        "V15_cycle_delta_ranges": delta_ranges,
        "running_commands": [], "source_or_hardware_approval": False,
        "next": "Parent reviews/publishes the exact coherent cohort, then arranges safe matched physical and real LAN Web/cast/HDMI/audio validation.",
    }
    (HERE / "coherent-r3-owner-result.json").write_bytes(encode(outcome))
    print(json.dumps(outcome, indent=2))


if __name__ == "__main__":
    main()
