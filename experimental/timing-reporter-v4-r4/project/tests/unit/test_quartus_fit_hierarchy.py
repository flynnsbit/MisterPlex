#!/usr/bin/env python3
"""Captured-mode hierarchy policy fixtures; never invokes Quartus."""
import hashlib
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import unittest
from unittest import mock
import uuid

ROOT = Path(__file__).resolve().parents[2]
CHECKER = ROOT / "scripts/check_quartus_fit_hierarchy.py"
CONFIG = ROOT / "tests/fixtures/critical_fit_hierarchy.json"
spec = importlib.util.spec_from_file_location("hierarchy_captured_test", CHECKER)
hierarchy = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = hierarchy
spec.loader.exec_module(hierarchy)


class HierarchyProfiles(unittest.TestCase):
    def setUp(self):
        self.work = Path(os.environ.get("MISTERPLEX_TEST_WORK", ROOT / "build")) / (
            "hierarchy-policy-" + uuid.uuid4().hex)
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
            self.manifest(path, manifest, bad_hash=bad_hash)
            args.extend(("--qsf", str(path)))
            if not no_manifest:
                args.extend(("--input-manifest", str(manifest)))
        return subprocess.run(args, text=True, capture_output=True)

    def manifest(self, qsf, manifest=None, bad_hash=False):
        manifest = manifest or self.work / "inputs.json"
        files = {"Plex.qsf": "0" * 64 if bad_hash else hashlib.sha256(qsf.read_bytes()).hexdigest()}
        data = {"input_files": files,
                "input_sha256": hashlib.sha256(json.dumps(files, sort_keys=True).encode()).hexdigest()}
        manifest.write_text(json.dumps(data))
        return data

    def captured(self, value=1):
        qsf = self.work / "project/Plex.qsf"
        qsf.parent.mkdir(exist_ok=True)
        qsf.write_text(f'set_global_assignment -name VERILOG_MACRO "FPGA_VIDEO_320={value}"\n'
                       'set_global_assignment -name VERILOG_MACRO "FRAME_LINES_8=1"\n')
        self.manifest(qsf)
        return qsf

    def published(self, cwd=None, **resources):
        receipt = self.work / (uuid.uuid4().hex + ".json")
        command = [sys.executable, str(CHECKER), "--fit-rpt", str(self.report(**resources)),
                   "--result-json", str(receipt)]
        result = subprocess.run(command, cwd=cwd, text=True, capture_output=True)
        return result, json.loads(receipt.read_text())

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
        for literal in ('"FPGA_VIDEO_320=1"', "{FPGA_VIDEO_320=1}", "FPGA_VIDEO_320=1"):
            self.assertEqual(self.check(qsf=f"set_global_assignment -name VERILOG_MACRO {literal} # captured\n").returncode, 0)
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

    def test_published_profile_uses_adjacent_capture_not_opposite_working_tree(self):
        other = self.work / "opposite-worktree"
        other.mkdir()
        for captured, opposite, bits in ((1, 0, 81920), (0, 1, 100000)):
            with self.subTest(captured=captured):
                qsf = self.captured(captured)
                (other / "Plex.qsf").write_text(
                    f'set_global_assignment -name VERILOG_MACRO "FPGA_VIDEO_320={opposite}"\n')
                result, record = self.published(cwd=other, bits=bits)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(record["profile"], "fpga320" if captured else "baseline")
                self.assertEqual(record["authority"]["qsf"]["sha256"],
                                 hashlib.sha256(qsf.read_bytes()).hexdigest())
                self.assertEqual(record["authority"]["input_manifest"]["sha256"],
                                 hashlib.sha256((self.work / "inputs.json").read_bytes()).hexdigest())
                self.assertEqual(record["authority"]["qsf"], record["artifacts"]["qsf"])
                frame = next(row for row in record["modules"] if row["policy"]["name"] == "ddr_frame_store")
                self.assertEqual(frame["policy"]["min_block_memory_bits"], 81920 if captured else 100000)
                if captured:
                    self.assertEqual(frame["policy"]["min_m10ks"], 96)
        result, record = self.published(bits=81920)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(record["status"], "rejected")
        self.assertIn("required 100000", result.stderr)

    def test_missing_malformed_or_mismatched_captured_authority_refuses(self):
        for variant in ("missing-qsf", "missing-manifest", "json-syntax", "json-list",
                        "bad-files", "bad-aggregate", "bad-qsf-hash", "malformed-qsf", "implicit-macro"):
            with self.subTest(variant=variant):
                qsf = self.captured()
                manifest = self.work / "inputs.json"
                if variant == "missing-qsf":
                    qsf.unlink()
                elif variant == "missing-manifest":
                    manifest.unlink()
                elif variant in ("json-syntax", "json-list", "bad-files"):
                    manifest.write_text({"json-syntax": "{", "json-list": "[]",
                                         "bad-files": '{"input_files":[]}' }[variant])
                elif variant == "bad-aggregate":
                    data = json.loads(manifest.read_text())
                    data["input_sha256"] = "0" * 64
                    manifest.write_text(json.dumps(data))
                elif variant == "bad-qsf-hash":
                    qsf.write_text("# differs from captured manifest\n")
                else:
                    qsf.write_text('set_global_assignment -name VERILOG_MACRO "FPGA_VIDEO_320' +
                                   ('=1\n' if variant == "malformed-qsf" else '"\n'))
                    self.manifest(qsf)
                result, record = self.published()
                self.assertEqual(result.returncode, 4, result.stderr)
                self.assertEqual(record["status"], "refused")
                self.assertIsNone(record["profile"])
                self.assertNotIn("FIT_HIERARCHY_PROFILE: baseline", result.stdout)

    def test_unreadable_captured_authority_and_discovery_errors_propagate(self):
        qsf = self.captured()
        command = ["hierarchy", "--fit-rpt", str(self.report())]
        read = Path.read_bytes
        lstat = Path.lstat
        for denied in (qsf, self.work / "inputs.json"):
            def unreadable(path):
                if path == denied:
                    raise PermissionError("host fixture denied captured authority")
                return read(path)
            with self.subTest(path=denied), mock.patch.object(Path, "read_bytes", unreadable), \
                    contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(hierarchy.main(command), 4)
        def denied_discovery(path):
            if path == self.work / "inputs.json":
                raise OSError("host fixture discovery failure")
            return lstat(path)
        with mock.patch.object(Path, "lstat", denied_discovery), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(hierarchy.main(command), 4)
        archive = self.work / "inputs.tar"
        with tarfile.open(archive, "w") as tar:
            tar.add(qsf, arcname="Plex.qsf")
        manifest = self.work / "inputs.json"
        data = json.loads(manifest.read_text())
        data["archive_sha256"] = hashlib.sha256(archive.read_bytes()).hexdigest()
        manifest.write_text(json.dumps(data))
        with self.assertRaisesRegex(ValueError, "mutually exclusive"):
            hierarchy.captured_profile(qsf, manifest, {}, archive)
        shutil.rmtree(qsf.parent)
        denied = archive
        with mock.patch.object(Path, "read_bytes", unreadable), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(hierarchy.main(command), 4)

    def test_no_capture_cannot_publish_or_replace_an_existing_receipt(self):
        result, record = self.published(bits=100000)
        self.assertEqual(result.returncode, 4)
        self.assertIsNone(record["profile"])
        self.captured()
        target = self.work / "prior-result.json"
        target.write_text("older result, not this transaction\n")
        result = subprocess.run([sys.executable, str(CHECKER), "--fit-rpt", str(self.report()),
                                 "--result-json", str(target)], text=True, capture_output=True)
        self.assertEqual(result.returncode, 4)
        self.assertEqual(target.read_text(), "older result, not this transaction\n")
        self.assertNotIn("PASS fit hierarchy", result.stdout)

    def test_normal_cleanup_uses_verified_archive_without_extracting_project(self):
        for value, bits in ((1, 81920), (0, 100000)):
            with self.subTest(value=value):
                qsf = self.captured(value)
                archive = self.work / "inputs.tar"
                with tarfile.open(archive, "w") as tar:
                    tar.add(qsf, arcname="Plex.qsf")
                manifest = self.work / "inputs.json"
                data = json.loads(manifest.read_text())
                data["archive_sha256"] = hashlib.sha256(archive.read_bytes()).hexdigest()
                manifest.write_text(json.dumps(data))
                shutil.rmtree(qsf.parent)
                result, record = self.published(bits=bits)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(record["profile"], "fpga320" if value else "baseline")
                self.assertEqual(record["authority"]["qsf"]["member"], "Plex.qsf")
                self.assertEqual(record["authority"]["qsf"]["archive"], record["artifacts"]["input_archive"])
                self.assertFalse(qsf.parent.exists())
        archive.write_bytes(b"mismatched captured archive")
        result, record = self.published()
        self.assertEqual(result.returncode, 4)
        self.assertIsNone(record["profile"])

    def test_archive_missing_duplicate_nonregular_or_invalid_qsf_refuses(self):
        for variant in ("absent", "duplicate", "symlink", "wrong-qsf", "corrupt"):
            with self.subTest(variant=variant):
                qsf = self.captured()
                archive = self.work / "inputs.tar"
                with tarfile.open(archive, "w") as tar:
                    if variant == "duplicate":
                        tar.add(qsf, arcname="Plex.qsf")
                        tar.add(qsf, arcname="Plex.qsf")
                    elif variant == "symlink":
                        member = tarfile.TarInfo("Plex.qsf")
                        member.type, member.linkname = tarfile.SYMTYPE, "other.qsf"
                        tar.addfile(member)
                    elif variant == "wrong-qsf":
                        qsf.write_text("# wrong QSF\n")
                        tar.add(qsf, arcname="Plex.qsf")
                if variant == "corrupt":
                    archive.write_bytes(b"not a tar")
                manifest = self.work / "inputs.json"
                data = json.loads(manifest.read_text())
                data["archive_sha256"] = hashlib.sha256(archive.read_bytes()).hexdigest()
                manifest.write_text(json.dumps(data))
                shutil.rmtree(qsf.parent)
                result, record = self.published()
                self.assertEqual(result.returncode, 4, result.stderr)
                self.assertIsNone(record["profile"])


if __name__ == "__main__":
    unittest.main()
