#!/usr/bin/env python3
"""Fail Quartus STA reports with negative timing slack."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import stat
import sys
from dataclasses import dataclass
from pathlib import Path

from quartus_sta_report import FmaxRow, NUMERIC, SlackRow, number, parse_sta_report
from quartus_timing_observer import REPORTER_FILES, collect_observer_evidence


@dataclass(frozen=True)
class PathSlack:
    corner: int
    clock: str
    check: str
    paths: int
    violated: int
    slack: float | None
    file: str
    scope: str = "global"


def parse_path_summary(text: str, expected_check: str) -> tuple[int, int, float | None]:
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    if (len(lines) == 4 and set(lines[0]) == {"-"} and lines[1] == "; Report Timing ;"
            and set(lines[2]) == {"-"} and lines[3] == "Nothing to report."):
        return 0, 0, None
    headers = [line for line in lines if line.startswith("Report Timing:")]
    if len(headers) != 1:
        raise ValueError("missing or duplicate detailed timing summary")
    match = re.fullmatch(
        rf"Report Timing: Found (\d+) (setup|hold) paths \((\d+) violated\)\."
        rf"\s+Worst case slack is ({NUMERIC})", headers[0])
    if not match:
        raise ValueError("malformed detailed timing summary")
    paths, check, violated, slack = match.groups()
    count, violations = int(paths), int(violated)
    if check != expected_check or not 1 <= count <= 10 or not 0 <= violations <= count:
        raise ValueError("detailed timing summary check/count mismatch")
    return count, violations, number(slack)


def read_evidence(path: Path, limit: int) -> bytes:
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
        raise ValueError(f"invalid/oversized timing evidence: {path}")
    with path.open("rb") as stream:
        data = stream.read(limit + 1)
    if len(data) > limit:
        raise ValueError(f"timing evidence grew beyond limit: {path}")
    return data


def read_table(path: Path, header: str, max_rows: int, limit: int = 16 * 1024**2) -> list[list[str]]:
    data = read_evidence(path, limit)
    if not data.endswith(b"\n"):
        raise ValueError(f"truncated timing table: {path.name}")
    lines = data.decode().splitlines()
    if not lines or lines[0] != header or len(lines) - 1 > max_rows:
        raise ValueError(f"missing/malformed/excess timing table: {path.name}")
    width = len(header.split("\t"))
    rows = [line.split("\t") for line in lines[1:]]
    if any(len(row) != width or any(len(value) > 4096 or
               re.search(r"[\x00-\x1f\x7f]", value) for value in row) for row in rows):
        raise ValueError(f"malformed timing table row: {path.name}")
    return rows


def collect_extended_evidence(
    directory: Path, pairs: set[tuple[int, int, str, str, str]], global_bytes: int,
) -> dict:
    summary_lines = read_evidence(directory / "extended.summary", 2048).decode().splitlines()
    summary = dict(line.split("=", 1) for line in summary_lines)
    fields = {"schema", "scoped_reports", "audit_files", "keeper_nodes", "decoder_nodes",
              "exception_commands", "exception_objects", "extra_bytes"}
    if len(summary_lines) != len(fields) or set(summary) != fields or \
            summary["schema"] != "misterplex.timing-extended.v2":
        raise ValueError("missing/malformed extended timing completion")
    counts = {key: int(value) for key, value in summary.items() if key != "schema"}
    if any(value < 0 for value in counts.values()):
        raise ValueError("negative extended timing count")
    corners = {pair[0] for pair in pairs}
    clocks = {pair[3] for pair in pairs}
    total = 0

    def artifact(name: str, limit: int) -> tuple[dict, bytes]:
        nonlocal total
        data = read_evidence(directory / name, limit)
        if not data.strip():
            raise ValueError(f"empty timing evidence: {name}")
        total += len(data)
        if total + global_bytes > 128 * 1024**2:
            raise ValueError("complete timing evidence byte budget exceeded")
        return {"file": name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}, data

    static = {"timing-nodes", "sdc-sources", "exception-commands", "exception-arguments",
              "exception-objects", "observer-events", "execution-events"}
    per_corner = {"sdc-used", "sdc-ignored", "sdc-macros", "exceptions-setup", "exceptions-hold"}
    expected_audits = {(kind, -1) for kind in static} | {
        (kind, corner) for kind in per_corner for corner in corners}
    audits, seen = [], set()
    for kind, corner, name in read_table(directory / "audit-index.tsv", "kind\tcorner\tfile", 64):
        ci = int(corner)
        expected_name = (f"Plex.{kind}.tsv" if ci == -1 else
                         f"Plex.corner-{ci:02d}.{kind}.{'txt' if kind == 'sdc-macros' else 'rpt'}")
        key = (kind, ci)
        if key not in expected_audits or key in seen or name != expected_name:
            raise ValueError("unsafe/duplicate/unexpected timing audit")
        seen.add(key)
        record, _ = artifact(name, 16 * 1024**2)
        audits.append({"kind": kind, "corner": ci, **record})
    if seen != expected_audits or len(audits) != counts["audit_files"]:
        raise ValueError("incomplete timing audit coverage")

    nodes = {}
    object_types = {"clk", "reg", "port", "cell", "pin", "comb", "net", "edge"}
    for kind, name, decoder in read_table(directory / "Plex.timing-nodes.tsv",
                                         "type\tname\tdecoder", 250000):
        if not name or kind not in object_types or name in nodes or decoder not in {"0", "1"}:
            raise ValueError("invalid/duplicate timing keeper")
        nodes[name] = (kind, decoder == "1")
    if len(nodes) != counts["keeper_nodes"] or \
            sum(value[1] for value in nodes.values()) != counts["decoder_nodes"]:
        raise ValueError("keeper/decoder inventory count mismatch")
    active_sources = []
    for (name,) in read_table(directory / "Plex.sdc-sources.tsv", "file", 64):
        path = Path(name)
        if (not name or path.is_absolute() or ".." in path.parts or "\\" in name or
                path.as_posix() != name or path.suffix != ".sdc" or name in active_sources):
            raise ValueError("unsafe/duplicate active SDC source")
        active_sources.append(name)
    if not active_sources:
        raise ValueError("missing active SDC source inventory")

    commands = {}
    kinds = {"set_clock_groups", "set_false_path", "set_max_delay", "set_min_delay",
             "set_multicycle_path"}
    for index, origin, file, line, kind, code, command, raw_hex in read_table(
            directory / "Plex.exception-commands.tsv",
            "id\torigin\tfile\tline\tkind\tcode\tcommand\traw_hex", 512):
        ci, ln = int(index), int(line)
        if (ci in commands or ci < 0 or origin not in {"sdc", "hdl_pending"} or
                (origin == "sdc" and (file not in active_sources or ln < 1)) or
                (origin == "hdl_pending" and (file or ln != 0)) or
                kind not in kinds or code != "0" or not command or not raw_hex):
            raise ValueError("invalid/incomplete exception command")
        commands[ci] = {"id": ci, "origin": origin, "file": file, "line": ln, "kind": kind,
                        "command": command, "raw_hex": raw_hex, "arguments": []}
    if set(commands) != set(range(counts["exception_commands"])):
        raise ValueError("exception command inventory is incomplete")
    options = {"-group", "-from", "-to", "-through", "-from_clock", "-to_clock",
               "-rise_from", "-fall_from", "-rise_to", "-fall_to", "-rise_through",
               "-fall_through", "-rise_from_clock", "-fall_from_clock",
               "-rise_to_clock", "-fall_to_clock"}
    arguments = {}
    for index, position, option, mode, count in read_table(
            directory / "Plex.exception-arguments.tsv", "id\targument\toption\tmode\tcount", 32768):
        ci, ai, size = int(index), int(position), int(count)
        key = ci, ai
        if (ci not in commands or key in arguments or option not in options or
                mode not in {"collection", "clock_pattern", "keeper_pattern", "implicit_all_keepers"} or
                not 0 <= size <= 250000):
            raise ValueError("invalid exception endpoint argument")
        implicit = mode == "implicit_all_keepers"
        if implicit:
            if (ai, option) not in {(-1, "-from"), (-2, "-to")} or size != len(nodes):
                raise ValueError("invalid implicit-all endpoint inventory")
        elif not 1 <= ai <= 128:
            raise ValueError("invalid explicit endpoint position")
        value = {"position": ai, "option": option, "mode": mode, "count": size,
                 "explicit_decoder_objects": 0}
        arguments[key] = (value, 0)
        commands[ci]["arguments"].append(value)
    object_count = 0
    for index, position, kind, name in read_table(
            directory / "Plex.exception-objects.tsv", "id\targument\ttype\tname", 250000):
        key = int(index), int(position)
        if key not in arguments:
            raise ValueError("exception object has no argument")
        value, seen_count = arguments[key]
        if value["mode"] == "implicit_all_keepers":
            raise ValueError("implicit endpoint has fabricated explicit objects")
        if (value["option"] == "-group" or "clock" in value["option"]) and kind != "clk":
            raise ValueError("clock endpoint inventory contains a non-clock object")
        if kind == "clk":
            if name not in clocks:
                raise ValueError("exception clock missing from analyzed clock inventory")
        elif name not in nodes or nodes[name][0] != kind:
            raise ValueError("exception endpoint is outside the actual keeper inventory")
        elif nodes[name][1]:
            value["explicit_decoder_objects"] += 1
        arguments[key] = value, seen_count + 1
        object_count += 1
    if object_count != counts["exception_objects"] or any(
            value["mode"] != "implicit_all_keepers" and seen_count != value["count"]
            for value, seen_count in arguments.values()):
        raise ValueError("incomplete expanded endpoint object inventory")
    for value in commands.values():
        args = value["arguments"]
        if value["kind"] == "set_clock_groups":
            if not args or any(arg["option"] != "-group" for arg in args):
                raise ValueError("incomplete clock-group membership")
        elif (not any("from" in arg["option"] for arg in args) or
              not any("to" in arg["option"] for arg in args)):
            raise ValueError("exception does not account for both endpoint directions")

    reports, seen = [], set()
    expected = {(pair, scope, check) for pair in pairs
                for scope in ("decoder-from", "decoder-to") for check in ("setup", "hold")}
    if not counts["decoder_nodes"]:
        expected = set()
    nonempty = set()
    for corner, clock_index, condition, clock, period, scope, check, name in read_table(
            directory / "scoped-index.tsv",
            "corner\tclock_index\tcondition\tclock\tperiod_ns\tscope\tcheck\tfile", 2048):
        ci, ki = int(corner), int(clock_index)
        pair = ci, ki, condition, clock, period
        key = pair, scope, check
        if (key not in expected or key in seen or
                name != f"Plex.corner-{ci:02d}.clock-{ki:02d}.{scope}.{check}.rpt"):
            raise ValueError("unsafe/duplicate/unexpected decoder timing report")
        seen.add(key)
        record, data = artifact(name, 8 * 1024**2)
        paths, violated, slack = parse_path_summary(data.decode(), check)
        if paths > 1:
            raise ValueError("decoder scope report must contain its single true minimum")
        if paths:
            nonempty.add((ci, check))
        reports.append({"corner": ci, "clock": clock, "period_ns": period, "scope": scope,
                        "check": check, "paths": paths, "violated": violated, "slack": slack, **record})
    if seen != expected or len(reports) != counts["scoped_reports"]:
        raise ValueError("incomplete decoder setup/hold scope coverage")
    if counts["decoder_nodes"] and nonempty != {
            (corner, check) for corner in corners for check in ("setup", "hold")}:
        raise ValueError("decoder scope lacks analyzed paths in an operating model")
    if total != counts["extra_bytes"]:
        raise ValueError("extended timing byte count mismatch")
    observer = collect_observer_evidence(directory, commands, active_sources, read_evidence, read_table)
    compiler_logs = {proof["compiled_source"]["log"]["sha256"]: proof["compiled_source"]["log"]["bytes"]
                     for proof in observer["hdl_sources"]}
    if total + global_bytes + sum(compiler_logs.values()) > 128 * 1024**2:
        raise ValueError("HDL compiler provenance exceeds complete timing byte budget")
    total += sum(compiler_logs.values())
    metadata = []
    for name in ("extended.summary", "audit-index.tsv", "scoped-index.tsv",
                 "observer.summary", "observer.complete", "reporter.log",
                 "sdk-catalog.json", "sdk-catalog.log", "sdk-catalog.exit", "Plex.compiled-sources.rpt"):
        data = read_evidence(directory / name, 32 * 1024**2 if name == "Plex.compiled-sources.rpt"
                             else 16 * 1024**2 if name in {"reporter.log", "sdk-catalog.json"} else 2 * 1024**2)
        if total + global_bytes + len(data) > 128 * 1024**2:
            raise ValueError("observer metadata exceeds complete timing byte budget")
        total += len(data)
        metadata.append({"file": name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
    return {"schema": summary["schema"], "scope": "h264-mb-rbsp-stub-v1",
            "keeper_nodes": len(nodes), "decoder_nodes": counts["decoder_nodes"],
            "active_sdc_files": active_sources, "exceptions": [commands[i] for i in sorted(commands)],
            "reports": reports, "audits": audits, "metadata": metadata, "observer": observer,
            "clock_group_coverage": "resolved membership; no Spectra-Q-only path-report claim"}


def parse_detailed_rows(directory: Path) -> list[PathSlack]:
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError("missing or linked detailed timing directory")
    manifest = json.loads(read_evidence(directory / "manifest.json", 8 * 1024**2))
    if manifest["schema"] not in {"misterplex.timing-paths.v1", "misterplex.timing-paths.v3"}:
        raise ValueError("unsupported detailed timing manifest")
    if (directory / "collector-failure.json").exists() or (directory / "collector-failure.json").is_symlink():
        raise ValueError("timing evidence contains a persistent collector failure")
    records = manifest["reports"]
    if not isinstance(records, list) or not 1 <= len(records) <= 1024:
        raise ValueError("missing/excess indexed timing reports")
    by_name = {record["file"]: record for record in records}
    if len(by_name) != len(records):
        raise ValueError("duplicate detailed timing artifacts")
    reporter_dir = directory.parent / "reporter"
    if reporter_dir.is_symlink():
        raise ValueError("linked timing reporter provenance")
    reporter = json.loads(read_evidence(reporter_dir / "provenance.json", 64 * 1024))
    inputs = json.loads(read_evidence(directory.parent / "inputs.json", 4 * 1024**2))
    reporter_schemas = {
        "misterplex.timing-reporter.v1": {"run.sh", "timing.tcl"},
        "misterplex.timing-reporter.v5": REPORTER_FILES,
    }
    if reporter != manifest["reporter"] or reporter["schema"] not in reporter_schemas:
        raise ValueError("detailed timing reporter provenance mismatch")
    if manifest["schema"] == "misterplex.timing-paths.v3" and \
            reporter["schema"] != "misterplex.timing-reporter.v5":
        raise ValueError("extended timing evidence requires the bound Python collector")
    if reporter["image_id"] != inputs["image_id"] or reporter["input_sha256"] != inputs["input_sha256"]:
        raise ValueError("detailed timing input/image provenance mismatch")
    if not isinstance(reporter["files"], dict) or \
            set(reporter["files"]) != reporter_schemas[reporter["schema"]]:
        raise ValueError("missing timing reporter files")
    if reporter["schema"] == "misterplex.timing-reporter.v5" and \
            {path.name for path in reporter_dir.iterdir()} != REPORTER_FILES | {"provenance.json"}:
        raise ValueError("unlisted timing reporter execution files")
    for name, expected in reporter["files"].items():
        if hashlib.sha256(read_evidence(
                reporter_dir / name, 16 * 1024**2 if name == "constraint-sources.json" else 1024**2)).hexdigest() != expected:
            raise ValueError(f"timing reporter hash mismatch: {name}")
    for name in ("compile.exit", "reporter.exit"):
        if read_evidence(directory / name, 64).decode().strip() != "0":
            raise ValueError("detailed timing reporter did not complete successfully")
    for name in ("rbf.before.sha256", "rbf.after.sha256"):
        fields = read_evidence(directory / name, 2048).decode().split()
        if not fields or fields[0] != manifest["rbf_sha256"]:
            raise ValueError("detailed timing RBF before/after hash mismatch")
    rbf = read_evidence(directory.parent / "Plex.rbf", 32 * 1024**2)
    if hashlib.sha256(rbf).hexdigest() != manifest["rbf_sha256"]:
        raise ValueError("detailed timing RBF provenance mismatch")

    index = read_evidence(directory / "index.tsv", 2 * 1024**2).decode().splitlines()
    if not index or index[0] != "corner\tclock_index\tcondition\tclock\tperiod_ns\tcheck\tfile":
        raise ValueError("missing detailed timing index header")
    rows, seen, pairs, total = [], set(), {}, 0
    for line in index[1:]:
        fields = line.split("\t")
        if len(fields) != 7:
            raise ValueError("malformed detailed timing index")
        corner, clock_index, condition, clock, period, check, filename = fields
        ci, ki = int(corner), int(clock_index)
        if not 0 <= ci < 8 or not 0 <= ki < 64 or check not in ("setup", "hold") or number(period) <= 0:
            raise ValueError("invalid detailed timing clock/corner/check")
        if filename != f"Plex.corner-{ci:02d}.clock-{ki:02d}.{check}.rpt" or filename in seen:
            raise ValueError("unsafe/duplicate detailed timing filename")
        seen.add(filename)
        record = by_name.get(filename)
        if record is None or any(record[key] != value for key, value in
                                 (("corner", ci), ("clock", clock), ("check", check), ("period_ns", period))):
            raise ValueError(f"detailed timing manifest/index mismatch: {filename}")
        data = read_evidence(directory / filename, 8 * 1024**2)
        if len(data) != record["bytes"] or hashlib.sha256(data).hexdigest() != record["sha256"]:
            raise ValueError(f"detailed timing artifact hash/size mismatch: {filename}")
        total += len(data)
        if total > 128 * 1024**2:
            raise ValueError("detailed timing byte budget exceeded")
        pairs.setdefault((ci, ki, condition, clock, period), set()).add(check)
        try:
            paths, violated, slack = parse_path_summary(data.decode(), check)
        except ValueError as exc:
            raise ValueError(f"{filename}: {exc}") from exc
        rows.append(PathSlack(ci, clock, check, paths, violated, slack, filename))
    if seen != set(by_name) or not pairs or any(checks != {"setup", "hold"} for checks in pairs.values()):
        raise ValueError("missing indexed timing artifacts or setup/hold pairs")
    summary_lines = read_evidence(directory / "complete.summary", 2048).decode().splitlines()
    if len(summary_lines) != 3:
        raise ValueError("missing/malformed timing completion summary")
    summary = dict(line.split("=", 1) for line in summary_lines)
    if set(summary) != {"reports", "bytes", "corners"}:
        raise ValueError("malformed timing completion summary")
    if (int(summary["reports"]) != len(rows) or int(summary["bytes"]) != total
            or int(summary["corners"]) != len({row.corner for row in rows})):
        raise ValueError("incomplete detailed timing evidence")
    if manifest["schema"] == "misterplex.timing-paths.v3":
        extended = collect_extended_evidence(directory, set(pairs), total)
        if extended != manifest.get("extended"):
            raise ValueError("extended timing provenance/content mismatch")
        rows.extend(PathSlack(record["corner"], record["clock"], record["check"],
                              record["paths"], record["violated"], record["slack"],
                              record["file"], record["scope"])
                    for record in extended["reports"])
    return rows


def parse_slack_rows(path: Path) -> list[SlackRow]:
    return parse_sta_report(path).slack_rows


def parse_fmax_rows(path: Path) -> list[FmaxRow]:
    return parse_sta_report(path).fmax_rows


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--sta-rpt", type=Path, required=True)
    ap.add_argument("--paths-dir", type=Path,
                    help="Retained timing/ directory: gate every indexed setup/hold clock and corner")
    ap.add_argument("--require-scoped", action="store_true",
                    help="Require complete decoder and effective-exception evidence, not legacy path sampling")
    args = ap.parse_args(argv[1:])
    if not args.sta_rpt.exists():
        print(f"QUARTUS_TIMING_REFUSED(exit=4): missing STA report {args.sta_rpt}", file=sys.stderr)
        return 4

    try:
        report = parse_sta_report(args.sta_rpt)
        fmax, slack_rows = report.fmax_rows, report.slack_rows
        if not slack_rows:
            raise ValueError("STA report has no timing summary rows")
        path_rows = parse_detailed_rows(args.paths_dir) if args.paths_dir else []
        scoped_missing = args.require_scoped and not any(row.scope != "global" for row in path_rows)
        native_models = {row.model for row in slack_rows if row.model}
        if path_rows and native_models and len(native_models) != len({row.corner for row in path_rows}):
            raise ValueError("native STA models do not cover every detailed timing corner")
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f"QUARTUS_TIMING_REFUSED(exit=4): {exc}", file=sys.stderr)
        return 4
    print("TIMING_FMAX_TABLE_BEGIN")
    print("| model | clock | Fmax | Restricted Fmax |")
    print("|---|---|---:|---:|")
    for row in fmax:
        print(f"| {row.model or 'legacy/unlabelled'} | `{row.clock}` | {row.fmax} | {row.restricted} |")
    print("TIMING_FMAX_TABLE_END")
    print("TIMING_SLACK_TABLE_BEGIN")
    print("| model | section | clock | slack | endpoint TNS |")
    print("|---|---|---|---:|---:|")
    for row in slack_rows:
        print(f"| {row.model or 'legacy/unlabelled'} | {row.section} | `{row.clock}` | {row.slack:g} | {row.tns:g} |")
    print("TIMING_SLACK_TABLE_END")
    if args.paths_dir:
        print("TIMING_PATH_SLACK_TABLE_BEGIN")
        print("| corner | clock | scope | check | paths | violated | worst slack |")
        print("|---|---|---|---|---:|---:|---:|")
        for row in path_rows:
            slack = "NO_PATHS" if row.slack is None else f"{row.slack:g}"
            print(f"| {row.corner} | `{row.clock}` | {row.scope} | {row.check} | {row.paths} | {row.violated} | {slack} |")
        print("TIMING_PATH_SLACK_TABLE_END")

    failures = [row for row in slack_rows if row.slack < 0 or row.tns < 0]
    path_failures = [row for row in path_rows if row.violated > 0 or (row.slack is not None and row.slack < 0)]
    if failures or path_failures:
        print("QUARTUS_TIMING_REJECTED(exit=1): negative slack/TNS", file=sys.stderr)
        for row in failures:
            model = f" [{row.model}]" if row.model else ""
            print(
                f"  {row.section}{model}: {row.clock}: "
                f"slack={row.slack:g} endpoint_tns={row.tns:g}",
                file=sys.stderr,
            )
        for row in path_failures:
            print(f"  Detailed {row.check}: corner={row.corner} clock={row.clock}: "
                  f"slack={row.slack:g} violated={row.violated} file={row.file}", file=sys.stderr)
        return 1
    if scoped_missing:
        print("QUARTUS_TIMING_REFUSED(exit=4): complete decoder-scoped timing evidence is required",
              file=sys.stderr)
        return 4
    if args.paths_dir:
        print("PASS timing: no negative standard slack/TNS or indexed detailed setup/hold violations")
    else:
        print("PASS timing: no negative setup/hold/recovery/removal/min-pulse slack")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
