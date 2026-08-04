#!/usr/bin/env python3
"""Curated source-level guard for Quartus SystemVerilog / project-file pitfalls.

This is not a synthesizer. It catches constructs that Verilator (or humans)
accept but the project's Quartus 17.0 flow rejected during open/Analysis.

Classes (parent fit escapes 2026-08-04 — all three previously returned make
quartus-sv-subset rc=0 while Quartus hard-failed):

  A. C-style `//` comments in Tcl-syntax project files (.qip/.qsf/.tcl/.sdc)
     → Error (125091): invalid command name "//"
  B. Duplicate module declarations across files listed in files.qip
     → Error (10228): module cannot be declared more than once
  C. SystemVerilog default values on ports (after stripping // comments)
     → Error (10231): value cannot be assigned to input "..."

Also retains prior curated SV patterns (localparam-in-#(), call part-select,
ref_win concat in functions).

Toolchain probe: if Quartus is unreachable the gate REFUSES (rc=4) rather than
manufacturing confidence from a static scan alone — unless
QUARTUS_SV_SUBSET_STATIC_ONLY=1 (unit self-test / fixture controls).
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

REFUSE_RC = 4
REJECT_RC = 1

TCL_SUFFIXES = {".qip", ".qsf", ".tcl", ".sdc"}

# Port direction ... name = value , or ;
# Applied to a single logical line with // comments already stripped.
_PORT_DEFAULT_RE = re.compile(
    r"(?P<pre>^|\n)\s*"
    r"(?P<dir>input|output|inout)\b"
    r"(?P<body>(?:(?!;)[\s\S])*?)"
    r"(?P<eq>=)\s*"
    r"(?P<val>[^,\n;]+)"
    r"(?P<trail>\s*[,;])",
    re.MULTILINE,
)

_MODULE_RE = re.compile(
    r"(?m)^\s*module\s+([A-Za-z_]\w*)\b"
)

_QIP_FILE_RE = re.compile(
    r"set_global_assignment\s+-name\s+(?:SYSTEMVERILOG_FILE|VERILOG_FILE)\s+(\S+)",
    re.IGNORECASE,
)


class ToolchainRefused(RuntimeError):
    pass


def strip_line_comments(text: str) -> str:
    """Strip // and /* */ comments. Used before SV semantic matches."""
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//.*", "", text)


def strip_comments(text: str) -> str:
    return strip_line_comments(text)


def line_no(text: str, idx: int) -> int:
    return text.count("\n", 0, idx) + 1


def unpacked_arrays(text: str) -> set[str]:
    names: set[str] = set()
    decl = re.compile(
        r"\b(?:input|output|inout|wire|reg|logic)\b"
        r"(?:\s+(?:wire|reg|logic|signed))*"
        r"(?:\s+\[[^\]]+\])*"
        r"\s+([A-Za-z_]\w*)\s*\[[^\]]+\]"
    )
    for m in decl.finditer(text):
        names.add(m.group(1))
    return names


def module_param_blocks(text: str) -> list[tuple[int, str]]:
    blocks: list[tuple[int, str]] = []
    pat = re.compile(r"\bmodule\s+[A-Za-z_]\w*\s*#\s*\(")
    for m in pat.finditer(text):
        depth = 1
        i = m.end()
        while i < len(text) and depth:
            if text[i] == "(":
                depth += 1
            elif text[i] == ")":
                depth -= 1
            i += 1
        blocks.append((m.end(), text[m.end() : i - 1]))
    return blocks


def function_blocks(text: str) -> list[tuple[int, str]]:
    blocks: list[tuple[int, str]] = []
    pat = re.compile(r"\bfunction\b")
    end_pat = re.compile(r"\bendfunction\b")
    for m in pat.finditer(text):
        end = end_pat.search(text, m.end())
        if end:
            blocks.append((m.start(), text[m.start() : end.end()]))
    return blocks


def _run_quartus_version(cmd: list[str], *, input_text: str | None = None) -> str | None:
    try:
        proc = subprocess.run(
            cmd,
            input=input_text,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=60,
        )
    except (OSError, subprocess.TimeoutExpired) as e:
        return f"{type(e).__name__}: {e}"
    if proc.returncode == 0:
        return None
    return (proc.stdout or f"exit {proc.returncode}").strip()


