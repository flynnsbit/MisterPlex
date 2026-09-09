"""Validate noninterfering SDC observation and source-bound HDL provenance.

Native HDL entity/statement messages are execution evidence, not a source
whitelist. Attribution also requires a unique compiled definition/elaboration,
the original Tcl frame and one frozen HDL attribute to agree.
Unsupported or external/unfrozen HDL origins deliberately fail closed.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re
from quartus_hdl_source import hdl_attributes

KINDS = {"set_clock_groups", "set_false_path", "set_max_delay",
         "set_min_delay", "set_multicycle_path"}
REPORTER_FILES = {"run.sh", "timing.tcl", "check_quartus_timing.py",
                  "quartus_sta_report.py", "quartus_timing_observer.py",
                  "constraint-sources.json", "observation.id",
                  "quartus_timing_sdk.py", "quartus_hdl_source.py", "sdk-image.id"}
FAILURE_PATTERN = re.compile(
    r"(?mi)^\s*(?:Error(?:\s*\(\d+\))?\s*:|Critical Warning\s*\(332008\)\s*:|"
    r"MPX_OBSERVER_FAILURE(?:_SINK)?\b)|Read_sdc failed")


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def unhex(value: str) -> str:
    if len(value) % 2 or re.fullmatch(r"[0-9a-f]*", value) is None:
        raise ValueError("malformed observer hex field")
    return bytes.fromhex(value).decode("utf-8")


def sdc_directives(text: str) -> list[tuple[int, str, str]]:
    lines = text.splitlines()
    directives = []
    pattern = re.compile(r"^\s*(set_clock_groups|set_false_path|set_max_delay|"
                         r"set_min_delay|set_multicycle_path)\b")
    index = 0
    while index < len(lines):
        match = pattern.match(lines[index])
        if not match:
            index += 1
            continue
        line = index + 1
        parts = [lines[index].rstrip()]
        while parts[-1].endswith("\\") and index + 1 < len(lines):
            index += 1
            parts.append(lines[index].rstrip())
        directives.append((line, match[1], "\n".join(parts).strip()))
        index += 1
    return directives


def bound_constraint_sources(directory, read_evidence):
    reporter_dir = directory.parent / "reporter"
    reporter = json.loads(read_evidence(reporter_dir / "provenance.json", 65536))
    inputs = json.loads(read_evidence(directory.parent / "inputs.json", 4 * 1024**2))
    if sha(json.dumps(inputs["input_files"], sort_keys=True).encode()) != inputs["input_sha256"]:
        raise ValueError("frozen input file map hash mismatch")
    if reporter["schema"] != "misterplex.timing-reporter.v4" or \
            set(reporter["files"]) != REPORTER_FILES:
        raise ValueError("observer requires the complete v4 bound reporter")
    if reporter["image_id"] != inputs["image_id"] or \
            reporter["input_sha256"] != inputs["input_sha256"]:
        raise ValueError("observer input/image identity mismatch")
    data = read_evidence(reporter_dir / "constraint-sources.json", 16 * 1024**2)
    if sha(data) != reporter["files"]["constraint-sources.json"]:
        raise ValueError("constraint source catalog hash mismatch")
    catalog = json.loads(data)
    if catalog["schema"] != "misterplex.constraint-sources.v1" or \
            catalog["input_sha256"] != inputs["input_sha256"]:
        raise ValueError("constraint source catalog input identity mismatch")
    records = []
    for filename, source in catalog["hdl"].items():
        path = Path(filename)
        if path.is_absolute() or ".." in path.parts or "\\" in filename or \
                path.as_posix() != filename or path.suffix.lower() not in {".v", ".sv", ".vhd", ".vhdl"}:
            raise ValueError("unsafe/non-HDL source catalog entry")
        if source["sha256"] != inputs["input_files"].get(filename) or \
                sha(source["text"].encode()) != source["sha256"]:
            raise ValueError(f"HDL source is not bound to frozen input bytes: {filename}")
        records.extend(hdl_attributes(filename, source["text"]))
    if set(catalog["hdl"]) != {name for name in inputs["input_files"]
                              if Path(name).suffix.lower() in {".v", ".sv", ".vhd", ".vhdl"}}:
        raise ValueError("frozen HDL source catalog is incomplete")
    sdcs = {}
    for filename, source in catalog["sdc"].items():
        path = Path(filename)
        if path.is_absolute() or ".." in path.parts or "\\" in filename or \
                path.as_posix() != filename or path.suffix != ".sdc":
            raise ValueError("unsafe/non-SDC source catalog entry")
        if source["sha256"] != inputs["input_files"].get(filename) or \
                sha(source["text"].encode()) != source["sha256"]:
            raise ValueError(f"SDC source is not bound to frozen input bytes: {filename}")
        sdcs[filename] = source["text"]
    if set(sdcs) != {name for name in inputs["input_files"] if Path(name).suffix == ".sdc"}:
        raise ValueError("frozen SDC source catalog is incomplete")
    sdk_records = bound_sdk_sources(directory, reporter, catalog, read_evidence)
    return reporter, records + sdk_records, sdcs


def bound_sdk_sources(directory, reporter, project_catalog, read_evidence):
    from quartus_timing_sdk import definitions, validate
    image = read_evidence(directory.parent / "reporter/sdk-image.id", 128)
    if image != (reporter["image_id"] + "\n").encode() or \
            sha(image) != reporter["files"]["sdk-image.id"]:
        raise ValueError("SDK collector image identity mismatch")
    if read_evidence(directory / "sdk-catalog.exit", 16) != b"0\n":
        raise ValueError("SDK dependency collection did not succeed")
    log = read_evidence(directory / "sdk-catalog.log", 1024 * 1024)
    if log.strip():
        raise ValueError("unexpected SDK dependency collector diagnostics")
    report = read_evidence(directory / "Plex.compiled-sources.rpt", 32 * 1024**2)
    catalog_bytes = read_evidence(directory / "sdk-catalog.json", 16 * 1024**2)
    catalog = json.loads(catalog_bytes)
    attributes = validate(catalog, report, reporter["image_id"])
    project_definitions = [item["entity"].lower()
                           for filename, source in project_catalog["hdl"].items()
                           for item in definitions(filename, source["text"])]
    sdk_definitions = [item["entity"].lower() for source in catalog["dependencies"]
                       for item in source["definitions"]]
    records = []
    for attribute in attributes:
        if attribute["entity"].lower() in project_definitions or \
                sdk_definitions.count(attribute["entity"].lower()) != 1:
            raise ValueError("SDK entity has ambiguous project/library definitions")
        source = next(item for item in catalog["dependencies"]
                      if item["sdk_relative"] == attribute["file"])
        records.append({**attribute, "sdk_source": {
            "image_id": reporter["image_id"],
            "dependency": {key: value for key, value in source.items()
                           if key not in {"attributes", "definitions"}},
            "catalog": {"file": "sdk-catalog.json", "bytes": len(catalog_bytes), "sha256": sha(catalog_bytes)},
            "log": {"file": "Plex.compiled-sources.rpt", "relative_to": "timing",
                    "bytes": len(report), "sha256": sha(report)},
            "producer": {"file": "quartus_timing_sdk.py",
                         "sha256": reporter["files"]["quartus_timing_sdk.py"]}}})
    return records


def compiled_hdl_definition(data, source):
    """Bind a definition, not the instantiating File: on an elaboration line."""
    if FAILURE_PATTERN.search(data.decode()):
        raise ValueError("error-tainted compiler HDL source evidence")
    current_file = None
    source_line = None
    definitions, elaborations = [], []
    for number, line in enumerate(data.decode().splitlines(), 1):
        text = line.strip()
        found = re.fullmatch(
            r"Info\s*\(12021\): Found \d+ design units, including \d+ entities, in source file (.+)", text)
        if found:
            current_file, source_line = found[1], number
        definition = re.fullmatch(
            r"Info\s*\(12023\): Found entity \d+: (\S+) File: (.+) Line: (\d+)", text)
        if definition and definition[1] == source["entity"]:
            filename = definition[2]
            if not filename.startswith("/build/") or filename[7:] != current_file:
                raise ValueError("HDL definition is external or lacks consistent compiler source context")
            definitions.append({
                "file": filename[7:], "line": int(definition[3]),
                "source_log_line": source_line, "definition_log_line": number})
        elaboration = re.match(
            r'Info\s*\(12128\): Elaborating entity "([^"]+)" for hierarchy "[^"]+"', text)
        if elaboration and elaboration[1] == source["entity"]:
            elaborations.append(number)
    if len(definitions) != 1 or not elaborations or \
            definitions[0]["file"] != source["file"] or definitions[0]["line"] != source["entity_line"]:
        raise ValueError("HDL definition has no unique compiled source/elaboration binding")
    return {"definition": definitions[0], "elaboration_log_lines": elaborations,
            "log": {"file": "compile.log", "relative_to": "transaction",
                    "bytes": len(data), "sha256": sha(data)}}


def collect_observer_evidence(directory, commands, active_sources, read_evidence, read_table):
    reporter, sources, sdcs = bound_constraint_sources(directory, read_evidence)
    identity = read_evidence(directory.parent / "reporter/observation.id", 128)
    if sha(identity) != reporter["files"]["observation.id"]:
        raise ValueError("observer identity hash mismatch")
    observation_id = identity.decode().strip()
    if re.fullmatch(r"[0-9a-f]{32}", observation_id) is None:
        raise ValueError("invalid observer identity")
    lines = read_evidence(directory / "observer.summary", 2048).decode().splitlines()
    summary = dict(line.split("=", 1) for line in lines)
    fields = {"schema", "observation_id", "state", "failures", "enters", "leaves",
              "read_enters", "read_leaves", "pending", "events"}
    if len(lines) != len(fields) or set(summary) != fields or \
            summary["schema"] != "misterplex.timing-observer.v1" or \
            summary["observation_id"] != observation_id or summary["state"] != "complete":
        raise ValueError("missing/incomplete/error-tainted observer completion")
    counts = {key: int(summary[key]) for key in fields - {"schema", "observation_id", "state"}}
    if counts["failures"] != 0 or counts["pending"] != 0 or \
            counts["enters"] != len(commands) or counts["leaves"] != len(commands) or \
            counts["read_enters"] < 1 or counts["read_enters"] != counts["read_leaves"]:
        raise ValueError("failed/incomplete observer command or read_sdc coverage")
    complete = read_evidence(directory / "observer.complete", 128).decode()
    if complete != f"misterplex.timing-observer.v1:{observation_id}\n":
        raise ValueError("missing observer final completion marker")
    if not set(active_sources) <= set(sdcs):
        raise ValueError("active SDC source is outside the frozen catalog")
    expected = {(name, line, kind): text for name in active_sources
                for line, kind, text in sdc_directives(sdcs[name])}
    file_commands = [item for item in commands.values() if item["origin"] == "sdc"]
    actual = {(item["file"], item["line"], item["kind"]) for item in file_commands}
    if len(actual) != len(file_commands) or actual != set(expected):
        raise ValueError("SDC execution coverage mismatch (missing, repeated or unexpected command)")
    normal = lambda value: re.sub(r"\s+", " ", re.sub(r"\\\r?\n", " ", value).strip())
    for item in file_commands:
        if normal(unhex(item["raw_hex"])) != normal(expected[item["file"], item["line"], item["kind"]]):
            raise ValueError("original SDC frame does not match its frozen source location")

    events = read_table(directory / "Plex.observer-events.tsv",
                        "sequence\tevent\tid\tkind\tcode\tdetail_hex", 8192)
    stack, entered, left = [], set(), set()
    read_enters = read_leaves = 0
    trace_markers = []
    if len(events) != counts["events"] or len(events) < 4:
        raise ValueError("incomplete observer event journal")
    for expected, (sequence, event, index, kind, code, detail_hex) in enumerate(events):
        detail = unhex(detail_hex)
        ci = int(index)
        if int(sequence) != expected or code != "0":
            raise ValueError("noncontiguous/error-tainted observer journal")
        if event == "begin":
            if expected != 0 or (ci, kind, detail) != (-1, "observer", observation_id):
                raise ValueError("invalid observer begin event")
        elif event == "end":
            if expected != len(events) - 1 or stack or (ci, kind, detail) != (-1, "observer", ""):
                raise ValueError("unclosed/invalid observer end event")
        elif event == "enter":
            if ci not in commands or ci in entered or commands[ci]["kind"] != kind or \
                    commands[ci]["command"] != detail or not stack:
                raise ValueError("observer enter disagrees with command inventory/read_sdc window")
            entered.add(ci)
            stack.append(("setter", ci, kind))
            trace_markers.append(("enter", ci, kind, commands[ci]["raw_hex"]))
        elif event == "leave":
            if ci not in entered or ci in left or not stack or stack.pop() != ("setter", ci, kind):
                raise ValueError("observer leave is unpaired/reordered")
            left.add(ci)
            trace_markers.append(("leave", ci, kind, code))
        elif event == "read-enter":
            if kind != "read_sdc":
                raise ValueError("invalid observer read_sdc enter")
            read_enters += 1
            stack.append(("read", ci, kind))
        elif event == "read-leave":
            if not stack or stack.pop() != ("read", ci, kind):
                raise ValueError("observer read_sdc completion is unpaired")
            read_leaves += 1
        else:
            raise ValueError("unknown/failure event in observer journal")
    if events[0][1] != "begin" or events[-1][1] != "end" or stack or \
            entered != set(commands) or left != set(commands) or \
            read_enters != counts["read_enters"] or read_leaves != counts["read_leaves"]:
        raise ValueError("observer event coverage is incomplete")

    log = read_evidence(directory / "reporter.log", 16 * 1024**2).decode()
    if FAILURE_PATTERN.search(log):
        raise ValueError("error-tainted reporter log (including swallowed Quartus/observer errors)")
    pending = None
    entity = None
    in_hdl = False
    begin_count = complete_count = 0
    markers, native_hdl, attributed = [], [], []
    compiler_data = None
    compiled_sources = {}
    for number, line in enumerate(log.splitlines(), 1):
        text = line.strip()
        if text.startswith("MPX_OBSERVER_BEGIN "):
            begin_count += 1
            if text != f"MPX_OBSERVER_BEGIN {observation_id}" or markers:
                raise ValueError("reporter log observer begin identity/order mismatch")
        elif text.startswith("MPX_OBSERVER_COMPLETE "):
            complete_count += 1
            if text != f"MPX_OBSERVER_COMPLETE {observation_id}" or pending:
                raise ValueError("reporter log observer completion mismatch")
        elif re.match(r"Info\s*\(332164\):\s*Evaluating HDL-embedded SDC commands\s*$", text):
            if pending:
                raise ValueError("unobserved native HDL statement")
            in_hdl, entity = True, None
        elif match := re.match(r"Info\s*\(332165\):\s*Entity\s+(\S+)\s*$", text):
            if not in_hdl or pending:
                raise ValueError("native HDL entity lacks complete execution context")
            entity = match[1]
        elif match := re.match(r"Info\s*\(332166\):\s*(.+)$", text):
            if not in_hdl or not entity or pending:
                raise ValueError("native HDL statement lacks complete entity context")
            statement = match[1].strip()
            if statement.split(maxsplit=1)[0] in KINDS:
                pending = {"entity": entity, "statement": statement, "log_line": number}
                native_hdl.append(pending)
        elif re.match(r"Info\s*\(332104\):\s*Reading SDC File:", text):
            if pending:
                raise ValueError("native HDL exclusion was not observed")
            in_hdl, entity = False, None
        elif match := re.fullmatch(r"MPX_OBSERVER_(ENTER|LEAVE) (\d+) (\w+) ([0-9a-f]*)", text):
            operation, index, kind, detail = match.groups()
            ci = int(index)
            if begin_count != 1 or complete_count or ci not in commands:
                raise ValueError("reporter log trace outside the bound observation window")
            markers.append((operation.lower(), ci, kind, detail))
            item = commands[ci]
            if operation == "ENTER" and item["origin"] == "hdl_pending":
                raw = unhex(item["raw_hex"]).strip()
                if pending is None or pending["statement"] != raw:
                    raise ValueError("source-less callback has no exact native HDL execution attribution")
                candidates = [source for source in sources if
                              source["entity"] == pending["entity"] and source["statement"] == raw]
                if len(candidates) != 1:
                    raise ValueError("HDL origin is unknown/unfrozen/ambiguous; exact source attribution required")
                source = dict(candidates[0])
                if "sdk_source" in source:
                    compiled = source.pop("sdk_source")
                    method = "pinned-sdk+compiled-source-table+literal-attribute+native-hdl-message+original-tcl-frame-v1"
                else:
                    if compiler_data is None:
                        compiler_data = read_evidence(directory.parent / "compile.log", 32 * 1024**2)
                    key = source["file"], source["entity"], source["entity_line"]
                    if key not in compiled_sources:
                        compiled_sources[key] = compiled_hdl_definition(compiler_data, source)
                    compiled = compiled_sources[key]
                    method = "compiler-definition+native-hdl-message+original-tcl-frame+frozen-attribute-v1"
                proof = {"method": method, **source, "compiled_source": compiled,
                         "native_log_line": pending["log_line"]}
                item["hdl_source"] = proof
                item["origin"] = "hdl"
                attributed.append({"id": ci, **proof})
                pending = None
            elif operation == "ENTER" and pending:
                raise ValueError("native HDL command was mislabeled as a file SDC")
        elif text.startswith("MPX_OBSERVER_"):
            raise ValueError("malformed reporter log observer marker")
    if begin_count != 1 or complete_count != 1 or markers != trace_markers or pending or \
            len(attributed) != len(native_hdl):
        raise ValueError("reporter log/journal/native-HDL execution coverage mismatch")
    return {"schema": "misterplex.timing-observer.v1", "observation_id": observation_id,
            "state": "complete", **counts, "hdl_sources": attributed,
            "coverage": "paired setter/read_sdc traces plus native HDL execution messages"}
