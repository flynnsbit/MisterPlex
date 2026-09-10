"""Actual clients plus the real terminator, with memory retained across reset."""
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import subprocess
import sys
import tarfile

resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
ROOT = Path.cwd()
SOURCE = ROOT / "fpga/Plex_MiSTer/sys"
BENCH = ROOT / "tests/rtl/fpga_sys_top_elaboration"
OUTPUT = ROOT / "build/reset-boundary" / sys.argv[1]
OUTPUT.mkdir(parents=True)
baseline = sys.argv[2] == "baseline"
only = sys.argv[3:] or (["palette", "scaler"] if baseline else ["palette", "scaler", "terminator"])
commands = []
if baseline:
    base = ROOT.parent.parent / "sys85-native-scaler-startup-5754/release"
    assert hashlib.sha256((base / "source.tar").read_bytes()).hexdigest() == "9606332ed29c3683b20cea5afc22075d578eedd0ce5e892eb02f0a4ce50ea5f7"
    pins = json.loads((base / "source-map.json").read_text())
    with tarfile.open(base / "source.tar") as archive:
        for member in archive:
            assert member.isfile() and ".." not in Path(member.name).parts
            data = archive.extractfile(member).read()
            assert hashlib.sha256(data).hexdigest() == pins[member.name]
            target = OUTPUT / "baseline-source" / member.name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
    SOURCE = OUTPUT / "baseline-source/sys"

def run(argv, name, stdout=None):
    commands.append(argv)
    (OUTPUT / "commands.json").write_text(json.dumps(commands, indent=2) + "\n")
    with (OUTPUT / (name + ".log")).open("w") as log:
        if stdout:
            with stdout.open("w") as out:
                result = subprocess.run(argv, stdout=out, stderr=log, timeout=240)
        else:
            result = subprocess.run(argv, stdout=log, stderr=subprocess.STDOUT, timeout=240)
    return result.returncode, (OUTPUT / (name + ".log")).read_text()

term = SOURCE / "f2sdram_safe_terminator.sv"
options = ["--timing", "--assert", "-Wno-fatal"]
sysmem = (SOURCE / "sysmem.sv").read_text()
if "PERSISTENT_MASTER" in term.read_text():
    assert re.search(r"#\(64, 8, 1\) f2sdram_safe_terminator_ram2", sysmem)
    assert re.search(r"#\(128, 8, 1\) f2sdram_safe_terminator_vbuf", sysmem)
    options += ["-DRESET_PERSISTENT_MASTER"]
code, text = run(["verilator", "--lint-only", *options, "--top-module",
                 "f2sdram_safe_terminator", str(term)], "terminator-unsuppressed")
if code:
    assert hashlib.sha256(term.read_bytes()).hexdigest() == "400bcbcfc0b4aae324fe813866a5443d577bf4de9b4ab1454cb068733d170261"
    errors = [line for line in text.splitlines() if line.startswith("%Error")]
    diagnostics = [line for line in errors if line.startswith("%Error-PROCASSWIRE:")]
    assert len(errors) == 16 and len(diagnostics) == 15, text
    assert all(str(term)+":" in line for line in diagnostics)
    assert {re.search(r": '(\w+)'$", line)[1] for line in diagnostics} == {
        "next_state_write", "burstcount_master", "address_master",
        "read_master", "write_master", "byteenable_master"}
    options += ["-Wno-PROCASSWIRE"]

