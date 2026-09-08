#!/usr/bin/env python3
"""Freeze the complete V15 source and measured evidence; no physical tools."""
import csv
import difflib
import hashlib
import io
import json
import re
import tarfile
from pathlib import Path, PurePosixPath

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]
BASE = HERE.parent / "critical-cones-v14-5754"
OLD = BASE / "release-v14"
PROJECT = HERE / "project/fpga/Plex_MiSTer"
RELEASE = HERE / "release-v15"
OWNER = "ce6e3c70-35d0-47b7-a3b9-c1704c76e2be"
GRANT = "v15-measured-hadamard-return-mv-cones-5754"
SOURCE = "4f09a4176a6b954463e0d6b7484c3d421efdb686421bcf67f7bf254bf34604ef"
CHANGED = ["rtl/ddr_frame_store.sv", "rtl/h264_i16_dc_hadamard.sv",
           "rtl/h264_inter_pred.sv", "rtl/h264_mb_ctrl.sv", "rtl/present_core.sv"]
JOBS = {
    "v15-targeted-r1": 1, "v15-publication-r2": 0, "v15-controller-r1": 0,
    "v15-legacy-and-composed-r1": 1, "v15-warm-v14-baseline": 1, "v15-composed-r1": 0,
}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def file_sha(path):
    return sha(path.read_bytes())


def encoded(value):
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()


def record(path, value):
    path.write_bytes(encoded(value))


def load(path):
    return json.loads(path.read_text())


def members(path):
    files = {}
    with tarfile.open(path) as archive:
        for member in archive:
            name = PurePosixPath(member.name)
            assert member.isfile() and not name.is_absolute() and ".." not in name.parts
            assert member.name not in files
            files[member.name] = archive.extractfile(member).read()
    return files


def hashes(files):
    return {name: sha(data) for name, data in files.items()}


def identity(mapping):
    return sha(json.dumps(mapping, sort_keys=True).encode())


def bundle(path, files):
    with tarfile.open(path, "w") as archive:
        for name, data in files.items():
            member = tarfile.TarInfo(name)
            member.size, member.mode = len(data), 0o444
            archive.addfile(member, io.BytesIO(data))
    assert members(path) == files


def check_sums(path):
    for line in path.read_text().splitlines():
        expected, name = line.split(maxsplit=1)
        actual = Path(name.lstrip("*"))
        if not actual.is_absolute():
            actual = HERE / "project" / actual
        assert file_sha(actual) == expected, str(actual)


def module_text(data):
    return {match.group(1): match.group(0) for match in
            re.finditer(r"(?ms)^module\s+(\w+)\b.*?^endmodule", data.decode())}


assert not RELEASE.exists(), "Never overwrite a frozen or partial release"
registry_path = ROOT / "Memory/lab/fpga-h264-30ff2997/handoff/registry.json"
registry = load(registry_path)
scope = next(item for item in registry["fresh_outcome_scopes"] if item["id"] == GRANT)
assert scope["owner"] == OWNER and scope["state"].startswith("active")
authority_sha256 = file_sha(registry_path)
assert file_sha(OLD / "manifest.json") == "be4dc86497aab4db2ae9c337d78ce19976b120de1220d07cd07a7b21650677a9"
old_manifest, old_meta = load(OLD / "manifest.json"), load(OLD / "inputs.json")
for name, expected in old_manifest["artifacts_sha256"].items():
    assert file_sha(OLD / name) == expected, name
old_source, old_inputs = members(OLD / "source.tar"), members(OLD / "inputs.tar")
assert len(old_source) == 149 and len(old_inputs) == 150
assert hashes(old_source) == old_meta["source_files"]
assert hashes(old_inputs) == old_meta["input_files"]
assert identity(hashes(old_source)) == old_meta["source_sha256"]
assert identity(hashes(old_inputs)) == old_meta["input_sha256"]
source = {name: (PROJECT / name).read_bytes() for name in old_source}
assert {str(p.relative_to(PROJECT)) for p in PROJECT.rglob("*") if p.is_file()} == set(source)
assert sorted(name for name in source if source[name] != old_source[name]) == CHANGED
source_map = hashes(source)
assert identity(source_map) == SOURCE
for name in CHANGED:
    before, after = module_text(old_source[name]), module_text(source[name])
    assert set(before) == set(after), name
    for module in before:
        assert before[module].split(");", 1)[0] == after[module].split(");", 1)[0], module
        if name == "rtl/h264_inter_pred.sv" and module != "h264_mv_pred_16x16":
            assert before[module] == after[module], module
    assert name.encode() in source["files.qip"], name
