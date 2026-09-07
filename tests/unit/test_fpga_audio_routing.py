#!/usr/bin/env python3
"""Exercise the actual emu audio/aspect boundaries without modeling vendor clocks."""

import os
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
        defines = [
            arg for arg in check_define_parity.verilator_define_args()
            if not arg.startswith("-DFPGA_VIDEO_320")
        ]
        for mode in ("baseline", "fpga320"):
            with self.subTest(mode=mode):
                build = output / mode
                build.mkdir(parents=True, exist_ok=True)
                command = [
                    str(ROOT / "scripts/run_verilator.sh"),
                    "--binary", "--timing", "--assert", "--build", "-j", "1",
                    "--Mdir", str(build), "--top-module", "fpga_audio_routing_tb",
                    "-Wno-fatal", f"-I{project}", f"-I{project / 'rtl'}",
                    f"-I{project / 'sys'}",
                    f"-I{ROOT / 'tests/rtl/fpga_audio_routing'}", *defines,
                ]
                if mode == "fpga320":
                    command += ["-DFPGA_VIDEO_320=1"]
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


if __name__ == "__main__":
    unittest.main()
