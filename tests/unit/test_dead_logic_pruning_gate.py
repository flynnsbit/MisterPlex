#!/usr/bin/env python3
"""Red/green for the dead-logic pruning gate (failure mode 3).

W-FIT-O5 measured with Quartus Analysis & Synthesis on `w-decode-hour27`
`2f165ed` that `h264_decode_core` is compiled, instantiated unconditionally,
elaborated with a full hierarchy path -- and then deleted, because it
contributes zero resources. Fit conditions 1 and 2 were both green there.

The gate is a source-level pre-filter for that. Its two real-world anchors,
measured on that same commit and agreeing with A&S in ~2s rather than 4m23s:

    --require h264_decode_core   rc=1   13/13 output nets dead   (A&S: ABSENT)
    --require decode_stub        rc=0   10/10 output nets live   (A&S: PRESENT)

Those anchors need another worktree, so this suite rebuilds the same shapes
synthetically. Two of the cases are regressions against defects the gate had
while I was writing it, both of which produced a *confident* wrong answer:

  * `port_direction_persists_across_commas` -- the first port parser used a
    greedy name group per direction keyword, so it swallowed every following
    port and reported `outputs=0` for the core. The gate then failed it for
    having no live outputs: a true rc=1 about nothing.
  * `paren_construct_is_not_an_instance` -- sibling instances were detected
    with a bare `identifier (` regex, which matches `if (`. Nearly every net
    became a sink and the core came out GREEN, contradicting Quartus.
"""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import check_dead_logic_pruning as dead  # noqa: E402

GATE = ROOT / "scripts" / "check_dead_logic_pruning.py"

TOP = """
module emu(input wire clk, output wire [7:0] pix);
	wire [7:0] w_out;
	wire       w_flag;
	widget u_w(.clk(clk), .o(w_out), .flag(w_flag));
{extra}
endmodule
"""

WIDGET = """
module widget(input wire clk, output wire [7:0] o, output wire flag);
	assign o = 8'd7;
	assign flag = 1'b1;
endmodule
"""


def build(root: Path, top_extra: str, extra_files: dict[str, str] | None = None) -> Path:
    proj = root / "fpga" / "Plex_MiSTer"
    rtl_dir = proj / "rtl"
    rtl_dir.mkdir(parents=True)
    (proj / "Plex.sv").write_text(TOP.format(extra=top_extra))
    (proj / "Plex.qsf").write_text("set_global_assignment -name TOP_LEVEL_ENTITY emu\n")
    (rtl_dir / "widget.sv").write_text(WIDGET)
    for name, text in (extra_files or {}).items():
        (rtl_dir / name).write_text(text)
    env = {
        **os.environ,
        "GIT_AUTHOR_NAME": "w-gate", "GIT_AUTHOR_EMAIL": "w-gate@example.invalid",
        "GIT_COMMITTER_NAME": "w-gate", "GIT_COMMITTER_EMAIL": "w-gate@example.invalid",
    }
    subprocess.run(["git", "init", "-q"], cwd=root, check=True, env=env)
    subprocess.run(["git", "add", "-A"], cwd=root, check=True, env=env)
    subprocess.run(["git", "commit", "-qm", "synthetic"], cwd=root, check=True, env=env)
    return root


def run(root: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(GATE), "--project-root", str(root), *args],
        capture_output=True, text=True,
    )


def scratch():
    base = ROOT / "build" / "w-gate-o5-scratch"
    base.mkdir(parents=True, exist_ok=True)
    return tempfile.TemporaryDirectory(prefix="deadlogic-", dir=str(base))


# The merge-base shape: every output is reduced into one keep wire that nobody
# reads.  A keep-alive that is never read keeps nothing.
KEEP_ONLY = "\twire _keep = |w_out | w_flag;\n"
# Same, but the keep wire carries the attribute Quartus honours.
KEPT = "\t(* keep = 1 *) wire _keep = |w_out | w_flag;\n"
# The output escapes through a port of the parent.
ESCAPES = "\tassign pix = w_out;\n"
# The output feeds another real instance.
FEEDS_SIBLING = (
    "\twire [7:0] chained;\n"
    "\tsink u_s(.clk(clk), .d(w_out), .q(chained));\n"
    "\tassign pix = chained;\n"
)
SINK = """
module sink(input wire clk, input wire [7:0] d, output wire [7:0] q);
	assign q = d;
endmodule
"""


def case_keep_only_chain_is_pruned() -> None:
    with scratch() as td:
        root = build(Path(td), KEEP_ONLY)
        proc = run(root, "--require", "widget")
        assert proc.returncode == 1, proc.stdout + proc.stderr
        assert "DEAD_OUTPUT_NET widget.o" in proc.stdout, proc.stdout
        assert "live=0 dead=2" in proc.stdout, proc.stdout
        assert "failure mode 3" in proc.stderr, proc.stderr


def case_escaping_through_parent_port_is_live() -> None:
    with scratch() as td:
        root = build(Path(td), ESCAPES + "\twire _keep = w_flag;\n")
        proc = run(root, "--require", "widget")
        assert proc.returncode == 0, proc.stdout + proc.stderr
        assert "LIVE_OUTPUT_NET widget.o" in proc.stdout, proc.stdout


def case_feeding_a_sibling_instance_is_live() -> None:
    with scratch() as td:
        root = build(Path(td), FEEDS_SIBLING, {"sink.sv": SINK})
        proc = run(root, "--require", "widget")
        assert proc.returncode == 0, proc.stdout + proc.stderr