def probe_quartus_toolchain() -> str:
    if os.environ.get("QUARTUS_SV_SUBSET_STATIC_ONLY") == "1":
        return "static_only:probe_skipped"
    if os.environ.get("QUARTUS_SV_SUBSET_DISABLE_LOCAL_PROBE") != "1":
        quartus_map = os.environ.get("QUARTUS_MAP") or shutil.which("quartus_map")
        if quartus_map:
            if not os.access(quartus_map, os.X_OK):
                raise ToolchainRefused(f"QUARTUS_MAP is not executable: {quartus_map}")
            err = _run_quartus_version([quartus_map, "--version"])
            if err is None:
                return f"local:{quartus_map}"
            raise ToolchainRefused(f"local quartus_map probe failed: {err}")

    if os.environ.get("QUARTUS_SV_SUBSET_DISABLE_REMOTE_PROBE") == "1":
        raise ToolchainRefused("local Quartus not found and remote probe disabled")

    ssh_bin = os.environ.get("MISTER_PREFIT_SSH_BIN", "ssh")
    ssh_path = shutil.which(ssh_bin) if "/" not in ssh_bin else ssh_bin
    if not ssh_path or not os.path.exists(ssh_path):
        raise ToolchainRefused(f"ssh client not found: {ssh_bin}")

    host = (
        os.environ.get("MISTER_PREFIT_REMOTE_HOST")
        or os.environ.get("MISTER_REMOTE_HOST")
        or "docker"
    )
    remote_dev = (
        os.environ.get("MISTER_PREFIT_REMOTE_DEV")
        or os.environ.get("MISTER_REMOTE_DEV")
        or "__DEFAULT_REMOTE_DEV__"
    )
    remote_script = r"""
set -euo pipefail
remote_dev="$1"
if [[ "$remote_dev" == "__DEFAULT_REMOTE_DEV__" ]]; then
  remote_dev_expanded="$HOME/misterfpga-dev"
else
  remote_dev_expanded="$remote_dev"
fi
if [[ ! -f "$remote_dev_expanded/scripts/lib.sh" ]]; then
  echo "Remote mister-dev lib not found at $remote_dev_expanded/scripts/lib.sh" >&2
  exit 4
fi
# shellcheck source=/dev/null
source "$remote_dev_expanded/scripts/lib.sh"
load_env
if [[ -z "${QUARTUS_IMAGE:-}" ]]; then
  echo "QUARTUS_IMAGE is not set after mister-dev load_env" >&2
  exit 4
fi
docker run --rm "$QUARTUS_IMAGE" quartus_map --version >/dev/null
"""
    err = _run_quartus_version(
        [ssh_bin, host, "bash", "-s", "--", remote_dev], input_text=remote_script
    )
    if err is None:
        return f"remote:{host}"
    raise ToolchainRefused(f"remote Quartus probe failed on {host}: {err}")


def check_legacy_sv_patterns(path: Path, raw: str) -> list[str]:
    text = strip_comments(raw)
    errors: list[str] = []

    for start, block in module_param_blocks(text):
        rel = block.find("localparam")
        if rel >= 0:
            errors.append(
                f"{path}:{line_no(text, start + rel)}: localparam in module parameter list "
                "is rejected by Quartus Analysis/Synthesis; use a normal parameter or move "
                "the localparam into the module body."
            )

    call_select = re.compile(r"\b[A-Za-z_]\w*\s*\([^;\n]*\)\s*\[[^\]]+\]")
    for m in call_select.finditer(text):
        errors.append(
            f"{path}:{line_no(text, m.start())}: part-select on a function-call result "
            "is rejected by Quartus; assign through a typed helper/temp first."
        )

    arrays = {name for name in unpacked_arrays(text) if name == "ref_win"}
    for fn_start, fn_body in function_blocks(text):
        for name in arrays:
            concat_array = re.compile(
                r"\{[^{}\n;]*\b" + re.escape(name) + r"\s*\[[^{}\n;]*\][^{}\n;]*\}"
            )
            for m in concat_array.finditer(fn_body):
                errors.append(
                    f"{path}:{line_no(text, fn_start + m.start())}: unpacked array element "
                    f"`{name}[...]` inside a function-body concatenation matched the observed "
                    "Quartus rejection; read it into a scalar temp first."
                )
    return errors


