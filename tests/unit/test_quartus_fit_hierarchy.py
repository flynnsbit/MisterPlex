#!/usr/bin/env python3
"""Captured-mode hierarchy policy fixtures; never invokes Quartus."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[2]
CHECKER = ROOT / "scripts/check_quartus_fit_hierarchy.py"
CONFIG = ROOT / "tests/fixtures/critical_fit_hierarchy.json"


class HierarchyProfiles(unittest.TestCase):
    def setUp(self):
        self.work = ROOT / "build" / ("hierarchy-policy-" + uuid.uuid4().hex)
        self.work.mkdir(parents=True)
        self.config = json.loads(CONFIG.read_text())

    def tearDown(self):
        shutil.rmtree(self.work)

    def report(self, bits=81920, m10ks=96, registers=500, missing=None):
        rows = ["; Compilation Hierarchy Node ; Full Hierarchy Name ; Entity Name ; "
                "Combinational ALUTs ; Dedicated Logic Registers ; Block Memory Bits ; M10Ks ; DSP Blocks ;"]
        for spec in self.config["modules"]:
            if spec["name"] == missing:
                continue
            frame = spec["name"] == "ddr_frame_store"
            rows.append(
                f"; |{spec['hierarchy_contains']}| ; |sys_top|{spec['hierarchy_contains']} ; {spec['entity']} ; "
                f"{spec.get('min_comb_aluts', 0)} ; {registers if frame else spec.get('min_registers', 0)} ; "
                f"{bits if frame else 0} ; {m10ks if frame else 0} ; 0 ;")
        path = self.work / "Plex.fit.rpt"
        path.write_text("\n".join(rows) + "\n")
        return path

    def check(self, qsf=None, bad_hash=False, no_manifest=False, extra=(), **resources):
        args = [sys.executable, str(CHECKER), "--fit-rpt", str(self.report(**resources)), *extra]
        if qsf is not None:
            path = self.work / "Plex.qsf"
            path.write_text(qsf)
            manifest = self.work / "inputs.json"
            manifest.write_text(json.dumps({"input_files": {
                "Plex.qsf": "0" * 64 if bad_hash else hashlib.sha256(path.read_bytes()).hexdigest()}}))
            args.extend(("--qsf", str(path)))
            if not no_manifest:
                args.extend(("--input-manifest", str(manifest)))
        return subprocess.run(args, text=True, capture_output=True)

    def test_baseline_floor_is_unchanged(self):
        frame = next(spec for spec in self.config["modules"] if spec["name"] == "ddr_frame_store")
        self.assertEqual(frame["min_block_memory_bits"], 100000)
        result = self.check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("required 100000", result.stderr)
        self.assertEqual(self.check(bits=100000).returncode, 0)

    def test_only_captured_enabled_macro_selects_fpga320(self):
        enabled = 'set_global_assignment -name VERILOG_MACRO "FPGA_VIDEO_320=1"\n'
        result = self.check(qsf=enabled)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PROFILE: fpga320", result.stdout)
        for qsf in ("#" + enabled, enabled.replace("=1", "=0"), "# no feature macro\n"):
            result = self.check(qsf=qsf)
            self.assertEqual(result.returncode, 1)
            self.assertIn("PROFILE: baseline", result.stdout)
        self.assertEqual(self.check(qsf=enabled, bad_hash=True).returncode, 4)
        self.assertEqual(self.check(qsf=enabled, no_manifest=True).returncode, 4)
        self.assertEqual(self.check(qsf=enabled + enabled.replace("=1", "=0")).returncode, 4)

    def test_fpga320_keeps_presence_register_and_m10k_floors(self):
        qsf = 'set_global_assignment -name VERILOG_MACRO "FPGA_VIDEO_320=1"\n'
        for resource in ({"bits": 81919}, {"m10ks": 95}, {"registers": 499},
                         {"missing": "ddr_frame_store"}, {"missing": "stream_path"},
                         {"missing": "ddr_bitstream_reader"}):
            with self.subTest(resource=resource):
                result = self.check(qsf=qsf, **resource)
                self.assertEqual(result.returncode, 1, result.stdout)
        result = self.check(qsf=qsf, missing="stream_path", extra=("--allow-missing", "stream_path"))
        self.assertEqual(result.returncode, 4)

    def test_removal_and_comb_loop_guards_still_apply(self):
        log = self.work / "compile.log"
        for text in (
            "Warning: ddr_frame_store removed because output is constant GND\n",
            "Warning (332125): Found combinational loop\n"
            'Warning (332126): Node "present|ddr_frame_store:fstore|comb"\n',
        ):
            log.write_text(text)
            result = self.check(qsf='set_global_assignment -name VERILOG_MACRO "FPGA_VIDEO_320=1"\n',
                                extra=("--log", str(log)))
            self.assertEqual(result.returncode, 1)

    def test_mapped_estimate_cannot_hide_undersized_or_missing_fitted_fpga320(self):
        mapped = self.work / "Plex.map.rpt"
        mapped.write_text(self.report(bits=159744, m10ks=96, registers=2000).read_text())
        qsf = 'set_global_assignment -name VERILOG_MACRO "FPGA_VIDEO_320=1"\n'
        for resources in ({"bits": 81919}, {"missing": "ddr_frame_store"}):
            result = self.check(qsf=qsf, extra=("--map-rpt", str(mapped)), **resources)
            self.assertEqual(result.returncode, 1, result.stdout)


if __name__ == "__main__":
    unittest.main()
