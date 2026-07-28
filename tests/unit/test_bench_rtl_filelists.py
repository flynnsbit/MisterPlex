#!/usr/bin/env python3
"""Guard: every RTL bench must list the files defining the modules it pulls in.

Motivation: `decode_stub.sv` gained instantiations of modules that live in
`h264_inter_pred.sv`. Git saw no conflict, so benches written earlier merged
cleanly with stale file lists and then failed at Verilator elaboration with
`%Error-MODMISSING`. A merge that is textually clean but semantically broken
must fail loudly here rather than in a worker's build log.

This walks the real module graph instead of hardcoding one known pair, so the
next module that moves files is caught the same way.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RTL_DIR = os.path.join(ROOT, "fpga", "Plex_MiSTer", "rtl")
UNIT_DIR = os.path.join(ROOT, "tests", "unit")

MODULE_RE = re.compile(r"^\s*module\s+([A-Za-z_]\w*)", re.M)
WORD = "[A-Za-z_]\\w*"


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    text = re.sub(r"//[^\n]*", " ", text)
    return text


def load_modules():
    """module name -> defining file basename"""
    owner = {}
    for name in sorted(os.listdir(RTL_DIR)):
        if not name.endswith(".sv") and not name.endswith(".v"):
            continue
        body = strip_comments(open(os.path.join(RTL_DIR, name), errors="replace").read())
        for mod in MODULE_RE.findall(body):
            owner[mod] = name
    return owner


def refs_of(fname, owner):
    """Module names referenced (instantiated) by an RTL file, other than its own."""
    body = strip_comments(open(os.path.join(RTL_DIR, fname), errors="replace").read())
    own = set(MODULE_RE.findall(body))
    found = set()
    for mod in owner:
        if mod in own:
            continue
        # instantiation looks like:  <module> [#(...)] <inst> (
        if re.search(r"\b%s\b\s*(?:#\s*\(|%s\s*\()" % (re.escape(mod), WORD), body):
            found.add(mod)
    return found


def drop_qip_membership_checks(text):
    """Remove QIP membership assertions before detecting simulator inputs.

    Some RTL benches separately assert that product files are present in
    files.qip. Those checks are valuable, but they are not Verilator compile
    lists. A filename that appears only in a grep against $QIP must not count
    as a file handed to the simulator.
    """
    lines = text.splitlines()
    kept = []
    i = 0
    for_header = re.compile(r"^\s*for\s+\w+\s+in\s+.*\b[\w.]+\.s?v\b.*;\s*do\s*$")
    qip_grep = re.compile(r"\bgrep\b[^\n]*(?:\$QIP|\$\{QIP\}|[\"']\$QIP[\"'])")

    while i < len(lines):
        line = lines[i]
        if for_header.search(line):
            j = i + 1
            while j < len(lines) and not re.match(r"^\s*done\s*$", lines[j]):
                j += 1
            if j < len(lines):
                block = "\n".join(lines[i:j + 1])
                if qip_grep.search(block):
                    i = j + 1
                    continue
        if qip_grep.search(line):
            i += 1
            continue
        kept.append(line)
        i += 1
    return "\n".join(kept)


def listed_files(text, known):
    """Files actually handed to the simulator.

    A bench names RTL through shell variables, so a filename appearing only in
    its own assignment is NOT evidence it is compiled -- the variable may never
    be referenced. Resolve assignments, drop them, then look at what remains.

    Likewise, filenames that appear only in QIP membership checks are not
    simulator inputs. Drop grep-against-$QIP checks before scanning so the guard
    catches stale Verilator file lists without penalizing product-QIP asserts.
    """
    text = drop_qip_membership_checks(text)
    var_file, body_lines = {}, []
    assign = re.compile(r"^\s*(\w+)=[\"\']?\S*?([\w.]+\.s?v)[\"\']?\s*$")
    for line in text.splitlines():
        m = assign.match(line)
        if m and m.group(2) in known:
            var_file[m.group(1)] = m.group(2)
        else:
            body_lines.append(line)
    body = "\n".join(body_lines)

    used = {f for f in known if re.search(r"\b%s\b" % re.escape(f), body)}
    for var, f in var_file.items():
        if re.search(r"\$\{?%s\b" % re.escape(var), body):
            used.add(f)

    # A bench that hands Verilator the Quartus file list itself cannot go stale
    # the way this guard exists to catch: when a peer adds a submodule under
    # h264_decode_core, the file arrives in the compile list automatically. Only
    # honour this when the bench actually expands "${QIP_RTL[@]}" into the
    # simulator invocation, and resolve it against files.qip rather than
    # assuming -- so a module whose file is missing from files.qip still fails,
    # which is the stronger check.
    if re.search(r"\$\{QIP_RTL\[@\]\}", body):
        used |= qip_rtl_files() & known
    return used


def qip_rtl_files():
    """Basenames of rtl sources listed in files.qip."""
    qip = os.path.join(ROOT, "fpga", "Plex_MiSTer", "files.qip")
    if not os.path.isfile(qip):
        return set()
    out = set()
    pat = re.compile(r"(?:SYSTEMVERILOG_FILE|VERILOG_FILE)\s+(rtl/[^\s\"]+)")
    for line in open(qip, errors="replace"):
        m = pat.search(line)
        if m:
            out.add(os.path.basename(m.group(1)))
    return out


def main():
    owner = load_modules()
    deps = {f: refs_of(f, owner) for f in set(owner.values())}

    failures = []
    checked_benches = 0
    for script in sorted(os.listdir(UNIT_DIR)):
        if not (script.endswith(".sh") or script.endswith(".py")):
            continue
        if script == os.path.basename(__file__):
            continue
        path = os.path.join(UNIT_DIR, script)
        text = open(path, errors="replace").read()
        # Only benches that actually elaborate RTL can hit MODMISSING. Source
        # inspection tests merely name files and must not be flagged.
        if not re.search(r"run_verilator\.sh|bin/verilator", text):
            continue
        text = strip_comments(text)
        listed = listed_files(text, set(deps))
        if not listed:
            continue
        checked_benches += 1

        # transitive closure of what the listed files actually need
        need, seen = set(), list(listed)
        while seen:
            cur = seen.pop()
            for mod in deps.get(cur, ()):
                dep_file = owner[mod]
                if dep_file not in listed and dep_file not in need:
                    need.add(dep_file)
                    seen.append(dep_file)
                    failures.append((script, cur, mod, dep_file))

    if failures:
        print("FAILED: bench RTL file lists are stale (would hit %Error-MODMISSING)")
        for script, cur, mod, dep_file in failures:
            print("  %s: lists %s which instantiates %s, but does not list %s"
                  % (script, cur, mod, dep_file))
        return 1

    print("bench RTL file lists OK (%d RTL benches checked against %d modules)"
          % (checked_benches, len(owner)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