def check_port_defaults(path: Path, raw: str) -> list[str]:
    """Class C: SV default port values (// comments stripped first).

    Prevents Quartus Error (10231): value cannot be assigned to input "...".
    Trailing `// 0=none` comments must NOT match.
    """
    # Work line-by-line so line numbers map to the source file.
    errors: list[str] = []
    for i, line in enumerate(raw.splitlines(), 1):
        code = re.sub(r"//.*", "", line)
        code = re.sub(r"/\*.*?\*/", "", code)
        if not re.search(r"\b(input|output|inout)\b", code):
            continue
        # Default value: direction ... = expr ending with , or ;
        if re.search(
            r"\b(input|output|inout)\b(?:(?![=;]).)*=\s*[^,;]+[,;]?\s*$",
            code,
        ):
            # Exclude pure parameter/localparam (not ports) — already require dir keyword.
            # Exclude assign statements: "assign x = " has no input/output/inout as port decl.
            if re.match(r"\s*assign\b", code):
                continue
            errors.append(
                f"{path}:{i}: Class C port default value — Quartus Error (10231) rejects "
                f"default values on ports (SV-2012); remove `=` and tie at the instance. "
                f"line={code.strip()}"
            )
    return errors


def check_tcl_c_comments(path: Path, raw: str) -> list[str]:
    """Class A: // as first non-ws on Tcl project files.

    Prevents Quartus Error (125091): invalid command name "//" / Error (125080).
    """
    errors: list[str] = []
    for i, line in enumerate(raw.splitlines(), 1):
        if re.match(r"\s*//", line):
            errors.append(
                f"{path}:{i}: Class A C-style comment in Tcl project file — Quartus Error "
                f"(125091) invalid command name \"//\"; use `#` (Tcl) not `//`. "
                f"line={line.strip()[:80]}"
            )
    return errors


def parse_qip_hdl_files(qip: Path) -> list[Path]:
    root = qip.parent
    out: list[Path] = []
    for line in qip.read_text().splitlines():
        # strip Tcl # comments
        code = re.sub(r"#.*", "", line).strip()
        if not code:
            continue
        m = _QIP_FILE_RE.search(code)
        if not m:
            continue
        rel = m.group(1).strip().strip("{}")
        out.append((root / rel).resolve())
    return out


def discover_project_dir(hint_paths: list[Path]) -> Path | None:
    env = os.environ.get("QUARTUS_SV_SUBSET_PROJECT_DIR")
    if env:
        p = Path(env)
        if (p / "files.qip").is_file():
            return p
    for path in hint_paths:
        cur = path if path.is_dir() else path.parent
        for parent in [cur, *cur.parents]:
            if (parent / "files.qip").is_file() and (parent / "Plex.qsf").is_file():
                return parent
    return None


def collect_tcl_project_files(project_dir: Path) -> list[Path]:
    files: list[Path] = []
    for p in sorted(project_dir.rglob("*")):
        if not p.is_file():
            continue
        if p.suffix.lower() in TCL_SUFFIXES:
            # Skip generated db/incremental_db noise if present under tree
            parts = set(p.parts)
            if "db" in parts or "incremental_db" in parts or "output_files" in parts:
                continue
            files.append(p)
    return files


def check_duplicate_modules(sv_files: list[Path]) -> list[str]:
    """Class B: module name declared more than once across QIP-listed SV files.

    Prevents Quartus Error (10228): module "X" cannot be declared more than once.
    """
    decls: dict[str, list[str]] = defaultdict(list)
    for path in sv_files:
        if not path.is_file():
            continue
        raw = path.read_text(errors="replace")
        text = strip_comments(raw)
        for m in _MODULE_RE.finditer(text):
            name = m.group(1)
            decls[name].append(f"{path}:{line_no(text, m.start())}")
    errors: list[str] = []
    for name, locs in sorted(decls.items()):
        if len(locs) > 1:
            joined = ", ".join(locs)
            errors.append(
                f"Class B duplicate module `{name}` — Quartus Error (10228) module "
                f"cannot be declared more than once; declarations at: {joined}"
            )
    return errors