protected = ["rtl/h264_cavlc_residual.sv", "rtl/h264_recon.sv", "rtl/h264_iq_idct_4x4.sv",
             "rtl/h264_dpb.sv", "rtl/h264_deblock.sv", "rtl/h264_deblock_frame.sv",
             "rtl/h264_intra_pred.sv", "rtl/stream_path.sv", "rtl/decode_stub.sv",
             "rtl/line_buf_ram.sv", "rtl/plex_performance_clock.svh", "Plex.qsf", "files.qip"]
assert all(source[name] == old_source[name] for name in protected)
sdcs = {name: source_map[name] for name in source if name.endswith(".sdc")}
clauses = sum(len(re.findall(rb"(?m)^set_(?:false_path|multicycle_path|clock_groups|max_delay|min_delay)\b",
                            source[name])) for name in sdcs)
assert len(sdcs) == 3 and clauses == 52
assert old_meta["legacy_build_date"] == "260906"

old_validation = members(OLD / "validation-code.tar")
assert len(old_validation) == 61
assert hashes(old_validation) == load(OLD / "validation-source-map.json")["new_members"]
validation_delta = sorted(name for name in old_validation
                          if (HERE / name).read_bytes() != old_validation[name])
assert validation_delta == [
    "guarded_campaign.py", "project/tests/rtl/fpga_video_publish_tb.cpp",
    "project/tests/rtl/h264_inter_reference_tb.cpp", "project/tests/rtl/p2_intra_controller_tb.cpp",
    "project/tests/rtl/p2_intra_controller_tb.sv",
]
assert "n<12000000" in (HERE / "project/tests/rtl/p2_intra_controller_tb.cpp").read_text()
assert "cycles<100" in (HERE / "project/tests/rtl/h264_iq_idct_4x4_tb.cpp").read_text()
assert (HERE / "project/tests/unit/test_ingress_frozen_pair.sh").read_bytes() == \
    old_validation["project/tests/unit/test_ingress_frozen_pair.sh"]
fixtures = load(OLD / "fixture-preservation.json")
assert len(fixtures) == 95
for name, expected in fixtures.items():
    assert file_sha(HERE / name) == file_sha(BASE / name) == expected, name
added = load(HERE / "evidence/added-validation-inputs.json")
assert len(added["members"]) == 10
original_added, new_fixture = {}, {}
for entry in added["members"]:
    origin = ROOT / entry["origin"]
    assert file_sha(origin) == entry["sha256"], entry["origin"]
    target = "project/" + entry["member"]
    if "/fixtures/" in target:
        assert file_sha(HERE / target) == entry["sha256"]
        new_fixture[target] = entry["sha256"]
    else:
        original_added[target] = origin.read_bytes()

curated, transactions = {}, {}
for label, expected_exit in JOBS.items():
    path = HERE / "evidence/jobs" / f"{label}.json"
    job = load(path)
    assert job["owner"] == OWNER and job["grant"] == GRANT
    assert job["source_map"] == source_map and job["source_sha256"] == SOURCE
    assert job["owned_child_group_settled"] and job["ended_at"] and job["exit_code"] == expected_exit
    assert all(value["value"] == 1 for value in job["guards_after"].values())
    assert {item["name"] for item in job["released"]} == {"controller", "execution"}
    assert file_sha(Path(job["output"])) == job["output_sha256"]
    if label == "v15-warm-v14-baseline":
        assert job["secondary_cohorts"]["v14-warm"]["source_map"] == old_meta["source_files"]
    transactions[label] = {"receipt_sha256": file_sha(path), "receipt": job}
    curated[f"transactions/{label}.json"] = path.read_bytes()
    curated[f"transactions/{label}.log"] = Path(job["output"]).read_bytes()
