#!/usr/bin/env python3
"""W-AUDIT adversarial checks for gate blind spots.

This is intentionally read-only against the product tree.  It reports classes of
false green rather than fixing them.
"""
from __future__ import annotations

import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DANGEROUS_SKIP_RE = re.compile(r"SKIP[^\n]*(?:NOT run|not found|was NOT run|simulation was NOT run)", re.I)
EXIT0_RE = re.compile(r"\bexit\s+0\b")
PIPE_RE = re.compile(r"\|")
PIPEFAIL_RE = re.compile(r"^\s*set\s+(?:-[A-Za-z]*o?\s*)?[^#\n]*\bpipefail\b|^\s*set\s+-o\s+pipefail\b", re.M)
NARROW_PIPE_RE = re.compile(r"\|\s*(tail|head|grep|tee)\b")
BROAD_STATUS_SINK_RE = re.compile(r"\|\s*(tail|head|grep|tee|sed|awk|cut|wc|sort|uniq|tr|cat)\b")


def git_files(*roots: str) -> list[Path]:
    out = subprocess.check_output(["git", "ls-files", "--", *roots], cwd=ROOT, text=True)
    return [ROOT / line for line in out.splitlines()]


def is_shell(path: Path, text: str) -> bool:
    return path.suffix == ".sh" or text.startswith("#!/usr/bin/env bash") or text.startswith("#!/bin/bash")


def strip_comment_lines(text: str) -> str:
    out: list[str] = []
    for line in text.splitlines(keepends=True):
        stripped = line.lstrip()
        out.append("\n" if stripped.startswith("#") and not stripped.startswith("#!") else line)
    return "".join(out)


def audit_skip_zero() -> list[str]:
    hits: list[str] = []
    for path in git_files("tests", "scripts"):
        if not path.exists():
            continue
        text = path.read_text(errors="ignore")
        if not is_shell(path, text):
            continue
        active = strip_comment_lines(text)
        if DANGEROUS_SKIP_RE.search(active) and EXIT0_RE.search(active):
            hits.append(str(path.relative_to(ROOT)))
    return hits


def audit_pipe_blindspots() -> tuple[list[str], list[str]]:
    broad_not_checked: list[str] = []
    masked: list[str] = []
    for path in git_files("tests", "scripts"):
        if not path.exists():
            continue
        text = path.read_text(errors="ignore")
        if not is_shell(path, text):
            continue
        active = strip_comment_lines(text)
        has_pipefail = bool(PIPEFAIL_RE.search(active))
        for no, line in enumerate(active.splitlines(), 1):
            if not PIPE_RE.search(line):
                continue
            if BROAD_STATUS_SINK_RE.search(line) and not NARROW_PIPE_RE.search(line):
                broad_not_checked.append(f"{path.relative_to(ROOT)}:{no}:{line.strip()[:160]}")
            if NARROW_PIPE_RE.search(line) and has_pipefail and re.search(r"(\|\|\s*true|\|\|\s*echo|;\s*true)", line):
                masked.append(f"{path.relative_to(ROOT)}:{no}:{line.strip()[:160]}")
    return broad_not_checked, masked


def candidate_edges(text: str, modules: set[str]) -> dict[str, set[str]]:
    defs = {m.group(1): m.group("body") for m in re.finditer(r"\bmodule\s+([A-Za-z_]\w*)\b(?P<body>.*?)\bendmodule\b", text, re.S)}
    known = sorted(modules | set(defs), key=len, reverse=True)
    graph = {name: set() for name in defs}
    for owner, body in defs.items():
        for candidate in known:
            if candidate == owner:
                continue
            pattern = r"\b" + re.escape(candidate) + r"\s*(?:#\s*\(.*?\)\s*)?[A-Za-z_]\w*(?:\s*\[[^\]]+\])?\s*\("
            if re.search(pattern, body, re.S):
                graph[owner].add(candidate)
    return graph


def reachable(root: str, graph: dict[str, set[str]]) -> set[str]:
    seen: set[str] = set()
    stack = [root]
    while stack:
        name = stack.pop()
        if name in seen:
            continue
        seen.add(name)
        stack.extend(sorted(graph.get(name, set()) - seen))
    return seen


def synthetic_reachability_blindspots() -> list[str]:
    findings: list[str] = []
    false_reachable = """
module qip_missing_child(input logic a, output logic b); assign b = a; endmodule
module emu(input logic a, output logic b); qip_missing_child u_child(.a(a), .b(b)); endmodule
"""
    graph = candidate_edges(false_reachable, {"emu", "qip_missing_child"})
    got = reachable("emu", graph)
    if "qip_missing_child" in got:
        findings.append("FALSE_REACHABLE_QIP_OMISSION: git/source graph reaches qip_missing_child even if files.qip omits its source; Quartus would not synthesize that module from the product file list.")

    param_false = """
module disabled_child(input logic a, output logic b); assign b = ~a; endmodule
module live_child(input logic a, output logic b); assign b = a; endmodule
module gen_parent #(parameter bit USE_DISABLED = 1'b0)(input logic a, output logic b);
  generate
    if (USE_DISABLED) begin : g_bad
      disabled_child u_bad(.a(a), .b(b));
    end else begin : g_good
      live_child u_good(.a(a), .b(b));
    end
  endgenerate
endmodule
module emu(input logic a, output logic b); gen_parent #(.USE_DISABLED(1'b0)) u(.a(a), .b(b)); endmodule
"""
    graph = candidate_edges(param_false, {"emu", "gen_parent", "disabled_child", "live_child"})
    got = reachable("emu", graph)
    if "disabled_child" in got:
        findings.append("FALSE_REACHABLE_PARAMETER_GENERATE: source regex reaches disabled_child inside if (USE_DISABLED) although the product parameter override is 0.")

    escaped_inst = r"""
module escaped_child(input logic a, output logic b); assign b = a; endmodule
module emu(input logic a, output logic b); escaped_child \inst.with.dots (.a(a), .b(b)); endmodule
"""
    graph = candidate_edges(escaped_inst, {"emu", "escaped_child"})
    got = reachable("emu", graph)
    if "escaped_child" not in got:
        findings.append("FALSE_UNREACHABLE_ESCAPED_INSTANCE: legal escaped SystemVerilog instance names are not matched by the instance-name regex.")
    return findings


def main() -> int:
    skips = audit_skip_zero()
    broad, masked = audit_pipe_blindspots()
    synth = synthetic_reachability_blindspots()
    print(f"W_AUDIT_SKIP_EXIT0 count={len(skips)}")
    for item in skips:
        print(f"  {item}")
    print(f"W_AUDIT_PIPE_BROAD_UNCHECKED count={len(broad)}")
    for item in broad[:80]:
        print(f"  {item}")
    if len(broad) > 80:
        print(f"  ... {len(broad) - 80} more")
    print(f"W_AUDIT_PIPE_MASKED_AFTER_NARROW_CHECK count={len(masked)}")
    for item in masked[:80]:
        print(f"  {item}")
    if len(masked) > 80:
        print(f"  ... {len(masked) - 80} more")
    print(f"W_AUDIT_SYNTHETIC_REACHABILITY_FINDINGS count={len(synth)}")
    for item in synth:
        print(f"  {item}")
    print("W_AUDIT_DONE exits_zero_for_report_mode")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
