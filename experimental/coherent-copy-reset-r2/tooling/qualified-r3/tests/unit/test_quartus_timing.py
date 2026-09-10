#!/usr/bin/env python3
"""All-corner timing gates using actual retained Quartus 17 header formats."""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import sys
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
SPEC = importlib.util.spec_from_file_location("quartus_timing_checker", ROOT / "scripts/check_quartus_timing.py")
CHECKER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = CHECKER
SPEC.loader.exec_module(CHECKER)
import check_timing_exclusions as EXCLUSIONS
from quartus_sta_report import parse_sta_report

HEADERS = json.loads((ROOT / "tests/fixtures/quartus_timing_path_headers.json").read_text())["headers"]
NATIVE = json.loads((ROOT / "tests/fixtures/quartus_sta_multicorner.json").read_text())


class DetailedTiming(unittest.TestCase):
    def setUp(self):
        self.work = Path(os.environ.get("MISTERPLEX_TEST_WORK", ROOT / "build")) / (
            "timing-policy-" + uuid.uuid4().hex)
        self.timing = self.work / "timing"
        self.reporter = self.work / "reporter"
        self.timing.mkdir(parents=True)
        self.reporter.mkdir()
        self.sta = self.work / "Plex.sta.rpt"
        self.sta.write_text(
            "; Setup Summary ;\n; Clock ; Slack ; End Point TNS ;\n"
            "; clk_sys ; 1.000 ; 0.000 ;\n; ddr90 ; 0.500 ; 0.000 ;\n"
            "; Hold Summary ;\n; Clock ; Slack ; End Point TNS ;\n"
            "; clk_sys ; 0.100 ; 0.000 ;\n; ddr90 ; 0.200 ; 0.000 ;\n")
        (self.work / "Plex.rbf").write_bytes(b"retained rbf")
        self.rbf_sha = hashlib.sha256(b"retained rbf").hexdigest()
        for name in ("run.sh", "timing.tcl"):
            (self.reporter / name).write_text("captured reporter fixture\n")
        self.provenance = {
            "schema": "misterplex.timing-reporter.v1", "image_id": "sha256:fixture",
            "input_sha256": "a" * 64,
            "files": {name: hashlib.sha256((self.reporter / name).read_bytes()).hexdigest()
                      for name in ("run.sh", "timing.tcl")},
        }
        (self.reporter / "provenance.json").write_text(json.dumps(self.provenance))
        (self.work / "inputs.json").write_text(json.dumps({
            "image_id": self.provenance["image_id"], "input_sha256": self.provenance["input_sha256"]}))
        for name in ("compile.exit", "reporter.exit"):
            (self.timing / name).write_text("0\n")
        for name in ("rbf.before.sha256", "rbf.after.sha256"):
            (self.timing / name).write_text(self.rbf_sha + "  output_files/Plex.rbf\n")

    def tearDown(self):
        shutil.rmtree(self.work)

    def bundle(self, overrides=None):
        overrides = overrides or {}
        records, total = [], 0
        lines = ["corner\tclock_index\tcondition\tclock\tperiod_ns\tcheck\tfile"]
        for corner in range(4):
            for index, clock, period in ((0, "clk_sys", "50.000"), (1, "ddr90", "11.111"),
                                         (2, "unused_clock", "20.000")):
                for check in ("setup", "hold"):
                    filename = f"Plex.corner-{corner:02d}.clock-{index:02d}.{check}.rpt"
                    text = HEADERS["no_paths" if index == 2 else f"positive_{check}"]
                    data = overrides.get((corner, index, check), text).encode()
                    (self.timing / filename).write_bytes(data)
                    total += len(data)
                    records.append({"corner": corner, "clock": clock, "period_ns": period, "check": check,
                                    "file": filename, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
                    lines.append(f"{corner}\t{index}\tcondition{corner}\t{clock}\t{period}\t{check}\t{filename}")
        (self.timing / "index.tsv").write_text("\n".join(lines) + "\n")
        (self.timing / "complete.summary").write_text(f"corners=4\nreports={len(records)}\nbytes={total}\n")
        (self.timing / "manifest.json").write_text(json.dumps({
            "schema": "misterplex.timing-paths.v1", "reporter": self.provenance,
            "rbf_sha256": self.rbf_sha, "reports": records, "timing_acceptance": "NOT_GRANTED"}))

    def check(self):
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = CHECKER.main(["check", "--sta-rpt", str(self.sta), "--paths-dir", str(self.timing)])
        return code, stdout.getvalue(), stderr.getvalue()

    def extend_bundle(self, overrides=None, decoder_target=False):
        overrides = overrides or {}
        project = self.work / "project"
        project.mkdir(exist_ok=True)
        target = "emu|spath|mb_ctrl|counter[0]" if decoder_target else "out_led"
        sdc = project / "sys_top.sdc"
        sdc.write_text(f"set_false_path -to {{{target}}}\n"
                       "set_clock_groups -exclusive -group [get_clocks clk_sys] "
                       "-group [get_clocks ddr90]\n")
        inactive = project / "optional.sdc"
        inactive.write_text("set_false_path -from {unused_optional}\n")
        inputs = json.loads((self.work / "inputs.json").read_text())
        inputs["input_files"] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                                for p in (sdc, inactive)}
        inputs["input_sha256"] = hashlib.sha256(
            json.dumps(inputs["input_files"], sort_keys=True).encode()).hexdigest()
        (self.work / "inputs.json").write_text(json.dumps(inputs))
        identity = "b" * 32
        command0 = f"set_false_path -to {{{target}}}"
        command1 = "set_clock_groups -exclusive -group sys_collection -group ddr_collection"
        raw0, raw1 = [line.encode().hex() for line in sdc.read_text().splitlines()]
        from test_rbf_build import fake_execution_steps
        steps = fake_execution_steps(identity, (
            ("set_false_path", command0, "sys_top.sdc", 1, raw0),
            ("set_clock_groups", command1, "sys_top.sdc", 2, raw1)))
        event_rows = [
            (0, "begin", -1, "observer", 0, identity.encode().hex()),
            (1, "read-enter", 1, "read_sdc", 0, b"read_sdc".hex()),
            (2, "enter", 0, "set_false_path", 0, command0.encode().hex()),
            (3, "leave", 0, "set_false_path", 0, b"original setter result".hex()),
            (4, "enter", 1, "set_clock_groups", 0, command1.encode().hex()),
            (5, "leave", 1, "set_clock_groups", 0, b"original setter result".hex()),
            (6, "read-leave", 1, "read_sdc", 0, ""),
            (7, "end", -1, "observer", 0, ""),
        ]
        static = {
            "timing-nodes": "type\tname\tdecoder\nreg\temu|spath|mb_ctrl|counter[0]\t1\n"
                            "port\tout_led\t0\nreg\tconfig\t0\n",
            "sdc-sources": "file\nsys_top.sdc\n",
            "exception-commands": "id\torigin\tfile\tline\tkind\tcode\tcommand\traw_hex\n"
                                  f"0\tsdc\tsys_top.sdc\t1\tset_false_path\t0\t{command0}\t{raw0}\n"
                                  f"1\tsdc\tsys_top.sdc\t2\tset_clock_groups\t0\t{command1}\t{raw1}\n",
            "exception-arguments": "id\targument\toption\tmode\tcount\n"
                                   "0\t1\t-to\tkeeper_pattern\t1\n"
                                   "0\t-1\t-from\timplicit_all_keepers\t3\n"
                                   "1\t2\t-group\tcollection\t1\n"
                                   "1\t4\t-group\tcollection\t1\n",
            "exception-objects": "id\targument\ttype\tname\n"
                                  f"0\t1\t{'reg' if decoder_target else 'port'}\t{target}\n"
                                  "1\t2\tclk\tclk_sys\n1\t4\tclk\tddr90\n",
            "observer-events": "sequence\tevent\tid\tkind\tcode\tdetail_hex\n" +
                               "".join("\t".join(map(str, row)) + "\n" for row in event_rows),
            "execution-events": steps["table"],
        }
        audit_index = ["kind\tcorner\tfile"]
        extra_bytes = 0
        for kind, text in static.items():
            name = f"Plex.{kind}.tsv"
            (self.timing / name).write_text(text)
            extra_bytes += len(text.encode())
            audit_index.append(f"{kind}\t-1\t{name}")
        pairs = set()
        scoped_index = ["corner\tclock_index\tcondition\tclock\tperiod_ns\tscope\tcheck\tfile"]
        for corner in range(4):
            for index, clock, period in ((0, "clk_sys", "50.000"), (1, "ddr90", "11.111"),
                                         (2, "unused_clock", "20.000")):
                pairs.add((corner, index, f"condition{corner}", clock, period))
                for scope in ("decoder-from", "decoder-to"):
                    for check in ("setup", "hold"):
                        name = f"Plex.corner-{corner:02d}.clock-{index:02d}.{scope}.{check}.rpt"
                        text = (HEADERS["no_paths"] if index == 2 else
                                f"Report Timing: Found 1 {check} paths (0 violated). Worst case slack is 0.250\n")
                        text = overrides.get((corner, index, scope, check), text)
                        (self.timing / name).write_text(text)
                        extra_bytes += len(text.encode())
                        scoped_index.append(f"{corner}\t{index}\tcondition{corner}\t{clock}\t{period}\t{scope}\t{check}\t{name}")
            for kind in ("sdc-used", "sdc-ignored", "sdc-macros", "exceptions-setup", "exceptions-hold"):
                name = f"Plex.corner-{corner:02d}.{kind}.{'txt' if kind == 'sdc-macros' else 'rpt'}"
                text = f"Mock {kind} report for condition{corner}; no hardware claim.\n"
                (self.timing / name).write_text(text)
                extra_bytes += len(text.encode())
                audit_index.append(f"{kind}\t{corner}\t{name}")
        (self.timing / "audit-index.tsv").write_text("\n".join(audit_index) + "\n")
        (self.timing / "scoped-index.tsv").write_text("\n".join(scoped_index) + "\n")
        (self.timing / "extended.summary").write_text(
            f"schema=misterplex.timing-extended.v2\nscoped_reports={len(scoped_index)-1}\n"
            f"audit_files={len(audit_index)-1}\nkeeper_nodes=3\ndecoder_nodes=1\n"
            f"exception_commands=2\nexception_objects=3\nextra_bytes={extra_bytes}\n")
        manifest = json.loads((self.timing / "manifest.json").read_text())
        reporter = self.work / "reporter"
        provenance = json.loads((reporter / "provenance.json").read_text())
        provenance["schema"] = "misterplex.timing-reporter.v5"
        provenance["input_sha256"] = inputs["input_sha256"]
        for name in ("check_quartus_timing.py", "quartus_sta_report.py", "quartus_timing_observer.py",
                     "quartus_timing_sdk.py", "quartus_hdl_source.py"):
            data = (ROOT / "scripts" / name).read_bytes()
            (reporter / name).write_bytes(data)
            provenance["files"][name] = hashlib.sha256(data).hexdigest()
        (reporter / "observation.id").write_text(identity + "\n")
        (reporter / "sdk-image.id").write_text(provenance["image_id"] + "\n")
        (reporter / "constraint-sources.json").write_text(json.dumps({
            "schema": "misterplex.constraint-sources.v1", "input_sha256": inputs["input_sha256"],
            "hdl": {}, "sdc": {p.name: {"sha256": inputs["input_files"][p.name], "text": p.read_text()}
                              for p in (sdc, inactive)}}))
        for name in ("observation.id", "constraint-sources.json", "sdk-image.id"):
            provenance["files"][name] = hashlib.sha256((reporter / name).read_bytes()).hexdigest()
        (reporter / "provenance.json").write_text(json.dumps(provenance))
        from test_rbf_build import write_fake_sdk
        write_fake_sdk(self.timing)
        (self.timing / "observer.summary").write_text(
            f"schema=misterplex.timing-observer.v2\nobservation_id={identity}\nstate=complete\n"
            "failures=0\nenters=2\nleaves=2\nread_enters=1\nread_leaves=1\npending=0\nevents=8\n" +
            steps["summary"])
        (self.timing / "observer.complete").write_text(f"misterplex.timing-observer.v2:{identity}\n")
        (self.timing / "reporter.log").write_text(
            f"MPX_OBSERVER_BEGIN {identity}\nMPX_OBSERVER_ENTER 0 set_false_path {raw0}\n"
            "MPX_OBSERVER_LEAVE 0 set_false_path 0\n"
            f"MPX_OBSERVER_ENTER 1 set_clock_groups {raw1}\n"
            f"MPX_OBSERVER_LEAVE 1 set_clock_groups 0\nMPX_OBSERVER_COMPLETE {identity}\n" + steps["log"])
        manifest["reporter"] = provenance
        total = sum(record["bytes"] for record in manifest["reports"])
        manifest["extended"] = CHECKER.collect_extended_evidence(self.timing, pairs, total)
        manifest["schema"] = "misterplex.timing-paths.v3"
        (self.timing / "manifest.json").write_text(json.dumps(manifest))
        return project, (sdc, inactive)

    def strict_check(self):
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = CHECKER.main(["check", "--sta-rpt", str(self.sta), "--paths-dir",
                                 str(self.timing), "--require-scoped"])
        return code, stdout.getvalue(), stderr.getvalue()

    def effective_check(self, project, sdcs):
        baseline = self.work / "effective-baseline.json"
        baseline.write_text(json.dumps({"exclusions": {
            entry.fingerprint: "fixture-only justification" for path in sdcs
            for entry in EXCLUSIONS.parse_sdc_exclusions(path)}}))
        stdout, stderr = io.StringIO(), io.StringIO()
        args = ["check", "--baseline", str(baseline), "--project", str(project),
                "--effective-dir", str(self.timing), "--sta-rpt", str(self.sta)]
        for path in sdcs:
            args.extend(("--sdc", str(path)))
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = EXCLUSIONS.main(args)
        return code, stdout.getvalue(), stderr.getvalue()

    def test_extended_scopes_and_actual_source_binding_are_read_only(self):
        self.bundle()
        project, sdcs = self.extend_bundle()
        code, stdout, stderr = self.strict_check()
        self.assertEqual(code, 0, stderr)
        self.assertIn("decoder-from", stdout)
        self.assertIn("decoder-to", stdout)
        self.assertEqual(len(CHECKER.parse_detailed_rows(self.timing)), 72)
        code, stdout, stderr = self.effective_check(project, sdcs)
        self.assertEqual(code, 0, stderr)
        self.assertIn("2 executed source exclusions", stdout)
        self.assertIn("1 unsourced exclusions", stdout)

    def test_new_gate_refuses_legacy_sampling_only_bundle(self):
        self.bundle()
        self.assertEqual(self.check()[0], 0)
        self.assertEqual(self.strict_check()[0], 4)

    def test_negative_scoped_hold_rejects_with_positive_global_reports(self):
        self.bundle()
        self.extend_bundle({(3, 0, "decoder-to", "hold"):
            "Report Timing: Found 1 hold paths (1 violated). Worst case slack is -0.034\n"})
        code, _, stderr = self.strict_check()
        self.assertEqual(code, 1)
        self.assertIn("decoder-to.hold.rpt", stderr)

    def test_missing_extended_report_inventory_and_completion_refuse(self):
        for name in ("scoped-index.tsv", "audit-index.tsv", "extended.summary",
                     "observer.summary", "observer.complete", "Plex.observer-events.tsv", "reporter.log",
                     "Plex.exception-objects.tsv", "Plex.corner-01.sdc-ignored.rpt",
                     "Plex.corner-01.clock-00.decoder-to.hold.rpt"):
            with self.subTest(name=name):
                self.bundle()
                self.extend_bundle()
                (self.timing / name).unlink()
                self.assertEqual(self.strict_check()[0], 4)

    def test_tampered_scoped_membership_or_clock_objects_refuse(self):
        for name, old, new in (
            ("Plex.timing-nodes.tsv", "counter[0]\t1", "counter[0]\t0"),
            ("Plex.exception-objects.tsv", "clk\tddr90", "clk\tinvented_clock"),
            ("Plex.exception-commands.tsv", "set_clock_groups\t0", "set_clock_groups\t1"),
            ("Plex.exception-arguments.tsv", "keeper_pattern\t1", "keeper_pattern\t2"),
        ):
            with self.subTest(name=name):
                self.bundle()
                self.extend_bundle()
                path = self.timing / name
                path.write_text(path.read_text().replace(old, new))
                self.assertEqual(self.strict_check()[0], 4)

    def test_source_hash_and_explicit_decoder_exclusions_cannot_be_waived(self):
        self.bundle()
        project, sdcs = self.extend_bundle(decoder_target=True)
        code, _, stderr = self.effective_check(project, sdcs)
        self.assertEqual(code, 1)
        self.assertIn("explicitly excludes decoder keepers", stderr)
        self.bundle()
        project, sdcs = self.extend_bundle()
        sdcs[0].write_text(sdcs[0].read_text() + "# source changed\n")
        self.assertEqual(self.effective_check(project, sdcs)[0], 4)

    def test_effective_sources_must_be_supplied_and_fully_observed(self):
        self.bundle()
        project, sdcs = self.extend_bundle()
        self.assertEqual(self.effective_check(project, [sdcs[1]])[0], 4)
        sdcs[0].write_text(sdcs[0].read_text() + "set_false_path -from {config}\n")
        inputs = json.loads((self.work / "inputs.json").read_text())
        inputs["input_files"][sdcs[0].name] = hashlib.sha256(sdcs[0].read_bytes()).hexdigest()
        (self.work / "inputs.json").write_text(json.dumps(inputs))
        code, _, stderr = self.effective_check(project, sdcs)
        self.assertEqual(code, 4)
        self.assertIn("frozen input file map hash mismatch", stderr)

    def test_bound_collector_cannot_be_missing_or_modified(self):
        for name in ("check_quartus_timing.py", "quartus_sta_report.py", "quartus_timing_observer.py",
                     "observation.id", "constraint-sources.json"):
            with self.subTest(name=name):
                self.bundle()
                self.extend_bundle()
                path = self.work / "reporter" / name
                path.write_text(path.read_text() + "\n# changed collector\n")
                self.assertEqual(self.strict_check()[0], 4)
                path.unlink()
                self.assertEqual(self.strict_check()[0], 4)

    def native_report(self, missing=None, drop_model=None, missing_clock_model=None):
        titles, bodies = [], []
        for model in NATIVE["models"]:
            if model == drop_model:
                continue
            for section, table in NATIVE["tables"].items():
                if section == "Fmax" and model.startswith("Fast"):
                    continue
                title = f"{model} {section} Summary"
                titles.append(title)
                if (model, section) == missing:
                    continue
                if model == missing_clock_model:
                    table = "\n".join(line for line in table.splitlines() if NATIVE["ddr_clock"] not in line) + "\n"
                bodies.append(f"+------------------------------+\n; {title} ;\n"
                              "+------------------------------+\n" + table + "\n")
        return ("; Table of Contents ;\n" +
                "\n".join(f" {i}. {title}" for i, title in enumerate(titles, 1)) + "\n\n" +
                "\n".join(bodies))

    def exclusion_check(self, sta_text, baseline=None):
        self.sta.write_text(sta_text)
        sdc = self.work / "fixture.sdc"
        sdc.write_text("# no exclusions\n")
        if baseline is None:
            baseline = self.work / "coverage.json"
            baseline.write_text(json.dumps({"exclusions": {}, "expected_sta_clocks": [
                NATIVE["sys_clock"], NATIVE["ddr_clock"]], "min_sta_rows": 6}))
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = EXCLUSIONS.main(["check", "--sdc", str(sdc), "--sta-rpt", str(self.sta),
                                    "--baseline", str(baseline)])
        return code, stdout.getvalue(), stderr.getvalue()

    def test_positive_paths_and_explicit_zero_path_clocks_pass_read_only(self):
        self.bundle()
        before = {path: path.read_bytes() for path in self.work.rglob("*") if path.is_file()}
        code, stdout, stderr = self.check()
        self.assertEqual(code, 0, stderr)
        self.assertIn("NO_PATHS", stdout)
        self.assertEqual(len(CHECKER.parse_detailed_rows(self.timing)), 24)
        self.assertEqual(before, {path: path.read_bytes() for path in self.work.rglob("*") if path.is_file()})

    def test_zero_logic_top_level_and_self_feedback_minima_are_not_filtered(self):
        hdmi = (-0.093, 0.132, 2.743, 3.370)
        holds = (0.425, 0.445, 0.181, 0.168)
        overrides = {}
        for corner in range(4):
            overrides[corner, 0, "setup"] = (
                f"Report Timing: Found 10 setup paths ({int(hdmi[corner] < 0)} violated). "
                f"Worst case slack is {hdmi[corner]:.3f}\n"
                "; From Node ; d[14] ;\n; To Node ; hdmi_out_d[14] ;\n; Logic Levels ; 0 ;\n")
            endpoint = ("btn_timeout[11]", "btn_user", "btn_user", "btn_timeout[0]")[corner]
            overrides[corner, 1, "hold"] = (
                f"Report Timing: Found 10 hold paths (0 violated). Worst case slack is {holds[corner]:.3f}\n"
                f"; From Node ; {endpoint} ;\n; To Node ; {endpoint} ;\n; Logic Levels ; 1 ;\n")
        self.bundle(overrides)
        rows = CHECKER.parse_detailed_rows(self.timing)
        self.assertEqual([r.slack for r in rows if r.clock == "clk_sys" and r.check == "setup"], list(hdmi))
        self.assertEqual([r.slack for r in rows if r.clock == "ddr90" and r.check == "hold"], list(holds))
        self.assertEqual(self.check()[0], 1)

    def test_old_or_error_tainted_observation_cannot_pass_either_gate(self):
        mutations = (
            ("extended.summary", "timing-extended.v2", "timing-extended.v1"),
            ("manifest.json", "timing-paths.v3", "timing-paths.v2"),
            ("observer.summary", "failures=0", "failures=1"),
            ("observer.summary", "state=complete", "state=running"),
            ("observer.summary", "enters=2", "enters=3"),
            ("reporter.log", "MPX_OBSERVER_COMPLETE",
             "Error (332000): Timing exception has no attributable SDC source\nMPX_OBSERVER_COMPLETE"),
        )
        for name, old, new in mutations:
            with self.subTest(name=name, change=new):
                self.bundle()
                project, sdcs = self.extend_bundle()
                path = self.timing / name
                path.write_text(path.read_text().replace(old, new))
                self.assertEqual(self.strict_check()[0], 4)
                self.assertEqual(self.effective_check(project, sdcs)[0], 4)

    def test_extra_corner_setup_and_hold_reject_even_with_green_standard_sta(self):
        self.bundle({(1, 0, "setup"): HEADERS["extra_corner_setup"],
                     (3, 0, "hold"): HEADERS["extra_corner_hold"]})
        code, _, stderr = self.check()
        self.assertEqual(code, 1)
        self.assertIn("corner=1 clock=clk_sys: slack=-31.164", stderr)
        self.assertIn("corner=3 clock=clk_sys: slack=-0.034", stderr)

    def test_declared_violation_rejects_even_when_slack_rounds_to_zero(self):
        header = HEADERS["positive_hold"].replace("(0 violated)", "(1 violated)").replace("0.278", "-0.000")
        self.bundle({(3, 0, "hold"): header})
        self.assertEqual(self.check()[0], 1)

    def test_malformed_missing_or_wrong_kind_summary_is_not_zero_paths(self):
        malformed = (
            "", "Nothing to report.\n", HEADERS["no_paths"] + "unexpected trailing data\n",
            HEADERS["positive_setup"].replace("7.497", "NaN"),
            HEADERS["positive_setup"].replace("7.497", "1e999"),
            HEADERS["positive_setup"].replace("10 setup", "0 setup"),
            HEADERS["positive_setup"].replace("(0 violated)", "(11 violated)"),
            HEADERS["positive_setup"] * 2, HEADERS["positive_hold"],
        )
        for header in malformed:
            with self.subTest(header=header):
                self.bundle({(0, 0, "setup"): header})
                self.assertEqual(self.check()[0], 4)

    def test_missing_or_altered_indexed_evidence_refuses(self):
        for name in ("Plex.corner-01.clock-00.setup.rpt", "index.tsv", "complete.summary", "manifest.json"):
            with self.subTest(name=name):
                self.bundle()
                (self.timing / name).unlink()
                self.assertEqual(self.check()[0], 4)
        self.bundle()
        (self.timing / "Plex.corner-01.clock-00.setup.rpt").write_text(HEADERS["extra_corner_setup"])
        self.assertEqual(self.check()[0], 4)
        self.bundle()
        (self.timing / "complete.summary").write_text("corners=4\nreports=1\nbytes=0\n")
        self.assertEqual(self.check()[0], 4)

    def test_omitted_clock_pair_or_changed_provenance_refuses(self):
        self.bundle()
        manifest = json.loads((self.timing / "manifest.json").read_text())
        manifest["reports"].pop()
        (self.timing / "manifest.json").write_text(json.dumps(manifest))
        self.assertEqual(self.check()[0], 4)
        self.bundle()
        (self.reporter / "timing.tcl").write_text("different reporter")
        self.assertEqual(self.check()[0], 4)

    def test_standard_sta_remains_required_and_strict(self):
        self.bundle()
        self.sta.write_text(self.sta.read_text().replace("1.000", "-1.000"))
        self.assertEqual(self.check()[0], 1)
        self.sta.write_text("; Setup Summary ;\n; Clock ; Slack ; End Point TNS ;\n; clk_sys ; N/A ; 0 ;\n")
        self.assertEqual(self.check()[0], 4)
        self.sta.write_text("; no timing summary\n")
        self.assertEqual(self.check()[0], 4)

    def test_native_models_preserve_all_slack_sections_fmax_and_failure_provenance(self):
        self.bundle()
        self.sta.write_text(self.native_report())
        report = parse_sta_report(self.sta)
        self.assertEqual(len(report.slack_rows), 36)
        self.assertEqual(len(report.fmax_rows), 4)
        self.assertEqual({row.model for row in report.slack_rows}, set(NATIVE["models"]))
        self.assertEqual({row.model for row in report.fmax_rows}, set(NATIVE["models"][:2]))
        self.assertEqual({row.section for row in report.slack_rows},
                         {"Setup", "Hold", "Recovery", "Removal", "Minimum Pulse Width"})
        code, stdout, stderr = self.check()
        self.assertEqual(code, 1, stderr)
        for slack in ("-7.569", "-0.832", "-0.44", "-0.553"):
            self.assertIn("slack=" + slack, stderr)
        for model in NATIVE["models"]:
            self.assertIn(model, stderr)
        self.assertIn("17.37 MHz", stdout)
        self.assertNotIn("no timing summary rows", stderr)

    def test_native_missing_malformed_or_truncated_tables_refuse(self):
        self.bundle()
        cases = (
            self.native_report(missing=(NATIVE["models"][3], "Hold")),
            self.native_report().replace("Slow 1100mV 100C Model Setup", "Slow 1100mV INVALID Model Setup"),
            self.native_report().replace("; Clock ; Slack ; End Point TNS ;", "; Clock ; Wrong ; End Point TNS ;", 1),
            self.native_report().rstrip().rsplit("\n", 1)[0],
        )
        for text in cases:
            with self.subTest(text=text[-100:]):
                self.sta.write_text(text)
                self.assertEqual(self.check()[0], 4)
                with self.assertRaises(ValueError):
                    EXCLUSIONS.parse_sta_clocks(self.sta)

    def test_native_missing_whole_model_cannot_hide_behind_detailed_corners(self):
        self.bundle()
        self.sta.write_text(self.native_report(drop_model=NATIVE["models"][3]))
        code, _, stderr = self.check()
        self.assertEqual(code, 4)
        self.assertIn("every detailed timing corner", stderr)

    def test_exclusion_coverage_uses_identical_parser_and_checks_each_model(self):
        code, stdout, stderr = self.exclusion_check(self.native_report())
        self.assertEqual(code, 0, stderr)
        coverage = EXCLUSIONS.parse_sta_clocks(self.sta)
        report = parse_sta_report(self.sta)
        self.assertEqual(coverage.total_rows, len(report.slack_rows))
        self.assertEqual(coverage.model_rows, {model: 9 for model in NATIVE["models"]})
        self.assertIn(NATIVE["models"][3], stdout)
        code, _, stderr = self.exclusion_check(self.native_report(missing_clock_model=NATIVE["models"][2]))
        self.assertEqual(code, 1)
        self.assertIn(NATIVE["ddr_clock"], stderr)
        self.assertIn(NATIVE["models"][2], stderr)

    def test_repository_baseline_requires_exact_core_clocks_in_every_model(self):
        baseline = EXCLUSIONS.DEFAULT_BASELINE
        expected = json.loads(baseline.read_text())["expected_sta_clocks"]
        self.assertEqual(expected, [NATIVE["sys_clock"], NATIVE["ddr_clock"]])
        code, _, stderr = self.exclusion_check(self.native_report(), baseline)
        self.assertEqual(code, 0, stderr)
        for replacement in (
            "general[0].gpll",
            "pll_audio|pll_audio_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk",
        ):
            with self.subTest(replacement=replacement):
                report = self.native_report().replace(NATIVE["sys_clock"], replacement)
                code, _, stderr = self.exclusion_check(report, baseline)
                self.assertEqual(code, 1)
                self.assertIn(NATIVE["sys_clock"], stderr)
        code, _, stderr = self.exclusion_check(
            self.native_report(missing_clock_model=NATIVE["models"][2]), baseline)
        self.assertEqual(code, 1)
        self.assertIn(NATIVE["ddr_clock"], stderr)
        self.assertIn(NATIVE["models"][2], stderr)


if __name__ == "__main__":
    unittest.main()