focused = (HERE / "evidence/jobs/v15-targeted-r1.log").read_text()
for marker in ["blocks=16 compared_values=768", "cases=312 qp=0..51 max_cycles=40",
               "cases=2388 qp=0..63 max_cycles=19 reset_replays=20", "MV cases=175616",
               "reads=46213 responses=46213", "BRAM_fetch_cycles=607", "max_mc_cycles=1058",
               "max_axis_mc_cycles=595", "max_odd_quarter_mc_cycles=953",
               "max_integer_luma_mc_cycles=258", "48 packed/fractional",
               "ddr_bitstream_ring.hpp: No such file or directory"]:
    assert marker in focused, marker
publication = (HERE / "evidence/jobs/v15-publication-r2.log").read_text()
assert "RETURN_STREAM returns=4096 latency=3" in publication
assert publication.splitlines()[-1].startswith("PASS native I420")
warm = load(HERE / "evidence/warm-baseline-comparison.json")
assert warm["candidate_source"] == SOURCE
assert warm["baseline_source"] == old_meta["source_sha256"]
assert warm["identical_diagnostics"] == 16 and warm["preceding_successful_scenarios"] == 15
warm_rows = [item["lines"] for item in warm["records"].values()]
assert warm_rows[0] == warm_rows[1] and warm_rows[0][-1].startswith("FAIL ")

old_results, latency = load(OLD / "results.json"), load(HERE / "evidence/latency-comparison.json")
old_curated = members(OLD / "results.tar")
cases = []
totals = dict(pictures=0, coded_samples=0, visible_samples=0, native_RGB_samples=0,
              counted_legacy_RGB565_pixels=0)
unchanged_metrics = [
    "display_cycle", "publication_retired_cycle", "checker_retired_cycle", "display_interval",
    "prediction_fetches", "fractional_fetches", "nonzero_P_blocks", "filter_writes",
    "SYS_Hz", "DDR_Hz", "base_Hz", "native_divisor", "filter_cycles", "filter_busy",
]
for old_case, comparison in zip(old_results["cases"], latency["cases"]):
    relative = Path(old_case["case"])
    assert str(relative) == comparison["case"]
    directory = HERE / "project/build/verilator" / relative
    text = (directory / "execution.log").read_text()
    assert text.splitlines()[-1].startswith("PASS ")
    for name in ("inputs.sha256", "binary.sha256", "actual.sha256"):
        check_sums(directory / name)
    reference = HERE / "project/tests/fixtures" / directory.name / "reference.yuv"
    assert (directory / "actual.i420").read_bytes() == reference.read_bytes()
    frames = re.findall(r"(?m)^FRAME_PASS .*native_bytes=(\d+).*coded_bytes=(\d+)", text)
    recovery = re.findall(r"(?m)^FAULT_RECOVERY_PASS .*coded_bytes=(\d+) visible_bytes=(\d+)", text)
    count = {
        "pictures": len(frames) + len(recovery),
        "coded_samples": sum(int(c) for _, c in frames) + sum(int(c) for c, _ in recovery),
        "visible_samples": sum(int(v) for v, _ in frames) + sum(int(v) for _, v in recovery),
        "native_RGB_samples": sum(map(int, re.findall(r"(?m)^NATIVE_PASS .*RGB_samples=(\d+)", text))),
        "counted_legacy_RGB565_pixels": sum(map(int, re.findall(r"(?m)^LEGACY_RGB_PASS .*pixels=(\d+)", text))),
    }
    for key, value in count.items():
        assert value == old_case[key]
        totals[key] += value
    csv_files = list(directory.glob("*.csv"))
    assert len(csv_files) == 1
    with csv_files[0].open() as stream:
        rows = [{k: int(v) for k, v in row.items()} for row in csv.DictReader(stream)]
    assert rows == comparison["metrics_SYS_cycles"]
    assert len(rows) == len(old_case["metrics_SYS_cycles"])
    deltas = []
    for before, after in zip(old_case["metrics_SYS_cycles"], rows):
        assert all(before[key] == after[key] for key in unchanged_metrics)
        deltas.append({key: after[key] - before[key] for key in after})
    assert deltas == comparison["V14_deltas_SYS_cycles"]
    checks = [line for line in text.splitlines() if re.match(
        r"^(?:FRAME_PASS|NATIVE_PASS|LEGACY_RGB_PASS|BANK_REUSE_PASS|FILTER_ACTIVE_FAULT|"
        r"FILTER_METADATA_FAULT|FAULT_RECOVERY_PASS|CODEC_ERROR_PASS|INGRESS_SEEK_PASS|METRIC|PASS )", line)]
    cases.append({"case": str(relative), "pass": True, **count,
                  "execution_sha256": file_sha(directory / "execution.log"),
                  "actual_sha256": file_sha(directory / "actual.i420"),
                  "reference_sha256": file_sha(reference),
                  "metrics_SYS_cycles": rows, "V14_deltas_SYS_cycles": deltas, "checks": checks})
    curated[f"composed/{relative}/checks.log"] = ("\n".join(checks) + "\n").encode()
    for name in [csv_files[0].name, "inputs.sha256", "binary.sha256", "actual.sha256", "clock-binding.json"]:
        curated[f"composed/{relative}/{name}"] = (directory / name).read_bytes()
        if name == "clock-binding.json":
            assert (directory / name).read_bytes() == old_curated[f"composed/{relative}/{name}"]
