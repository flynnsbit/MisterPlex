#!/usr/bin/env python3
"""Collect minimal SDK source provenance, never vendor source text.

The native Analysis & Synthesis Source Files Read table selects dependencies.
An immutable image supplies their bytes; literal attributes are derived locally.
Neither an instantiator location nor a matching module name selects a file.
"""
import argparse
import json
import os
from pathlib import Path
import re
import stat

from quartus_hdl_source import FAILURE_PATTERN, hdl_attributes, sha

SCHEMA = "misterplex.sdk-constraint-sources.v1"
HEADER = ["File Name with User-Entered Path", "Used in Netlist", "File Type",
          "File Name with Absolute Path", "Library"]
SDK_ROOT = "/opt/intelFPGA"


def compiled_sources(data):
    text = data.decode("utf-8")
    if FAILURE_PATTERN.search(text):
        raise ValueError("error-tainted native source-file report")
    rows, sections, in_section, header, complete = [], 0, False, False, False
    for number, line in enumerate(text.splitlines(), 1):
        cells = [cell.strip() for cell in line.strip().split(";")[1:-1]]
        if cells == ["Analysis & Synthesis Source Files Read"]:
            sections += 1
            in_section, header = True, False
        elif in_section and cells == HEADER:
            if header:
                raise ValueError("duplicate native source-file header")
            header = True
        elif in_section and header and cells:
            if len(cells) != 5 or cells[1] not in {"yes", "no"}:
                raise ValueError("malformed native source-file row")
            rows.append({"entered": cells[0], "used": cells[1], "type": cells[2],
                         "absolute": cells[3], "library": cells[4], "report_line": number})
        elif in_section and header and rows and re.fullmatch(r"\+[-+]+\+", line.strip()):
            in_section, complete = False, True
        elif in_section and header and not line.strip():
            raise ValueError("unterminated native source-file table")
    if sections != 1 or not rows or not complete:
        raise ValueError("missing/ambiguous native source-file table")
    identities = [row["absolute"] for row in rows]
    if len(identities) != len(set(identities)):
        raise ValueError("duplicate compiled source dependency")
    for row in rows:
        path = Path(row["absolute"])
        if not row["absolute"] or ".." in path.parts or "\\" in str(path):
            raise ValueError("unsafe compiled source coordinate")
    return rows


def definitions(filename, text):
    token = re.compile(r'"(?:\\.|[^"\\])*"|//[^\n]*|/\*.*?\*/', re.S)
    blank = lambda match: re.sub(r"[^\n]", " ", match.group(0))
    code = token.sub(blank, text)
    if Path(filename).suffix.lower() in {".v", ".sv"}:
        return [{"entity": match.group(1), "line": code.count("\n", 0, match.start()) + 1}
                for match in re.finditer(r"\bmodule\s+([A-Za-z_][A-Za-z0-9_$]*)\b", code)]
    if Path(filename).suffix.lower() in {".vhd", ".vhdl"}:
        code = re.sub(r"--[^\n]*", "", text)
        return [{"entity": match.group(1), "line": code.count("\n", 0, match.start()) + 1}
                for match in re.finditer(r"\bentity\s+([A-Za-z_][A-Za-z0-9_]*)\s+is\b", code, re.I)]
    return []


