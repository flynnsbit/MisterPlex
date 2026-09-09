#!/usr/bin/env python3
"""Actual mixed-language sys_top gate, not a simulation or hardware acceptance.

Run: python3 -m unittest discover -s tests/unit -p test_fpga_sys_top_elaboration.py -v

GHDL and Verilator must already be installed. INTEL_SIM_LIB names a local
directory containing the vendor files listed in the helper's VENDOR_FILES (default:
build/verilator/fpga_sys_top_elaboration/vendor). cyclonev_wysiwyg_components.vhd
is Quartus libraries/vhdl/wysiwyg/cyclonev_components.vhd, not the sim_lib file.
No Quartus process, container, deployment, or service is started by this test.

For only the scaler cycle/format regression, add -k test_ascal_timing_pipeline.
ASCAL_SOURCE selects an isolated scaler leaf; ASCAL_TEST_OUTPUT selects its
build directory. ASCAL_REFERENCE_SOURCE optionally checks that all logic outside
the coefficient and vertical-edge pipeline cones is byte-identical
to an archived baseline.
"""

import hashlib
import gzip
import json
import os
import re
import shutil
import subprocess
import sys
import time
import threading
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PROJECT = ROOT / "fpga/Plex_MiSTer"
OUTPUT = Path(os.environ.get("SYS_TOP_TEST_OUTPUT", str(
    ROOT / "build/verilator/fpga_sys_top_elaboration"))).resolve()
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "tests/rtl/fpga_sys_top_elaboration"))
import check_define_parity
import rbf_build
import rtl_lint
import sys_top_elaboration_helpers as helpers