def check_file(path: Path) -> list[str]:
    raw = path.read_text(errors="replace")
    suf = path.suffix.lower()
    if suf in TCL_SUFFIXES:
        return check_tcl_c_comments(path, raw)
    if suf in {".sv", ".v", ".svh", ".vh"}:
        return check_legacy_sv_patterns(path, raw) + check_port_defaults(path, raw)
    return []


def run_checks(
    files: list[Path],
    *,
    project_dir: Path | None,
    skip_project_scan: bool = False,
) -> list[str]:
    errors: list[str] = []
    for path in files:
        if path.is_file():
            errors.extend(check_file(path))

    if skip_project_scan:
        return errors

    proj = project_dir or discover_project_dir(files)
    if proj is None:
        return errors

    # Class A over all Tcl project files under the Quartus project dir.
    for tp in collect_tcl_project_files(proj):
        # Avoid double-scanning if already in files list
        if tp.resolve() in {f.resolve() for f in files if f.suffix.lower() in TCL_SUFFIXES}:
            continue
        errors.extend(check_tcl_c_comments(tp, tp.read_text(errors="replace")))

    # Class B over QIP-listed HDL only (what Quartus is told to read).
    qip = proj / "files.qip"
    if qip.is_file():
        # Also include top from QSF if present
        hdl = parse_qip_hdl_files(qip)
        qsf = proj / "Plex.qsf"
        if qsf.is_file():
            for line in qsf.read_text(errors="replace").splitlines():
                code = re.sub(r"#.*", "", line)
                m = _QIP_FILE_RE.search(code)
                if m:
                    hdl.append((proj / m.group(1).strip().strip("{}")).resolve())
        # Unique preserve order
        seen: set[Path] = set()
        uniq: list[Path] = []
        for p in hdl:
            rp = p.resolve()
            if rp not in seen:
                seen.add(rp)
                uniq.append(rp)
        errors.extend(check_duplicate_modules(uniq))
        # Class C on QIP set even if not in argv (rtl_lint list may differ)
        for p in uniq:
            if p.is_file() and p.suffix.lower() in {".sv", ".v"}:
                # port defaults already checked if p in files; still check QIP-only
                if p.resolve() not in {f.resolve() for f in files}:
                    errors.extend(check_port_defaults(p, p.read_text(errors="replace")))
                    errors.extend(check_legacy_sv_patterns(p, p.read_text(errors="replace")))
    return errors


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("files", nargs="*", type=Path, help="SV/Tcl files to scan")
    ap.add_argument(
        "--project-dir",
        type=Path,
        default=None,
        help="Quartus project dir containing files.qip (enables A/B project scan)",
    )
    ap.add_argument(
        "--no-project-scan",
        action="store_true",
        help="Only scan argv files (fixture unit tests)",
    )
    ap.add_argument(
        "--static-only",
        action="store_true",
        help="Skip Quartus toolchain probe (same as QUARTUS_SV_SUBSET_STATIC_ONLY=1)",
    )
    args = ap.parse_args(argv[1:])

    if args.static_only:
        os.environ["QUARTUS_SV_SUBSET_STATIC_ONLY"] = "1"

    try:
        toolchain = probe_quartus_toolchain()
    except ToolchainRefused as e:
        print(f"QUARTUS_SV_SUBSET_REFUSED(exit={REFUSE_RC}): {e}", file=sys.stderr)
        return REFUSE_RC

    files = list(args.files)
    if not files and args.project_dir is None and not args.no_project_scan:
        print("usage: check_quartus_sv_subset.py FILE... | --project-dir DIR", file=sys.stderr)
        return 2

    errors = run_checks(
        files,
        project_dir=args.project_dir,
        skip_project_scan=args.no_project_scan,
    )
    if errors:
        print(f"QUARTUS_SV_SUBSET_REJECTED(exit={REJECT_RC}):", file=sys.stderr)
        for err in errors:
            print(f"  {err}", file=sys.stderr)
        return REJECT_RC
    print(
        f"STATIC_PASS Quartus SV subset pattern scan: {len(files)} argv file(s); "
        f"toolchain={toolchain}; classes=A_tcl_//,B_dup_module,C_port_default,"
        f"legacy_localparam_callsel_refwin; "
        "limitation=static_curated_patterns_only; "
        "paired_gate=verilator-elab_for_elaboration_errors; "
        "not_a_Quartus_analysis_or_synthesis_PASS"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