def case_keep_attribute_is_honoured() -> None:
    """Quartus honours (* keep *), so the gate must too, even though it hides deadness."""
    with scratch() as td:
        root = build(Path(td), KEPT)
        proc = run(root, "--require", "widget")
        assert proc.returncode == 0, proc.stdout + proc.stderr


def case_unconnected_output_is_dead() -> None:
    with scratch() as td:
        top = TOP.format(extra="\tassign pix = 8'd0;\n").replace(
            "widget u_w(.clk(clk), .o(w_out), .flag(w_flag));",
            "widget u_w(.clk(clk), .o(), .flag());",
        )
        root = Path(td)
        proj = root / "fpga" / "Plex_MiSTer"
        (proj / "rtl").mkdir(parents=True)
        (proj / "Plex.sv").write_text(top)
        (proj / "Plex.qsf").write_text("set_global_assignment -name TOP_LEVEL_ENTITY emu\n")
        (proj / "rtl" / "widget.sv").write_text(WIDGET)
        env = {**os.environ, "GIT_AUTHOR_NAME": "w", "GIT_AUTHOR_EMAIL": "w@x.invalid",
               "GIT_COMMITTER_NAME": "w", "GIT_COMMITTER_EMAIL": "w@x.invalid"}
        subprocess.run(["git", "init", "-q"], cwd=root, check=True, env=env)
        subprocess.run(["git", "add", "-A"], cwd=root, check=True, env=env)
        subprocess.run(["git", "commit", "-qm", "s"], cwd=root, check=True, env=env)
        proc = run(root, "--require", "widget")
        assert proc.returncode == 1, proc.stdout + proc.stderr
        assert "<unconnected>" in proc.stdout, proc.stdout


def case_module_without_outputs_is_refused_not_failed() -> None:
    """outputs=0 is a Scope: 0. The gate must refuse, never score it as dead."""
    with scratch() as td:
        root = build(
            Path(td),
            "\tmonitor u_m(.clk(clk), .d(w_out));\n\tassign pix = w_out;\n",
            {"monitor.sv": "module monitor(input wire clk, input wire [7:0] d);\nendmodule\n"},
        )
        proc = run(root, "--require", "monitor")
        assert proc.returncode == 2, proc.stdout + proc.stderr
        assert "NO_OUTPUT_PORTS monitor" in proc.stdout, proc.stdout
        assert "REFUSED" in proc.stderr, proc.stderr


def case_uninstantiated_module_is_not_a_deadness_finding() -> None:
    with scratch() as td:
        root = build(Path(td), ESCAPES, {"lonely.sv": SINK.replace("sink", "lonely")})
        proc = run(root, "--require", "lonely")
        assert proc.returncode == 1, proc.stdout + proc.stderr
        assert "NOT_INSTANTIATED lonely" in proc.stdout, proc.stdout
        assert "failure mode 2" in proc.stdout, proc.stdout


def case_fictional_module_is_fatal() -> None:
    with scratch() as td:
        root = build(Path(td), ESCAPES)
        proc = run(root, "--require", "w_gate_totally_fictional_module")
        assert proc.returncode == 1, proc.stdout + proc.stderr
        assert "do not exist" in proc.stderr, proc.stderr


def case_no_require_is_unscored_not_green() -> None:
    with scratch() as td:
        root = build(Path(td), ESCAPES)
        proc = run(root)
        assert proc.returncode == 77, proc.stdout + proc.stderr
        assert proc.stdout.splitlines()[0].startswith("Scope: "), proc.stdout


def case_port_direction_persists_across_commas() -> None:
    """Regression: the greedy name group reported outputs=0 for the real core."""
    ports = dead.module_port_directions(
        "(input wire clk, reset, output wire [7:0] a, b, input c);"
    )
    assert ports["clk"] == "input", ports
    assert ports["reset"] == "input", ports
    assert ports["a"] == "output", ports
    assert ports["b"] == "output", ports
    assert ports["c"] == "input", ports
    unpacked = dead.module_port_directions("(input wire [7:0] rbsp_byte [0:63]);")
    assert unpacked == {"rbsp_byte": "input"}, unpacked


def case_paren_construct_is_not_an_instance() -> None:
    """Regression: `if (` used to register as a sibling instantiation.

    Under that defect every net named in any parenthesised construct became a
    sink, so a module whose outputs go nowhere came out GREEN -- contradicting
    the Quartus run this gate exists to anticipate.
    """
    with scratch() as td:
        extra = (
            "\treg seen;\n"
            "\talways @(posedge clk) begin\n"
            "\t\tif (w_flag) begin end\n"
            "\tend\n"
            "\tassign pix = 8'd0;\n"
            "\twire _keep = |w_out;\n"
        )
        root = build(Path(td), extra)
        proc = run(root, "--require", "widget")
        assert proc.returncode == 1, (
            "a net mentioned only inside if(...) is not consumed\n"
            + proc.stdout + proc.stderr
        )
        assert "live=0" in proc.stdout, proc.stdout


def main() -> int:
    cases = (
        case_keep_only_chain_is_pruned,
        case_escaping_through_parent_port_is_live,
        case_feeding_a_sibling_instance_is_live,
        case_keep_attribute_is_honoured,
        case_unconnected_output_is_dead,
        case_module_without_outputs_is_refused_not_failed,
        case_uninstantiated_module_is_not_a_deadness_finding,
        case_fictional_module_is_fatal,
        case_no_require_is_unscored_not_green,
        case_port_direction_persists_across_commas,
        case_paren_construct_is_not_an_instance,
    )
    print(f"Scope: dead_logic_gate_cases={len(cases)}")
    for case in cases:
        case()
    print(f"DEAD_LOGIC_GATE_TEST_OK cases={len(cases)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
