#!/usr/bin/env python3
"""Static libav loader/capability guard; no network or hardware."""
import importlib.util
from pathlib import Path
import shutil
import subprocess
import unittest
from unittest import mock
import uuid

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "arm_ffmpeg_static", ROOT / "scripts/check_arm_ffmpeg_static.py")
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class StaticLibav(unittest.TestCase):
    def setUp(self):
        self.prefix = ROOT / "build" / ("static-libav-policy-" + uuid.uuid4().hex)
        (self.prefix / "lib").mkdir(parents=True)
        self.addCleanup(shutil.rmtree, self.prefix)
        for archive in guard.ARCHIVES:
            (self.prefix / "lib" / archive).write_bytes(b"!<arch>\n")
        self.symbols = "".join("00000000 T " + name + "\n" for name in guard.REQUIRED)

    def check(self, extra="", code=0):
        result = subprocess.CompletedProcess([], code, self.symbols + extra, "")
        with mock.patch.object(guard.subprocess, "run", return_value=result) as run:
            guard.check_archives(self.prefix, "fixture-arm-nm")
        self.assertEqual(run.call_args.args[0][:2], ["fixture-arm-nm", "-g"])

    def test_safe_complete_archives(self):
        self.check("         U av_malloc\n")

    def test_iconv_and_other_module_loaders_are_refused(self):
        for symbol in guard.MODULE_LOADERS:
            with self.subTest(symbol=symbol):
                with self.assertRaisesRegex(guard.Refused, "runtime module loader"):
                    self.check("         U " + symbol + "\n")

    def test_versioned_and_defined_iconv_symbols_are_refused(self):
        for text in ("         U iconv_open@GLIBC_2.4\n", "00000000 T iconv\n"):
            with self.subTest(symbol=text), self.assertRaises(guard.Refused):
                self.check(text)

    def test_missing_required_features_are_refused(self):
        for symbol in guard.REQUIRED:
            with self.subTest(symbol=symbol):
                old = self.symbols
                self.symbols = self.symbols.replace("00000000 T " + symbol + "\n", "")
                with self.assertRaisesRegex(guard.Refused, "required HTTP"):
                    self.check("         U " + symbol + "\n")
                self.symbols = old

    def test_missing_archive_is_refused(self):
        (self.prefix / "lib" / guard.ARCHIVES[0]).unlink()
        with self.assertRaisesRegex(guard.Refused, "all four"):
            self.check()

    def test_undefined_weak_protocol_is_not_a_capability(self):
        self.symbols = self.symbols.replace("00000000 T ff_http_protocol\n", "")
        for kind in ("U", "w", "v"):
            with self.subTest(kind=kind), self.assertRaisesRegex(guard.Refused, "required HTTP"):
                self.check("         " + kind + " ff_http_protocol\n")

    def test_unreadable_symbols_are_refused(self):
        with self.assertRaisesRegex(guard.Refused, "cannot inspect"):
            self.check(code=1)

    def make_plan(self, target):
            output = self.prefix / "candidate" / "misterplexd.debug"
            result = subprocess.run(
                ["make", "-s", "-n", target, "ARM_CXX=fixture-arm-g++",
                 "ARM_PLEXD_OUTPUT=" + str(output)], cwd=ROOT,
                text=True, capture_output=True, check=True)
            return output, result.stdout

    def test_daemon_only_candidate_does_not_build_auxiliaries(self):
            output, plan = self.make_plan("arm-plexd-daemon")
            self.assertIn('-o "' + str(output) + '"', plan)
            for name in ("ddr_write_bench", "push_frame", "set_status", "input_mailbox_probe"):
                self.assertNotIn(str(ROOT / "build/arm" / name), plan)
            self.assertFalse(output.exists(), "make dry-run wrote a candidate")

    def test_default_arm_build_retains_all_auxiliaries(self):
            output, plan = self.make_plan("arm-plexd")
            self.assertIn('-o "' + str(output) + '"', plan)
            for name in ("ddr_write_bench", "push_frame", "set_status", "input_mailbox_probe"):
                self.assertIn(str(ROOT / "build/arm" / name), plan)


if __name__ == "__main__":
    unittest.main()
