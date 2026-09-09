#!/usr/bin/env python3
"""Run existing focused audio/framework suites serially under the owner guard."""
import os
from pathlib import Path
import subprocess
import unittest

output = Path(os.environ["AUDIO_BOUNDARY_OUTPUT"])
output.mkdir(parents=True, exist_ok=True)
loader = unittest.TestLoader()
suite = loader.discover("tests/unit", pattern="test_fpga_audio_routing.py")
loader.testNamePatterns = ["*test_framework_constraints"]
suite.addTests(loader.discover("tests/unit", pattern="test_fpga_sys_top_elaboration.py"))
result = unittest.TextTestRunner(verbosity=2).run(suite)
failed = not result.wasSuccessful()
for name in ("test_audio_session.sh", "test_fpga_video_audio_feedback.sh"):
    with (output / (name + ".log")).open("x") as log:
        status = subprocess.run(["bash", "tests/unit/" + name],
                                env=dict(os.environ, AUDIO_REAL_CDC_CASES="1"),
                                stdout=log, stderr=subprocess.STDOUT).returncode
    print(f"EXISTING_SUITE {name} exit={status}", flush=True)
    failed |= status != 0
raise SystemExit(int(failed))