assert len(cases) == 11 and totals == old_results["totals"] and totals["pictures"] == 38
assert sum(len(case["metrics_SYS_cycles"]) for case in cases) == 35
assert sum(line.startswith("INGRESS_SEEK_PASS") for case in cases for line in case["checks"]) == 5
compute_deltas = {delta["vcl_to_promotion"] for case in cases for delta in case["V14_deltas_SYS_cycles"]}
assert compute_deltas == {0, 3, 108, 117, 471, 486}

controller = []
directory = HERE / "results/controller-v1"
check_sums(directory / "inputs.sha256")
labels = ["baseline-lease0", "baseline-lease1"] + [
    f"hdc-{mode}-{stage}" for mode in ("reset", "vcl") for stage in (0, 1, 2, 3, 17, 18, 19)]
for label in labels:
    log = directory / (f"{label}.execution.log" if label.startswith("baseline") else f"{label}.log")
    actual = directory / f"{label}.actual.yuv"
    gold = directory / "baseline-lease1.ffmpeg.yuv"
    text = log.read_text()
    assert actual.stat().st_size == 115200 and actual.read_bytes() == gold.read_bytes()
    assert "YUV mismatches=0,0,0" in text and "capacity=8192 payload=6841" in text
    assert "HADAMARD_TRANSACTIONS" in text and "core_cycles=19" in text
    lease = 0 if label == "baseline-lease0" else 1
    build = HERE / "project/build" / ("p2-intra-controller-13" + ("-native-lease" if lease else ""))
    if label.startswith("hdc-"):
        assert "HADAMARD_CANCEL" in text and "canceled=1 core_cycles=19" in text
    controller.append({"case": label, "native_lease": lease, "pass": True,
                       "coded_samples": 115200, "RGB565_pixels": 76800,
                       "original_picture_cycle_budget": 12000000,
                       "header_delivery": "end" if label.startswith("hdc-") else "ordinary",
                       "execution_sha256": file_sha(log), "actual_sha256": file_sha(actual),
                       "reference_sha256": file_sha(gold),
                       "binary_sha256": file_sha(build / "obj/Vp2_intra_controller_tb"),
                       "checks": text.splitlines()})
    curated[f"controller/{label}.log"] = log.read_bytes()
assert len(controller) == 16
for path in directory.glob("*.sha256"):
    check_sums(path)
    curated[f"controller/{path.name}"] = path.read_bytes()
curated["controller/modes.txt"] = (directory / "modes.txt").read_bytes()

