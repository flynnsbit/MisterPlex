#!/usr/bin/env python3
"""Freeze the complete, validated V14 cohort without Git or physical tools."""
import csv
import difflib
import hashlib
import io
import json
import os
import re
import tarfile
from pathlib import Path, PurePosixPath

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]
BASE = HERE.parent / "cavlc-timing-v13-5754"
OLD = BASE / "release-v13"
PROJECT = HERE / "project/fpga/Plex_MiSTer"
RELEASE = HERE / "release-v14"
OWNER = "ce6e3c70-35d0-47b7-a3b9-c1704c76e2be"
GRANT = "v14-real-critical-cones-5754"
SOURCE = "df9edd2c2c283ca574706401c1d253a5ca976394d8d33acf9456c18f2bb1ec59"
CHANGED = ["rtl/h264_deblock.sv", "rtl/h264_deblock_frame.sv",
           "rtl/h264_intra_pred.sv", "rtl/h264_mb_ctrl.sv"]
JOBS = ["v14-focused-r1", "v14-controller-r1", "v14-composed-r1"]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def file_sha(path):
    return sha(path.read_bytes())


def encoded(value):
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()


def record(path, value):
    path.write_bytes(encoded(value))


def archive_files(path):
    files = {}
    with tarfile.open(path) as archive:
        for member in archive:
            p = PurePosixPath(member.name)
            assert member.isfile() and not p.is_absolute() and ".." not in p.parts
            assert member.name not in files
            files[member.name] = archive.extractfile(member).read()
    return files


def bundle(path, files):
    with tarfile.open(path, "w") as archive:
        for name, data in files.items():
            member = tarfile.TarInfo(name)
            member.size, member.mode = len(data), 0o444
            archive.addfile(member, io.BytesIO(data))
    assert archive_files(path) == files


def hashes(files):
    return {name: sha(data) for name, data in files.items()}


def identity(mapping):
    return sha(json.dumps(mapping, sort_keys=True).encode())


def checksum_file(path):
    for line in path.read_text().splitlines():
        expected, name = line.split(maxsplit=1)
        p = Path(name.lstrip("*"))
        if not p.is_absolute():
            p = HERE / "project" / p
        assert file_sha(p) == expected, str(p)


def modules(data):
    return {m.group(1): m.group(0) for m in
            re.finditer(r"(?ms)^module\s+(\w+)\b.*?^endmodule", data.decode())}


assert not RELEASE.exists(), "Never overwrite a frozen or partial release"
assert file_sha(OLD / "manifest.json") == "574e670fa6446bf2d853da5c18cd54a5f2bc3483adf1aade1a881db183a6166b"
old_manifest = json.loads((OLD / "manifest.json").read_text())
for name, expected in old_manifest["artifacts_sha256"].items():
    assert file_sha(OLD / name) == expected, name
old_meta = json.loads((OLD / "inputs.json").read_text())
old_source, old_inputs = archive_files(OLD / "source.tar"), archive_files(OLD / "inputs.tar")
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

for name in ["rtl/h264_cavlc_residual.sv", "rtl/h264_recon.sv", "rtl/h264_iq_idct_4x4.sv",
             "rtl/h264_dpb.sv", "rtl/stream_path.sv", "rtl/decode_stub.sv"]:
    assert source[name] == old_source[name]
for name in ["rtl/h264_deblock_frame.sv", "rtl/h264_mb_ctrl.sv"]:
    assert source[name].split(b");", 1)[0] == old_source[name].split(b");", 1)[0]
for name in ["rtl/h264_deblock.sv", "rtl/h264_intra_pred.sv"]:
    before, after = modules(old_source[name]), modules(source[name])
    for module, text in before.items():
        if module != "h264_deblock_qp":
            assert after[module] == text, module
    expected_added = {"h264_deblock_samples_pipe"} if "deblock" in name else {"h264_chroma_pred_region_pipe"}
    assert set(after) - set(before) == expected_added
    assert name.encode() in source["files.qip"]
sdcs = {name: source_map[name] for name in source if name.endswith(".sdc")}
clauses = sum(len(re.findall(rb"(?m)^set_(?:false_path|multicycle_path|clock_groups|max_delay|min_delay)\b",
                            source[name])) for name in sdcs)
assert len(sdcs) == 3 and clauses == 52
assert old_meta["legacy_build_date"] == "260906"