def collect(report, sdk_root, image_id):
    if re.fullmatch(r"sha256:[0-9a-f]{64}", image_id) is None:
        raise ValueError("SDK image must be pinned by full digest")
    sdk_root = Path(sdk_root).resolve()
    data = Path(report).read_bytes()
    rows = compiled_sources(data)
    dependencies = []
    for row in rows:
        if row["used"] != "yes" or not row["absolute"].startswith(SDK_ROOT + "/"):
            continue
        relative = row["absolute"][len(SDK_ROOT) + 1:]
        path = sdk_root / relative
        try:
            path.resolve().relative_to(sdk_root)
        except ValueError:
            raise ValueError("SDK dependency escapes immutable image root")
        before = path.stat()
        if not stat.S_ISREG(before.st_mode) or before.st_size > 32 * 1024**2:
            raise ValueError("unsupported SDK source dependency")
        content = path.read_bytes()
        after = path.stat()
        if (before.st_ino, before.st_size, before.st_mtime_ns) != \
                (after.st_ino, after.st_size, after.st_mtime_ns):
            raise ValueError("SDK dependency changed while reading")
        attributes, entities = [], []
        if path.suffix.lower() in {".v", ".sv", ".vhd", ".vhdl"}:
            text = content.decode("utf-8")
            attributes = hdl_attributes(relative, text)
            entities = definitions(relative, text)
        dependencies.append({"sdk_relative": relative, "sha256": sha(content),
                             "bytes": len(content), "mode": format(stat.S_IMODE(before.st_mode), "04o"),
                             "compiled": row, "definitions": entities, "attributes": attributes})
    return {"schema": SCHEMA, "image_id": image_id, "sdk_root": SDK_ROOT,
            "native_report": {"sha256": sha(data), "bytes": len(data)},
            "source_rows": len(rows), "dependencies": dependencies,
            "source_text_included": False}


def validate(catalog, report, image_id):
    """Validate derivation structure and compiled origin, not source text hashes offline.

    SDK bytes must be re-collected in the pinned image and the resulting catalog
    bound into reporter provenance by its host driver before using this result.
    """
    if catalog.get("schema") != SCHEMA or catalog.get("image_id") != image_id or \
            catalog.get("sdk_root") != SDK_ROOT or catalog.get("source_text_included") is not False:
        raise ValueError("SDK identity/schema mismatch")
    if catalog["native_report"] != {"sha256": sha(report), "bytes": len(report)}:
        raise ValueError("native SDK source-file report binding mismatch")
    rows = compiled_sources(report)
    expected = {row["absolute"]: row for row in rows
                if row["used"] == "yes" and row["absolute"].startswith(SDK_ROOT + "/")}
    if catalog["source_rows"] != len(rows) or len(catalog["dependencies"]) != len(expected):
        raise ValueError("incomplete SDK dependency catalog")
    seen, attributes = set(), []
    for dependency in catalog["dependencies"]:
        relative = dependency["sdk_relative"]
        path = Path(relative)
        absolute = SDK_ROOT + "/" + relative
        if path.is_absolute() or ".." in path.parts or "\\" in relative or \
                path.as_posix() != relative or absolute in seen:
            raise ValueError("unsafe/duplicate SDK dependency")
        seen.add(absolute)
        if dependency["compiled"] != expected.get(absolute):
            raise ValueError("SDK source was not selected by native compiled-source evidence")
        if re.fullmatch(r"[0-9a-f]{64}", dependency["sha256"]) is None or \
                not isinstance(dependency["bytes"], int) or dependency["bytes"] <= 0 or \
                re.fullmatch(r"0[0-7]{3}", dependency["mode"]) is None:
            raise ValueError("invalid SDK dependency identity")
        for attr in dependency["attributes"]:
            if attr["file"] != relative or attr["source_sha256"] != dependency["sha256"] or \
                    attr["statement_sha256"] != sha(attr["statement"].encode()) or \
                    re.fullmatch(r"[0-9a-f]{64}", attr["attribute_sha256"]) is None or \
                    {"entity": attr["entity"], "line": attr["entity_line"]} not in dependency["definitions"]:
                raise ValueError("SDK attribute/definition binding mismatch")
            if attr["line"] < attr["entity_line"]:
                raise ValueError("SDK attribute precedes its definition")
            attributes.append(attr)
    if seen != set(expected):
        raise ValueError("missing SDK dependency")
    return attributes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--image-id", required=True)
    parser.add_argument("--sdk-root", type=Path, default=Path(SDK_ROOT))
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    catalog = collect(args.report, args.sdk_root, args.image_id)
    validate(catalog, args.report.read_bytes(), args.image_id)
    with args.output.open("x") as stream:
        json.dump(catalog, stream, sort_keys=True, indent=2)
        stream.write("\n")


if __name__ == "__main__":
    main()
