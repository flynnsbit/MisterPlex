#!/usr/bin/env python3
"""Post-fit guard for critical modules in Quartus hierarchy reports."""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import re
import sys
import tarfile
from dataclasses import asdict, dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONFIG = ROOT / "tests" / "fixtures" / "critical_fit_hierarchy.json"


@dataclass
class HierRow:
    source: str
    hierarchy_node: str
    full_hierarchy: str
    entity: str
    comb_aluts: float = 0.0
    registers: float = 0.0
    block_memory_bits: float = 0.0
    m10ks: float = 0.0
    dsps: float = 0.0
    alms_needed: float = 0.0


def parse_number(text: str) -> float:
    m = re.search(r"-?\d+(?:,\d{3})*(?:\.\d+)?", text)
    return float(m.group(0).replace(",", "")) if m else 0.0


def split_report_row(line: str) -> list[str]:
    return [cell.strip() for cell in line.strip().strip(";").split(";")]


def normalize_header(cell: str) -> str:
    cell = re.sub(r"\s+", " ", cell.strip())
    return cell


def parse_hierarchy_report(path: Path) -> list[HierRow]:
    rows: list[HierRow] = []
    if not path.exists():
        raise FileNotFoundError(path)

    header: list[str] | None = None
    for line in path.read_text(errors="ignore").splitlines():
        if "Compilation Hierarchy Node" in line and "Full Hierarchy Name" in line:
            header = [normalize_header(c) for c in split_report_row(line)]
            continue
        if not header or not line.lstrip().startswith(";"):
            continue
        cells = split_report_row(line)
        if len(cells) != len(header) or not cells or not cells[0].startswith("|"):
            continue
        data = dict(zip(header, cells))
        entity = data.get("Entity Name", "")
        full = data.get("Full Hierarchy Name", "")
        if not entity or not full:
            continue
        rows.append(
            HierRow(
                source=str(path),
                hierarchy_node=data.get("Compilation Hierarchy Node", ""),
                full_hierarchy=full,
                entity=entity,
                comb_aluts=parse_number(data.get("Combinational ALUTs", "0")),
                registers=parse_number(data.get("Dedicated Logic Registers", "0")),
                block_memory_bits=parse_number(data.get("Block Memory Bits", "0")),
                m10ks=parse_number(data.get("M10Ks", "0")),
                dsps=parse_number(data.get("DSP Blocks", "0")),
                alms_needed=parse_number(data.get("ALMs needed [=A-B+C]", "0")),
            )
        )
    return rows


def captured_inputs(qsf: Path | None, manifest: Path | None, report: Path):
    if qsf is not None or manifest is not None:
        return qsf, manifest, None
    # Retained driver outputs carry their own authority. Never look in ROOT/cwd.
    directory = report.absolute().parent
    for marker in ("inputs.json", "inputs.tar", "tool.json", "project/Plex.qsf"):
        try:
            (directory / marker).lstat()
        except FileNotFoundError:
            continue
        qsf = directory / "project/Plex.qsf"
        try:
            qsf.lstat()
        except FileNotFoundError:
            # Default local/remote cleanup removes project, not captured inputs.
            archive = directory / "inputs.tar"
            try:
                archive.lstat()
            except FileNotFoundError:
                pass
            else:
                return None, directory / "inputs.json", archive
        return qsf, directory / "inputs.json", None
    return None, None, None


def file_binding(path: Path, data: bytes | None = None) -> dict:
    if data is None:
        data = path.read_bytes()
    return {"path": str(path.absolute()), "sha256": hashlib.sha256(data).hexdigest(),
            "bytes": len(data)}