old_validation = archive_files(OLD / "validation-code.tar")
validation_delta = sorted(name for name, data in old_validation.items() if (HERE / name).read_bytes() != data)
assert validation_delta == ["project/tests/rtl/h264_deblock_frame_tb.cpp",
                            "project/tests/rtl/h264_inter_reference_tb.cpp",
                            "project/tests/rtl/h264_inter_reference_tb.sv"]
frame_tb = (HERE / "project/tests/rtl/h264_deblock_frame_tb.cpp").read_text()
frame_original = frame_tb.split("void pipelineCancellation()", 1)[0] + \
    "void ordinary(" + frame_tb.split("void pipelineCancellation()", 1)[1].split("void ordinary(", 1)[1]
assert frame_original.replace("if(argc==1) {synthetic();pipelineCancellation();}",
                              "if(argc==1) synthetic();") == \
    old_validation["project/tests/rtl/h264_deblock_frame_tb.cpp"].decode()
inter_tb = (HERE / "project/tests/rtl/h264_inter_reference_tb.cpp").read_text()
inter_original = inter_tb.split("void pipelinedFilterTests()", 1)[0] + \
    "void geometryTests()" + inter_tb.split("void pipelinedFilterTests()", 1)[1].split("void geometryTests()", 1)[1]
assert inter_original.replace("        pipelinedFilterTests();\n", "") == \
    old_validation["project/tests/rtl/h264_inter_reference_tb.cpp"].decode()
assert "n<12000000" in (HERE / "project/tests/rtl/p2_intra_controller_tb.cpp").read_text()

fixtures = json.loads((OLD / "fixture-preservation.json").read_text())
assert len(fixtures) == 92
for name, expected in fixtures.items():
    assert file_sha(HERE / name) == file_sha(BASE / name) == expected, name
origins = json.loads((HERE / "evidence/added-existing-bench-origins.json").read_text())
dependencies = json.loads((HERE / "evidence/restored-oracle-dependencies.json").read_text())
original_benches = {}
for entry in origins["records"]:
    path = ROOT / entry["source"]
    assert file_sha(path) == entry["sha256"]
    original_benches[entry["source"].split("/tests/", 1)[1]] = path.read_bytes()
chroma_original = original_benches["rtl/p2_chroma_pred_tb.cpp"].decode()
chroma_new = (HERE / "project/tests/rtl/p2_chroma_pred_tb.cpp").read_text()
assert chroma_original.split("static int floor32", 1)[1].split("int main", 1)[0] == \
    chroma_new.split("static int floor32", 1)[1].split("static void tick", 1)[0]
original_loop = chroma_original.split("        for(unsigned sample=0;sample<4104;++sample)", 1)[1].split(
    "        if(!low_clips", 1)[0]
new_loop = chroma_new.split("        for(unsigned sample=0;sample<4104;++sample)", 1)[1].split(
    "        if(!low_clips", 1)[0]
assert new_loop.replace("                    pipeline(d);\n", "") == original_loop
new_fixtures = {}
for entry in dependencies["records"]:
    assert file_sha(HERE / entry["member"]) == entry["sha256"]
    if "/fixtures/" in entry["member"]:
        new_fixtures[entry["member"]] = entry["sha256"]

curated, transactions = {}, {}
for label in ["v14-frame-r1"] + JOBS:
    path = HERE / "evidence/jobs" / f"{label}.json"
    job = json.loads(path.read_text())
    assert job["owner"] == OWNER and job["grant"] == GRANT
    assert job["source_map"] == source_map and job["source_sha256"] == SOURCE
    assert job["owned_child_group_settled"] and job["ended_at"]
    assert all(value["value"] == 1 for value in job["guards_after"].values())
    assert {item["name"] for item in job["released"]} == {"controller", "execution"}
    assert job["exit_code"] == (1 if label == "v14-frame-r1" else 0)
    assert file_sha(Path(job["output"])) == job["output_sha256"]
    if label == "v14-frame-r1":
        assert "fatal error: libmisterplex/h264_recon.hpp: No such file" in Path(job["output"]).read_text()
    transactions[label] = {"receipt_sha256": file_sha(path), "receipt": job}
    curated[f"transactions/{label}.json"] = path.read_bytes()
    curated[f"transactions/{label}.log"] = Path(job["output"]).read_bytes()
