#!/usr/bin/env python3
"""Isolated build policy fixtures; optional Tcl mocks never open a real netlist."""
from __future__ import annotations

import importlib.util
import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import shlex
import socket
import subprocess
import sys
import tarfile
import time
import unittest
from unittest import mock
import uuid

ROOT = Path(__file__).resolve().parents[2]
DRIVER = ROOT / "scripts/rbf_build.py"
spec = importlib.util.spec_from_file_location("rbf_build", DRIVER)
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


class BuildPolicy(unittest.TestCase):
    def setUp(self):
        self.work = ROOT / "build" / ("rbf-policy-" + uuid.uuid4().hex)
        self.project = self.work / "fixture"
        self.project.mkdir(parents=True)
        self.fake_sockets = []
        self.semaphores = []
        self.ipc_patches = []
        for attribute in ("CONTROLLER_KEY", "EXECUTION_KEY"):
            while True:
                key = 0x50000000 | (uuid.uuid4().int & 0x0FFFFFFF)
                sem = build.LIBC.semget(key, 1, 0o1000 | 0o2000 | 0o666)
                if sem >= 0:
                    break
                if build.ctypes.get_errno() != build.errno.EEXIST:
                    raise OSError(build.ctypes.get_errno(), "test semaphore allocation failed")
            self.semaphores.append(sem)
            self.assertEqual(build.LIBC.semctl(sem, 0, 16, 1), 0)
            patch = mock.patch.object(build, attribute, key)
            patch.start()
            self.ipc_patches.append(patch)
        subprocess.run(["git", "init", "-q", self.project], check=True)
        (self.project / "Plex.qpf").write_text('PROJECT_REVISION = "Plex"\n')
        (self.project / "Plex.qsf").write_text(
            "set_global_assignment -name SEED 6\n"
            "set_global_assignment -name NUM_PARALLEL_PROCESSORS 2\n")
        (self.project / "Plex.sdc").write_text("# captured timing constraints\n")
        (self.project / "rtl").mkdir()
        (self.project / "rtl/top.sv").write_text("module top; endmodule\n")
        (self.project / "output_files").mkdir()
        (self.project / "output_files/old.sv").write_text("not an input\n")
        (self.project / "db").mkdir()
        (self.project / "db/stale.qsf").write_text("not an input\n")
        subprocess.run(["git", "-C", self.project, "add", "."], check=True)
        original_output = build.output

        def fixture_output(args):
            if args[-2:] == ["rev-parse", "HEAD"]:
                return "fixture-head"
            return original_output(args)

        self.output_patch = mock.patch.object(build, "output", side_effect=fixture_output)
        self.output_patch.start()

    def tearDown(self):
        self.output_patch.stop()
        for patch in self.ipc_patches:
            patch.stop()
        for sem in self.semaphores:
            build.LIBC.semctl(sem, 0, 0)  # Remove only this fixture's IPC objects.
        for sock in self.fake_sockets:
            sock.close()
        shutil.rmtree(self.work)

    def make_snapshot(self, name="first", **kwargs):
        dest = self.work / name
        meta = build.snapshot(self.project, dest, "sha256:fixture", **kwargs)
        build.prepare_reporting(dest, meta)
        return dest, meta

    def test_default_and_permission_alone_still_refuse(self):
        env = os.environ.copy()
        for permission in ("0", "1"):
            env["MISTERPLEX_ALLOW_LOCAL_FIT"] = permission
            result = subprocess.run([ROOT / "scripts/build_rbf.sh"], env=env, capture_output=True)
            self.assertEqual(result.returncode, 3)
        env["MISTERPLEX_ALLOW_LOCAL_FIT"] = "0"
        result = subprocess.run([ROOT / "scripts/build_rbf.sh", "--backend", "local-container", "slot"],
                                env=env, capture_output=True)
        self.assertEqual(result.returncode, 3)

    def test_reference_and_processor_guards_precede_any_build(self):
        env = {"MISTERPLEX_ALLOW_LOCAL_FIT": "1", "MISTERPLEX_BUILD_ALLOW_UNVERIFIED": "0",
               "MISTER_REMOTE_ALLOW_UNVERIFIED": "0"}
        with mock.patch.dict(os.environ, env), contextlib.redirect_stderr(io.StringIO()):
            for backend in ("local-container", "remote"):
                self.assertEqual(build.main([backend, "no-reference", str(self.project)]), 4)
        env.update(MISTER_REMOTE_ALLOW_UNVERIFIED="1", MISTER_REMOTE_PROCESSORS="4",
                   MISTER_REMOTE_ALLOW_PROCESSOR_OVERRIDE="0")
        with mock.patch.dict(os.environ, env), contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as refused:
                build.main(["remote", "processor-change", str(self.project)])
        self.assertEqual(refused.exception.code, 2)
        self.assertFalse((self.project / "remote_out").exists())

    def test_concurrent_slots_and_worktrees_share_lock_inode(self):
        trees = []
        for name in ("one", "two"):
            tree = self.work / ("worktree-" + name)
            tree.mkdir()
            admin = self.project / ".git/worktrees" / name
            admin.mkdir(parents=True)
            (admin / "commondir").write_text("../..\n")
            (admin / "HEAD").write_text("ref: refs/heads/master\n")
            (admin / "gitdir").write_text(str(tree / ".git") + "\n")
            (tree / ".git").write_text(f"gitdir: {admin}\n")
            trees.append(tree)
        lock = build.repository_lock(trees[0])
        self.assertEqual(lock, build.repository_lock(trees[1]))
        code = (
            "import importlib.util,sys; from pathlib import Path; "
            "s=importlib.util.spec_from_file_location('b',sys.argv[1]); "
            "b=importlib.util.module_from_spec(s); s.loader.exec_module(b)\n"
            "with b.fit_lock(Path(sys.argv[2])):\n"
            " print('locked',flush=True)\n"
            " sys.stdin.readline()\n"
        )
        holder = subprocess.Popen([sys.executable, "-c", code, DRIVER, lock],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(holder.stdout.readline().strip(), "locked")
            inode = lock.stat().st_ino
            env = {"MISTERPLEX_ALLOW_LOCAL_FIT": "1", "MISTERPLEX_BUILD_ALLOW_UNVERIFIED": "1",
                   "MISTER_REMOTE_ALLOW_UNVERIFIED": "1"}
            with mock.patch.object(build, "ROOT", trees[1]), mock.patch.dict(os.environ, env):
                for backend in ("local-container", "remote"):
                    with self.assertRaisesRegex(RuntimeError, "single-fit lock is busy"):
                        build.main([backend, "another-slot", str(self.project)])
        finally:
            holder.communicate("release\n", timeout=5)
        with build.fit_lock(lock):
            self.assertEqual(lock.stat().st_ino, inode)

    def test_failed_holder_releases_lock(self):
        lock = self.work / "single-fit.lock"
        with self.assertRaisesRegex(RuntimeError, "injected failure"):
            with build.fit_lock(lock):
                raise RuntimeError("injected failure")
        with build.fit_lock(lock):
            pass
        self.assertFalse(lock.with_name(lock.name + ".owner").exists())

    def test_unclean_owner_is_fail_closed(self):
        lock = self.work / "single-fit.lock"
        lock.with_name(lock.name + ".owner").write_text('{"pid": 99999999}\n')
        with self.assertRaisesRegex(RuntimeError, "unclean previous transaction"):
            with build.fit_lock(lock):
                self.fail("unclean lock was silently reused")

    def test_host_lease_crosses_clones_remote_bases_and_login_homes(self):
        clone = self.work / "independent-clone"
        subprocess.run(["git", "init", "-q", clone], check=True)
        self.assertNotEqual(build.repository_lock(clone), build.repository_lock(self.project))
        home, env = self.remote_fixture()
        another_home = self.work / "another-login-home"
        another_home.mkdir()
        env["HOME"] = str(another_home)
        env["MISTER_REMOTE_BASE"] = str(self.work / "different-slot-base")
        with build.host_lock(build.EXECUTION_KEY):
            worker = self.start_worker(env, "other-slot")
            stdout, stderr = worker.communicate(timeout=5)
            self.assertEqual(worker.returncode, 1, stderr)
            self.assertIn("host single-fit lease", stdout)
            settings = {"MISTERPLEX_ALLOW_LOCAL_FIT": "1", "MISTERPLEX_BUILD_ALLOW_UNVERIFIED": "1"}
            with mock.patch.object(build, "ROOT", clone), mock.patch.dict(os.environ, settings):
                with self.assertRaisesRegex(RuntimeError, "host single-fit lease"):
                    build.main(["local-container", "independent", str(self.project)])
        self.assertFalse((home / "compile-entered").exists())

    def test_host_ownership_survives_uncatchable_controller_exit(self):
        code = (
            "import importlib.util,os,sys\n"
            "s=importlib.util.spec_from_file_location('b',sys.argv[1]); "
            "b=importlib.util.module_from_spec(s); s.loader.exec_module(b)\n"
            "with b.host_lock(int(sys.argv[2])): os._exit(17)\n"
        )
        child = subprocess.run([sys.executable, "-c", code, DRIVER, str(build.CONTROLLER_KEY)])
        self.assertEqual(child.returncode, 17)
        with self.assertRaisesRegex(RuntimeError, "host single-fit lease"):
            with build.host_lock(build.CONTROLLER_KEY):
                self.fail("kernel undid unresolved controller ownership")

    def test_candidate_validation_keeps_ban_and_identity_gates(self):
        work, meta = self.make_snapshot()
        build.unpack(work / "inputs.tar", work / "project", meta)
        (work / "Plex.rbf").write_bytes(b"candidate")
        policy = self.work / "policy"
        ban = policy / "tests/unit/test_phase1a_rbf_ban.sh"
        ban.parent.mkdir(parents=True)
        ban.write_text("# fixture gate\n")
        with mock.patch.object(build, "run") as guarded:
            build.validate(policy, work, None)
        commands = [call.args[0] for call in guarded.call_args_list]
        self.assertEqual(sum(str(ban) in [str(x) for x in command] for command in commands), 2)
        result = json.loads((work / "result.json").read_text())
        self.assertEqual(result["bit_identity"], "UNVERIFIED")
        self.assertEqual(result["promotion"], "NOT_AUTHORIZED")
        (work / "result.json").unlink()
        reference = work / "reference.rbf"
        reference.write_bytes(b"different reference")
        with mock.patch.object(build, "run"), self.assertRaisesRegex(RuntimeError, "not bit-identical"):
            build.validate(policy, work, reference)
        self.assertFalse((work / "result.json").exists())
        def reject_ban(command, **_kwargs):
            if command[0] == "bash":
                raise subprocess.CalledProcessError(2, "ban")

        with mock.patch.object(build, "run", side_effect=reject_ban):
            with self.assertRaises(subprocess.CalledProcessError):
                build.validate(policy, work, None)
        self.assertFalse((work / "result.json").exists())

    def test_snapshot_is_detached_and_replay_is_identical(self):
        first, meta = self.make_snapshot()
        self.assertNotIn("db/stale.qsf", meta["input_files"])
        self.assertNotIn("output_files/old.sv", meta["input_files"])
        (self.project / "rtl/top.sv").write_text("live edit after capture\n")
        (self.project / "Plex.qsf").write_text("different seed and processors\n")
        build.unpack(first / "inputs.tar", first / "project", meta)
        self.assertEqual((first / "project/rtl/top.sv").read_text(), "module top; endmodule\n")
        second, replay_meta = self.make_snapshot("second", replay=first / "inputs.tar")
        self.assertEqual(meta, replay_meta)
        self.assertEqual((first / "inputs.tar").read_bytes(), (second / "inputs.tar").read_bytes())
        self.assertFalse((first / "inputs.tar").stat().st_mode & 0o222)

    def test_video_build_id_uses_original_not_rendered_identity(self):
        baseline, original_meta = self.make_snapshot("baseline")
        derived, meta = self.make_snapshot("derived", derive_video_build_id=True)
        expected = original_meta["source_sha256"][:8]
        self.assertNotEqual(int(expected, 16), 0)
        self.assertEqual(meta["fpga_video_build_id"], expected)
        self.assertEqual(meta["source_sha256"], original_meta["source_sha256"])
        self.assertNotEqual(meta["input_sha256"], meta["source_sha256"])
        self.assertEqual((baseline / "source.tar").read_bytes(), (derived / "source.tar").read_bytes())
        self.assertEqual((baseline / "source.tar").read_bytes(), (baseline / "inputs.tar").read_bytes())
        self.assertEqual(meta["source_archive_sha256"], build.digest((derived / "source.tar").read_bytes()))
        self.assertFalse((derived / "source.tar").stat().st_mode & 0o222)
        with tarfile.open(derived / "inputs.tar") as tar:
            qsf = tar.extractfile("Plex.qsf").read().decode()
        self.assertIn(f'"FPGA_VIDEO_BUILD_ID=32\'h{expected}"', qsf)
        self.assertIn("NUM_PARALLEL_PROCESSORS 2", qsf)
        self.assertIn("SEED 6", qsf)
        self.assertNotIn("FPGA_VIDEO_BUILD_ID", (self.project / "Plex.qsf").read_text())
        overridden, other = self.make_snapshot("overridden", processors="4", derive_video_build_id=True)
        self.assertEqual(other["fpga_video_build_id"], expected)
        self.assertEqual((derived / "source.tar").read_bytes(), (overridden / "source.tar").read_bytes())
        self.assertNotEqual(other["input_sha256"], meta["input_sha256"])

    def test_video_build_id_replay_preserves_original_and_rendered_archives(self):
        first, meta = self.make_snapshot(derive_video_build_id=True)
        (self.project / "rtl/top.sv").write_text("later live source edit\n")
        second, replayed = self.make_snapshot("replay", replay=first / "inputs.tar",
                                             derive_video_build_id=True)
        self.assertEqual(meta, replayed)
        for name in ("source.tar", "inputs.tar"):
            self.assertEqual((first / name).read_bytes(), (second / name).read_bytes())
        baseline, _ = self.make_snapshot("baseline")
        with self.assertRaisesRegex(RuntimeError, "replay has no derived"):
            self.make_snapshot("cannot-render-replay", replay=baseline / "inputs.tar",
                               derive_video_build_id=True)
        (first / "source.tar").chmod(0o644)
        (first / "source.tar").write_bytes(b"altered original archive")
        with self.assertRaisesRegex(RuntimeError, "original-source archive hash"):
            self.make_snapshot("altered-original", replay=first / "inputs.tar")

    def test_video_build_id_zero_and_preexisting_assignment_refuse(self):
        with mock.patch.object(build, "digest", return_value="0" * 64):
            with self.assertRaisesRegex(RuntimeError, "must be nonzero"):
                self.make_snapshot("zero", derive_video_build_id=True)
        qsf = self.project / "Plex.qsf"
        qsf.write_text(qsf.read_text() +
                       'set_global_assignment -name VERILOG_MACRO "FPGA_VIDEO_BUILD_ID=32\'h12345678"\n')
        with self.assertRaisesRegex(RuntimeError, "already assigns FPGA_VIDEO_BUILD_ID"):
            self.make_snapshot("conflict", derive_video_build_id=True)
        self.assertFalse((self.work / "conflict/inputs.tar").exists())
        self.assertFalse((self.work / "conflict/inputs.tar.pending").exists())

    def test_legacy_build_date_is_generated_and_frozen_outside_original_identity(self):
        generator = self.project / "sys/build_id.tcl"
        generator.parent.mkdir()
        shutil.copyfile(ROOT / "fpga/Plex_MiSTer/sys/build_id.tcl", generator)
        generated = self.project / "build_id.v"
        generated.write_text("simulation-only header must never be used\n")
        subprocess.run(["git", "-C", self.project, "add", "build_id.v"], check=True)
        first, meta = self.make_snapshot("day-one", legacy_build_date="260905")
        self.assertNotIn("build_id.v", meta["source_files"])
        self.assertIn("build_id.v", meta["input_files"])
        self.assertIsNone(meta["fpga_video_build_id"])
        with tarfile.open(first / "inputs.tar") as tar:
            self.assertEqual(tar.extractfile("build_id.v").read(), b'`define BUILD_DATE "260905"')
            frozen_tcl = tar.extractfile("sys/build_id.tcl").read().decode()
        self.assertNotIn(build.BUILD_DATE_EXPRESSION, frozen_tcl)
        self.assertIn('set buildDate "`define BUILD_DATE \\"260905\\""', frozen_tcl)
        self.assertIn(build.BUILD_DATE_EXPRESSION, generator.read_text())
        generated.write_text("different generated simulation header\n")
        second, changed_date = self.make_snapshot("day-two", legacy_build_date="260906",
                                                 derive_video_build_id=True)
        self.assertEqual(meta["source_sha256"], changed_date["source_sha256"])
        self.assertEqual(changed_date["fpga_video_build_id"], meta["source_sha256"][:8])
        self.assertNotEqual(meta["input_sha256"], changed_date["input_sha256"])
        replay, replay_meta = self.make_snapshot("replay-date", replay=first / "inputs.tar",
                                                legacy_build_date="260907")
        self.assertEqual(replay_meta["legacy_build_date"], "260905")
        self.assertEqual((replay / "inputs.tar").read_bytes(), (first / "inputs.tar").read_bytes())
        self.assertEqual((first / "source.tar").read_bytes(), (second / "source.tar").read_bytes())

    def test_replay_rejects_tool_change_and_processor_override(self):
        first, _ = self.make_snapshot()
        with self.assertRaisesRegex(RuntimeError, "replay image"):
            build.snapshot(self.project, self.work / "wrong-image", "sha256:changed",
                           replay=first / "inputs.tar")
        with self.assertRaisesRegex(RuntimeError, "processor override"):
            self.make_snapshot("wrong-processors", replay=first / "inputs.tar", processors="4")

    def test_source_change_during_snapshot_cleans_partial_archive(self):
        actual_hashes = build.hashes
        calls = 0

        def changing_hashes(files):
            nonlocal calls
            calls += 1
            result = actual_hashes(files)
            if calls == 2:
                result["rtl/top.sv"] = "changed"
            return result

        with mock.patch.object(build, "hashes", side_effect=changing_hashes):
            with self.assertRaisesRegex(RuntimeError, "live sources changed"):
                self.make_snapshot()
        self.assertFalse((self.work / "first/inputs.tar").exists())
        self.assertFalse((self.work / "first/inputs.tar.pending").exists())
        self.assertFalse((self.work / "first/source.tar.pending").exists())

    def test_disk_refusal_precedes_copy(self):
        with mock.patch.object(build.shutil, "disk_usage", return_value=shutil._ntuple_diskusage(1, 1, 0)):
            with self.assertRaisesRegex(RuntimeError, "disk free"):
                self.make_snapshot()
        self.assertFalse((self.work / "first/inputs.tar").exists())

    def test_symlink_and_archive_traversal_are_refused(self):
        (self.project / "rtl/linked.sv").symlink_to(self.project / "rtl/top.sv")
        with self.assertRaisesRegex(RuntimeError, "linked or external"):
            self.make_snapshot()
        archive = self.work / "evil.tar"
        with tarfile.open(archive, "w") as tar:
            member = tarfile.TarInfo("../escaped.sv")
            member.size = 1
            tar.addfile(member, io.BytesIO(b"x"))
        with self.assertRaisesRegex(RuntimeError, "unsafe snapshot"):
            build.unpack(archive, self.work / "unpack", {"input_files": {}})
        self.assertFalse((self.work / "escaped.sv").exists())

    def test_fake_compile_uses_pinned_image_and_captured_configuration(self):
        work, meta = self.make_snapshot()
        docker = self.fake_docker(self.work / "daemon")
        with mock.patch.dict(os.environ, {"PATH": str(docker.parent) + os.pathsep + os.environ["PATH"]}):
            with build.fit_lock(self.work / "fit.lock") as fd:
                build.compile_snapshot(work, meta, fd, build.require_local_daemon())
        tool = json.loads((work / "tool.json").read_text())
        self.assertEqual(tool["image_id"], "sha256:fixture")
        self.assertIn("set_global_assignment -name SEED 6", tool["qsf_configuration"])
        self.assertIn("set_global_assignment -name NUM_PARALLEL_PROCESSORS 2", tool["qsf_configuration"])
        self.assertEqual((work / "Plex.rbf").read_text(), "fixture")
        self.assertEqual(build.digest((work / "inputs.tar").read_bytes()), meta["archive_sha256"])
        self.assertEqual(build.digest((work / "source.tar").read_bytes()), meta["source_archive_sha256"])
        timing = json.loads((work / "timing/manifest.json").read_text())
        self.assertEqual({row["clock"] for row in timing["reports"]}, {"clk_sys", "ddr90"})
        self.assertEqual({row["check"] for row in timing["reports"]}, {"setup", "hold"})
        self.assertEqual(timing["timing_acceptance"], "NOT_GRANTED")
        self.assertEqual(tool["timing_reporter"]["files"],
                         json.loads((work / "reporter/provenance.json").read_text())["files"])

    def test_reporter_is_readonly_sidecar_and_covers_clocks_and_corners(self):
        work, meta = self.make_snapshot()
        provenance = build.verify_reporter(work, meta)
        tcl = (work / "reporter/timing.tcl").read_text()
        for required in ("project_open Plex", "create_timing_netlist", "read_sdc", "update_timing_netlist",
                         "get_available_operating_conditions", "set_operating_conditions",
                         "get_clocks *", "report_timing -setup", "report_timing -hold",
                         "-npaths 10", "-detail full_path"):
            self.assertIn(required, tcl)
        for required in ("decoder-from", "decoder-to", "trace add execution", "get_collection_size",
                         "get_object_info", "report_sdc -ignored", "report_exceptions -setup"):
            self.assertIn(required, tcl)
        self.assertNotIn("set_global_assignment", tcl)
        self.assertNotIn("quartus_fit", tcl)
        self.assertEqual(provenance["schema"], "misterplex.timing-reporter.v2")
        self.assertEqual(set(provenance["files"]),
                         {"run.sh", "timing.tcl", "check_quartus_timing.py", "quartus_sta_report.py"})
        for name in provenance["files"]:
            self.assertFalse((work / "reporter" / name).stat().st_mode & 0o222)
        self.assertEqual(provenance["input_sha256"], meta["input_sha256"])
        self.assertEqual(build.digest((work / "inputs.tar").read_bytes()), meta["archive_sha256"])
        script = work / "reporter/timing.tcl"
        script.chmod(0o644)
        script.write_text(tcl + "\n# changed after capture\n")
        with self.assertRaisesRegex(RuntimeError, "reporter hash mismatch"):
            build.verify_reporter(work, meta)

    @unittest.skipUnless(os.environ.get("MISTERPLEX_TIMING_TCL"),
                         "MISTERPLEX_TIMING_TCL must name an existing quartus_sh -t runner")
    def test_tcl_observer_and_standalone_bound_collector(self):
        for variant in ("success", "setter-error", "unresolved-through"):
            with self.subTest(variant=variant):
                sdc = ("set_false_path -to {out_led}\n"
                       "set_max_delay -from [get_keepers config] -to [get_keepers out_led] 4.0\n"
                       "set_clock_groups -exclusive \\\n"
                       "  -group [get_clocks clk_sys] \\\n"
                       "  -group [get_clocks ddr90]\n"
                       "set_min_delay -from_clock [get_clocks clk_sys] -to [get_keepers config] 0.0\n")
                if variant == "unresolved-through":
                    sdc = "set_false_path -through {unknown_pin}\n"
                (self.project / "Plex.sdc").write_text(sdc)
                work, meta = self.make_snapshot("tcl-" + variant)
                project, timing = work / "project", work / "timing"
                project.mkdir()
                timing.mkdir()
                shutil.copyfile(self.project / "Plex.sdc", project / "Plex.sdc")
                result = subprocess.run(
                    [*shlex.split(os.environ["MISTERPLEX_TIMING_TCL"]),
                     ROOT / "tests/fixtures/quartus_timing_mock.tcl", work / "reporter/timing.tcl",
                     project, timing, variant], capture_output=True, text=True, timeout=60)
                if variant != "success":
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertFalse((timing / "extended.summary").exists())
                    continue
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                (project / "output_files").mkdir()
                rbf = b"Mock RBF; no compile or hardware claim."
                (project / "output_files/Plex.rbf").write_bytes(rbf)
                (work / "Plex.rbf").write_bytes(rbf)
                for name in ("compile.exit", "reporter.exit"):
                    (timing / name).write_text("0\n")
                for name in ("rbf.before.sha256", "rbf.after.sha256"):
                    (timing / name).write_text(build.digest(rbf) + "  output_files/Plex.rbf\n")
                # A fresh standalone worker cannot import working-tree modules.
                program = ("import json,sys; from pathlib import Path; "
                           "worker={'__name__':'bound_worker'}; "
                           "exec(Path(sys.argv[1]).read_text(), worker); "
                           "w=Path(sys.argv[2]); m=json.loads((w/'inputs.json').read_text()); "
                           "worker['verify_timing_reports'](w,m,worker['verify_reporter'](w,m))")
                result = subprocess.run([sys.executable, "-I", "-c", program, DRIVER, work],
                                        cwd=self.work, capture_output=True, text=True, timeout=20)
                self.assertEqual(result.returncode, 0, result.stderr)
                manifest = json.loads((timing / "manifest.json").read_text())
                self.assertEqual(manifest["schema"], "misterplex.timing-paths.v2")
                self.assertEqual(len(manifest["extended"]["reports"]), 48)
                self.assertEqual(manifest["extended"]["decoder_nodes"], 1)
                self.assertEqual(len(manifest["extended"]["exceptions"]), 4)
                original = {p: p.read_bytes() for p in timing.iterdir()}
                sys.path.insert(0, str(ROOT / "scripts"))
                from check_timing_exclusions import effective_exclusions
                self.assertEqual(effective_exclusions(timing, project, [project / "Plex.sdc"]),
                                 ([], 4, 0))
                self.assertEqual(original, {p: p.read_bytes() for p in timing.iterdir()})

    def test_failed_timing_still_runs_effective_exclusion_gate(self):
        work, _ = self.make_snapshot("gate-order")
        project = work / "project"
        project.mkdir()
        shutil.copyfile(self.project / "Plex.qsf", project / "Plex.qsf")
        shutil.copyfile(self.project / "Plex.sdc", project / "Plex.sdc")
        seen = []

        def gates(args, **kwargs):
            seen.append(args)
            if str(args[1]).endswith("check_quartus_timing.py"):
                raise subprocess.CalledProcessError(1, args)
            return subprocess.CompletedProcess(args, 0)

        with mock.patch.object(build, "run", side_effect=gates):
            with self.assertRaises(subprocess.CalledProcessError) as failure:
                build.validate(ROOT, work, None)
        self.assertEqual(failure.exception.returncode, 1)
        self.assertIn("--require-scoped", seen[1])
        self.assertEqual(Path(seen[2][1]).name, "check_timing_exclusions.py")
        self.assertIn("--effective-dir", seen[2])
        self.assertIn("--project", seen[2])
        self.assertFalse((work / "result.json").exists())

    def test_reporter_runner_preserves_compile_failure_and_rbf_bytes(self):
        work, _ = self.make_snapshot()
        binaries = self.work / "reporter-fakes"
        binaries.mkdir()
        compiler = binaries / "quartus_sh"
        compiler.write_text(
            "#!/usr/bin/env python3\n"
            "import os,pathlib,sys\n"
            "assert sys.argv[1:]==['--flow','compile','Plex.qpf']\n"
            "case=pathlib.Path(os.environ['REPORTER_TEST_CASE'])\n"
            "(case/'calls').write_text('compile\\n')\n"
            "pathlib.Path('output_files').mkdir()\n"
            "pathlib.Path('output_files/Plex.rbf').write_bytes(b'unchanged RBF')\n"
            "sys.exit(int(os.environ['REPORTER_TEST_COMPILE_RC']))\n")
        reporter = binaries / "quartus_sta"
        reporter.write_text(
            "#!/usr/bin/env python3\n"
            "import os,pathlib,sys\n"
            "assert sys.argv[1]=='-t' and pathlib.Path(sys.argv[2]).is_file()\n"
            "case=pathlib.Path(os.environ['REPORTER_TEST_CASE'])\n"
            "with (case/'calls').open('a') as f: f.write('reporter\\n')\n"
            "pathlib.Path(sys.argv[3],'partial.rpt').write_text('timing details')\n"
            "if os.environ['REPORTER_TEST_MUTATE']=='1': pathlib.Path('output_files/Plex.rbf').write_bytes(b'changed')\n"
            "sys.exit(int(os.environ['REPORTER_TEST_REPORT_RC']))\n")
        compiler.chmod(0o755)
        reporter.chmod(0o755)
        for name, compile_rc, report_rc, mutate, expected in (
            ("success", 0, 0, 0, 0), ("compile-failure", 19, 23, 0, 19),
            ("reporter-failure", 0, 23, 0, 23), ("changed-rbf", 0, 0, 1, 1),
        ):
            with self.subTest(name=name):
                case = self.work / name
                project, reports = case / "project", case / "timing"
                project.mkdir(parents=True)
                reports.mkdir()
                env = dict(os.environ, PATH=str(binaries) + os.pathsep + os.environ["PATH"],
                           REPORTER_TEST_CASE=str(case), REPORTER_TEST_COMPILE_RC=str(compile_rc),
                           REPORTER_TEST_REPORT_RC=str(report_rc), REPORTER_TEST_MUTATE=str(mutate))
                result = subprocess.run(["/bin/sh", work / "reporter/run.sh", work / "reporter/timing.tcl", reports],
                                        cwd=project, env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertEqual((reports / "compile.exit").read_text().strip(), str(compile_rc))
                if compile_rc:
                    self.assertEqual((case / "calls").read_text(), "compile\n")
                    self.assertFalse((reports / "reporter.exit").exists())
                else:
                    self.assertEqual((case / "calls").read_text(), "compile\nreporter\n")
                if expected == 0:
                    self.assertEqual((reports / "rbf.before.sha256").read_bytes(),
                                     (reports / "rbf.after.sha256").read_bytes())

    def test_detailed_reports_survive_post_fit_timing_rejection(self):
        daemon = self.work / "daemon"
        docker = self.fake_docker(daemon)
        env = {"MISTERPLEX_ALLOW_LOCAL_FIT": "1", "MISTERPLEX_BUILD_ALLOW_UNVERIFIED": "1",
               "PATH": str(docker.parent) + os.pathsep + os.environ["PATH"]}
        with mock.patch.dict(os.environ, env), mock.patch.object(build, "ROOT", self.project), \
                mock.patch.object(build, "validate", side_effect=RuntimeError("STA fails setup -30.110 / hold -0.481")):
            with self.assertRaisesRegex(RuntimeError, "STA fails"):
                build.main(["local-container", "timing-red", str(self.project)])
        out = self.project / "local_out/timing-red"
        self.assertFalse((out / "project").exists())
        self.assertTrue((out / "Plex.rbf").exists())
        self.assertTrue((out / "timing/manifest.json").exists())
        self.assertTrue((out / "timing/Plex.corner-00.clock-00.setup.rpt").exists())
        self.assertTrue((out / "timing/Plex.corner-00.clock-01.hold.rpt").exists())
        self.assertFalse((out / "result.json").exists())

    def test_actual_detailed_gate_rejects_after_rbf_collection_and_retains_evidence(self):
        for flag, expected in (("detailed-timing-fails", 1), ("malformed-timing", 4)):
            with self.subTest(flag=flag):
                daemon = self.work / flag
                docker = self.fake_docker(daemon)
                (daemon / flag).touch()
                env = {"MISTERPLEX_ALLOW_LOCAL_FIT": "1", "MISTERPLEX_BUILD_ALLOW_UNVERIFIED": "1",
                       "PATH": str(docker.parent) + os.pathsep + os.environ["PATH"]}
                actual_run = build.run

                def guards(args, **kwargs):
                    if len(args) > 1 and str(args[1]).endswith("check_quartus_timing.py"):
                        self.assertIn("--paths-dir", args)
                        self.assertIn("--require-scoped", args)
                        command = [args[0], ROOT / "scripts/check_quartus_timing.py", *args[2:]]
                        return actual_run(command, capture_output=True, text=True)
                    if len(args) > 1 and str(args[1]).endswith("check_quartus_fit_hierarchy.py"):
                        return subprocess.CompletedProcess(args, 0)
                    if len(args) > 1 and str(args[1]).endswith("check_timing_exclusions.py"):
                        self.assertIn("--effective-dir", args)
                        return subprocess.CompletedProcess(args, 0)
                    return actual_run(args, **kwargs)

                with mock.patch.dict(os.environ, env), mock.patch.object(build, "ROOT", self.project), \
                        mock.patch.object(build, "run", side_effect=guards):
                    with self.assertRaises(subprocess.CalledProcessError) as error:
                        build.main(["local-container", flag, str(self.project)])
                self.assertEqual(error.exception.returncode, expected, error.exception.stderr)
                if expected == 1:
                    self.assertIn("-31.164", error.exception.stderr)
                    self.assertIn("-0.034", error.exception.stderr)
                out = self.project / "local_out" / flag
                self.assertTrue((out / "Plex.rbf").is_file())
                self.assertFalse((out / "project").exists())
                self.assertTrue((out / "timing/manifest.json").is_file())
                self.assertTrue((out / "timing/complete.summary").is_file())
                self.assertTrue((out / "timing/Plex.corner-00.clock-00.setup.rpt").is_file())
                self.assertFalse((out / "result.json").exists())

    def test_reporter_failure_and_rbf_mutation_cannot_approve_a_build(self):
        for flag, message in (("reporter-fails", "client failed"), ("reporter-mutates-rbf", "reporter changed")):
            with self.subTest(flag=flag):
                daemon = self.work / flag
                docker = self.fake_docker(daemon)
                (daemon / flag).touch()
                env = {"MISTERPLEX_ALLOW_LOCAL_FIT": "1", "MISTERPLEX_BUILD_ALLOW_UNVERIFIED": "1",
                       "PATH": str(docker.parent) + os.pathsep + os.environ["PATH"]}
                with mock.patch.dict(os.environ, env), mock.patch.object(build, "ROOT", self.project):
                    with self.assertRaisesRegex(RuntimeError, message):
                        build.main(["local-container", flag, str(self.project)])
                out = self.project / "local_out" / flag
                self.assertFalse((out / "project").exists())
                self.assertFalse((out / "Plex.rbf").exists())
                self.assertFalse((out / "result.json").exists())
                self.assertTrue((out / "timing/reporter.exit").exists())
                self.assertTrue((out / "diagnostics/output_files/Plex.map.rpt").exists())
                if flag == "reporter-fails":
                    self.assertTrue((out / "timing/partial.rpt").exists())

    def fake_docker(self, state):
        state.mkdir(parents=True, exist_ok=True)
        sock = socket.socket(socket.AF_UNIX)
        self.fake_sockets.append(sock)
        cwd = Path.cwd()
        try:
            os.chdir(state)
            sock.bind("docker.sock")
        finally:
            os.chdir(cwd)
        docker = state / "bin/docker"
        docker.parent.mkdir()
        docker.write_text(
            "#!/usr/bin/env python3\n"
            "import hashlib,json,os,pathlib,socket,sys,time\n"
            f"base=pathlib.Path({str(state)!r}); path=base/'container.json'\n"
            "a=sys.argv[1:]\n"
            "original='unix://'+str(base/'docker.sock')\n"
            "current='unix://'+str(base/'other.sock') if (base/'current-context-switched').exists() else original\n"
            "if a[:2]==['context','inspect']:\n"
            " with (base/'calls.jsonl').open('a') as f: f.write(json.dumps(a)+'\\n')\n"
            " print(current); sys.exit(0)\n"
            "explicit=a[:1]==['--host']\n"
            "endpoint=a[1] if explicit else current\n"
            "if explicit:\n"
            " assert 'DOCKER_CONTEXT' not in os.environ and 'DOCKER_HOST' not in os.environ\n"
            " a=a[2:]\n"
            "with (base/'calls.jsonl').open('a') as f: f.write(json.dumps(a)+'\\n')\n"
            "with (base/'bindings.jsonl').open('a') as f: f.write(json.dumps({'args':a,'endpoint':endpoint,'explicit':explicit})+'\\n')\n"
            "if endpoint!=original:\n"
            " if a[0]=='info': print('daemon-other'); sys.exit(0)\n"
            " if a[0]=='inspect': sys.exit(1)\n"
            " if a[:2]==['container','ls']: sys.exit(0)\n"
            " raise AssertionError('wrong daemon: '+str(a))\n"
            "if a[0]=='info':\n"
            " if (base/'degraded').exists(): sys.exit(2)\n"
            " print('daemon-replacement' if (base/'daemon-changed').exists() else 'daemon-original'); sys.exit(0)\n"
            "if a[:2]==['image','inspect']: print('sha256:fixture'); sys.exit(0)\n"
            "if a[0]=='ps': sys.exit(0)\n"
            "if a[0]=='run' and '--entrypoint' in a: print('260905'); sys.exit(0)\n"
            "if a[0]=='create':\n"
            " assert 'sha256:fixture' in a\n"
            " p=pathlib.Path(a[a.index('-v')+1].split(':')[0]); assert p.name=='project'\n"
            " mounts=[a[i+1] for i,v in enumerate(a) if v=='-v']\n"
            " assert any(v.endswith(':/misterplex-reporter:ro') for v in mounts)\n"
            " assert '/misterplex-reporter/run.sh' in a\n"
            " timing=next(v.split(':')[0] for v in mounts if v.endswith(':/misterplex-timing'))\n"
            " s={'Running':False,'Status':'created','ExitCode':0,'project':str(p),'timing':timing}\n"
            " path.write_text(json.dumps(s)); print('a'*64); sys.exit(0)\n"
            "if a[0]=='start':\n"
            " s=json.loads(path.read_text()); s.update(Running=True,Status='running'); path.write_text(json.dumps(s))\n"
            " p=pathlib.Path(s['project']); assert (p/'rtl/top.sv').read_text()=='module top; endmodule\\n'\n"
            " (base/'compile-entered').touch()\n"
            " if (base/'switch-context-after-start').exists(): (base/'current-context-switched').touch()\n"
            " if (base/'change-daemon-after-start').exists(): (base/'daemon-changed').touch()\n"
            " if (base/'replace-socket-after-start').exists():\n"
            "  (base/'docker.sock').unlink(); os.chdir(base)\n"
            "  s2=socket.socket(socket.AF_UNIX); s2.bind('docker.sock'); s2.close()\n"
            " if (base/'failed-reports').exists():\n"
            "  o=p/'output_files'; o.mkdir()\n"
            "  (o/'Plex.map.rpt').write_text('Analysis successful: estimated ALMs 96586\\n')\n"
            "  (o/'Plex.fit.rpt').write_text('Error 170011: insufficient device resources\\n')\n"
            "  (o/'Plex.fit.summary').write_text('Fitter Status : Failed\\n')\n"
            "  (p/'Plex.flow.rpt').write_text('Flow failed after successful map\\n')\n"
            "  (o/'Plex.rbf').write_bytes(b'partial RBF must never be collected')\n"
            " if (base/'compiler-fails').exists():\n"
            "  s.update(Running=False,Status='exited',ExitCode=42); path.write_text(json.dumps(s)); sys.exit(42)\n"
            " if (base/'client-exits').exists():\n"
            "  if (base/'degrade-after-start').exists(): (base/'degraded').touch()\n"
            "  sys.exit(17)\n"
            " while (base/'pause').exists() and not (base/'release-compile').exists(): time.sleep(0.01)\n"
            " o=p/'output_files'; o.mkdir()\n"
            " for n in ('Plex.rbf','Plex.fit.rpt','Plex.map.rpt','Plex.sta.rpt'): (o/n).write_text('fixture')\n"
            " (o/'Plex.sta.rpt').write_text('; Setup Summary ;\\n; Clock ; Slack ; End Point TNS ;\\n; clk_sys ; 1.000 ; 0.000 ;\\n; Hold Summary ;\\n; Clock ; Slack ; End Point TNS ;\\n; clk_sys ; 0.100 ; 0.000 ;\\n')\n"
            " timing=pathlib.Path(s['timing']); (timing/'compile.exit').write_text('0\\n')\n"
            " if (base/'reporter-fails').exists():\n"
            "  (timing/'reporter.exit').write_text('37\\n'); (timing/'partial.rpt').write_text('partial timing detail')\n"
            "  s.update(Running=False,Status='exited',ExitCode=37); path.write_text(json.dumps(s)); sys.exit(37)\n"
            " (timing/'reporter.exit').write_text('0\\n')\n"
            " sha=hashlib.sha256((o/'Plex.rbf').read_bytes()).hexdigest()\n"
            " for n in ('rbf.before.sha256','rbf.after.sha256'): (timing/n).write_text(sha+'  output_files/Plex.rbf\\n')\n"
            " lines=['corner\\tclock_index\\tcondition\\tclock\\tperiod_ns\\tcheck\\tfile']; total=0\n"
            " corners=4 if (base/'detailed-timing-fails').exists() else 1\n"
            " for corner in range(corners):\n"
            "  for index,clock,period in ((0,'clk_sys','50.0'),(1,'ddr90','11.111')):\n"
            "   for check in ('setup','hold'):\n"
            "    slack='7.497' if check=='setup' else '0.278'; violated=0\n"
            "    if corner==1 and index==0 and check=='setup': slack='-31.164'; violated=10\n"
            "    if corner==3 and index==0 and check=='hold': slack='-0.034'; violated=1\n"
            "    name=f'Plex.corner-{corner:02d}.clock-{index:02d}.{check}.rpt'\n"
            "    text=f'----------------\\n; Command Info ;\\n----------------\\nReport Timing: Found 10 {check} paths ({violated} violated).  Worst case slack is {slack}\\n'\n"
            "    if (base/'malformed-timing').exists() and index==0 and check=='setup': text='malformed path summary\\n'\n"
            "    (timing/name).write_text(text); total+=len(text)\n"
            "    lines.append(f'{corner}\\t{index}\\tcondition{corner}\\t{clock}\\t{period}\\t{check}\\t{name}')\n"
            " (timing/'index.tsv').write_text('\\n'.join(lines)+'\\n')\n"
            " (timing/'complete.summary').write_text(f'corners={corners}\\nreports={corners*4}\\nbytes={total}\\n')\n"
            " if (base/'reporter-mutates-rbf').exists(): (o/'Plex.rbf').write_text('changed')\n"
            " s.update(Running=False,Status='exited'); path.write_text(json.dumps(s)); sys.exit(0)\n"
            "if (base/'degraded').exists(): sys.exit(2)\n"
            "if a[0]=='inspect':\n"
            " if not path.exists(): sys.exit(1)\n"
            " print(path.read_text()); sys.exit(0)\n"
            "if a[:2]==['container','ls']:\n"
            " if path.exists(): print('a'*64)\n"
            " sys.exit(0)\n"
            "if a[0]=='stop':\n"
            " s=json.loads(path.read_text()); s.update(Running=False,Status='exited',ExitCode=143)\n"
            " path.write_text(json.dumps(s)); sys.exit(0)\n"
            "if a[0]=='rm':\n"
            " assert not json.loads(path.read_text())['Running']; path.unlink(); sys.exit(0)\n"
            "raise AssertionError(a)\n"
        )
        docker.chmod(0o755)
        ps = docker.parent / "ps"
        ps.write_text("#!/bin/sh\nexit 0\n")
        ps.chmod(0o755)
        return docker

    def test_transaction_failure_removes_compile_tree_and_releases_lock(self):
        common = self.work / "common-git"
        real_output = build.output

        def fixture_output(args):
            if args[-1] == "--git-common-dir":
                return str(common)
            return real_output(args)

        def failed_compile(work, meta, _fd, _docker):
            self.assertEqual(meta["fpga_video_build_id"], meta["source_sha256"][:8])
            build.unpack(work / "inputs.tar", work / "project", meta)
            raise RuntimeError("injected compiler failure")

        env = {"MISTERPLEX_ALLOW_LOCAL_FIT": "1", "MISTERPLEX_BUILD_ALLOW_UNVERIFIED": "1"}
        with mock.patch.dict(os.environ, env), \
                mock.patch.object(build, "output", side_effect=fixture_output), \
                mock.patch.object(build, "require_local_daemon"), \
                mock.patch.object(build, "image_id", return_value="sha256:fixture"), \
                mock.patch.object(build, "compile_snapshot", side_effect=failed_compile):
            with self.assertRaisesRegex(RuntimeError, "injected compiler failure"):
                build.main(["local-container", "failure", str(self.project), "--derive-video-build-id"])
        self.assertFalse((self.project / "local_out/failure/project").exists())
        with build.fit_lock(common / "misterplex-build/single-fit.lock"):
            pass

    def failed_client_environment(self, degraded=False):
        daemon = self.work / "daemon"
        docker = self.fake_docker(daemon)
        (daemon / "client-exits").touch()
        if degraded:
            (daemon / "degrade-after-start").touch()
        env = {"MISTERPLEX_ALLOW_LOCAL_FIT": "1", "MISTERPLEX_BUILD_ALLOW_UNVERIFIED": "1",
               "MISTER_REMOTE_ALLOW_UNVERIFIED": "1",
               "PATH": str(docker.parent) + os.pathsep + os.environ["PATH"]}
        return daemon, env

    def test_dead_docker_client_does_not_bypass_owned_container_stop(self):
        daemon, env = self.failed_client_environment()
        with mock.patch.dict(os.environ, env), mock.patch.object(build, "ROOT", self.project):
            with self.assertRaisesRegex(RuntimeError, "client failed"):
                build.main(["local-container", "client-died", str(self.project)])
        calls = [json.loads(line) for line in (daemon / "calls.jsonl").read_text().splitlines()]
        self.assertIn(["stop", "--time", "30", "a" * 64], calls)
        self.assertIn(["rm", "a" * 64], calls)
        self.assertFalse((daemon / "container.json").exists())
        self.assertFalse((self.project / "local_out/client-died/project").exists())
        with build.host_lock(build.EXECUTION_KEY), build.host_lock(build.CONTROLLER_KEY):
            pass

    def test_failed_compiler_and_client_reports_survive_private_cleanup(self):
        for failure, status in (("compiler-fails", 42), ("client-exits", 17)):
            with self.subTest(failure=failure):
                daemon = self.work / failure
                docker = self.fake_docker(daemon)
                (daemon / failure).touch()
                (daemon / "failed-reports").touch()
                env = {"MISTERPLEX_ALLOW_LOCAL_FIT": "1", "MISTERPLEX_BUILD_ALLOW_UNVERIFIED": "1",
                       "PATH": str(docker.parent) + os.pathsep + os.environ["PATH"]}
                with mock.patch.dict(os.environ, env), mock.patch.object(build, "ROOT", self.project):
                    with self.assertRaisesRegex(RuntimeError, rf"client failed \({status}\)"):
                        build.main(["local-container", failure, str(self.project)])
                out = self.project / "local_out" / failure
                self.assertFalse((out / "project").exists())
                self.assertIn("96586", (out / "diagnostics/output_files/Plex.map.rpt").read_text())
                self.assertIn("170011", (out / "diagnostics/output_files/Plex.fit.rpt").read_text())
                self.assertIn("Failed", (out / "diagnostics/output_files/Plex.fit.summary").read_text())
                self.assertIn("Flow failed", (out / "diagnostics/Plex.flow.rpt").read_text())
                manifest = json.loads((out / "diagnostics/manifest.json").read_text())
                self.assertEqual(manifest["build_status"], "FAILED")
                self.assertEqual(len(manifest["copied"]), 4)
                self.assertFalse((out / "result.json").exists())
                self.assertEqual(list(out.rglob("*.rbf")), [])
                with build.host_lock(build.EXECUTION_KEY), build.host_lock(build.CONTROLLER_KEY):
                    pass

    def test_failed_diagnostic_collection_does_not_replace_compiler_error(self):
        daemon, env = self.failed_client_environment()
        (daemon / "failed-reports").touch()
        stderr = io.StringIO()
        with mock.patch.dict(os.environ, env), mock.patch.object(build, "ROOT", self.project), \
                mock.patch.object(build, "preserve_failed_diagnostics", side_effect=OSError("diagnostic disk full")), \
                contextlib.redirect_stderr(stderr):
            with self.assertRaisesRegex(RuntimeError, r"client failed \(17\)"):
                build.main(["local-container", "diagnostic-io-error", str(self.project)])
        self.assertIn("diagnostics incomplete", stderr.getvalue())
        out = self.project / "local_out/diagnostic-io-error"
        self.assertFalse((out / "project").exists())
        self.assertFalse((out / "result.json").exists())
        self.assertFalse((out / "Plex.rbf").exists())

    def test_failed_diagnostics_are_bounded_and_truncation_is_explicit(self):
        work = self.work / "bounded-diagnostics"
        reports = work / "project/output_files"
        reports.mkdir(parents=True)
        (work / "project/Plex.flow.rpt").write_bytes(b"R" * 64)
        (reports / "Plex.fit.summary").write_bytes(b"S" * 64)
        (reports / "Plex.rbf").write_bytes(b"never copy")
        with mock.patch.object(build, "DIAGNOSTIC_FILE_BYTES", 16), \
                mock.patch.object(build, "DIAGNOSTIC_TOTAL_BYTES", 20), \
                mock.patch.object(build, "DIAGNOSTIC_FILES", 2):
            build.preserve_failed_diagnostics(work)
        manifest = json.loads((work / "diagnostics/manifest.json").read_text())
        self.assertEqual(manifest["total_bytes"], 20)
        self.assertTrue(manifest["limit_reached"])
        self.assertEqual(len(manifest["copied"]), 2)
        self.assertTrue(all(item["truncated"] for item in manifest["copied"]))
        self.assertTrue(all(item["bytes"] <= 16 for item in manifest["copied"]))
        self.assertEqual(list((work / "diagnostics").rglob("*.rbf")), [])

    def test_failed_diagnostics_reject_file_directory_and_hard_links_and_fifo(self):
        work = self.work / "linked-diagnostics"
        reports = work / "project/output_files"
        reports.mkdir(parents=True)
        outside = self.work / "outside.rpt"
        outside.write_text("outside must not be collected")
        (reports / "linked.rpt").symlink_to(outside)
        os.link(outside, reports / "hardlink.summary")
        os.mkfifo(reports / "pipe.rpt")
        (reports / "Plex.map.rpt").write_text("regular diagnostic")
        build.preserve_failed_diagnostics(work)
        self.assertEqual((work / "diagnostics/output_files/Plex.map.rpt").read_text(), "regular diagnostic")
        for name in ("linked.rpt", "hardlink.summary", "pipe.rpt"):
            self.assertFalse((work / "diagnostics/output_files" / name).exists())
        self.assertEqual(outside.read_text(), "outside must not be collected")
        other = self.work / "linked-report-directory"
        (other / "project").mkdir(parents=True)
        (other / "project/output_files").symlink_to(reports, target_is_directory=True)
        (other / "project/Plex.flow.rpt").write_text("root diagnostic")
        build.preserve_failed_diagnostics(other)
        self.assertTrue((other / "diagnostics/Plex.flow.rpt").is_file())
        self.assertFalse((other / "diagnostics/output_files").exists())

    def test_default_context_switch_after_launch_cannot_redirect_cleanup(self):
        daemon, env = self.failed_client_environment()
        env.update(DOCKER_CONTEXT="mutable-default", DOCKER_HOST="unix:///ignored-by-context.sock")
        (daemon / "switch-context-after-start").touch()
        with mock.patch.dict(os.environ, env), mock.patch.object(build, "ROOT", self.project):
            with self.assertRaisesRegex(RuntimeError, "client failed"):
                build.main(["local-container", "context-switch", str(self.project)])
        self.assertTrue((daemon / "current-context-switched").exists())
        bindings = [json.loads(line) for line in (daemon / "bindings.jsonl").read_text().splitlines()]
        self.assertTrue(all(item["explicit"] for item in bindings))
        self.assertEqual({item["endpoint"] for item in bindings}, {"unix://" + str(daemon / "docker.sock")})
        calls = [json.loads(line) for line in (daemon / "calls.jsonl").read_text().splitlines()]
        self.assertEqual(sum(call[:2] == ["context", "inspect"] for call in calls), 1)
        for operation in ("image", "create", "start", "inspect", "stop", "rm", "container"):
            self.assertTrue(any(item["args"][0] == operation for item in bindings), operation)
        self.assertFalse((daemon / "container.json").exists())
        self.assertFalse((self.project / "local_out/context-switch/project").exists())
        with build.host_lock(build.EXECUTION_KEY), build.host_lock(build.CONTROLLER_KEY):
            pass

    def test_daemon_identity_change_at_pinned_endpoint_preserves_live_inputs(self):
        daemon, env = self.failed_client_environment()
        (daemon / "change-daemon-after-start").touch()
        with mock.patch.dict(os.environ, env), mock.patch.object(build, "ROOT", self.project):
            with self.assertRaisesRegex(build.UnresolvedBuild, "daemon changed"):
                build.main(["local-container", "daemon-switch", str(self.project)])
        self.assertTrue(json.loads((daemon / "container.json").read_text())["Running"])
        self.assertTrue((self.project / "local_out/daemon-switch/project/rtl/top.sv").exists())
        calls = [json.loads(line) for line in (daemon / "calls.jsonl").read_text().splitlines()]
        self.assertNotIn(["rm", "a" * 64], calls)
        with self.assertRaisesRegex(RuntimeError, "host single-fit lease"):
            with build.host_lock(build.CONTROLLER_KEY):
                pass

    def test_socket_replacement_is_uncertain_even_with_same_daemon_id(self):
        daemon, env = self.failed_client_environment()
        (daemon / "replace-socket-after-start").touch()
        with mock.patch.dict(os.environ, env), mock.patch.object(build, "ROOT", self.project):
            with self.assertRaisesRegex(build.UnresolvedBuild, "socket changed"):
                build.main(["local-container", "socket-switch", str(self.project)])
        self.assertTrue(json.loads((daemon / "container.json").read_text())["Running"])
        self.assertTrue((self.project / "local_out/socket-switch/project/rtl/top.sv").exists())
        with self.assertRaisesRegex(RuntimeError, "host single-fit lease"):
            with build.host_lock(build.EXECUTION_KEY):
                pass

    def test_degraded_daemon_keeps_live_inputs_and_all_ownership(self):
        daemon, env = self.failed_client_environment(degraded=True)
        with mock.patch.dict(os.environ, env), mock.patch.object(build, "ROOT", self.project):
            with self.assertRaises(build.UnresolvedBuild):
                build.main(["local-container", "unknown", str(self.project)])
        self.assertTrue(json.loads((daemon / "container.json").read_text())["Running"])
        self.assertTrue((self.project / "local_out/unknown/project/rtl/top.sv").exists())
        owner = build.repository_lock(self.project).with_name("single-fit.lock.owner")
        self.assertTrue(owner.exists())
        with self.assertRaisesRegex(RuntimeError, "host single-fit lease"):
            with build.host_lock(build.EXECUTION_KEY):
                pass
        clone = self.work / "independent-clone"
        subprocess.run(["git", "init", "-q", clone], check=True)
        with mock.patch.dict(os.environ, env), mock.patch.object(build, "ROOT", clone):
            for backend in ("local-container", "remote"):
                with self.assertRaisesRegex(RuntimeError, "host single-fit lease"):
                    build.main([backend, "other-backend", str(self.project)])

    def test_controller_ssh_loss_retains_cross_backend_ownership(self):
        remote_work = self.work / "remote-daemon"
        remote_work.mkdir()
        real_run = build.run

        class LostSsh:
            def __init__(this, args, **_kwargs):
                config = json.loads(shlex.split(args[-1])[-1])
                ready = {"transaction": config["run"], "work": str(remote_work),
                         "image_id": "sha256:fixture", "legacy_build_date": "260905"}
                this.stdout = io.StringIO(json.dumps(ready) + "\n" + '{"sync":true}\n')

                class Input(io.StringIO):
                    def write(stream, data):
                        if json.loads(data) == {"build": True}:
                            meta = json.loads((remote_work / "inputs.json").read_text())
                            build.unpack(remote_work / "inputs.tar", remote_work / "project", meta)
                            (remote_work / "container-running").touch()
                        return super().write(data)

                this.stdin = Input()

            def wait(this, **_kwargs):
                return 255  # Only the SSH client died; the remote container did not.

        def fake_transfer(args, **kwargs):
            if args[0] != "rsync":
                return real_run(args, **kwargs)
            for path in args[3:-1]:
                if Path(path).is_dir():
                    shutil.copytree(path, remote_work / Path(path).name)
                else:
                    shutil.copyfile(path, remote_work / Path(path).name)

        env = {"MISTER_REMOTE_ALLOW_UNVERIFIED": "1", "MISTER_REMOTE_HOST": "lost-ssh-host",
               "MISTERPLEX_ALLOW_LOCAL_FIT": "1", "MISTERPLEX_BUILD_ALLOW_UNVERIFIED": "1"}
        with mock.patch.dict(os.environ, env), mock.patch.object(build, "ROOT", self.project), \
                mock.patch.object(build.subprocess, "Popen", side_effect=LostSsh), \
                mock.patch.object(build, "run", side_effect=fake_transfer):
            # Git queries run before SSH and use subprocess.run/Popen too.
            with mock.patch.object(build, "repository_lock", return_value=self.project / ".git/fit.lock"), \
                    mock.patch.object(build, "source_files", return_value={
                        name: self.project / name for name in ("Plex.qpf", "Plex.qsf", "Plex.sdc", "rtl/top.sv")}):
                original_output = build.output
                with mock.patch.object(build, "output", side_effect=lambda args:
                                       "fixture-head" if args[-2:] == ["rev-parse", "HEAD"] else original_output(args)):
                    with self.assertRaises(build.UnresolvedBuild):
                        build.main(["remote", "disconnect", str(self.project)])
        self.assertTrue((remote_work / "container-running").exists())
        self.assertTrue((remote_work / "project/rtl/top.sv").exists())
        self.assertTrue((self.project / "remote_out/disconnect/inputs.tar").exists())
        marker = self.project / ".git/fit.lock.owner"
        self.assertIn("lost-ssh-host", marker.read_text())
        with mock.patch.dict(os.environ, env), mock.patch.object(build, "ROOT", self.project):
            for backend in ("local-container", "remote"):
                with self.assertRaisesRegex(RuntimeError, "host single-fit lease"):
                    build.main([backend, "must-not-start", str(self.project)])

    def test_remote_terminal_ack_must_match_transaction(self):
        child = mock.Mock()
        child.stdin = io.StringIO()
        child.stdout = io.StringIO('{"complete":true,"transaction":"foreign"}\n')
        session = build.RemoteSession(child, {"transaction": "owned"})
        session.started = True
        with self.assertRaises(build.UnresolvedBuild):
            session.collected()
        self.assertFalse(session.completed)

    def test_remote_docker_endpoint_cannot_escape_host_lease(self):
        with mock.patch.dict(os.environ, {"DOCKER_HOST": "tcp://another-host:2375", "DOCKER_CONTEXT": ""}):
            with self.assertRaisesRegex(RuntimeError, "local Unix socket"):
                build.require_local_daemon()
        with mock.patch.dict(os.environ, {"DOCKER_CONTEXT": "foreign-context"}), \
                mock.patch.object(build, "output", return_value="ssh://another-host"):
            with self.assertRaisesRegex(RuntimeError, "local Unix socket"):
                build.require_local_daemon()

    def remote_fixture(self):
        home = self.work / "remote-home"
        home.mkdir()
        lib = home / "misterfpga-dev/scripts/lib.sh"
        lib.parent.mkdir(parents=True)
        lib.write_text("load_env() { QUARTUS_IMAGE=fixture; }\n")
        docker = self.fake_docker(home)
        (home / "pause").touch()
        (home / "switch-context-after-start").touch()
        env = dict(os.environ, HOME=str(home), PATH=str(docker.parent) + os.pathsep + os.environ["PATH"])
        return home, env

    def start_worker(self, env, slot):
        code = DRIVER.read_text().replace("EXECUTION_KEY = 0x4D505845", f"EXECUTION_KEY = {build.EXECUTION_KEY}")
        return subprocess.Popen(
            [sys.executable, "-c", code, "--worker", json.dumps({"slot": slot, "run": "run"})],
            env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def start_remote_compile(self, worker, home):
        ready = build.receive(worker.stdout)
        with self.assertRaisesRegex(RuntimeError, "host single-fit lease"):
            with build.host_lock(build.EXECUTION_KEY):
                pass
        first, _ = self.make_snapshot()
        build.send(worker.stdin, {"bytes": (first / "inputs.tar").stat().st_size})
        self.assertEqual(build.receive(worker.stdout), {"sync": True})
        for name in ("inputs.tar", "inputs.json", "source.tar"):
            shutil.copyfile(first / name, Path(ready["work"]) / name)
        shutil.copytree(first / "reporter", Path(ready["work"]) / "reporter")
        (self.project / "rtl/top.sv").write_text("edited after remote sync\n")
        build.send(worker.stdin, {"build": True})
        deadline = time.monotonic() + 5
        while not (home / "compile-entered").exists():
            if time.monotonic() > deadline or worker.poll() is not None:
                self.fail("fake remote compiler did not enter")
            time.sleep(0.01)
        return Path(ready["work"])

    def test_remote_lease_covers_sync_compile_and_collection_across_slots(self):
        home, env = self.remote_fixture()
        worker = self.start_worker(env, "slot-a")
        try:
            work = self.start_remote_compile(worker, home)
            other = self.start_worker(env, "slot-b")
            stdout, stderr = other.communicate(timeout=5)
            self.assertEqual(other.returncode, 1, stderr)
            self.assertIn("host single-fit lease", stdout)
            (home / "release-compile").touch()
            self.assertEqual(build.receive(worker.stdout), {"built": True})
            with self.assertRaisesRegex(RuntimeError, "host single-fit lease"):
                with build.host_lock(build.EXECUTION_KEY):
                    pass
            self.assertTrue((work / "Plex.rbf").exists())
            build.send(worker.stdin, {"collected": True})
            self.assertEqual(build.receive(worker.stdout), {"complete": True, "transaction": "run"})
            _, stderr = worker.communicate(timeout=5)
            self.assertEqual(worker.returncode, 0, stderr)
            self.assertFalse((work / "project").exists())
            bindings = [json.loads(line) for line in (home / "bindings.jsonl").read_text().splitlines()]
            self.assertTrue(all(item["explicit"] for item in bindings))
            self.assertEqual({item["endpoint"] for item in bindings}, {"unix://" + str(home / "docker.sock")})
            with build.host_lock(build.EXECUTION_KEY):
                pass
        finally:
            (home / "release-compile").touch()
            if worker.poll() is None:
                worker.communicate(timeout=5)

    def test_remote_failed_reports_are_available_before_collection_ack(self):
        home, env = self.remote_fixture()
        (home / "failed-reports").touch()
        (home / "compiler-fails").touch()
        worker = self.start_worker(env, "failed-report-slot")
        try:
            work = self.start_remote_compile(worker, home)
            result = build.receive(worker.stdout)
            self.assertFalse(result["built"])
            self.assertIn("client failed (42)", result["reason"])
            self.assertTrue((work / "project").exists())
            self.assertIn("96586", (work / "diagnostics/output_files/Plex.map.rpt").read_text())
            self.assertFalse((work / "Plex.rbf").exists())
            self.assertFalse((work / "result.json").exists())
            build.send(worker.stdin, {"collected": True})
            self.assertEqual(build.receive(worker.stdout), {"complete": True, "transaction": "run"})
            _, stderr = worker.communicate(timeout=5)
            self.assertEqual(worker.returncode, 0, stderr)
            self.assertFalse((work / "project").exists())
            self.assertTrue((work / "diagnostics/output_files/Plex.fit.summary").exists())
        finally:
            (home / "release-compile").touch()
            if worker.poll() is None:
                worker.communicate(timeout=5)

    def test_remote_disconnect_does_not_unlock_a_running_compile(self):
        home, env = self.remote_fixture()
        worker = self.start_worker(env, "slot-a")
        try:
            work = self.start_remote_compile(worker, home)
            worker.stdin.close()
            worker.stdin = None
            with self.assertRaisesRegex(RuntimeError, "host single-fit lease"):
                with build.host_lock(build.EXECUTION_KEY):
                    pass
            (home / "release-compile").touch()
            stdout, stderr = worker.communicate(timeout=5)
            self.assertEqual(worker.returncode, 1, stderr)
            self.assertIn("disconnected", stdout)
            self.assertFalse((work / "project").exists())
            with build.host_lock(build.EXECUTION_KEY):
                pass
        finally:
            (home / "release-compile").touch()
            if worker.poll() is None:
                worker.communicate(timeout=5)


if __name__ == "__main__":
    unittest.main()