physical_path = ROOT / ".worktrees/fpga-h264-fleet-30ff2997/build/coherent-v14-physical-5754/results/final-outcome-summary.json"
physical, native = load(physical_path), load(HERE / "evidence/native-witnesses.json")
assert file_sha(physical_path) == native["physical_summary_sha256"]
pins = physical["identities"]
for key, name in [("source_tar_sha256", "source.tar"), ("inputs_tar_sha256", "inputs.tar"),
                  ("inputs_json_sha256", "inputs.json"), ("release_manifest_sha256", "manifest.json")]:
    assert pins[key] == file_sha(OLD / name), key
assert pins["source_sha256"] == old_meta["source_sha256"]
assert pins["derived_build_id"] == old_meta["fpga_video_build_id"]
assert physical["fit_outcome"]["rbf_sha256"] == \
    "fcb3c75ff0a1f9bf5437f955c5950113cd0b3b68dc490881505d473847423920"
for entry in native["paths"]:
    assert file_sha(ROOT / entry["file"]) == entry["sha256"]
    assert file_sha(HERE / entry["first_path"]) == entry["first_path_sha256"]
    entry["data_path_sha256"] = file_sha(HERE / entry["data_path"])
design = load(HERE / "evidence/implemented-design.json")
assert design["source"] == SOURCE
limits = [
    "Completed V14 fit/native STA still fails setup -15.073/-15.858/-4.015/-2.029ns; RBFfcb3c75f remains unapproved.",
    "V15 is source-only: no Quartus/STA/netlist/fit/area/Fmax/hardware/ARM/capture/deployment result.",
    "DDR/HDMI and other native physical paths, including legitimate zero-logic/top-level/self-feedback paths, are not waived; separately granted physical flow must measure the new cohort.",
    "No R4 observer, hierarchy floor, clock, SDC, seed, capability or memory-function change was made.",
    "Identical inherited legacy equal-token-refresh failure remains on V14 and V15; its later red variants did not run.",
    "V14 full240 +68340 SYS/+one-native-period startup cost remains; V15 adds +3 full240 IDR compute SYS but no measured additional display-period shift.",
]
witnesses = {"base_physical_summary": str(physical_path.relative_to(ROOT)),
             "base_physical_summary_sha256": file_sha(physical_path), "base_physical_pins": pins,
             "native_setup_paths": native["paths"], "implemented_design": design,
             "new_registered_helpers": {}, "registration": "All changes remain in five existing registered members.",
             "remaining_physical_limits": limits}

provenance = ["base-verification.json", "derive-base-failure.json", "source-edit-intent.json",
              "added-validation-inputs.json", "targeted-r1-recovery.json", "warm-baseline-intent.json",
              "warm-baseline-inputs.json", "warm-baseline-comparison.json",
              "latency-comparison.json", "implemented-design.json", "freeze-intent.json"]
for name in provenance:
    curated[f"provenance/{name}"] = (HERE / "evidence" / name).read_bytes()
curated["provenance/intent.json"] = (HERE / "intent.json").read_bytes()
curated["provenance/guarded-campaign-r1.py"] = \
    (HERE / "evidence/validation-revisions/guarded-campaign-r1.py").read_bytes()
compiler_provenance = {}
for root in (HERE / "project/build", HERE / "baselines/v14-warm/project/build"):
    for path in sorted(root.rglob("*__verFiles.dat")):
        name = str(path.relative_to(HERE))
        compiler_provenance[name] = file_sha(path)
        curated[f"compiler/{name}"] = path.read_bytes()
assert len(compiler_provenance) >= 10

inputs = dict(old_inputs)
for name in CHANGED:
    inputs[name] = source[name]
macro = '\nset_global_assignment -name VERILOG_MACRO "FPGA_VIDEO_BUILD_ID=32\'h{}"\n'
assert old_inputs["Plex.qsf"] == old_source["Plex.qsf"] + macro.format(old_meta["fpga_video_build_id"]).encode()
inputs["Plex.qsf"] = source["Plex.qsf"] + macro.format(SOURCE[:8]).encode()
input_map = hashes(inputs)
input_delta = sorted(name for name in inputs if inputs[name] != old_inputs[name])
assert input_delta == ["Plex.qsf"] + CHANGED
validation = {name: (HERE / name).read_bytes() for name in old_validation}
for name in original_added:
    validation[name] = (HERE / name).read_bytes()