focused = (HERE / "evidence/jobs/v14-focused-r1.log").read_text()
for marker in ["262656 chroma blocks", "512 live-input/busy-start", "generations=15",
               "edges=54080", "QP full-port pairs=131072", "reads=46213 responses=46213",
               "BRAM_fetch_cycles=607", "max_mc_cycles=1058", "max_axis_mc_cycles=595",
               "max_odd_quarter_mc_cycles=953", "48 packed/fractional"]:
    assert marker in focused, marker
assert len(re.findall(r"(?m)^PASS ordinary FFmpeg filter-on ", focused)) == 2

old_results = json.loads((OLD / "results.json").read_text())
cases = []
totals = dict(pictures=0, coded_samples=0, visible_samples=0, native_RGB_samples=0,
              counted_legacy_RGB565_pixels=0)
unchanged_metrics = ["display_interval", "prediction_fetches", "fractional_fetches",
                     "nonzero_P_blocks", "filter_writes", "SYS_Hz", "DDR_Hz", "base_Hz", "native_divisor"]
for old_case in old_results["cases"]:
    relative = Path(old_case["case"])
    directory = HERE / "project/build/verilator" / relative
    text = (directory / "execution.log").read_text()
    assert text.splitlines()[-1].startswith("PASS ")
    for name in ["inputs.sha256", "binary.sha256", "actual.sha256"]:
        checksum_file(directory / name)
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
    metric_path = next(directory.glob("*.csv"))
    with metric_path.open() as stream:
        rows = [{k: int(v) for k, v in row.items()} for row in csv.DictReader(stream)]
    assert len(rows) == len(old_case["metrics_SYS_cycles"])
    deltas = []
    for before, after in zip(old_case["metrics_SYS_cycles"], rows):
        assert all(before[key] == after[key] for key in unchanged_metrics)
        deltas.append({key: after[key] - before[key] for key in after})
    startup_shift = [delta["display_cycle"] for delta in deltas]
    shifted = relative.parts[1] in ("full240-joint", "legacy-full240", "active-filter-recovery")
    assert startup_shift == [2005872 if shifted else 0] * len(rows)
    checks = [line for line in text.splitlines() if re.match(
        r"^(?:FRAME_PASS|NATIVE_PASS|LEGACY_RGB_PASS|BANK_REUSE_PASS|FILTER_ACTIVE_FAULT|"
        r"FILTER_METADATA_FAULT|FAULT_RECOVERY_PASS|CODEC_ERROR_PASS|INGRESS_SEEK_PASS|METRIC|PASS )", line)]
    cases.append({"case": str(relative), "pass": True, **count,
                  "execution_sha256": file_sha(directory / "execution.log"),
                  "actual_sha256": file_sha(directory / "actual.i420"),
                  "reference_sha256": file_sha(reference),
                  "metrics_SYS_cycles": rows, "V13_deltas_SYS_cycles": deltas, "checks": checks})
    curated[f"composed/{relative}/checks.log"] = ("\n".join(checks) + "\n").encode()
    for name in [metric_path.name, "inputs.sha256", "binary.sha256", "actual.sha256", "clock-binding.json"]:
        curated[f"composed/{relative}/{name}"] = (directory / name).read_bytes()
        if name == "clock-binding.json":
            assert (directory / name).read_bytes() == (BASE / "project/build/verilator" / relative / name).read_bytes()
assert len(cases) == 11 and totals == old_results["totals"]
assert sum(line.startswith("INGRESS_SEEK_PASS") for case in cases for line in case["checks"]) == 5

controller = []
for lease in (False, True):
    build = HERE / "project/build" / ("p2-intra-controller-13" + ("-native-lease" if lease else ""))
    labels = ["run"] + (["native-reset", "native-vcl"] if lease else
                       [f"chroma-{mode}-stage{stage}" for mode in ("reset", "vcl") for stage in (1, 2, 3, 4, 0)])
    gold = build / "run.ffmpeg.yuv"
    assert gold.stat().st_size == 115200
    for label in labels:
        log, actual = build / f"{label}.log", build / f"{label}.actual.yuv"
        text = log.read_text()
        assert "YUV mismatches=0,0,0" in text and actual.read_bytes() == gold.read_bytes()
        assert "CHROMA_TRANSACTIONS" in text and "capacity=8192 payload=6841" in text
        sample = {"native_lease": lease, "case": label, "pass": True, "coded_samples": 115200,
                  "RGB565_pixels": 76800, "execution_sha256": file_sha(log),
                  "actual_sha256": file_sha(actual), "reference_sha256": file_sha(gold),
                  "binary_sha256": file_sha(build / "obj/Vp2_intra_controller_tb"),
                  "checks": text.splitlines()}
        if label.startswith("chroma-"):
            assert "canceled=1" in text and "requests=2401 retired=2400" in text
        controller.append(sample)
        curated[f"controller/lease{int(lease)}/{label}.log"] = log.read_bytes()
