#!/usr/bin/env python3
"""Exercise the actual emu audio/aspect boundaries without modeling vendor clocks."""

import hashlib
import json
import os
import re
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import check_define_parity
import rtl_lint


class AudioRoutingTests(unittest.TestCase):
    def test_native_content_de_connections(self):
        project = ROOT / "fpga/Plex_MiSTer"
        plex = "".join((project / "Plex.sv").read_text().split())
        present = "".join((project / "rtl/present_core.sv").read_text().split())
        for connection in (".de_pix(native_de)", ".de_in(native_de)", "assignVGA_DE=native_de;"):
            self.assertIn(connection, plex)
        self.assertIn(
            "wirede_out=(FPGA_DECODE_320&&use_ext)?frame_de:(~hb_d&~vb_d);", present
        )
        self.assertIn("assignde_pix=de_out;", present)

    def test_legacy_and_dma_only_routing(self):
        project = ROOT / "fpga/Plex_MiSTer"
        output = ROOT / "build/verilator/fpga_audio_routing"
        scratch = output / "compiler-scratch"
        scratch.mkdir(parents=True, exist_ok=True)
        env = dict(os.environ, TMPDIR=str(scratch))
        sources = [p for p in rtl_lint.discover_sources() if not rtl_lint.is_excluded(p)]
        sources += [project / "rtl/pll.v", project / "rtl/pll/pll_0002.v"]
        stub = rtl_lint.write_intel_stubs()
        source_map = {
            str(path.relative_to(project)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(project.rglob("*")) if path.is_file()
        }
        source_id = hashlib.sha256(json.dumps(source_map, sort_keys=True).encode()).hexdigest()
        defines = check_define_parity.verilator_define_args()
        self.assertIn("-DFPGA_VIDEO_320=1", defines)
        self.assertIn("-DPLEX_H264_INTER=1", defines)
        self.assertIn("-DPLEX_H264_FRAME_DEBLOCK=1", defines)
        self.assertIn("-DPLEX_CLK_SYS_120=1", defines)
        defines += [f"-DFPGA_VIDEO_BUILD_ID=32'h{source_id[:8]}"]
        report = {"source_sha256": source_id, "source_map": source_map,
                  "production_defines": defines, "modes": {},
                  "limitations": "Actual emu elaboration/routing; vendor clocks are not modeled. No fit, PCM-rate or hardware acceptance."}
        variants = {
            "baseline": {"FPGA_VIDEO_320"},
            "fpga320": set(),
            "fpga320-idr": {"PLEX_H264_INTER", "PLEX_H264_FRAME_DEBLOCK"},
            "fpga320-inter-no-filter": {"PLEX_H264_FRAME_DEBLOCK"},
            "fpga320-idr-filter": {"PLEX_H264_INTER"},
        }
        profile_pattern = re.compile(
            r"ELAB_PROFILE features=([0-9a-f]+) build_id=([0-9a-f]+) "
            r"max_width=(\d+) max_height=(\d+) max_au_bytes=(\d+) "
            r"idr_only=(\d+) deblock=(\d+)"
        )
        for mode, excluded in variants.items():
            with self.subTest(mode=mode):
                build = output / mode
                build.mkdir(parents=True, exist_ok=True)
                command = [
                    str(ROOT / "scripts/run_verilator.sh"),
                    "--binary", "--timing", "--assert", "--build", "-j", "1",
                    "--Mdir", str(build), "--top-module", "fpga_audio_routing_tb",
                    "-Wno-fatal", f"-I{project}", f"-I{project / 'rtl'}",
                    f"-I{project / 'sys'}",
                    f"-I{ROOT / 'tests/rtl/fpga_audio_routing'}",
                    *(arg for arg in defines if arg[2:].split("=")[0] not in excluded),
                ]
                command += [
                    str(ROOT / "tests/rtl/fpga_audio_routing_tb.sv"),
                    str(stub), *(str(p) for p in sources),
                ]
                log = output / f"{mode}.log"
                with log.open("w") as stream:
                    compile_result = subprocess.run(
                        command, cwd=ROOT, env=env, stdout=stream,
                        stderr=subprocess.STDOUT, check=False,
                    )
                    self.assertEqual(compile_result.returncode, 0, f"compile failed: {log}")
                    result = subprocess.run(
                        [str(build / "Vfpga_audio_routing_tb")], cwd=ROOT, env=env,
                        stdout=stream, stderr=subprocess.STDOUT, check=False,
                    )
                self.assertEqual(result.returncode, 0, f"routing failed: {log}")
                match = profile_pattern.search(log.read_text())
                self.assertIsNotNone(match, f"missing observed actual-emu profile: {log}")
                values = match.groups()
                report["modes"][mode] = dict(zip(
                    ("features", "build_id", "max_width", "max_height", "max_au_bytes",
                     "idr_only", "deblock"),
                    [int(value, 16 if index < 2 else 10)
                     for index, value in enumerate(values)],
                ))
                (output / "bindings.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    unittest.main()