def identity(path):
    return {"sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "size": path.stat().st_size, "mtime_ns": path.stat().st_mtime_ns}


def source_identities():
    paths = list(rbf_build.source_files(PROJECT).values())
    paths += [ROOT / "scripts" / name for name in
              ("rtl_lint.py", "check_define_parity.py", "run_verilator.sh", "rbf_build.py")]
    paths += [Path(__file__), ROOT / "tests/rtl/fpga_sys_top_elaboration/sys_top_elaboration_helpers.py",
              ROOT / "tests/rtl/fpga_sys_top_elaboration/build_id.v"]
    return {str(path.relative_to(ROOT)): identity(path) for path in sorted(paths)}


def nodes(tree):
    if isinstance(tree, dict):
        yield tree
        for value in tree.values():
            yield from nodes(value)
    elif isinstance(tree, list):
        for value in tree:
            yield from nodes(value)


def parameters(module):
    result = {}
    for node in module["stmtsp"]:
        if node.get("type") != "VAR" or not node.get("isParam"):
            continue
        value = node.get("valuep", [])
        if len(value) != 1 or value[0].get("type") != "CONST":
            continue
        literal = value[0]["name"]
        match = re.fullmatch(r"\d+'s?([hbd])([0-9a-fA-F_]+)", literal)
        if match:
            result[node["origName"]] = int(
                match.group(2).replace("_", ""), {"h": 16, "b": 2, "d": 10}[match.group(1)]
            )
    return result


class SysTopElaborationTests(unittest.TestCase):
    def test_framework_reset_boundary(self):
        result = subprocess.run([sys.executable, str(ROOT / "tests/run_reset_boundary.py"),
            os.environ.get("FRAMEWORK_RESET_LABEL", "registered-reset-boundary"), "corrected"],
            cwd=ROOT, text=True, capture_output=True, timeout=600)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS corrected reset boundaries", result.stdout)

    def test_framework_measurement_event(self):
        output = Path(os.environ["FRAMEWORK_EVENT_OUTPUT"]).resolve()
        output.mkdir(parents=True)
        source = PROJECT / "sys/hps_io.sv"
        bench = ROOT / "tests/rtl/video_measurement_event_tb.sv"
        before = {str(p): identity(p) for p in (source, bench)}
        self.assertEqual(identity(source)["sha256"], "c1e2eb8f601ac41e5a615749da5711dccb615e0f9046a47e1d6fb7349fa71dbc")
        self.assertEqual(identity(bench)["sha256"], "db4405ac9683cefd7200a2b903474ad5ae10f4a50f919f939a8853388d8ec78c")
        commands = [[str(ROOT / "scripts/run_verilator.sh"), "--binary", "--timing", "--assert",
                     "-j", "1", "-Wno-fatal", "--top-module", "video_measurement_event_tb",
                     "--Mdir", str(output / "obj"), str(source), str(bench)]]
        configurations = [
            ("25000", 1, 0, 540, 703),
            ("5882.352941176471", 1, 1, 2200, 2799),
            ("5882.352941176471", 0, 0, 646, 838)]
        expectations = []
        for half, alias, ce, tuples, queries in configurations:
            for delay in (0, 32):
                commands.append([str(output / "obj/Vvideo_measurement_event_tb"),
                    f"+SYS_HALF={half}", f"+ALIAS_VIDEO={alias}", f"+NATIVE_CE={ce}", f"+VS_DELAY={delay}"])
                expectations.append((alias, ce, delay, tuples, queries))
        (output / "commands.json").write_text(json.dumps(commands, indent=2) + "\n")
        (output / "inputs.json").write_text(json.dumps(before, indent=2) + "\n")
        metrics = []
        for index, command in enumerate(commands):
            log = output / f"{index}.log"
            with log.open("w") as stream:
                result = subprocess.run(command, cwd=ROOT, stdout=stream,
                                        stderr=subprocess.STDOUT, timeout=180)
            text = log.read_text()
            self.assertEqual(result.returncode, 0, "\n".join(text.splitlines()[-30:]))
            if index:
                line = next((line for line in text.splitlines() if line.startswith("PASS EVENT ")), "")
                self.assertTrue(line, text)
                values = {key: float(value) for key, value in re.findall(r"(\w+)=([0-9.]+)", line)}
                alias, ce, delay, tuples, queries = expectations[index-1]
                self.assertEqual(tuple(values[key] for key in ("alias", "native_ce", "VS_DELAY",
                    "full_tuple_observations", "host_queries")), (alias, ce, delay, tuples, queries))
                self.assertEqual(values["raster_configurations"], 16)
                self.assertEqual(values["recovery_checks"], 5)
                self.assertEqual(values["receiver_pause_scenarios"], 3)
                self.assertEqual(values["reset_scenarios"], 2)
                metrics.append(values)
        (output / "metrics.json").write_text(json.dumps(metrics, indent=2) + "\n")
        self.assertEqual(before, {str(Path(p)): identity(Path(p)) for p in before})

    def test_framework_measurement(self):
        output = Path(os.environ.get("FRAMEWORK_MEASUREMENT_OUTPUT", str(OUTPUT / "framework-measurement"))).resolve()
        output.mkdir(parents=True)
        source = PROJECT / "sys/hps_io.sv"
        bench = ROOT / "tests/rtl/video_measurement_tb.sv"
        before = {str(p): identity(p) for p in (source, bench)}
        commands = [[str(ROOT / "scripts/run_verilator.sh"), "--binary", "--timing", "--assert",
                     "-j", "1", "-Wno-fatal", "--top-module", "video_measurement_tb",
                     "--Mdir", str(output / "obj"), str(source), str(bench)]]
        for half in ("25000", "5882.352941176471"):
            for phase in ("1100", "4377"):
                commands.append([str(output / "obj/Vvideo_measurement_tb"),
                                 f"+SYS_HALF={half}", f"+CLK100_PHASE={phase}"])
        (output / "commands.json").write_text(json.dumps(commands, indent=2) + "\n")
        (output / "inputs.json").write_text(json.dumps(before, indent=2) + "\n")
        for index, command in enumerate(commands):
            log = output / f"{index}.log"
            with log.open("w") as stream:
                result = subprocess.run(command, cwd=ROOT, stdout=stream,
                                        stderr=subprocess.STDOUT, timeout=180)
            self.assertEqual(result.returncode, 0, "\n".join(log.read_text().splitlines()[-30:]))
            if index:
                match = re.search(r"PASS video_measurement .*queries=(\d+) producer_modes=(\d+) "
                                  r".*ack_abort=(\d+) producer_reset_recovery=1 stable_identity=1 interlaced=1",
                                  log.read_text())
                self.assertIsNotNone(match, log.read_text())
                self.assertEqual(tuple(map(int, match.groups())), (62, 14, 12))
        self.assertEqual(before, {str(Path(p)): identity(Path(p)) for p in before})

    def test_framework_native_input(self):
        output = Path(os.environ.get("FRAMEWORK_NATIVE_OUTPUT", str(OUTPUT / "framework-native"))).resolve()
        result = subprocess.run(
            [sys.executable, str(ROOT / "tests/run_reset_boundary.py"), str(output), "corrected", "native"],
            cwd=ROOT, env=dict(os.environ, NATIVE_MATRIX="1"), capture_output=True, text=True, timeout=600)
        self.assertEqual(result.returncode, 0, result.stdout[-8000:] + result.stderr[-8000:])
        metrics = json.loads((output / "results.json").read_text())
        self.assertEqual(len(metrics), 60)
        self.assertTrue(all(row["native_summary"]["frames"] >= 4 for row in metrics.values()))
        self.assertTrue(all(row["native_frames"][0]["frame"] == 1 for row in metrics.values()))

    def test_framework_native_modes(self):
        output = Path(os.environ.get("FRAMEWORK_MODES_OUTPUT", str(OUTPUT / "framework-native-modes"))).resolve()
        result = subprocess.run(
            [sys.executable, str(ROOT / "tests/run_reset_boundary.py"), str(output), "corrected", "native"],
            cwd=ROOT, env=dict(os.environ, MODE_MATRIX="1"), capture_output=True, text=True, timeout=600)
        self.assertEqual(result.returncode, 0, result.stdout[-8000:] + result.stderr[-8000:])
        metrics = json.loads((output / "results.json").read_text())
        self.assertEqual(len(metrics), 60)
        self.assertTrue(all(row["native_frames"][0]["frame"] == 1 for row in metrics.values()))
        for row in metrics.values():
            mode = row["mode_summary"]
            self.assertEqual((mode["ready_valid"], mode["config_active"]), (1, 1))
            if row["case"] in (26,30,31):
                self.assertEqual(mode["porch_checks"], 3)
            if row["case"] == 32:
                self.assertGreaterEqual(mode["minimum_periods"], 2)
                self.assertGreaterEqual(mode["maximum_periods"], 1)

    def test_framework_constraints(self):
        output = Path(os.environ.get("FRAMEWORK_SDC_OUTPUT", str(OUTPUT / "framework-sdc"))).resolve()
        output.mkdir(parents=True)
        directory = ROOT / "tests/rtl/fpga_sys_top_elaboration"
        harness = directory / "framework_constraints.tcl"
        files = [harness, directory / "reference_sys_top.sdc",
                 PROJECT / "Plex.sdc", PROJECT / "sys/sys_top.sdc", PROJECT / "sys/framework_cdc.sdc"]
        before = {str(p): identity(p) for p in files}
        interpreter = ([shutil.which("tclsh")] if shutil.which("tclsh") else
                       [str(Path.home() / ".local/oss-cad-suite/bin/yosys"), "-Q", "-T", "-c", "/dev/stdin"])
        cases = ("active", "aliases", "disabled", "missing-source", "missing-capture",
                 "missing-palette", "unexpected-register", "invalid-bit", "ambiguous-instance",
                 "missing-measurement", "missing-clock", "zero-period", "ambiguous-clock",
                 "gray-intervals", "invalid-gray-interval", "missing-completion-source",
                 "missing-completion-capture", "invalid-completion-bit",
                 "missing-native-source", "missing-native-capture", "missing-native-release",
                 "missing-native-refresh", "missing-write-source", "missing-write-capture",
                 "invalid-native-bit", "optimized-bank", "partial-constants",
                 "wrong-source-clock", "wrong-capture-clock", "wrong-root-clock",
                 "wrong-duplicate-clock", "missing-node-clock", "mixed-node-clock",
                 "clock-cycle", "missing-clock-target", "missing-bank")
        (output / "inputs.json").write_text(json.dumps(before, indent=2) + "\n")
        (output / "interpreter.json").write_text(json.dumps(interpreter) + "\n")
        for rate in ("20", "85"):
            for case in cases:
                env = dict(os.environ, FRAMEWORK_SDC_CASE=case, FRAMEWORK_SDC_RATE=rate,
                           FRAMEWORK_SDC_REFERENCE=str(directory / "reference_sys_top.sdc"),
                           FRAMEWORK_SDC_SYSTEM=str(PROJECT / "sys/sys_top.sdc"),
                           FRAMEWORK_SDC_PRODUCT=str(PROJECT / "Plex.sdc"),
                           FRAMEWORK_SDC_HELPER=str(PROJECT / "sys/framework_cdc.sdc"))
                script = "if {[catch {\n" + harness.read_text() + "\n} message]} {puts stderr $message; exit 1}\n"
                result = subprocess.run(interpreter, input=script, text=True, env=env,
                                        capture_output=True, timeout=60)
                log = result.stdout + result.stderr
                (output / f"{rate}-{case}.log").write_text(log)
                self.assertEqual(result.returncode, 0, log)
                self.assertIn("PASS", log)
        self.assertEqual(before, {str(Path(p)): identity(Path(p)) for p in before})

    def test_framework_control_pll(self):
        output = Path(os.environ.get("FRAMEWORK_CONTROL_OUTPUT", str(OUTPUT / "framework-control"))).resolve() / "pll"
        work = output / "ghdl"
        work.mkdir(parents=True)
        source = PROJECT / "sys/pll_hdmi_adj.vhd"
        bench = ROOT / "tests/rtl/fpga_sys_top_elaboration/pll_mode_tb.vhd"
        self.assertEqual(len(re.findall(r"\bllena\b", source.read_text(), re.I)), 2,
                         "Raw mode must only appear at its port and first synchronizer")
        before = {str(p): identity(p) for p in (source, bench)}
        ghdl = str(Path.home() / ".local/oss-cad-suite/bin/ghdl")
        common = ["--std=08", f"--workdir={work}"]
        commands = [
            [ghdl, "-a", *common, str(source), str(bench)],
            [ghdl, "-e", *common, "-o", str(work / "pll_mode_tb"), "pll_mode_tb"]]
        for rate in (85, 20):
            for phase in (37, 3001):
                commands.append([str(work / "pll_mode_tb"), f"-gSYS_MHZ={rate}",
                                 f"-gPHASE={phase}", f"--vcd={output / f'{rate}-{phase}.vcd'}",
                                 "--assert-level=error", "--ieee-asserts=disable-at-0"])
        (output / "commands.json").write_text(json.dumps(commands, indent=2) + "\n")
        (output / "inputs.json").write_text(json.dumps(before, indent=2) + "\n")
        for index, command in enumerate(commands):
            log = output / f"{index}.log"
            with log.open("w") as stream:
                result = subprocess.run(command, cwd=ROOT, stdout=stream,
                                        stderr=subprocess.STDOUT, timeout=180)
            self.assertEqual(result.returncode, 0, "\n".join(log.read_text().splitlines()[-30:]))
        counts = {}
        for wave in sorted(output.glob("*.vcd")):
            scope, names, values = [], {}, {}
            previous = {"clk": "0", "reset_na": "0"}
            expected_meta = expected_sync = "0"
            edges = 0
            wanted = {"clk", "reset_na", "llena", "llena_meta", "llena_sync"}
            def check():
                nonlocal expected_meta, expected_sync, previous, edges
                if set(values) != wanted:
                    return
                if values["reset_na"] == "0":
                    expected_meta = expected_sync = "0"
                elif values["clk"] == "1" and previous["clk"] == "0":
                    expected_sync, expected_meta = expected_meta, values["llena"]
                    edges += 1
                self.assertEqual(values["llena_meta"], expected_meta, str(wave))
                self.assertEqual(values["llena_sync"], expected_sync, str(wave))
                previous = dict(values)
            for line in wave.read_text().splitlines():
                words = line.split()
                if not words:
                    continue
                if words[0] == "$scope":
                    scope.append(words[2])
                elif words[0] == "$upscope":
                    scope.pop()
                elif words[0] == "$var" and scope == ["pll_mode_tb", "dut"] and words[4] in wanted:
                    names[words[3]] = words[4]
                elif line.startswith("#"):
                    check()
                elif line[0] in "01xXzZuU" and line[1:] in names:
                    values[names[line[1:]]] = line[0]
            check()
            self.assertEqual(set(names.values()), wanted)
            self.assertGreater(edges, 60)
            counts[wave.name] = edges
        (output / "checked-clock-edges.json").write_text(json.dumps(counts, indent=2) + "\n")
        self.assertEqual(len(counts), 4)
        self.assertEqual(before, {str(Path(p)): identity(Path(p)) for p in before})

    def test_framework_control_palette(self):
        output = Path(os.environ.get("FRAMEWORK_CONTROL_OUTPUT", str(OUTPUT / "framework-control"))).resolve() / "palette"
        output.mkdir(parents=True)
        sources = [PROJECT / "sys/scaler_palette.sv", PROJECT / "sys/ddr_svc.sv",
                   ROOT / "tests/rtl/fpga_sys_top_elaboration/scaler_palette_tb.sv"]
        before = {str(p): identity(p) for p in sources}
        commands = []
        for rate in (85, 20):
            for phase in (37, 3001):
                directory = output / f"{rate}-{phase}"
                directory.mkdir()
                commands += [[
                    "verilator", "--binary", "--timing", "--assert", "-j", "2", "-Wno-fatal",
                    "--top-module", "scaler_palette_tb", f"-GSYS_MHZ={rate}", f"-GPHASE={phase}",
                    "--Mdir", str(directory), "-o", "palette-test", *map(str, sources)],
                    [str(directory / "palette-test")]]
        (output / "commands.json").write_text(json.dumps(commands, indent=2) + "\n")
        (output / "inputs.json").write_text(json.dumps(before, indent=2) + "\n")
        for index, command in enumerate(commands):
            log = output / f"{index}.log"
            with log.open("w") as stream:
                result = subprocess.run(command, cwd=ROOT, stdout=stream,
                                        stderr=subprocess.STDOUT, timeout=180)
            self.assertEqual(result.returncode, 0, "\n".join(log.read_text().splitlines()[-30:]))
            if index % 2:
                self.assertIn("PASS actual palette/ddr_svc: loads=4 words=512 audio=1", log.read_text())
        self.assertEqual(before, {str(Path(p)): identity(Path(p)) for p in before})

    def test_framework_ascal_config(self):
        output = Path(os.environ.get("FRAMEWORK_GHDL_OUTPUT", str(OUTPUT / "framework-ascal"))).resolve()
        work = output / "ghdl"
        work.mkdir(parents=True)
        source = PROJECT / "sys/ascal.vhd"
        bench = ROOT / "tests/rtl/fpga_sys_top_elaboration/ascal_config_tb.vhd"
        before = {str(p): identity(p) for p in (source, bench)}
        # Add observations only; keep every assignment in the actual module.
        monitor = r"""
  check_input_image:process(i_clk,i_reset_na)
    variable valid : boolean := false;
    variable image : unsigned(269 downto 0);
    variable tag : std_logic := '0';
  begin
    if i_reset_na='0' then valid:=false; tag:='0';
    elsif rising_edge(i_clk) then
      if valid then
        assert i_mode=image(125 downto 121) and i_format=image(120 downto 119)
          and i_freeze=image(27) and i_bob_deint=image(26)
          and i_ohsize=to_integer(image(209 downto 198))-to_integer(image(221 downto 210))+1
          and i_ovsize=to_integer(image(137 downto 126))-to_integer(image(149 downto 138))+1
          report "Input image packing/window changed between frame boundaries" severity failure;
        if tag/=cfg_req and not (i_pce='1' and i_pvs='1' and i_vs_pre='0') then
          report "PASS input image controls at midframe descriptor";
        end if;
      end if;
      if i_pce='1' and (not valid or
        (i_pvs='1' and i_vs_pre='0' and (i_inter='0' or i_pfl='0'))) then
        image:=cfg_data; valid:=true;
      end if;
      tag:=cfg_req;
    end if;
  end process;
"""
        text = source.read_text()
        match = list(re.finditer(r"(?im)^END\s+ARCHITECTURE", text))
        self.assertEqual(len(match), 1)
        observed = output / "ascal_assertions.vhd"
        observed.write_text(text[:match[0].start()] + monitor + text[match[0].start():])
        (output / "assert-only-instrumentation.json").write_text(json.dumps({
            "source": identity(source), "observed": identity(observed),
            "added_text": monitor, "product_assignments_modified": False,
            "limit": "Input control cadence checked; input RGB is blank, output RGB remains real."
        }, indent=2) + "\n")
        ghdl = str(Path.home() / ".local/oss-cad-suite/bin/ghdl")
        common = ["--std=08", f"--workdir={work}"]
        commands = [
            [ghdl, "-a", *common, str(observed), str(bench)],
            [ghdl, "-e", *common, "-o", str(work / "ascal_config_tb"), "ascal_config_tb"]]
        for rate in (85, 20):
            for phase in (37, 3001):
                commands.append([str(work / "ascal_config_tb"), f"-gSYS_MHZ={rate}",
                                 f"-gPHASE={phase}", "--assert-level=error",
                                 "--ieee-asserts=disable-at-0"])
        (output / "commands.json").write_text(json.dumps(commands, indent=2) + "\n")
        (output / "inputs.json").write_text(json.dumps(before, indent=2) + "\n")
        for index, command in enumerate(commands):
            log = output / f"{index}.log"
            if index < 2:
                with log.open("w") as stream:
                    code = subprocess.run(command, cwd=ROOT, stdout=stream,
                                          stderr=subprocess.STDOUT, timeout=180).returncode
            else:
                warnings = 0
                raw_hash = hashlib.sha256()
                with log.open("w") as stream, gzip.open(str(log) + ".gz", "wb", compresslevel=1) as raw_log:
                    child = subprocess.Popen(command, cwd=ROOT, stdout=subprocess.PIPE,
                                             stderr=subprocess.STDOUT)
                    timer = threading.Timer(180, child.kill)
                    timer.start()
                    try:
                        for line in child.stdout:
                            raw_log.write(line)
                            raw_hash.update(line)
                            if b"(assertion warning): NUMERIC_STD." in line:
                                warnings += 1
                            else:
                                stream.write(line.decode(errors="replace"))
                        code = child.wait()
                    finally:
                        timer.cancel()
                        timer.join()
                        child.stdout.close()
                    stream.write(f"Retained {warnings} numeric warnings in {log.name}.gz; "
                                 f"complete raw SHA256 {raw_hash.hexdigest()}\n")
            self.assertEqual(code, 0, "\n".join(log.read_text().splitlines()[-40:]))
            if index >= 2:
                self.assertIn("PASS actual ascal configuration:", log.read_text())
                self.assertGreaterEqual(log.read_text().count("PASS input image controls at midframe"), 4)
        self.assertEqual(before, {str(Path(p)): identity(Path(p)) for p in before})

    def test_framework_control_source(self):
        output = Path(os.environ.get("FRAMEWORK_TEST_OUTPUT", str(OUTPUT / "framework-source"))).resolve()
        output.mkdir(parents=True, exist_ok=True)
        source = PROJECT / "sys/scaler_config.sv"
        math = PROJECT / "sys/math.sv"
        bench = ROOT / "tests/rtl/fpga_sys_top_elaboration/scaler_config_tb.sv"
        before = {str(p): identity(p) for p in (source, math, bench)}
        commands = []
        for rate in (85, 20):
            for phase in (37, 3001):
                directory = output / f"{rate}-{phase}"
                directory.mkdir()
                compile_command = [
                    "verilator", "--binary", "--timing", "--assert", "-j", "2",
                    "-Wno-fatal", "--top-module", "scaler_config_tb",
                    f"-GSYS_MHZ={rate}", f"-GPHASE={phase}",
                    "--Mdir", str(directory), "-o", "source-test",
                    str(source), str(math), str(bench)]
                commands += [compile_command, [str(directory / "source-test")]]
        (output / "commands.json").write_text(json.dumps(commands, indent=2) + "\n")
        (output / "inputs.json").write_text(json.dumps(before, indent=2) + "\n")
        for index, command in enumerate(commands):
            log = output / f"{index}.log"
            with log.open("w") as stream:
                result = subprocess.run(command, cwd=ROOT, stdout=stream,
                                        stderr=subprocess.STDOUT, timeout=180)
            self.assertEqual(result.returncode, 0, log.read_text())
            if index % 2:
                self.assertIn("PASS actual scaler_config: 12 command/AR/held/reset cases", log.read_text())
        self.assertEqual(before, {str(Path(p)): identity(Path(p)) for p in before})

    def test_ascal_burst_terminal_pipeline(self):
        source = PROJECT / "sys/ascal.vhd"
        reference = ROOT / "tests/rtl/ascal_c4e.vhd"
        output = OUTPUT / "ascal-burst"
        work, scratch = output / "ghdl", output / "compiler-scratch"
        work.mkdir(parents=True, exist_ok=True)
        scratch.mkdir(exist_ok=True)
        before = {str(p): identity(p) for p in
                  (source, reference, Path(__file__), Path(helpers.__file__))}
        (output / "inputs.json").write_text(json.dumps(before, indent=2) + "\n")
        bench = output / "ascal_burst_tb.vhd"
        projection = output / "actual-terminal-in-reference.vhd"
        helpers.arithmetic_projection(reference, source, projection, "burst")
        helpers.write_ascal_burst_tb(reference, projection, bench)
        (output / "projection.json").write_text(json.dumps({
            "source": identity(source), "projection": identity(projection),
            "scope": "Actual terminal declarations/capture/decision/FSM; whole framework is separately tested",
            "assertions_or_budget_changed": False}, indent=2) + "\n")
        ghdl = str(Path.home() / ".local/oss-cad-suite/bin/ghdl")
        common = ["--std=08", f"--workdir={work}"]
        env = dict(os.environ, TMPDIR=str(scratch), TMP=str(scratch), TEMP=str(scratch))
        commands = [
            [ghdl, "-a", *common, str(source), str(bench)],
            [ghdl, "-e", *common, "-o", str(work / "ascal_burst_tb"), "ascal_burst_tb"],
            [str(work / "ascal_burst_tb"), "--assert-level=error"],
        ]
        (output / "commands.json").write_text(json.dumps(commands, indent=2) + "\n")
        for index, command in enumerate(commands):
            with (output / f"{index}.log").open("w") as log:
                result = subprocess.run(command, cwd=ROOT, env=env, stdout=log,
                                        stderr=subprocess.STDOUT, timeout=180)
            self.assertEqual(result.returncode, 0, (output / f"{index}.log").read_text())
        self.assertIn("PASS burst terminal: 8192 cycles", (output / "2.log").read_text())
        self.assertEqual(before, {str(Path(p)): identity(Path(p)) for p in before})

    def test_ascal_fraction_pipeline(self):
        source = Path(os.environ["ASCAL_SOURCE"]).resolve()
        reference = Path(os.environ["ASCAL_REFERENCE_SOURCE"]).resolve()
        output = Path(os.environ["ASCAL_FRACTION_OUTPUT"]).resolve()
        output.mkdir(parents=True, exist_ok=True)
        work, scratch = output / "ghdl", output / "compiler-scratch"
        work.mkdir(exist_ok=True)
        scratch.mkdir(exist_ok=True)
        before = {str(p): identity(p) for p in
                  (source, reference, Path(__file__), Path(helpers.__file__))}
        (output / "inputs.json").write_text(json.dumps(before, indent=2) + "\n")
        bench = output / "ascal_fraction_tb.vhd"
        projection = output / "actual-hscal-in-reference.vhd"
        helpers.arithmetic_projection(reference, source, projection, "fraction")
        helpers.write_ascal_fraction_tb(reference, projection, bench)
        (output / "projection.json").write_text(json.dumps({
            "source": identity(source), "projection": identity(projection),
            "scope": "Actual whole HSCAL/fraction arithmetic; reference OSWEEP control, not current reset bootstrap",
            "assertions_or_budget_changed": False}, indent=2) + "\n")
        ghdl = os.environ.get("GHDL") or str(Path.home() / ".local/oss-cad-suite/bin/ghdl")
        env = dict(os.environ, TMPDIR=str(scratch), TMP=str(scratch), TEMP=str(scratch),
                   OMP_NUM_THREADS="1", MAKEFLAGS="-j1")
        common = ["--std=08", f"--workdir={work}"]
        commands = [
            [ghdl, "-a", *common, str(source), str(bench)],
            [ghdl, "-e", *common, "-o", str(work / "ascal_fraction_tb"), "ascal_fraction_tb"],
        ]
        for frac in range(4, 9):
            for width in (1024, 2048, 2304, 2560, 4096):
                commands.append([str(work / "ascal_fraction_tb"), f"-gFRAC={frac}",
                                 f"-gOHRES={width}", "--assert-level=error",
                                 "--ieee-asserts=disable-at-0"])
        (output / "commands.json").write_text(json.dumps(commands, indent=2) + "\n")
        for index, command in enumerate(commands):
            log = output / f"{index}.log"
            with log.open("w") as stream:
                result = subprocess.run(command, cwd=ROOT, env=env, stdout=stream,
                                        stderr=subprocess.STDOUT, timeout=180, check=False)
            self.assertEqual(result.returncode, 0, log.read_text())
            if index >= 2:
                self.assertIn("PASS fraction arithmetic: 167936 exact pairs", log.read_text())
                self.assertIn("PASS HSCAL/OSWEEP phase: 32768 cycles, 12 frames", log.read_text())
        self.assertEqual(before, {str(Path(p)): identity(Path(p)) for p in before})

    def test_ascal_sweep_pipeline(self):
        source = PROJECT / "sys/ascal.vhd"
        reference = ROOT / "reference/sys/ascal.vhd"
        output = ROOT / "build/verilator/ascal-sweep"
        work, scratch = output / "ghdl", output / "compiler-scratch"
        work.mkdir(parents=True, exist_ok=True)
        scratch.mkdir(exist_ok=True)
        before = {str(path): identity(path) for path in (source, reference)}
        (output / "inputs.json").write_text(json.dumps(before, indent=2) + "\n")
        bench = output / "ascal_sweep_tb.vhd"
        helpers.write_ascal_sweep_tb(reference, source, bench)
        ghdl = str(Path.home() / ".local/oss-cad-suite/bin/ghdl")
        env = dict(os.environ, TMPDIR=str(scratch), TMP=str(scratch), TEMP=str(scratch),
                   OMP_NUM_THREADS="1", MAKEFLAGS="-j1")
        common = ["--std=08", f"--workdir={work}"]
        commands = (
            [ghdl, "-a", *common, str(source), str(bench)],
            [ghdl, "-e", *common, "-o", str(work / "ascal"), "ascal"],
            [ghdl, "-e", *common, "-o", str(work / "ascal_sweep_tb"), "ascal_sweep_tb"],
            [str(work / "ascal_sweep_tb"), "--assert-level=error", "--ieee-asserts=disable-at-0"],
        )
        for index, command in enumerate(commands):
            log = output / f"{index}.log"
            with log.open("w") as stream:
                result = subprocess.run(command, cwd=ROOT, env=env, stdout=stream,
                                        stderr=subprocess.STDOUT, check=False)
            self.assertEqual(result.returncode, 0, log.read_text())
        self.assertIn("PASS sweep arithmetic: 16777216", (output / "3.log").read_text())
        self.assertIn("PASS sweep pipeline: 65536", (output / "3.log").read_text())
        self.assertEqual(before, {str(path): identity(path) for path in (source, reference)})

    def test_ascal_timing_pipeline(self):
        source = Path(os.environ.get("ASCAL_SOURCE", str(PROJECT / "sys/ascal.vhd"))).resolve()
        output = Path(os.environ.get("ASCAL_TEST_OUTPUT", str(OUTPUT / "ascal-timing"))).resolve()
        output.mkdir(parents=True, exist_ok=True)
        work, scratch = output / "ghdl", output / "compiler-scratch"
        work.mkdir(exist_ok=True)
        scratch.mkdir(exist_ok=True)
        env = dict(os.environ, TMPDIR=str(scratch), TMP=str(scratch),
                   TEMP=str(scratch), OMP_NUM_THREADS="1", MAKEFLAGS="-j1")
        before = identity(source)
        reference = os.environ.get("ASCAL_REFERENCE_SOURCE")
        inputs = {str(source): before, str(Path(__file__)): identity(Path(__file__)),
                  str(Path(helpers.__file__)): identity(Path(helpers.__file__))}
        if reference:
            def unchanged_regions(path):
                text = helpers.ascal_fraction_unchanged(path.read_text())
                text = text.replace(helpers.ascal_vertical_edge_stages(text), "")
                text = re.sub(r"\tSIGNAL o_vpix_past, o_vpix_last : boolean;\n", "", text)
                return (text[:text.index("-- Polyphase")],
                        text[text.index("FUNCTION poly_cvt"):text.index("-- C5 / HC5 / VC6")],
                        text[text.index("-- C8 / HC8 / VC9"):])
            self.assertEqual(unchanged_regions(source), unchanged_regions(Path(reference)),
                             "Unrelated scaler, format, DE/sync or output logic changed")
            inputs[str(Path(reference).resolve())] = identity(Path(reference))
        (output / "inputs.json").write_text(json.dumps(inputs, indent=2) + "\n")
        ghdl = os.environ.get("GHDL") or str(
            Path(os.environ.get("OSS_CAD_SUITE", str(Path.home() / ".local/oss-cad-suite")))
            / "bin/ghdl")
        if not Path(ghdl).is_file():
            ghdl = shutil.which("ghdl")
        self.assertTrue(ghdl, "GHDL missing; no VHDL blackbox fallback")
        bench = output / "ascal_timing_tb.vhd"
        helpers.write_ascal_timing_tb(source, bench)
        common = ["--std=08", f"--workdir={work}"]
        commands = (
            [ghdl, "-a", *common, str(source), str(bench)],
            [ghdl, "-e", *common, "-o", str(work / "ascal"), "ascal"],
            [ghdl, "-e", *common, "-o", str(work / "ascal_timing_tb"), "ascal_timing_tb"],
            [str(work / "ascal_timing_tb"), "--assert-level=error", "--ieee-asserts=disable-at-0"],
        )
        for index, command in enumerate(commands):
            log = output / f"{index}.log"
            with log.open("w") as stream:
                result = subprocess.run(command, cwd=ROOT, env=env, stdout=stream,
                                        stderr=subprocess.STDOUT, timeout=180, check=False)
            self.assertEqual(result.returncode, 0, log.read_text())
        self.assertIn("PASS adaptive pipeline: 851972 cycles", (output / "3.log").read_text())
        self.assertIn("PASS pixel mux: 8192 cycles", (output / "3.log").read_text())
        self.assertIn("PASS vertical edge: 114690 cycles", (output / "3.log").read_text())
        self.assertEqual(identity(source), before, "Scaler source changed during simulation")

    def test_real_sys_top_baseline_and_fpga320(self):
        OUTPUT.mkdir(parents=True, exist_ok=True)
        work = OUTPUT / "ghdl"
        scratch = OUTPUT / "compiler-scratch"
        work.mkdir(exist_ok=True)
        scratch.mkdir(exist_ok=True)
        env = dict(os.environ, TMPDIR=str(scratch), TMP=str(scratch),
                   TEMP=str(scratch), OMP_NUM_THREADS="2", MAKEFLAGS="-j2")
        report = {
            "top": "sys_top", "status": "running", "commands": [], "modes": {},
            "limitations": [
                "Elaboration only: no clocks simulated, synthesis/fit/timing or HDMI qualification.",
                "Intel hard interfaces have exact declarations, not behavioral models.",
                "BUILD_DATE uses existing parity helper's lint placeholder.",
            ],
        }
        before = source_identities()
        (OUTPUT / "source-hashes-before.json").write_text(json.dumps(before, indent=2) + "\n")

        def run(command, log, stdout=None):
            record = {"argv": [str(arg) for arg in command], "log": str(log),
                      "started": time.time()}
            report["commands"].append(record)
            with log.open("w") as errors:
                if stdout:
                    with stdout.open("w") as stream:
                        proc = subprocess.run(command, cwd=ROOT, env=env, stdout=stream,
                                              stderr=errors, timeout=240, check=False)
                else:
                    proc = subprocess.run(command, cwd=ROOT, env=env, stdout=errors,
                                          stderr=subprocess.STDOUT, timeout=240, check=False)
            record.update(returncode=proc.returncode, seconds=time.time() - record["started"])
            return proc.returncode

        try:
            sources = rtl_lint.discover_sources()
            self.assertIn(PROJECT / "sys/sys_top.v", sources)
            self.assertIn(PROJECT / "sys/alsa.sv", sources)
            self.assertIn(PROJECT / "sys/sysmem.sv", sources)
            self.assertIn(PROJECT / "Plex.sv", sources)
            vhdl = [PROJECT / "sys/ascal.vhd", PROJECT / "sys/pll_hdmi_adj.vhd"]
            # Discovery intentionally traverses both checked-in PLL QIPs. Record
            # that fact, and let duplicate definitions fail rather than hide them.
            report["sources"] = [str(p.relative_to(ROOT)) for p in sources + vhdl]
            report["pll_qips"] = ["sys/pll_q13.qip", "sys/pll_q17.qip"]
            qsf_macros = check_define_parity.verilator_lint_macros()
            coherent = os.environ.get("FRAMEWORK_FINAL_TOP") == "1"
            expected = {"DDR_FRAME_STORE": "1", "FRAME_W": "640", "FRAME_H": "480",
                        "FRAME_LINES_8": "1", "SDRAM_CLK_142": "1", "SDRAM_CL3": "1"}
            if coherent:
                expected.update(FPGA_VIDEO_320="1", CAVLC_WINDOW_BYTES="8",
                                CAVLC_LEVEL_LANES="1", PLEX_H264_INTER="1",
                                PLEX_H264_FRAME_DEBLOCK="1", PLEX_CLK_SYS_85="1")
            for key, value in expected.items():
                self.assertIn(key, qsf_macros)
                self.assertEqual(qsf_macros[key].value, value, key)
            forbidden = {"MISTER_DEBUG_NOHDMI", "MISTER_DISABLE_ALSA", "MISTER_FB",
                         "MISTER_SMALL_VBUF", "MISTER_DISABLE_ADAPTIVE", "MENU_CORE",
                         "MISTER_DOWNSCALE_NN", "PLEX_PRESENT_720P_L4",
                         "PLEX_HD_960", "PLEX_HD_MULTIPIXEL"}
            self.assertFalse(forbidden.intersection(qsf_macros),
                             f"Unsupported QSF configuration: {forbidden.intersection(qsf_macros)}")
            if not coherent:
                self.assertNotIn("FPGA_VIDEO_320", qsf_macros,
                                 "Baseline requires the candidate macro to remain disabled in QSF")
            self.assertEqual(set(qsf_macros), set(expected) | {"BUILD_DATE"},
                             "This gate requires the stated baseline QSF feature set")
            defines = check_define_parity.verilator_define_args()
            report["baseline_defines"] = defines
            profile_contracts = {
                "Plex.sv": (
                    ".ENABLE_AU_PROTOCOL(STREAM_AU_PROTOCOL)",
                    ".ENABLE_PICTURE_PUBLISH(FPGA320_CONFIG)",
                    ".IDR_ONLY_PROFILE(FPGA320_CONFIG)", ".VIDEO_FEATURES(32'd0)",
                    "localparam bit STREAM_AU_PROTOCOL = FPGA320_CONFIG;",
                ),
                "rtl/stream_path.sv": (
                    "parameter bit LEGACY_SLICE_DIAGNOSTIC = !ENABLE_AU_PROTOCOL",
                    "localparam int RBSP_ADDR_W = LEGACY_SLICE_DIAGNOSTIC ? 13 : 16;",
                    "localparam int RBSP_BYTES = 1 << RBSP_ADDR_W;",
                    ".NATIVE_PUBLISH_LEASE(ENABLE_PICTURE_PUBLISH)",
                    ".STATIC_IDR_ONLY(IDR_ONLY_PROFILE)",
                ),
            }
            if coherent:
                profile_contracts = {
                    "Plex.sv": (".ENABLE_AU_PROTOCOL(STREAM_AU_PROTOCOL)",
                                ".ENABLE_PICTURE_PUBLISH(FPGA320_CONFIG)",
                                ".VIDEO_FEATURES(VIDEO_FUNCTIONAL_FEATURES)",
                                ".IDR_ONLY_PROFILE(H264_STATIC_IDR)"),
                    "rtl/stream_path.sv": (".RBSP_ADDR_W(13)",
                                          ".NATIVE_PUBLISH_LEASE(ENABLE_PICTURE_PUBLISH)",
                                          ".STATIC_IDR_ONLY(IDR_ONLY_PROFILE)"),
                }
            report["candidate_source_contracts"] = profile_contracts
            for filename, contracts in profile_contracts.items():
                source = "".join(helpers.no_comments((PROJECT / filename).read_text()).split())
                for contract in contracts:
                    self.assertIn("".join(contract.split()), source,
                                  f"Candidate source profile drift: {filename}: {contract}")
            ghdl = os.environ.get("GHDL") or str(
                Path(os.environ.get("OSS_CAD_SUITE", str(Path.home() / ".local/oss-cad-suite")))
                / "bin/ghdl")
            if not Path(ghdl).is_file():
                ghdl = shutil.which("ghdl")
            self.assertTrue(ghdl, "GHDL missing; this gate never substitutes VHDL blackboxes")
            self.assertEqual(run([ghdl, "--version"], OUTPUT / "ghdl-version.log"), 0)
            wrapper = str(ROOT / "scripts/run_verilator.sh")
            self.assertEqual(run([wrapper, "--version"], OUTPUT / "verilator-version.log"), 0)
            common = ["--std=08", f"--workdir={work}"]
            self.assertEqual(run([ghdl, "-a", *common, *map(str, vhdl)],
                                 OUTPUT / "ghdl-analyze.log"), 0, "GHDL analysis failed")
            for entity in ("ascal", "pll_hdmi_adj"):
                self.assertEqual(run([ghdl, "-e", *common, "-o", str(work / entity), entity],
                                     OUTPUT / f"{entity}-elaborate.log"), 0,
                                 f"Real {entity} VHDL elaboration failed")
                specialization = ([f"-g{k}={v}" for k, v in helpers.ASCAL_SPECIALIZATION.items()]
                                  if entity == "ascal" else [])
                self.assertEqual(run([ghdl, "--synth", *common, "--out=verilog",
                                      *specialization, entity],
                                     OUTPUT / f"{entity}-synth.log", OUTPUT / f"{entity}.v"),
                                 0, f"Real {entity} VHDL conversion failed; no blackbox fallback")
                shutil.copyfile(OUTPUT / f"{entity}.v", work / f"{entity}.raw.v")
            report["ghdl_raw_outputs"] = {
                str(path.relative_to(ROOT)): identity(path)
                for path in (work / "ascal.raw.v", work / "pll_hdmi_adj.raw.v")
            }
            adapter = OUTPUT / "ascal_adapter.sv"
            helpers.write_ascal_adapter(vhdl[0], OUTPUT / "ascal.v", adapter)
            vendor_dir = Path(os.environ.get("INTEL_SIM_LIB", str(OUTPUT / "vendor"))).resolve()
            for name in helpers.VENDOR_FILES:
                self.assertTrue((vendor_dir / name).is_file(),
                                f"Missing installed vendor declarations: {vendor_dir / name}")
            vendor_inputs = [vendor_dir / name for name in helpers.VENDOR_FILES]
            optional_debug = vendor_dir / "cyclonev_hps_interface_dbg_apb.v"
            if optional_debug.exists():
                vendor_inputs.append(optional_debug)
            report["vendor_inputs"] = {str(p): identity(p) for p in vendor_inputs}
            provenance = vendor_dir / "provenance.json"
            if provenance.exists():
                report["vendor_provenance"] = json.loads(provenance.read_text())
            vendor = OUTPUT / "intel_interfaces.sv"
            report["vendor_interface_only_modules"] = helpers.write_vendor_interfaces(
                vendor_dir, vendor, PROJECT / "sys/sysmem.sv")
            report["vendor_real_body_modules"] = ["altera_std_synchronizer"]
            if not optional_debug.exists():
                report["legacy_debug_atom_boundary"] = (
                    "Installed Quartus 17 declarations omit cyclonev_hps_interface_dbg_apb; "
                    "only its exact checked-in generated sysmem two-scalar-input instance "
                    "(DBG_APB_DISABLE=0,P_CLK_EN=0,no outputs) supplies the interface declaration. "
                    "Any connection change fails. No behavior or public vendor-header coverage claimed."
                )
            generated = [vendor, adapter, OUTPUT / "ascal.v", OUTPUT / "pll_hdmi_adj.v"]
            report["generated"] = {str(p.relative_to(ROOT)): identity(p) for p in generated}
            failures = []
            for mode in (("coherent",) if coherent else ("baseline", "fpga320")):
                directory = OUTPUT / mode
                directory.mkdir(exist_ok=True)
                netlist = directory / "sys_top.tree.json"
                if netlist.exists():
                    netlist.unlink()
                mode_defines = defines + (["-DFPGA_VIDEO_320=1"] if mode == "fpga320" else [])
                command = [
                    wrapper, "--json-only", "--json-only-output", str(netlist),
                    "--timing", "--assert", "-j", "2", "--Mdir", str(directory),
                    "--top-module", "sys_top", "-Wno-fatal", "-Werror-MODDUP",
                    "-Werror-USERERROR", f"-I{PROJECT}", f"-I{PROJECT / 'sys'}",
                    f"-I{PROJECT / 'rtl'}",
                    f"-I{ROOT / 'tests/rtl/fpga_sys_top_elaboration'}", *mode_defines,
                    *map(str, generated), *map(str, sources),
                ]
                log = OUTPUT / f"{mode}.log"
                status = run(command, log)
                errors = [line for line in log.read_text().splitlines() if line.startswith("%Error")]
                assignin = [line for line in errors if line.startswith("%Error-ASSIGNIN:")]
                if coherent and status and len(errors) == 2 and len(assignin) == 1:
                    # Verilator treats the existing all-Z unused ADC inout as
                    # a drive of the board's input-only SDO. First require that
                    # precise sole diagnostic; never mask other input drivers.
                    self.assertIn("sys/sys_top.v:", assignin[0])
                    self.assertTrue(assignin[0].endswith("Assigning to input/const variable: 'ADC_SDO'"))
                    self.assertRegex((PROJECT / "Plex.sv").read_text(), r"assign\s+ADC_BUS\s*=\s*'Z\s*;")
                    shutil.copyfile(log, OUTPUT / f"{mode}-adc-direction-diagnostic.log")
                    report["unused_adc_frontend_limit"] = assignin
                    status = run(command + ["-Wno-ASSIGNIN"], log)
                    errors = [line for line in log.read_text().splitlines() if line.startswith("%Error")]
                report["modes"][mode] = {"returncode": status, "errors": errors, "defines": mode_defines}
                if status:
                    failures.append(f"{mode}: " + "\n".join(errors or ["see " + str(log)]))
                    continue
                module_nodes = [node for node in nodes(json.loads(netlist.read_text()))
                                if node.get("type") == "MODULE"]
                modules = {node["origName"] for node in module_nodes}
                report["modes"][mode]["elaborated_modules"] = sorted(modules)
                required = {"sys_top", "emu", "ascal", "ascal_ghdl", "pll_hdmi_adj",
                            "alsa", "sysmem_lite", "hps_io", "audio_out", "stream_path"}
                if mode in ("fpga320", "coherent"):
                    required |= {"fpga_video_publish", "ddr_frame_store",
                                 "audio_session_mailbox", "playback_overlay_plane",
                                 "ddr_bus_arbiter", "h264_mb_ctrl", "h264_slice_rbsp_ram"}
                if coherent:
                    required |= {"scaler_config", "scaler_palette", "video_calc",
                                 "video_measurement_cdc", "video_measurement_event_join", "ddr_svc"}
                missing = required - modules
                if missing:
                    failures.append(f"{mode}: required real hierarchy missing: {sorted(missing)}")
                profiles = {node["origName"]: parameters(node) for node in module_nodes
                            if node["origName"] in {"stream_path", "h264_mb_ctrl"}}
                report["modes"][mode]["profile_parameters"] = profiles
                candidate = int(mode == "fpga320")
                checks = {
                    "stream_path": {
                        "ENABLE_AU_PROTOCOL": candidate, "ENABLE_PICTURE_PUBLISH": candidate,
                        "IDR_ONLY_PROFILE": candidate, "VIDEO_FEATURES": 0,
                        "RBSP_ADDR_W": 16 if candidate else 13,
                        "RBSP_BYTES": 65536 if candidate else 8192,
                        "RBSP_BIT_W": 20 if candidate else 17,
                        "INPUT_FIFO_BYTES": 65536 if candidate else 32768,
                    },
                    "h264_mb_ctrl": {
                        "STATIC_IDR_ONLY": candidate, "NATIVE_PUBLISH_LEASE": candidate,
                        "RBSP_ADDR_W": 16 if candidate else 13,
                        "RBSP_LEN_W": 17 if candidate else 14,
                        "RBSP_BIT_W": 20 if candidate else 17,
                        "RBSP_MAX": 65536 if candidate else 8192,
                    },
                }
                if coherent:
                    checks = {
                        "stream_path": {
                            "ENABLE_AU_PROTOCOL": 1, "ENABLE_PICTURE_PUBLISH": 1,
                            "IDR_ONLY_PROFILE": 0, "VIDEO_FEATURES": 0xe1ff,
                            "ENABLE_FRAME_DEBLOCK": 1, "MAX_AU_BYTES": 8192,
                            "ENCODED_AU_LIMIT": 8192, "INPUT_FIFO_BYTES": 32768,
                        },
                        "h264_mb_ctrl": {
                            "STATIC_IDR_ONLY": 0, "NATIVE_PUBLISH_LEASE": 1,
                            "RBSP_ADDR_W": 13, "RBSP_LEN_W": 14,
                            "RBSP_BIT_W": 17, "RBSP_MAX": 8192,
                        },
                    }
                for module, settings in checks.items():
                    for name, value in settings.items():
                        actual = profiles.get(module, {}).get(name)
                        if actual != value:
                            failures.append(f"{mode}: {module}.{name}={actual}, expected {value}")
            self.assertFalse(failures, "\n".join(failures) + f"\nEvidence: {OUTPUT}")
            report["status"] = "passed"
        except BaseException as error:
            report["status"] = "failed"
            report["failure"] = str(error)
            raise
        finally:
            after = source_identities()
            changed = sorted(key for key in before.keys() | after.keys()
                             if before.get(key) != after.get(key))
            report["mutated_sources"] = changed
            if changed:
                report["status"] = "failed"
            (OUTPUT / "source-hashes-after.json").write_text(json.dumps(after, indent=2) + "\n")
            (OUTPUT / "results.json").write_text(json.dumps(report, indent=2) + "\n")
            self.assertFalse(changed, f"Sources mutated during gate; rerun stable inputs: {changed}")


if __name__ == "__main__":
    unittest.main()