assert len(controller) == 14

native = json.loads((HERE / "evidence/native-witnesses.json").read_text())
native_summaries = []
for entry in native["paths"]:
    assert file_sha(ROOT / entry["file"]) == entry["sha256"]
    native_summaries.append({**{key: value for key, value in entry.items() if key != "first_path"},
                             "retained_first_path_text_sha256": sha(entry["first_path"].encode())})
physical_summary = ROOT / ".worktrees/fpga-h264-fleet-30ff2997/build/coherent-v13-physical-5754/results/final-outcome-summary.json"
physical = json.loads(physical_summary.read_text())
physical_pins = physical["identities"]
for key, name in [("source_tar_sha256", "source.tar"), ("inputs_tar_sha256", "inputs.tar"),
                  ("inputs_json_sha256", "inputs.json"), ("release_manifest_sha256", "manifest.json")]:
    assert physical_pins[key] == file_sha(OLD / name), key
assert physical_pins["derived_build_id"] == old_meta["fpga_video_build_id"]
assert physical["fit_outcome"]["rbf_sha256"] == "d88c6425328cfcfd1ee648f3dedf499b75f51f104fc6781c28bc0b184a91c65c"
design = json.loads((HERE / "evidence/implementation-intent.json").read_text())
witnesses = {
    "base_source_sha256": old_meta["source_sha256"], "source_sha256": SOURCE,
    "base_physical_summary": str(physical_summary.relative_to(ROOT)),
    "base_physical_summary_sha256": file_sha(physical_summary),
    "base_physical_input_pins": {key: physical_pins[key] for key in
                                ["source_tar_sha256", "inputs_tar_sha256", "inputs_json_sha256",
                                 "release_manifest_sha256", "derived_build_id"]},
    "native_setup_paths": native_summaries, "implemented_design_and_bounds": design,
    "new_registered_helpers": {
        "h264_deblock_samples_pipe": "rtl/h264_deblock.sv",
        "h264_chroma_pred_region_pipe": "rtl/h264_intra_pred.sv",
    },
    "registration": "Both helpers are in already-registered source files; files.qip and source QSF remain byte-identical.",
    "native_path_policy": "Full endpoints and zero-logic/top-level/self-feedback paths are legitimate; no path class was excluded or waived.",
    "remaining_physical_limits": [
        "V13 native setup remains -20.572/-21.774/-6.414/-4.398 ns; its RBFd88c6425 is unapproved.",
        "V14 cuts the witnessed source cones but has no Quartus/STA/fit, area/capacity, Fmax or deployment result.",
        "Shared DPB RAM fanout/routing and DDR/HDMI/CLK2 physical paths still require the separately assigned flow.",
        "Observer/retention/DDR hierarchy-floor assessment remains with the independent reviewer; no floor/tool/DDR/painter edit here.",
        "Full240 first display moves one modeled native period later; latency cost is retained and requires independent acceptance.",
    ],
}
for name in ["base-verification.json", "implementation-intent.json", "added-existing-bench-origins.json",
             "restored-oracle-dependencies.json", "freeze-intent.json"]:
    curated[f"provenance/{name}"] = (HERE / "evidence" / name).read_bytes()
freeze_failures = {}
for path in sorted((HERE / "evidence/jobs").glob("v14-freeze-*.json")):
    failure = json.loads(path.read_text())
    if "exit_code" not in failure:
        assert failure.get("child_pid") == os.getpid(), "Another unfinished freezer exists"
        continue
    if failure.get("exit_code") == 0:
        continue
    assert failure["state"] == "failed" and failure["running_command"] is None
    freeze_failures[path.stem] = failure
    curated[f"artifact-failures/{path.name}"] = path.read_bytes()
    curated[f"artifact-failures/{path.stem}.log"] = path.with_suffix(".log").read_bytes()
    if "failed_generator_snapshot" in failure:
        snapshot = HERE / failure["failed_generator_snapshot"]
        assert file_sha(snapshot) == failure["failed_generator_sha256"]
        curated[f"artifact-failures/{snapshot.name}"] = snapshot.read_bytes()