def captured_profile(qsf: Path | None, manifest: Path | None,
                     evidence: dict | None = None, archive: Path | None = None) -> str:
    if qsf is not None and archive is not None:
        raise ValueError("captured QSF and archive authority are mutually exclusive")
    if qsf is None and archive is None:
        if manifest is not None:
            raise ValueError("--input-manifest requires --qsf")
        if evidence is not None:
            evidence.update(kind="legacy-default", captured=False)
        return "baseline"
    if manifest is None:
        raise ValueError("--qsf requires its captured --input-manifest")
    manifest_data = manifest.read_bytes()
    inputs = json.loads(manifest_data)
    if not isinstance(inputs, dict) or not isinstance(inputs.get("input_files"), dict):
        raise ValueError("captured input manifest must contain an input_files object")
    files = inputs["input_files"]
    if not files or any(not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value)
                        for value in files.values()):
        raise ValueError("captured input_files must contain SHA256 values")
    input_sha = hashlib.sha256(json.dumps(files, sort_keys=True).encode()).hexdigest()
    if inputs.get("input_sha256") != input_sha:
        raise ValueError("captured input manifest aggregate hash does not match input_files")
    if archive is not None:
        archive_data = archive.read_bytes()
        archive_binding = file_binding(archive, archive_data)
        if archive_binding["sha256"] != inputs.get("archive_sha256"):
            raise ValueError("captured input archive hash does not match input manifest")
        with tarfile.open(fileobj=io.BytesIO(archive_data), mode="r:") as captured:
            members = [member for member in captured.getmembers() if member.name == "Plex.qsf"]
            if len(members) != 1 or not members[0].isfile():
                raise ValueError("captured archive must contain exactly one regular Plex.qsf")
            with captured.extractfile(members[0]) as stream:
                data = stream.read()
        qsf_binding = {"archive": archive_binding, "member": "Plex.qsf",
                       "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}
    else:
        data = qsf.read_bytes()
        qsf_binding = file_binding(qsf, data)
    if hashlib.sha256(data).hexdigest() != files.get("Plex.qsf"):
        raise ValueError("captured QSF hash does not match input manifest")
    values = set()
    assignments = []
    for number, line in enumerate(data.decode().splitlines(), 1):
        if not re.match(r'^\s*set_global_assignment\s+-name\s+VERILOG_MACRO\b', line):
            continue
        match = re.match(
            r'^\s*set_global_assignment\s+-name\s+VERILOG_MACRO\s+'
            r'(?:"((?:\\.|[^"\\])+)"|\{([^{}]+)\}|([^\s#;"{}]+))\s*(?:#.*)?$',
            line,
        )
        if not match:
            raise ValueError(f"malformed captured VERILOG_MACRO assignment at line {number}")
        macro = next(value for value in match.groups() if value is not None)
        if macro == "FPGA_VIDEO_320":
            raise ValueError("captured FPGA_VIDEO_320 requires an explicit 0/1 value")
        if macro.startswith("FPGA_VIDEO_320="):
            values.add(macro.split("=", 1)[1])
        if macro.startswith(("FPGA_VIDEO_320=", "FRAME_LINES_8=")):
            assignments.append({"line": number, "literal": macro})
    if len(values) > 1 or values - {"0", "1"}:
        raise ValueError("ambiguous FPGA_VIDEO_320 configuration in captured QSF")
    profile = "fpga320" if values == {"1"} else "baseline"
    if evidence is not None:
        evidence.update(kind="captured-inputs", captured=True, profile=profile,
                        qsf=qsf_binding, input_manifest=file_binding(manifest, manifest_data),
                        input_sha256=input_sha, declared_source_sha256=inputs.get("source_sha256"),
                        literal_assignments=assignments)
    return profile


def load_config(path: Path, profile: str = "baseline") -> list[dict[str, object]]:
    data = json.loads(path.read_text())
    specs = [dict(spec) for spec in data.get("modules", [])]
    if profile != "baseline":
        overrides = data["profiles"][profile]["module_overrides"]
        for spec in specs:
            spec.update(overrides.get(spec["name"], {}))
    return specs


def find_row(rows: list[HierRow], spec: dict[str, object]) -> HierRow | None:
    entity = str(spec.get("entity", ""))
    contains = str(spec.get("hierarchy_contains", ""))
    candidates = [
        row
        for row in rows
        if (not entity or row.entity == entity)
        and (not contains or contains in row.full_hierarchy or contains in row.hierarchy_node)
    ]
    if not candidates:
        return None
    return max(
        candidates,
        key=lambda row: row.comb_aluts + row.registers + row.block_memory_bits / 1000.0 + row.m10ks * 100,
    )


def scan_log(path: Path | None, module_names: list[str]) -> list[str]:
    if not path or not path.exists():
        return []
    danger = re.compile(
        r"removed|stuck|does not drive|doesn't drive|no clock|without a clock|dangling|"
        r"tied (?:to|off)|constant (?:GND|VCC|0|1)|stuck at (?:GND|VCC)",
        re.I,
    )
    module_re = re.compile("|".join(re.escape(name) for name in module_names), re.I)
    hits: list[str] = []
    for line in path.read_text(errors="ignore").splitlines():
        if module_re.search(line) and danger.search(line):
            hits.append(line.strip())
    return hits


def scan_comb_loops(path: Path | None, specs: list[dict[str, object]]) -> list[str]:
    if not path or not path.exists():
        return []
    allow = {
        str(item)
        for spec in specs
        for item in spec.get("allowed_comb_loop_nodes", [])
    }
    contexts = [
        str(spec.get("hierarchy_contains", "")) for spec in specs if spec.get("hierarchy_contains")
    ] + [
        str(spec.get("log_contains", "")) for spec in specs if spec.get("log_contains")
    ] + [str(spec.get("name", "")) for spec in specs if spec.get("name")]
    hits: list[str] = []
    current: list[str] = []
    active = False
    for line in path.read_text(errors="ignore").splitlines():
        if "Warning (332125): Found combinational loop" in line:
            current = [line.strip()]
            active = True
            continue
        if active and "Warning (332126): Node" in line:
            current.append(line.strip())
            continue
        if active:
            text = "\n".join(current)
            if any(ctx and ctx in text for ctx in contexts) and not any(token and token in text for token in allow):
                hits.extend(current)
            current = []
            active = False
    if active:
        text = "\n".join(current)
        if any(ctx and ctx in text for ctx in contexts) and not any(token and token in text for token in allow):
            hits.extend(current)
    return hits


def format_table(rows: list[tuple[dict[str, object], HierRow | None]]) -> str:
    lines = [
        "| module | entity | hierarchy | comb ALUTs | registers | block bits | M10Ks | DSPs | status |",
        "|---|---|---|---:|---:|---:|---:|---:|---|",
    ]
    for spec, row in rows:
        if not row:
            lines.append(
                f"| `{spec.get('name')}` | `{spec.get('entity')}` | `{spec.get('hierarchy_contains')}` | — | — | — | — | — | MISSING |"
            )
            continue
        lines.append(
            f"| `{spec.get('name')}` | `{row.entity}` | `{row.full_hierarchy}` | "
            f"{row.comb_aluts:g} | {row.registers:g} | {row.block_memory_bits:g} | "
            f"{row.m10ks:g} | {row.dsps:g} | present |"
        )
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--fit-rpt", type=Path, required=True)
    ap.add_argument("--map-rpt", type=Path)
    ap.add_argument("--log", type=Path, help="Quartus compile log to scan for removal/tie-off warnings")
    ap.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    ap.add_argument("--qsf", type=Path, help="Captured private QSF; never defaults to the live worktree")
    ap.add_argument("--input-manifest", type=Path, help="inputs.json binding the captured QSF hash")
    ap.add_argument("--result-json", type=Path,
                    help="New immutable result receipt; requires captured QSF/input authority")
    ap.add_argument(
        "--allow-missing",
        action="append",
        default=[],
        help="Module names that may be absent (L4 720p present stubs stream_path)",
    )
    args = ap.parse_args(argv[1:])

    result = {"schema": "misterplex.fit-hierarchy-result.v1", "profile": None,
              "authority": {}, "artifacts": {}, "command": argv}

    def finish(code, errors):
        result.update(exit_code=code, status={0: "pass", 1: "rejected", 4: "refused"}[code],
                      errors=errors)
        if args.result_json:
            try:
                with args.result_json.open("x") as stream:
                    json.dump(result, stream, sort_keys=True, indent=2)
                    stream.write("\n")
            except OSError as exc:
                print(f"FIT_HIERARCHY_REFUSED(exit=4): cannot publish new result: {exc}", file=sys.stderr)
                return 4
        return code

    try:
        qsf, manifest, archive = captured_inputs(args.qsf, args.input_manifest, args.fit_rpt)
        profile = captured_profile(qsf, manifest, result["authority"], archive)
        if args.result_json and not result["authority"]["captured"]:
            raise ValueError("--result-json requires verified captured QSF/input manifest")
        result["profile"] = profile
        consumed = {"fit_report": args.fit_rpt, "config": args.config, "checker": Path(__file__)}
        if args.map_rpt:
            consumed["map_report"] = args.map_rpt
        if args.log:
            consumed["log"] = args.log
        if qsf is not None:
            consumed["qsf"] = qsf
        if archive is not None:
            consumed["input_archive"] = archive
        if manifest is not None:
            consumed["input_manifest"] = manifest
        result["artifacts"] = {role: file_binding(path) for role, path in consumed.items()}
        fitted_rows = parse_hierarchy_report(args.fit_rpt)
        rows = list(fitted_rows)
        if args.map_rpt:
            rows += parse_hierarchy_report(args.map_rpt)
        specs = load_config(args.config, profile)
        if profile == "fpga320" and args.allow_missing:
            raise ValueError("FPGA320 does not permit --allow-missing modules")
    except (OSError, ValueError, KeyError, TypeError, tarfile.TarError) as exc:
        print(f"FIT_HIERARCHY_REFUSED(exit=4): {exc}", file=sys.stderr)
        return finish(4, [str(exc)])
    print(f"FIT_HIERARCHY_PROFILE: {profile}")
    print("FIT_HIERARCHY_AUTHORITY: " + json.dumps(result["authority"], sort_keys=True))
    if profile == "fpga320":
        # Mapped estimates cannot satisfy physical FPGA320 presence/M10K floors.
        rows = fitted_rows
    found = [(spec, find_row(rows, spec)) for spec in specs]
    result["modules"] = [{"policy": spec, "observed": asdict(row) if row else None}
                         for spec, row in found]
    print("FIT_HIERARCHY_TABLE_BEGIN")
    print(format_table(found))
    print("FIT_HIERARCHY_TABLE_END")

    errors: list[str] = []
    allow_missing = set(args.allow_missing)
    for spec, row in found:
        name = str(spec.get("name"))
        if not row:
            if name in allow_missing:
                continue
            errors.append(f"{name}: missing from Quartus fitted hierarchy")
            continue
        checks = [
            ("comb_aluts", row.comb_aluts),
            ("registers", row.registers),
            ("block_memory_bits", row.block_memory_bits),
            ("m10ks", row.m10ks),
            ("dsps", row.dsps),
        ]
        for field, value in checks:
            key = "min_" + field
            if key in spec and value < float(spec[key]):
                errors.append(f"{name}: {field} {value:g} < required {spec[key]}")

    try:
        warning_hits = scan_log(args.log, [str(spec.get("name")) for spec in specs])
        comb_hits = scan_comb_loops(args.log, specs)
        if result["artifacts"] != {role: file_binding(path) for role, path in consumed.items()}:
            raise ValueError("hierarchy inputs changed during evaluation")
        if manifest is not None and result["authority"]["input_manifest"] != result["artifacts"]["input_manifest"]:
            raise ValueError("captured profile authority changed during evaluation")
        if qsf is not None and result["authority"]["qsf"] != result["artifacts"]["qsf"]:
            raise ValueError("captured QSF changed during evaluation")
        if archive is not None and result["authority"]["qsf"]["archive"] != result["artifacts"]["input_archive"]:
            raise ValueError("captured archive changed during evaluation")
    except (OSError, ValueError) as exc:
        print(f"FIT_HIERARCHY_REFUSED(exit=4): {exc}", file=sys.stderr)
        return finish(4, [str(exc)])
    if warning_hits:
        errors.append("critical-module removal/tie-off warning(s):")
        errors.extend("  " + hit for hit in warning_hits[:20])
    if comb_hits:
        errors.append("critical-module combinational-loop warning(s):")
        errors.extend("  " + hit for hit in comb_hits[:20])

    if errors:
        print("FIT_HIERARCHY_REJECTED(exit=1):", file=sys.stderr)
        for err in errors:
            print(f"  {err}", file=sys.stderr)
        return finish(1, errors)
    code = finish(0, [])
    if code == 0:
        print("PASS fit hierarchy: critical modules present with non-trivial resource usage")
    return code


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