results = {}
for name in only:
    sources = [term]
    if name == "palette":
        sources += [SOURCE / "scaler_palette.sv", SOURCE / "ddr_svc.sv"]
    elif name in ("scaler", "native"):
        work = OUTPUT / "ghdl"
        work.mkdir()
        ghdl = str(Path.home() / ".local/oss-cad-suite/bin/ghdl")
        common = ["--std=08", f"--workdir={work}"]
        code, text = run([ghdl, "-a", *common, str(SOURCE / "ascal.vhd")], "ascal-analyze")
        assert code == 0, text
        sys.path.insert(0, str(BENCH))
        from sys_top_elaboration_helpers import ASCAL_SPECIALIZATION
        converted = OUTPUT / "ascal.v"
        code, text = run([ghdl, "--synth", *common, "--out=verilog",
                          *[f"-g{k}={v}" for k, v in ASCAL_SPECIALIZATION.items()], "ascal"],
                         "ascal-synth", converted)
        assert code == 0, text
        sources.append(converted)
        if name == "native": sources.append(SOURCE / "scaler_palette.sv")
    top = name + "_reset_tb"
    native_options = ["-DNATIVE_OWNERSHIP_PROBES"] if name == "native" else []
    code, text = run(["verilator", "--binary", *options, "-j", "2", "--top-module", top,
                     "--Mdir", str(OUTPUT / name), "-o", "test",
                     *native_options, *map(str, sources), str(BENCH / (top + ".sv"))], name + "-compile")
    assert code == 0, text[-8000:]
    cases = {"palette": [0, 1, 2, 3], "scaler": [0, 1, 2, 3, 4], "terminator": [0], "native": [0]}[name]
    if os.environ.get("RESET_CASES"):
        cases = list(map(int, os.environ["RESET_CASES"].split(",")))
    configurations = [(case, os.environ.get("RESET_SYS_HALF", "5882.352941176471"),
                       os.environ.get("EDGE_ARGS", "").split()) for case in cases]
    if name == "native" and os.environ.get("NATIVE_BOTH") == "1":
        configurations = [(case, half, [f"+SYS85={sys85}", *os.environ.get("EDGE_ARGS", "").split()])
                          for half, sys85 in (("5882.352941176471", 1), ("25000", 0))
                          for case in cases]
    if name == "native" and os.environ.get("NATIVE_MATRIX") == "1":
        configurations = []
        for half, sys85 in (("5882.352941176471", 1), ("25000", 0)):
            for packing, width, height, native_cases in (
                    (1, 32, 24, (0,1,2,3,4,5,6,7,8,10,11)),
                    (1, 320, 240, (0,1,2,3,4,5,6,8,10,11)),
                    (2, 32, 24, (0,3,4,7,8,10,11))):
                for case in native_cases:
                    configurations.append((case, half, [f"+SYS85={sys85}", f"+PACKING={packing}",
                                                       f"+WIDTH={width}", f"+HEIGHT={height}"]))
            for packing in (1,2):
                configurations.append((9, half, [f"+SYS85={sys85}", f"+PACKING={packing}", "+LOWLAT=1"]))
    if name == "scaler" and os.environ.get("EDGE_MATRIX") == "1":
        configurations = []
        for half in ("5882.352941176471", "25000"):
            configurations += [(case, half, []) for case in (0,1,2,3,4,90)]
            for aligned in (0,1):
                for y in (0,1,2,3,8):
                    configurations.append((0, half, [f"+WINDOW_Y={y}",f"+ALIGNED={aligned}"]))
                configurations.append((0, half, ["+WINDOW_Y=0","+WINDOW_HEIGHT=64",f"+ALIGNED={aligned}"]))
                for case in (1,2,3,4,5):
                    configurations.append((case, half, ["+WINDOW_Y=0",f"+ALIGNED={aligned}",
                        "+ACCEPT_DELAY=600","+RETURN_DELAY=6000"]))
    if name == "native" and os.environ.get("MODE_MATRIX") == "1":
        configurations = []
        for half, sys85 in (("5882.352941176471", 1), ("25000", 0)):
            for lowlat in (0,1):
                args = [f"+SYS85={sys85}", f"+LOWLAT={lowlat}"]
                configurations += [(case, half, args) for case in (20,21,22,23,24,25,26,30,31,32)]
                configurations += [(case, half, [*args, "+VRR_ENABLE=1"]) for case in (21,25)]
                configurations += [(case, half, [*args, "+WIDTH=320", "+HEIGHT=240"]) for case in (20,22,23)]
    if name == "native" and os.environ.get("MODE_BASELINE_MATRIX") == "1":
        assert baseline
        configurations = []
        for half, sys85 in (("5882.352941176471", 1), ("25000", 0)):
            configurations += [(case, half, [f"+SYS85={sys85}", "+LOWLAT=1"]) for case in (20,22,23,25)]
            configurations += [(30, half, [f"+SYS85={sys85}", f"+LOWLAT={lowlat}", f"+VRR_POSITION={position}"])
                               for lowlat in (0,1) for position in (0,1,2)]
    for number, (case, half, args) in enumerate(configurations):
        code, text = run([str(OUTPUT / name / "test"), f"+CASE={case}",
                         "+SYS_HALF="+half, *args], f"{name}-{number}-case{case}")
        print(text[-4000:])
        witness = "RESET OWNERSHIP" in text
        results[f"{name}-{number}-case{case}"] = {"exit": code, "protocol_failure": witness,
            "case": case, "sys_half": half, "args": args,
            "first_frame_pixels": 8192 if code == 0 and case != 90 and name == "scaler" else None}
        if name == "native":
            frames = [dict(zip(("session", "frame", "tag", "pixels", "writes", "reads"), map(int, row)))
                      for row in re.findall(r"NATIVE_FRAME session=(\d+) frame=(\d+) tag=(\d+) pixels=(\d+) writes=(\d+) reads=(\d+)", text)]
            summary = re.search(r"frames=(\d+) identities=(\d+) pixels=(\d+) lifetime_pixels=(\d+) partial_reset_pixels=(\d+) packing=(\d+)", text)
            results[f"{name}-{number}-case{case}"]["native_frames"] = frames
            if summary:
                values = dict(zip(("frames", "identities", "pixels", "lifetime_pixels", "partial_reset_pixels", "packing"), map(int, summary.groups())))
                assert sum(f["pixels"] for f in frames) + values["partial_reset_pixels"] == values["lifetime_pixels"]
                results[f"{name}-{number}-case{case}"]["native_summary"] = values
            mode = re.search(r"NATIVE_MODE readiness=(\d)/(\d) config_active=(\d) lowlat=(\d) vrr=(\d) porch_checks=(\d+) minimum_periods=(\d+) maximum_periods=(\d+)", text)
            if mode:
                results[f"{name}-{number}-case{case}"]["mode_summary"] = dict(zip(
                    ("ready_tag", "ready_valid", "config_active", "lowlat", "vrr", "porch_checks",
                     "minimum_periods", "maximum_periods"), map(int, mode.groups())))
            results[f"{name}-{number}-case{case}"]["availability"] = [
                dict(zip(("cycle", "interval_lines", "output_row"), map(int, row)))
                for row in re.findall(r"NATIVE_AVAILABLE cycle=(\d+) interval_lines=(\d+) output_row=(\d+)", text)]
            results[f"{name}-{number}-case{case}"]["porch_responses"] = [
                dict(zip(("position", "available_cycle", "vs_cycle", "interval_lines", "checks"), map(int, row)))
                for row in re.findall(r"VRR_RESPONSE position=(\d+) available_cycle=(\d+) vs_cycle=(\d+) interval_lines=(\d+) checks=(\d+)", text)]
            results[f"{name}-{number}-case{case}"]["vrr_periods"] = [
                dict(zip(("clocks", "minimum", "maximum"), map(int, row)))
                for row in re.findall(r"VRR_PERIOD clocks=(\d+) minimum=(\d+) maximum=(\d+)", text)]
        (OUTPUT / "results.json").write_text(json.dumps(results, indent=2) + "\n")
        if baseline:
            required_failure = name in ("scaler", "native")
            if required_failure:
                assert code != 0 and witness, "Expected real ownership failure, not tool/setup failure"
            elif code:
                assert witness or (case == 90 and "first-frame pixel" in text), text
        else:
            assert code == 0 and ("PASS " + name in text or "PASS persistent terminator:" in text)
print("PASS baseline witnesses" if baseline else "PASS corrected reset boundaries")