compiler_provenance = {}
for path in sorted((HERE / "project/build").rglob("*__verFiles.dat")):
    relative = str(path.relative_to(HERE))
    compiler_provenance[relative] = file_sha(path)
    curated[f"compiler/{relative}"] = path.read_bytes()
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
validation = {name: (HERE / name).read_bytes() for name in old_validation if name != "freeze_release_v13.py"}
for entry in origins["records"]:
    name = "project/tests/" + entry["source"].split("/tests/", 1)[1]
    validation[name] = (HERE / name).read_bytes()
for entry in dependencies["records"]:
    if entry["member"].startswith("project/host/"):
        validation[entry["member"]] = (HERE / entry["member"]).read_bytes()
for name in ["guarded_campaign.py", "run_focused_v14.sh", "run_controller_v14.sh",
             "run_composed_v14.sh", "freeze_release_v14.py", "verify_release_v14.py"]:
    validation[name] = (HERE / name).read_bytes()
assert len(validation) == 61

RELEASE.mkdir()
bundle(RELEASE / "source.tar", source)
bundle(RELEASE / "inputs.tar", inputs)
generator = file_sha(Path(__file__))
record(RELEASE / "inputs.json", {
    **old_meta, "source_sha256": SOURCE, "source_archive_sha256": file_sha(RELEASE / "source.tar"),
    "source_files": source_map, "input_files": input_map, "input_sha256": identity(input_map),
    "fpga_video_build_id": SOURCE[:8], "archive_sha256": file_sha(RELEASE / "inputs.tar"),
    "driver_sha256": generator, "historical_base_driver_sha256": old_meta["driver_sha256"],
    "generation": "Source-only deterministic complete V13 member-map derivation; no Git or physical executable.",
    "git_commit_role": "Inherited ancestry only, not publication or the authoritative source definition for V14.",
    "future_physical_tool_binding": "Unassigned; parent must authorize and bind an independently reviewed physical owner/tool.",
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
    "unchanged_source_members": 145, "unchanged_effective_members": 145,
    "all_other_members_byte_identical": True,
    "CAVLC_DPB_fetch_reconstruction_and_full32_escape_source_byte_identical": True,
    "legacy_deblock_and_intra_helpers_unchanged_except_proven_signed8_QP_mapping": True,
    "source_SDC_sha256": sdcs, "source_exclusion_clauses": clauses,
    "files_qip_QSF_clocks_audio_cap0_aspect_decode_stub_and_DDR_unchanged": True,
    "existing_validation_source_delta": validation_delta,
    "original_frame_inter_chroma_oracles_and_budgets_preserved": True,
})
record(RELEASE / "fixture-preservation.json", {**fixtures, **new_fixtures})
record(RELEASE / "witnesses.json", witnesses)
record(RELEASE / "results.json", {
    "owner": OWNER, "grant": GRANT, "source_sha256": SOURCE,
    "status": "PASS_SOURCE_SEMANTICS_ONLY_WITH_RECORDED_LATENCY_COST", "compiler_workers": 1,
    "transactions": transactions, "running_commands": [],
    "artifact_generation_failures": freeze_failures,
    "cases": cases, "totals": totals, "controller_cases": controller,
    "additional_controller_totals": {"pictures": 14, "coded_samples": 1612800, "RGB565_pixels": 1075200},
    "complete_coded_picture_comparisons": 52,
    "focused_checks": focused.splitlines(), "compiler_provenance_sha256": compiler_provenance,
    "original_budgets": {"frame_filter_cycles": 4000000, "frame_abort_trigger_guard": 10000,
                         "controller_picture_cycles": 12000000, "DPB_BRAM_fetch_cycles": 607,
                         "MC_guard_cycles": 1060, "composed_event_budget_seconds": 1},
    "pipeline_cycles": {"sample_filter_core": 3, "chroma_predictor_core": 5,
                        "additional_filter_SYS_per_segment": 3, "additional_chroma_SYS_per_block": 5},
    "fixture_timing": old_results["fixture_timing"],
    "service_change": "Full240 IDR promotion +68340 SYS (filter +56340, chroma +12000); full240/legacy/active-recovery first display +2005872 SYS, subsequent cadence unchanged. Exact per-case deltas retained; no budget widened.",
    "validation_provenance": "149 product hashes guarded before/after each job; composed tests also check pre-build input/binary manifests. Exact bench/dependency bytes are archived; compiler command/dependency records are retained. Unchanged broad CAVLC campaigns were not repeated.",
    "physical_result": "UNMEASURED: no Quartus, synthesis, STA, netlist, fit, hardware, ARM, capture or deployment.",
})
bundle(RELEASE / "results.tar", dict(sorted(curated.items())))
bundle(RELEASE / "validation-code.tar", dict(sorted(validation.items())))
bundle(RELEASE / "original-added-benches.tar", dict(sorted(original_benches.items())))
record(RELEASE / "validation-source-map.json", {
    "base_validation_archive_sha256": file_sha(OLD / "validation-code.tar"),
    "base_members": hashes(old_validation), "new_members": hashes(validation),
    "changed_existing_members": validation_delta,
    "added_existing_bench_origins": origins, "restored_oracle_dependencies": dependencies,
    "original_added_benches": hashes(original_benches),
    "omitted_historical_script": "freeze_release_v13.py remains locally preserved and unexecuted; superseded by the V14 freezer.",
    "fixture_oracle_bytes_not_bundled": True,
})
manifest = {
    "owner": OWNER, "grant": GRANT, "lane": "coherent-fpga-integration",
    "source_sha256": SOURCE, "base_source_sha256": old_meta["source_sha256"],
    "base_release_manifest_sha256": file_sha(OLD / "manifest.json"),
    "source_delta": CHANGED, "input_delta": input_delta,
    "source_members": 149, "effective_input_members": 150,
    "clock_profile": old_manifest["clock_profile"], "capability": old_manifest["capability"],
    "restricted_profile": old_manifest["restricted_profile"], "legacy_build_date": "260906",
    "seed": 6, "processors": 2, "source_generator_sha256": generator,
    "historical_base_driver_sha256": old_meta["driver_sha256"], "image_id": old_meta["image_id"],
    "proposed_build_id": SOURCE[:8],
    "actual_test_results": {"original_composed": totals, "additional_controller_pictures": 14,
                           "original_chroma_blocks": 262656, "four_lane_sample_edges": 54080,
                           "QP_full_port_pairs": 131072, "frame_pipeline_cancel_replays": 15},
    "artifacts_sha256": {path.name: file_sha(path) for path in sorted(RELEASE.iterdir())},
    "validation_source_members": len(validation), "curated_evidence_members": len(curated),
    "physical_area_timing_result": "UNMEASURED; no capacity, Fmax, closure or playback acceptance.",
    "remaining_physical_witnesses": witnesses["remaining_physical_limits"],
    "latency_disposition": "Explicit +3/edge and +5/chroma-block cost; three full240 scenarios start display one modeled native period later. Review required, not hidden or waived.",
    "physical_tool_owner": None, "fit_grant": None, "Quartus_or_hardware_invoked": False,
    "running_commands": [], "publication": "LOCAL_FROZEN_ONLY; independent review/publication and future physical scope belong to parent.",
    "media_policy": "Source, maps, simulation text/CSV and compiler provenance only. Fixture media, native raw timing reports, runtime/browser/config data and physical outputs remain outside release archives.",
}
record(RELEASE / "manifest.json", manifest)
for path in RELEASE.iterdir():
    path.chmod(0o444)
RELEASE.chmod(0o555)
for path in PROJECT.rglob("*"):
    if path.is_file():
        path.chmod(0o444)
result = {
    "owner": OWNER, "grant": GRANT, "status": "FROZEN_V14_SOURCE_SEMANTICS_PASS_UNFIT_WITH_LATENCY_COST",
    "source_sha256": SOURCE, "release": "release-v14",
    "files_sha256": {path.name: file_sha(path) for path in sorted(RELEASE.iterdir())},
    "validation_handles": JOBS, "retained_failure_handles": ["v14-frame-r1"],
    "running_commands": [], "fit_or_device_authority": False,
    "next_action": "Parent independently reviews the complete V14 delta and recorded latency cost, publishes accepted source, then grants a distinct physical owner/tool. No RBF/deployment approval.",
}
record(HERE / "owner-result.json", result)
print(json.dumps(result, indent=2, sort_keys=True))
