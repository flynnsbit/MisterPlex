"""Host Tcl regressions for the preserved V12 swallowed-ENTER failure."""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import unittest
from unittest import mock
import uuid
import copy
import contextlib
import errno

from test_rbf_build import BuildPolicy, ROOT, build, write_fake_sdk

sys.path.insert(0, str(ROOT / "scripts"))
from check_quartus_timing import parse_detailed_rows
from check_timing_exclusions import effective_exclusions
from quartus_timing_observer import hdl_attributes
from quartus_timing_sdk import compiled_sources

FAILURE = json.loads((ROOT / "tests/fixtures/quartus_hdl_observer_failure.json").read_text())


@unittest.skipUnless(os.environ.get("MISTERPLEX_HOST_TCL"),
                     "MISTERPLEX_HOST_TCL must name a host tclsh, never Quartus")
class ObserverPolicy(unittest.TestCase):
    setUp = BuildPolicy.setUp
    tearDown = BuildPolicy.tearDown
    make_snapshot = BuildPolicy.make_snapshot

    def prepare_case(self, sdc="set_false_path -to {out_led}\n", hdl=False, image="sha256:fixture"):
        (self.project / "Plex.sdc").write_text(sdc)
        source = self.project / "rtl/embedded.v"
        if source.exists():
            source.unlink()
        if hdl:
            statement = FAILURE["statement"]
            value = '-name SDC_STATEMENT "' + statement + '"'
            encoded = value.replace("\\", "\\\\").replace('"', '\\"')
            source.write_text(f'module {FAILURE["entity"]};\n'
                              f'(* altera_attribute = "{encoded}" *) reg din_s1;\nendmodule\n')
        work, meta = self.make_snapshot("observer-" + uuid.uuid4().hex, image=image)
        if hdl:
            (work / "compile.log").write_text(
                "Info (12021): Found 1 design units, including 1 entities, in source file rtl/embedded.v\n"
                f'    Info (12023): Found entity 1: {FAILURE["entity"]} File: /build/rtl/embedded.v Line: 1\n'
                f'Info (12128): Elaborating entity "{FAILURE["entity"]}" for hierarchy "test" '
                "File: /build/instantiator.v Line: 27\n")
        build.unpack(work / "inputs.tar", work / "project", meta)
        (work / "timing").mkdir()
        write_fake_sdk(work / "timing")
        (work / "unobserved").mkdir()
        (work / "project/output_files").mkdir()
        rbf = b"Host mock RBF only; no physical tool invoked."
        (work / "project/output_files/Plex.rbf").write_bytes(rbf)
        (work / "Plex.rbf").write_bytes(rbf)
        for name in ("compile.exit", "reporter.exit"):
            (work / "timing" / name).write_text("0\n")
        for name in ("rbf.before.sha256", "rbf.after.sha256"):
            (work / "timing" / name).write_text(build.digest(rbf) + "  output_files/Plex.rbf\n")
        return work, meta

    def invoke(self, work, variant, unobserved=False):
        runner = Path(os.environ["MISTERPLEX_HOST_TCL"])
        self.assertRegex(runner.name, r"^tclsh(?:8[.]6|9[.]0)?$")
        target = work / ("unobserved" if unobserved else "timing")
        result = subprocess.run([
            runner, ROOT / "tests/fixtures/quartus_timing_mock.tcl", work / "reporter/timing.tcl",
            work / "project", target, ("unobserved:" if unobserved else "") + variant,
        ], capture_output=True, text=True, timeout=30)
        (target / "reporter.log").write_text(result.stdout + result.stderr)
        rows = [line.split("\t") for line in (target / "mock-semantics.tsv").read_text().splitlines()[1:]]
        collections = dict(line.split("\t") for line in
                           (target / "mock-collections.tsv").read_text().splitlines()[1:])
        # Cross-interpreter opaque handles differ because inventory queries
        # allocate collections. Compare their actual object identities only.
        for row in rows:
            for index in range(3, 7):
                text = bytes.fromhex(row[index]).decode()
                text = re.sub(r"\b_col[0-9]+\b",
                              lambda match: "<collection " + collections[match[0]] + ">", text)
                row[index] = text.encode().hex()
        return result, rows

    def collect(self, work, meta):
        build.verify_timing_reports(work, meta, build.verify_reporter(work, meta))
        return json.loads((work / "timing/manifest.json").read_text())

    def retain(self, work, variant):
        destination = os.environ.get("MISTERPLEX_OBSERVER_EVIDENCE")
        if not destination:
            return
        target = Path(destination) / (variant + "-" + work.name)
        target.mkdir(parents=True)
        for name in ("observer.summary", "observer.complete", "Plex.observer-events.tsv",
                     "Plex.exception-commands.tsv", "Plex.exception-arguments.tsv",
                     "Plex.exception-objects.tsv", "reporter.log", "collector-failure.json",
                     "mock-semantics.tsv", "mock-collections.tsv", "host-refusal.txt", "manifest.json"):
            path = work / "timing" / name
            if path.exists():
                shutil.copyfile(path, target / name)
        for name in ("provenance.json", "constraint-sources.json", "observation.id"):
            shutil.copyfile(work / "reporter" / name, target / ("reporter-" + name))
        if (work / "compile.log").exists():
            shutil.copyfile(work / "compile.log", target / "compiler-definition.log")

    def compare_original(self, work, variant, count=1):
        _, baseline = self.invoke(work, variant, unobserved=True)
        observed, rows = self.invoke(work, variant)
        calls = lambda values: [row for row in values if row[0] == "setter"]
        self.assertEqual(len(calls(rows)), count)
        self.assertEqual(calls(rows), calls(baseline), "observer changed/replayed original arguments")
        return observed, baseline, rows

    def test_preserved_hdl_enter_failure_never_prevents_the_setter(self):
        work, meta = self.prepare_case("# no file exclusions\n", hdl=True)
        result, baseline, rows = self.compare_original(work, "hdl-enter-error")
        self.assertEqual(FAILURE["provenance"]["historical_reporter_exit"], 0)
        self.assertEqual(rows, baseline, "ENTER observer failure changed the original return/options")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        summary = (work / "timing/observer.summary").read_text()
        self.assertIn("state=failed", summary)
        self.assertIn("enters=1\nleaves=1", summary)
        journal = (work / "timing/Plex.observer-events.tsv").read_text()
        self.assertIn(FAILURE["callback_error"].encode().hex(), journal)
        self.assertFalse((work / "timing/observer.complete").exists())
        with self.assertRaises(RuntimeError):
            self.collect(work, meta)
        self.assertTrue((work / "timing/collector-failure.json").is_file())
        self.assertFalse((work / "timing/manifest.json").exists())
        self.retain(work, "preserved-hdl-enter-failure")

    def test_unknown_hdl_is_a_recorded_failure_not_a_fabricated_sdc(self):
        work, meta = self.prepare_case("# no file exclusions\n")
        result, baseline, rows = self.compare_original(work, "hdl-unknown")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(rows, baseline)
        commands = (work / "timing/Plex.exception-commands.tsv").read_text()
        self.assertIn("\thdl_pending\t\t0\tset_false_path\t0\t", commands)
        with self.assertRaisesRegex(RuntimeError, "HDL origin is unknown/unfrozen/ambiguous"):
            self.collect(work, meta)
        failure = json.loads((work / "timing/collector-failure.json").read_text())
        self.assertIn("exact source attribution required", failure["error"])
        self.assertFalse((work / "timing/manifest.json").exists())
        self.retain(work, "unknown-hdl")

    def test_missing_hdl_frame_cannot_be_guessed_from_matching_frozen_source(self):
        work, meta = self.prepare_case("# no file exclusions\n", hdl=True)
        result, baseline, rows = self.compare_original(work, "hdl-no-frame")
        self.assertEqual(rows, baseline)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("state=failed", (work / "timing/observer.summary").read_text())
        self.assertFalse((work / "timing/observer.complete").exists())
        with self.assertRaises(RuntimeError):
            self.collect(work, meta)
        self.retain(work, "hdl-no-frame")

    def test_attributable_hdl_is_hash_bound_and_cannot_exclude_decoder(self):
        for variant in ("hdl-attributed", "hdl-decoder"):
            with self.subTest(variant=variant):
                work, meta = self.prepare_case("# no file exclusions\n", hdl=True)
                result, baseline, rows = self.compare_original(work, variant)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(rows, baseline)
                manifest = self.collect(work, meta)
                self.assertEqual(manifest["extended"]["exceptions"][0]["origin"], "hdl")
                self.assertEqual(manifest["extended"]["exceptions"][0]["file"], "")
                proof = manifest["extended"]["observer"]["hdl_sources"][0]
                self.assertEqual(proof["file"], "rtl/embedded.v")
                self.assertEqual(proof["source_sha256"], meta["input_files"]["rtl/embedded.v"])
                self.assertEqual(proof["entity"], FAILURE["entity"])
                self.assertEqual(proof["statement"], FAILURE["statement"])
                self.assertEqual(proof["compiled_source"]["definition"]["file"], "rtl/embedded.v")
                self.assertEqual(proof["compiled_source"]["log"]["sha256"],
                                 build.digest((work / "compile.log").read_bytes()))
                self.assertEqual(len(parse_detailed_rows(work / "timing")), 72)
                errors, files, empty = effective_exclusions(
                    work / "timing", work / "project", [work / "project/Plex.sdc"])
                self.assertEqual((files, empty), (0, 0))
                if variant == "hdl-decoder":
                    self.assertTrue(any("explicitly excludes decoder keepers" in error for error in errors))
                else:
                    self.assertEqual(errors, [])
                self.retain(work, variant)

    def actual_sdk_case(self, variant="hdl-attributed"):
        catalog = Path(os.environ["MISTERPLEX_SDK_CATALOG"])
        report = Path(os.environ["MISTERPLEX_SDK_NATIVE_MAP"])
        data = json.loads(catalog.read_text())
        self.assertEqual(data["image_id"],
                         "sha256:1fba8b9347973365e9f7851d73f7cb035e38fefb827cbf0ed2ea291b48bdf6dd")
        self.assertEqual(build.digest(report.read_bytes()),
                         "2987ab1f8c0521c03027ee0dbe82b929d0d60856dda2c2260fe9e3c226f341d5")
        work, meta = self.prepare_case("# no file exclusions\n", image=data["image_id"])
        shutil.copyfile(catalog, work / "timing/sdk-catalog.json")
        shutil.copyfile(report, work / "timing/Plex.compiled-sources.rpt")
        result, baseline, rows = self.compare_original(work, variant)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(rows, baseline)
        return work, meta

    def test_sdk_literal_concatenation_and_incomplete_source_table(self):
        value = '-name SDC_STATEMENT "set_false_path -to [get_keepers target]"'
        encoded = value.replace("\\", "\\\\").replace('"', '\\"')
        literal = 'module sample;\n(* altera_attribute = {"' + encoded + '"} *) reg target;\nendmodule\n'
        self.assertEqual(hdl_attributes("sample.v", literal)[0]["line"], 2)
        self.assertEqual(hdl_attributes("sample.v", literal.replace('"}', '", PARAM}')), [])
        self.assertEqual(hdl_attributes("sample.v", literal.replace('{"', '{PARAM, "')), [])
        from test_rbf_build import MOCK_SOURCE_TABLE
        self.assertEqual(len(compiled_sources(MOCK_SOURCE_TABLE.encode())), 1)
        for invalid in (MOCK_SOURCE_TABLE.replace("+---+---+", ""),
                        MOCK_SOURCE_TABLE + MOCK_SOURCE_TABLE,
                        MOCK_SOURCE_TABLE + "Error (1): native source evidence failed\n"):
            with self.assertRaises(ValueError):
                compiled_sources(invalid.encode())

    def test_fitted_database_is_retained_with_bytes_and_mode_identity(self):
        work, _ = self.prepare_case()
        database = work / "project/db"
        database.mkdir()
        path = database / "fixture.cdb"
        path.write_bytes(b"synthetic database retention fixture, not a real netlist")
        path.chmod(0o440)
        before = path.read_bytes()
        build.retain_analysis_project(work, "host-fixture")
        record = json.loads((work / "analysis-project.json").read_text())
        self.assertEqual(path.read_bytes(), before)
        self.assertEqual(record["files"]["db/fixture.cdb"],
                         {"sha256": build.digest(before), "bytes": len(before), "mode": "0440"})
        self.assertEqual(record["analysis_or_deployment_approval"], "NOT_GRANTED")
        self.assertEqual(record["database_status"], "retained-unvalidated")
        self.assertFalse(record["fitted_database_validated"])
        self.assertEqual(record["project_path"], str(work / "project"))

    def test_retention_missing_partial_unsafe_and_unresolved_never_claim_fitted(self):
        for variant in ("missing-project", "missing-database", "failed-compile", "linked-database",
                        "unresolved"):
            with self.subTest(variant=variant):
                work, meta = self.prepare_case()
                if variant == "missing-project":
                    shutil.rmtree(work / "project")
                elif variant in {"failed-compile", "linked-database", "unresolved"}:
                    database = work / "project/db"
                    database.mkdir()
                    target = database / "fixture.cdb"
                    if variant == "linked-database":
                        outside = work / "outside"
                        outside.write_text("outside must never be read or inventoried")
                        target.symlink_to(outside)
                    else:
                        target.write_text("partial synthetic database")
                    (work / "timing/compile.exit").write_text("42\n")
                if variant == "linked-database":
                    with self.assertRaisesRegex(RuntimeError, "inventory is incomplete"):
                        build.retain_analysis_project(work, "compile-and-report", "RuntimeError")
                else:
                    build.retain_analysis_project(work, "compile-and-report", "RuntimeError",
                                                  inventory_safe=variant != "unresolved", cohort_metadata=meta)
                record = json.loads((work / "analysis-project.json").read_text())
                expected = {"missing-project": "missing", "missing-database": "missing",
                            "failed-compile": "incomplete-or-unvalidated",
                            "linked-database": "inventory-incomplete",
                            "unresolved": "ownership-unresolved"}[variant]
                self.assertEqual(record["database_status"], expected)
                self.assertFalse(record["fitted_database_validated"])
                self.assertEqual(record["cohort"]["input_sha256"], meta["input_sha256"])
                if variant == "unresolved":
                    self.assertEqual(record["files"], {})
                    self.assertFalse(record["inventory_complete"])
                if variant != "missing-project":
                    self.assertTrue((work / "project").is_dir())

    def test_nested_retention_enumeration_stat_open_and_read_errors_fail_closed(self):
        for variant in ("scan-permission", "scan-oserror", "scan-iteration", "entry-stat-permission",
                        "entry-stat-vanished", "directory-open-permission", "read-error",
                        "root-stat-permission", "metadata-stat-permission"):
            with self.subTest(variant=variant):
                work, _ = self.prepare_case()
                nested = work / "project/db/generated/nested"
                nested.mkdir(parents=True)
                leaf = nested / "fixture.cdb"
                leaf.write_bytes(b"synthetic nested database must remain intact")
                native_scan, native_stat = os.scandir, os.stat
                native_open, native_fdopen = os.open, os.fdopen

                def coordinate(path, parent=None):
                    if isinstance(path, int):
                        return Path(os.readlink(f"/proc/self/fd/{path}"))
                    return Path(os.readlink(f"/proc/self/fd/{parent}")) / path if parent is not None else Path(path)

                @contextlib.contextmanager
                def failed_iteration(path):
                    with native_scan(path) as entries:
                        def rows():
                            yield next(entries)
                            raise OSError(errno.EIO, "controlled nested iterator failure")
                        yield rows()

                def scan(path):
                    if coordinate(path) == nested:
                        if variant == "scan-permission":
                            raise PermissionError(errno.EACCES, "controlled nested enumeration failure")
                        if variant == "scan-oserror":
                            raise OSError(errno.EIO, "controlled nested enumeration failure")
                        if variant == "scan-iteration":
                            return failed_iteration(path)
                    return native_scan(path)

                def get_stat(path, *args, **kwargs):
                    target = coordinate(path, kwargs.get("dir_fd"))
                    if variant == "entry-stat-permission" and target == leaf or \
                            variant == "root-stat-permission" and target == work / "project" or \
                            variant == "metadata-stat-permission" and target == work / "inputs.json":
                        raise PermissionError(errno.EACCES, "controlled stat failure")
                    if variant == "entry-stat-vanished" and target == leaf:
                        raise FileNotFoundError(errno.ENOENT, "controlled post-enumeration disappearance")
                    return native_stat(path, *args, **kwargs)

                def open_file(path, *args, **kwargs):
                    if variant == "directory-open-permission" and coordinate(path, kwargs.get("dir_fd")) == nested:
                        raise PermissionError(errno.EACCES, "controlled directory open failure")
                    return native_open(path, *args, **kwargs)

                @contextlib.contextmanager
                def fdopen(descriptor, *args, **kwargs):
                    target = coordinate(descriptor)
                    with native_fdopen(descriptor, *args, **kwargs) as stream:
                        class FailedReader:
                            def fileno(self):
                                return stream.fileno()

                            def read(self, size):
                                raise OSError(errno.EIO, "controlled nested data read failure")
                        yield FailedReader() if variant == "read-error" and target == leaf else stream

                with mock.patch.object(build.os, "scandir", side_effect=scan), \
                        mock.patch.object(build.os, "stat", side_effect=get_stat), \
                        mock.patch.object(build.os, "open", side_effect=open_file), \
                        mock.patch.object(build.os, "fdopen", side_effect=fdopen):
                    with self.assertRaisesRegex(RuntimeError, "inventory is incomplete") as failure:
                        build.retain_analysis_project(work, "complete")
                record = json.loads((work / "analysis-project.json").read_text())
                self.assertEqual(record["database_status"], "inventory-incomplete")
                self.assertFalse(record["inventory_complete"])
                self.assertFalse(record["fitted_database_validated"])
                self.assertEqual(record["inventory_error_type"], type(failure.exception.__cause__).__name__)
                self.assertEqual(leaf.read_bytes(), b"synthetic nested database must remain intact")
                self.assertTrue((work / "project").is_dir())

    def test_nested_inventory_is_complete_and_verified_missing_is_distinct(self):
        for variant in ("no-database", "empty-database-directories", "nested-database"):
            with self.subTest(variant=variant):
                work, _ = self.prepare_case()
                expected = {}
                if variant != "no-database":
                    (work / "project/db/generated/nested").mkdir(parents=True)
                    (work / "project/incremental_db/partition").mkdir(parents=True)
                if variant == "nested-database":
                    for name in ("db/generated/nested/a.cdb", "incremental_db/partition/b.qdb"):
                        data = ("synthetic complete enumeration " + name).encode()
                        path = work / "project" / name
                        path.write_bytes(data)
                        expected[name] = build.digest(data)
                record = build.retain_analysis_project(work, "complete")
                self.assertTrue(record["inventory_complete"])
                self.assertTrue(record["input_files_match"])
                self.assertFalse(record["fitted_database_validated"])
                self.assertEqual(set(record["database_files"]), set(expected))
                for name, digest in expected.items():
                    self.assertEqual(record["files"][name]["sha256"], digest)
                self.assertEqual(record["database_status"], "retained-unvalidated" if expected else "missing")

    @unittest.skipUnless(os.environ.get("MISTERPLEX_SDK_CATALOG") and os.environ.get("MISTERPLEX_SDK_NATIVE_MAP"),
                         "requires actual pinned SDK-derived catalog and retained V12 native map")
    def test_actual_sdk_source_proof_and_decoder_policy(self):
        for variant in ("hdl-attributed", "hdl-decoder"):
            with self.subTest(variant=variant):
                work, meta = self.actual_sdk_case(variant)
                manifest = self.collect(work, meta)
                proof = manifest["extended"]["observer"]["hdl_sources"][0]
                self.assertEqual(proof["source_sha256"],
                                 "36e2c3efac7d0af1f92db47dee690eebf402949fc8dd8c55d12dee7c8cccf292")
                self.assertEqual((proof["entity_line"], proof["line"]), (18, 45))
                self.assertIn("compiled-source-table", proof["method"])
                self.assertNotIn("definition", proof["compiled_source"])
                self.assertEqual(proof["compiled_source"]["dependency"]["compiled"]["report_line"], 751)
                errors, _, _ = effective_exclusions(
                    work / "timing", work / "project", [work / "project/Plex.sdc"])
                if variant == "hdl-decoder":
                    self.assertTrue(any("explicitly excludes decoder keepers" in error for error in errors))
                else:
                    self.assertEqual(errors, [])
                self.assertEqual(len(parse_detailed_rows(work / "timing")), 72)
                self.retain(work, "actual-sdk-" + variant)

    @unittest.skipUnless(os.environ.get("MISTERPLEX_SDK_CATALOG") and os.environ.get("MISTERPLEX_SDK_NATIVE_MAP"),
                         "requires actual pinned SDK-derived catalog and retained V12 native map")
    def test_actual_sdk_missing_tampered_incomplete_or_error_evidence_refuses(self):
        for mutation in ("missing-catalog", "missing-report", "catalog-error", "catalog-log",
                         "image", "source-hash", "statement-hash", "attribute-definition",
                         "missing-dependency", "duplicate-dependency", "report-hash",
                         "wrong-sdk-source-path", "unselected-sdk-source", "unknown-native-entity"):
            with self.subTest(mutation=mutation):
                work, meta = self.actual_sdk_case()
                timing = work / "timing"
                path = timing / "sdk-catalog.json"
                data = json.loads(path.read_text())
                source = next(item for item in data["dependencies"] if item["attributes"])
                if mutation == "missing-catalog":
                    path.unlink()
                elif mutation == "missing-report":
                    (timing / "Plex.compiled-sources.rpt").unlink()
                elif mutation == "catalog-error":
                    (timing / "sdk-catalog.exit").write_text("1\n")
                elif mutation == "catalog-log":
                    (timing / "sdk-catalog.log").write_text("Error: swallowed SDK producer error\n")
                elif mutation == "image":
                    data["image_id"] = "sha256:" + "0" * 64
                elif mutation == "source-hash":
                    source["sha256"] = "0" * 64
                elif mutation == "statement-hash":
                    source["attributes"][0]["statement_sha256"] = "0" * 64
                elif mutation == "attribute-definition":
                    source["attributes"][0]["entity_line"] += 1
                elif mutation == "missing-dependency":
                    data["dependencies"].pop()
                elif mutation == "duplicate-dependency":
                    data["dependencies"][-1] = copy.deepcopy(source)
                elif mutation == "report-hash":
                    data["native_report"]["sha256"] = "0" * 64
                elif mutation == "wrong-sdk-source-path":
                    source["sdk_relative"] = "../instantiator.v"
                elif mutation == "unselected-sdk-source":
                    source["compiled"]["used"] = "no"
                elif mutation == "unknown-native-entity":
                    log = timing / "reporter.log"
                    log.write_text(log.read_text().replace("Entity altera_std_synchronizer", "Entity unknown"))
                if path.exists():
                    path.write_text(json.dumps(data))
                with self.assertRaises(RuntimeError):
                    self.collect(work, meta)
                self.assertTrue((timing / "collector-failure.json").is_file())
                self.assertFalse((timing / "manifest.json").exists())

    @unittest.skipUnless(os.environ.get("MISTERPLEX_SDK_CATALOG") and os.environ.get("MISTERPLEX_SDK_NATIVE_MAP"),
                         "requires actual pinned SDK-derived catalog and retained V12 native map")
    def test_actual_sdk_catalog_mutation_after_collection_fails_both_gates(self):
        work, meta = self.actual_sdk_case()
        self.collect(work, meta)
        path = work / "timing/sdk-catalog.json"
        data = json.loads(path.read_text())
        data["dependencies"][0]["sha256"] = "a" * 64
        path.write_text(json.dumps(data))
        with self.assertRaises(ValueError):
            parse_detailed_rows(work / "timing")
        with self.assertRaises(ValueError):
            effective_exclusions(work / "timing", work / "project", [work / "project/Plex.sdc"])

    def test_hdl_provenance_requires_native_context_not_just_matching_text(self):
        for mutation in ("entity", "missing-context", "unobserved-native", "source-hash"):
            with self.subTest(mutation=mutation):
                work, meta = self.prepare_case("# no file exclusions\n", hdl=True)
                result, _ = self.invoke(work, "hdl-attributed")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                log = work / "timing/reporter.log"
                text = log.read_text()
                if mutation == "entity":
                    log.write_text(text.replace("Entity altera_std_synchronizer", "Entity unrelated_entity"))
                elif mutation == "missing-context":
                    log.write_text("\n".join(line for line in text.splitlines() if "(33216" not in line) + "\n")
                elif mutation == "unobserved-native":
                    log.write_text(text.replace("MPX_OBSERVER_ENTER 0", "NOT_AN_OBSERVER_ENTER 0"))
                else:
                    path = work / "reporter/constraint-sources.json"
                    data = json.loads(path.read_text())
                    data["hdl"]["rtl/embedded.v"]["sha256"] = "0" * 64
                    path.chmod(0o644)
                    path.write_text(json.dumps(data))
                    provenance = work / "reporter/provenance.json"
                    record = json.loads(provenance.read_text())
                    record["files"][path.name] = build.digest(path.read_bytes())
                    provenance.chmod(0o644)
                    provenance.write_text(json.dumps(record))
                with self.assertRaises(RuntimeError):
                    self.collect(work, meta)
                self.assertTrue((work / "timing/collector-failure.json").is_file())

    def test_matching_hdl_text_or_an_instantiation_location_is_not_source_proof(self):
        for mutation in ("no-definition", "different-file", "duplicate-definition", "no-elaboration",
                         "external-library", "changed-definition-line", "missing-compiler-log",
                         "error-tainted-compiler-log"):
            with self.subTest(mutation=mutation):
                work, meta = self.prepare_case("# no file exclusions\n", hdl=True)
                result, _ = self.invoke(work, "hdl-attributed")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                path = work / "compile.log"
                text = path.read_text()
                if mutation == "no-definition":
                    text = "\n".join(line for line in text.splitlines() if "(12128)" in line) + "\n"
                elif mutation == "different-file":
                    text = text.replace("rtl/embedded.v", "rtl/not_the_bound_definition.v")
                elif mutation == "duplicate-definition":
                    text += text
                elif mutation == "no-elaboration":
                    text = "\n".join(line for line in text.splitlines() if "(12128)" not in line) + "\n"
                elif mutation == "external-library":
                    text = text.replace("/build/rtl/embedded.v", "/opt/unfrozen-sdk/embedded.v")
                elif mutation == "changed-definition-line":
                    text = text.replace("embedded.v Line: 1", "embedded.v Line: 9")
                elif mutation == "error-tainted-compiler-log":
                    text += FAILURE["swallowed_diagnostics"][0] + "\n"
                else:
                    path.unlink()
                if mutation != "missing-compiler-log":
                    path.write_text(text)
                with self.assertRaises(RuntimeError):
                    self.collect(work, meta)
                self.assertFalse((work / "timing/manifest.json").exists())
                self.assertTrue((work / "timing/collector-failure.json").is_file())

    def test_original_setter_codes_results_options_and_error_state_are_preserved(self):
        for variant in ("success", "setter-error", "setter-return", "setter-break",
                        "setter-continue", "setter-custom-code", "hdl-setter-error",
                        "setter-error-and-command-write-error"):
            with self.subTest(variant=variant):
                work, meta = self.prepare_case("# no file exclusions\n" if variant.startswith("hdl-")
                                               else "set_false_path -to {out_led}\n", hdl=True)
                result, baseline, rows = self.compare_original(work, variant)
                self.assertEqual(rows, baseline)
                if variant == "success":
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.collect(work, meta)
                else:
                    self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                    self.assertFalse((work / "timing/observer.complete").exists())
                self.retain(work, variant)

    def test_observer_io_resolution_and_coverage_failures_cannot_suppress_setters(self):
        for variant in ("argument-write-error", "command-write-error", "journal-write-error",
                        "status-write-error", "origin-resolution-error", "collection-size-error",
                        "keeper-query-error", "object-info-error", "trace-removed", "unresolved-through",
                        "begin-write-error", "begin-query-error", "source-inventory-error", "read-sdc-error"):
            with self.subTest(variant=variant):
                sdc = ("set_false_path -through {unknown_pin}\n" if variant == "unresolved-through"
                       else "set_false_path -to {out_led}\n")
                work, meta = self.prepare_case(sdc)
                result, baseline, rows = self.compare_original(work, variant)
                self.assertEqual(rows, baseline)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertFalse((work / "timing/observer.complete").exists())
                with self.assertRaises(RuntimeError):
                    self.collect(work, meta)
                self.assertTrue((work / "timing/collector-failure.json").is_file())
                self.retain(work, variant)

    def test_nested_setters_are_paired_and_not_replayed(self):
        for variant, inner in (("nested-original", "set_min_delay -to {config} 0.0"),
                               ("nested-same-setter", "set_false_path -to {config}")):
            with self.subTest(variant=variant):
                work, meta = self.prepare_case(
                    f"proc native_inner {{}} {{\n  {inner}\n}}\nset_false_path -to {{out_led}}\n")
                result, baseline, rows = self.compare_original(work, variant, count=2)
                self.assertEqual(rows, baseline)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                manifest = self.collect(work, meta)
                self.assertEqual(len(manifest["extended"]["exceptions"]), 2)
                self.assertEqual(effective_exclusions(
                    work / "timing", work / "project", [work / "project/Plex.sdc"]), ([], 2, 0))
                self.retain(work, variant)

    def test_reentrant_observer_is_a_failure_and_does_not_replay_original(self):
        work, meta = self.prepare_case()
        result, rows = self.invoke(work, "reentrant-observer")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        calls = [row[1] for row in rows if row[0] == "setter"]
        self.assertEqual(calls, ["set_min_delay", "set_false_path"])
        self.assertIn("Reentrant timing observer callback".encode().hex(),
                      (work / "timing/Plex.observer-events.tsv").read_text())
        with self.assertRaises(RuntimeError):
            self.collect(work, meta)

    def test_swallowed_native_error_is_rejected_even_with_complete_zero_error_observer(self):
        work, meta = self.prepare_case()
        result, baseline, rows = self.compare_original(work, "swallowed-native-error")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(rows, baseline)
        self.assertIn("failures=0", (work / "timing/observer.summary").read_text())
        for diagnostic in FAILURE["swallowed_diagnostics"]:
            self.assertIn(diagnostic, (work / "timing/reporter.log").read_text())
        with self.assertRaisesRegex(RuntimeError, "error-tainted reporter log"):
            self.collect(work, meta)
        with self.assertRaisesRegex(RuntimeError, "persistent timing collector failure"):
            self.collect(work, meta)
        self.retain(work, "swallowed-native-error")

    def test_collector_requires_full_source_coverage_even_if_all_exits_and_counts_are_zero(self):
        work, meta = self.prepare_case("if {0} {\nset_false_path -to {out_led}\n}\n")
        result, _ = self.invoke(work, "success")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("enters=0\nleaves=0", (work / "timing/observer.summary").read_text())
        with self.assertRaisesRegex(RuntimeError, "SDC execution coverage mismatch"):
            self.collect(work, meta)

    def test_input_file_map_cannot_be_rebound_without_its_frozen_digest(self):
        work, meta = self.prepare_case()
        result, _ = self.invoke(work, "success")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        path = work / "inputs.json"
        inputs = json.loads(path.read_text())
        inputs["input_files"]["Plex.sdc"] = "0" * 64
        path.write_text(json.dumps(inputs))
        with self.assertRaisesRegex(RuntimeError, "frozen input file map hash mismatch"):
            self.collect(work, meta)

    def test_host_failure_sink_error_is_explicit_and_cannot_create_a_manifest(self):
        work, meta = self.prepare_case("# no file exclusions\n")
        result, _ = self.invoke(work, "hdl-unknown")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        original_open = Path.open

        def broken_sink(path, *args, **kwargs):
            if path.name == "collector-failure.json":
                raise OSError("Injected collector failure sink error")
            return original_open(path, *args, **kwargs)

        with mock.patch.object(Path, "open", broken_sink):
            with self.assertRaisesRegex(RuntimeError, "collector failure evidence write failed") as failure:
                self.collect(work, meta)
        self.assertFalse((work / "timing/manifest.json").exists())
        (work / "timing/host-refusal.txt").write_text(str(failure.exception) + "\n")
        self.retain(work, "host-failure-sink-error")

    def test_hdl_attribute_parser_does_not_attribute_comments_or_other_modules(self):
        value = '-name SDC_STATEMENT \\"' + FAILURE["statement"] + '\\"'
        attr = f'(* altera_attribute = "{value}" *) reg din_s1;'
        text = f"module unrelated;\n// {attr}\nendmodule\nmodule actual;\n{attr}\nendmodule\n"
        records = hdl_attributes("rtl/fixture.v", text)
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["entity"], "actual")
        self.assertEqual(records[0]["line"], 5)


if __name__ == "__main__":
    unittest.main()