for name in ("run_v15_controller.sh", "freeze_release_v15.py", "verify_release_v15.py"):
    validation[name] = (HERE / name).read_bytes()
assert len(validation) == 73
generator = file_sha(Path(__file__))
RELEASE.mkdir()
bundle(RELEASE / "source.tar", source)
bundle(RELEASE / "inputs.tar", inputs)
record(RELEASE / "inputs.json", {
    **old_meta, "source_sha256": SOURCE, "source_archive_sha256": file_sha(RELEASE / "source.tar"),
    "source_files": source_map, "input_files": input_map, "input_sha256": identity(input_map),
    "fpga_video_build_id": SOURCE[:8], "archive_sha256": file_sha(RELEASE / "inputs.tar"),
    "driver_sha256": generator, "historical_base_driver_sha256": old_meta["driver_sha256"],
    "generation": "Source-only deterministic complete V14 member-map derivation; no Git or physical executable.",
    "git_commit_role": "Inherited ancestry only, not publication or the authoritative frozen V15 source.",
    "future_physical_tool_binding": "Unassigned; independent review/publication and a fresh parent grant are required.",
})
record(RELEASE / "source-map.json", source_map)
record(RELEASE / "effective-input-map.json", input_map)
patch = "".join("".join(difflib.unified_diff(old_source[name].decode().splitlines(True),
                                           source[name].decode().splitlines(True),
                                           fromfile="a/" + name, tofile="b/" + name)) for name in CHANGED)
