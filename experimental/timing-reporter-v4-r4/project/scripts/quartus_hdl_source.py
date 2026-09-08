"""Literal HDL provenance derivation, compatible with the pinned SDK Python3.5."""
import hashlib
from pathlib import Path
import re

KINDS = {"set_clock_groups", "set_false_path", "set_max_delay",
         "set_min_delay", "set_multicycle_path"}
FAILURE_PATTERN = re.compile(
    r"(?mi)^\s*(?:Error(?:\s*\(\d+\))?\s*:|Critical Warning\s*\(332008\)\s*:|"
    r"MPX_OBSERVER_FAILURE(?:_SINK)?\b)|Read_sdc failed")


def sha(data):
    return hashlib.sha256(data).hexdigest()


def unquote(value):
    def escape(match):
        char = match.group(1)
        if char not in {'"', "\\", "n", "r", "t", "\n"}:
            raise ValueError("unsupported HDL/attribute escape; no inferred provenance")
        return {"n": "\n", "r": "\r", "t": "\t", "\n": ""}.get(char, char)
    return re.sub(r"\\(.)", escape, value, flags=re.S)


def hdl_attributes(filename, text):
    if Path(filename).suffix.lower() not in {".v", ".sv"}:
        return []
    token = re.compile(r'"(?:\\.|[^"\\])*"|//[^\n]*|/\*.*?\*/', re.S)
    blank = lambda value: re.sub(r"[^\n]", " ", value)
    uncommented = token.sub(
        lambda match: match.group(0) if match.group(0).startswith('"') else blank(match.group(0)), text)
    code = token.sub(lambda match: blank(match.group(0)), text)
    modules = list(re.finditer(r"\b(module\s+([A-Za-z_][A-Za-z0-9_$]*)|endmodule)\b", code))
    records = []
    for attr in re.finditer(r"\(\*(.*?)\*\)", uncommented, re.S):
        owner = next((match for match in reversed(modules) if match.start() < attr.start()), None)
        if owner is None or owner.group(2) is None:
            continue
        for match in re.finditer(
                r'\baltera_attribute\s*=\s*(?:"((?:\\.|[^"\\])*)"|'
                r'\{\s*"((?:\\.|[^"\\])*)"\s*\})\s*(?=,|$)', attr.group(1), re.S):
            value = unquote(match.group(1) if match.group(1) is not None else match.group(2))
            for statement in re.finditer(
                    r'(?:^|;)\s*-name\s+SDC_STATEMENT\s+"((?:\\.|[^"\\])*)"\s*(?=;|$)', value, re.S):
                command = unquote(statement.group(1)).strip()
                if not command or command.split(None, 1)[0] not in KINDS:
                    continue
                records.append({
                    "file": filename, "source_sha256": sha(text.encode()),
                    "line": text.count("\n", 0, attr.start()) + 1,
                    "entity_line": text.count("\n", 0, owner.start()) + 1,
                    "entity": owner.group(2), "statement": command,
                    "statement_sha256": sha(command.encode()),
                    "attribute_sha256": sha(text[attr.start():attr.end()].encode()),
                })
    return records
