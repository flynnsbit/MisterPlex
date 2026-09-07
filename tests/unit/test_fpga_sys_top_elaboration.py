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
import json
import os
import re
import shutil
import subprocess
import sys
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PROJECT = ROOT / "fpga/Plex_MiSTer"
OUTPUT = ROOT / "build/verilator/fpga_sys_top_elaboration"
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
    def test_ascal_timing_pipeline(self):
        source = Path(os.environ.get("ASCAL_SOURCE", str(PROJECT / "sys/ascal.vhd"))).resolve()
        output = Path(os.environ.get("ASCAL_TEST_OUTPUT", str(OUTPUT / "ascal-timing"))).resolve()
        output.mkdir(parents=True, exist_ok=True)
        work, scratch = output / "ghdl", output / "compiler-scratch"
        work.mkdir(exist_ok=True)
        scratch.mkdir(exist_ok=True)
        env = dict(os.environ, TMPDIR=str(scratch), TMP=str(scratch),
                   TEMP=str(scratch), OMP_NUM_THREADS="2", MAKEFLAGS="-j2")
        before = identity(source)
        reference = os.environ.get("ASCAL_REFERENCE_SOURCE")
        inputs = {str(source): before, str(Path(__file__)): identity(Path(__file__)),
                  str(Path(helpers.__file__)): identity(Path(helpers.__file__))}
        if reference:
            def unchanged_regions(path):
                text = path.read_text()
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
            expected = {"DDR_FRAME_STORE": "1", "FRAME_W": "640", "FRAME_H": "480",
                        "FRAME_LINES_8": "1", "SDRAM_CLK_142": "1", "SDRAM_CL3": "1"}
            for key, value in expected.items():
                self.assertIn(key, qsf_macros)
                self.assertEqual(qsf_macros[key].value, value, key)
            forbidden = {"MISTER_DEBUG_NOHDMI", "MISTER_DISABLE_ALSA", "MISTER_FB",
                         "MISTER_SMALL_VBUF", "MISTER_DISABLE_ADAPTIVE", "MENU_CORE",
                         "MISTER_DOWNSCALE_NN", "PLEX_PRESENT_720P_L4",
                         "PLEX_HD_960", "PLEX_HD_MULTIPIXEL"}
            self.assertFalse(forbidden.intersection(qsf_macros),
                             f"Unsupported QSF configuration: {forbidden.intersection(qsf_macros)}")
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
            for mode in ("baseline", "fpga320"):
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
                if mode == "fpga320":
                    required |= {"fpga_video_publish", "ddr_frame_store",
                                 "audio_session_mailbox", "playback_overlay_plane",
                                 "ddr_bus_arbiter", "h264_mb_ctrl", "h264_slice_rbsp_ram"}
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