(RELEASE / "critical-cones.patch").write_text(patch)
record(RELEASE / "member-preservation.json", {
    "base_source_sha256": old_meta["source_sha256"], "source_sha256": SOURCE,
    "source_members": 149, "effective_input_members": 150,
    "source_delta": CHANGED, "input_delta": input_delta,
    "unchanged_source_members": 144, "unchanged_effective_members": 144,
    "all_other_members_byte_identical": True, "protected_members_unchanged": protected,
    "source_SDC_sha256": sdcs, "source_exclusion_clauses": clauses,
    "module_ports_and_registration_unchanged": True,
    "existing_validation_source_delta": validation_delta,
    "original_fixture_oracle_budgets_and_work_counts_preserved": True,
})
record(RELEASE / "fixture-preservation.json", {**fixtures, **new_fixture})
record(RELEASE / "witnesses.json", witnesses)
record(RELEASE / "results.json", {
    "owner": OWNER, "grant": GRANT, "source_sha256": SOURCE,
    "status": "REQUIRED_SOURCE_REGRESSIONS_PASS_WITH_MATCHING_LEGACY_BASELINE_FAILURE_UNFIT",
    "compiler_workers": 1, "transactions": transactions, "running_commands": [],
    "cases": cases, "totals": totals, "controller_cases": controller,
    "additional_controller_totals": {"pictures": 16, "coded_samples": 1843200, "RGB565_pixels": 1228800},
    "complete_coded_picture_comparisons": 54,
    "focused_checks": [line for line in focused.splitlines() if line.startswith(("OK ", "PASS "))],
    "publication_checks": [line for line in publication.splitlines() if line.startswith(("RETURN_STREAM", "PASS "))],
    "legacy_baseline_failure": warm, "artifact_generation_failures": {},
    "compiler_provenance_sha256": compiler_provenance,
    "original_budgets": {"IQ_Hadamard_cycles": 100, "controller_picture_cycles": 12000000,
                         "DPB_BRAM_fetch_cycles": 607, "MC_guard_cycles": 1060,
                         "composed_event_budget_seconds": 1},
    "pipeline_cycles": {"Hadamard": 19, "Hadamard_added_SYS": 3, "limited_colour_return": 3,
                        "limited_colour_added_SYS": 1, "motion_request_added_SYS": 0},
    "fixture_timing": old_results["fixture_timing"],
    "latency_comparison": latency, "service_change": design["composition"],
    "validation_provenance": "149 product and complete bench/oracle maps guarded across every job; exact full V14 baseline separately bound. Original composed input/binary/clock records and work counts remain. No unchanged broad CAVLC campaign was repeated.",
    "physical_result": "UNMEASURED: no Quartus, STA, synthesis, netlist, fit, hardware, ARM, capture or deployment.",
})
bundle(RELEASE / "results.tar", dict(sorted(curated.items())))
bundle(RELEASE / "validation-code.tar", dict(sorted(validation.items())))
bundle(RELEASE / "original-added-benches.tar", dict(sorted(original_added.items())))
record(RELEASE / "validation-source-map.json", {
    "base_validation_archive_sha256": file_sha(OLD / "validation-code.tar"),
    "base_members": hashes(old_validation), "new_members": hashes(validation),
    "changed_existing_members": validation_delta, "added_existing_bench_origins": added,
    "original_added_benches": hashes(original_added),
    "preserved_historical_scripts": "The complete61-member V14 validation archive remains; historical launchers/freezers are not V15 execution authority.",
    "fixture_oracle_bytes_not_bundled": True,
})
manifest = {
    "owner": OWNER, "grant": GRANT, "lane": "coherent-fpga-integration",
    "authority_registry_sha256_at_freeze": authority_sha256,
    "source_sha256": SOURCE, "base_source_sha256": old_meta["source_sha256"],
    "base_release_manifest_sha256": file_sha(OLD / "manifest.json"),
    "source_delta": CHANGED, "input_delta": input_delta,
    "source_members": 149, "effective_input_members": 150,
    "clock_profile": old_manifest["clock_profile"], "capability": old_manifest["capability"],
    "restricted_profile": old_manifest["restricted_profile"], "legacy_build_date": "260906",
    "seed": 6, "processors": 2, "source_generator_sha256": generator,
    "historical_base_driver_sha256": old_meta["driver_sha256"], "image_id": old_meta["image_id"],
    "proposed_build_id": SOURCE[:8],
    "actual_test_results": {"original_composed": totals, "additional_controller_pictures": 16,
                           "added_Hadamard_cases": 2388, "Hadamard_reset_replays": 20,
                           "controller_Hadamard_cancel_replays": 14, "signed16_MV_cases": 175616,
                           "dense_colour_returns": 4096},
    "artifacts_sha256": {path.name: file_sha(path) for path in sorted(RELEASE.iterdir())},
    "validation_source_members": len(validation), "curated_evidence_members": len(curated),
    "physical_area_timing_result": "UNMEASURED; no capacity, Fmax, timing or playback acceptance.",
    "remaining_physical_witnesses": limits, "latency_disposition": design["composition"],
    "baseline_failure_disposition": "Legacy equal-token-refresh fails identically on complete V14 and V15; unfixed/unwaived.",
    "physical_tool_owner": None, "fit_grant": None, "Quartus_or_hardware_invoked": False,
    "running_commands": [], "publication": "LOCAL_FROZEN_ONLY; parent assigns independent review/publication and any physical scope.",
    "media_policy": "Source, maps, simulation text/CSV and compiler provenance only. Fixture media/oracles, raw native reports, physical outputs and runtime/browser/config data are not bundled.",
}
record(RELEASE / "manifest.json", manifest)
for path in RELEASE.iterdir():
    path.chmod(0o444)
RELEASE.chmod(0o555)
for path in PROJECT.rglob("*"):
    if path.is_file():
        path.chmod(0o444)
result = {
    "owner": OWNER, "grant": GRANT,
    "status": "FROZEN_V15_SOURCE_REGRESSIONS_PASS_MATCHING_LEGACY_BASELINE_FAILURE_UNFIT",
    "source_sha256": SOURCE, "input_sha256": identity(input_map), "release": "release-v15",
    "files_sha256": {path.name: file_sha(path) for path in sorted(RELEASE.iterdir())},
    "validation_handles": list(JOBS), "retained_failure_handles": [name for name, code in JOBS.items() if code],
    "earlier_derivation_failure": "v15-derive-base", "running_commands": [],
    "fit_or_device_authority": False,
    "next_action": "Parent independently reviews/publishes the full five-member V14 delta and recorded latency/baseline limits, then separately grants physical ownership. No image approval.",
}
record(HERE / "owner-result.json", result)
print(json.dumps(result, indent=2, sort_keys=True))
