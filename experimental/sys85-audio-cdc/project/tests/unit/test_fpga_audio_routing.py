#!/usr/bin/env python3
"""Exercise the actual emu audio/aspect boundaries without modeling vendor clocks."""

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import check_define_parity
import rtl_lint


class AudioRoutingTests(unittest.TestCase):
    def _audio_boundary_binary(self, name, source):
        output = Path(os.environ["AUDIO_BOUNDARY_OUTPUT"]) / name
        output.mkdir(parents=True)
        bench = ROOT / "tests/rtl" / f"{name}_tb.sv"
        inputs = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in (source, bench)}
        (output / "inputs.json").write_text(json.dumps(inputs, indent=2) + "\n")
        command = [str(ROOT / "scripts/run_verilator.sh"), "--binary", "--timing", "--assert",
                   "--build", "-j", "1", "--Mdir", str(output), "--top-module", name + "_tb",
                   "-Wno-fatal", "-DSIMULATION", str(source), str(bench)]
        (output / "command.json").write_text(json.dumps(command) + "\n")
        with (output / "build.log").open("w") as log:
            result = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, timeout=180)
        self.assertEqual(result.returncode, 0, (output / "build.log").read_text())
        return output, output / ("V" + name + "_tb")

    def test_audio_fifo_boundaries(self):
        source = Path(os.environ.get("AUDIO_FIFO_SOURCE", str(ROOT / "fpga/Plex_MiSTer/rtl/audio_fifo.sv")))
        output, binary = self._audio_boundary_binary("audio_fifo_boundary", source)
        cases = tuple(map(int, os.environ.get("AUDIO_FIFO_CASES", "0,1,2,3").split(",")))
        for rate in (20, 85):
            for case in cases:
                with self.subTest(rate=rate, case=case):
                    result = subprocess.run([binary, f"+RATE={rate}", f"+CASE={case}"],
                                            text=True, capture_output=True, timeout=120)
                    (output / f"{rate}-{case}.log").write_text(result.stdout + result.stderr)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn("PASS audio_fifo_boundary", result.stdout)

    def test_audio_control_boundaries(self):
        output, binary = self._audio_boundary_binary(
            "audio_control_boundary", ROOT / "fpga/Plex_MiSTer/rtl/audio_control_cdc.sv")
        for rate in (20, 85):
            with self.subTest(rate=rate):
                result = subprocess.run([binary, f"+RATE={rate}"], text=True, capture_output=True, timeout=60)
                (output / f"{rate}.log").write_text(result.stdout + result.stderr)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("PASS audio_control_boundary", result.stdout)

    def test_held_session_sdc_selection(self):
        # Exercise the real Tcl, including fail-closed selections. This models
        # collection APIs, not a Quartus netlist or routed endpoint inventory.
        sdc = ROOT / "fpga/Plex_MiSTer/Plex.sdc"
        self.assertNotIn("set_clock_groups", sdc.read_text())
        harness = r"""
proc derive_pll_clocks {} {}
proc derive_clock_uncertainty {} {}
proc get_collection_size {c} {llength $c}
proc foreach_in_collection {var collection body} {
    uplevel 1 [list foreach $var $collection $body]
}
proc get_object_info {option node} {
    if {$option ne "-name"} {error "unexpected object option"}
    return $node
}
proc get_registers {args} {
    set result {}
    foreach node $::registers {
        regsub -all {(^|\|)[^|:]+:} $node {\1} alias
        foreach pattern [lindex $args end] {
            if {$node eq $pattern || [string match $pattern $node] ||
                [string match $pattern $alias]} {
                lappend result $node
                break
            }
        }
    }
    return $result
}
proc get_clocks {args} {
    set result {}
    foreach node $::clocks {
        if {$node eq [lindex $args end] || [string match [lindex $args end] $node]} {
            lappend result $node
        }
    }
    return $result
}
proc get_clock_info {option clock} {
    if {$option ne "-period"} {error "unexpected clock option"}
    if {$::case eq "zero-period"} {return 0}
    if {[string match "*pll_audio*" $clock]} {return 40.682}
    return [expr {$::mode eq "85" ? 11.764 : 50.0}]
}
proc set_max_delay {args} {
    if {[llength $args] != 5 || [lindex $args 0] ne "-from" ||
        [lindex $args 2] ne "-to"} {error "unsupported max-delay shape"}
    foreach scalar {audio_ctrl_toggle audio_snapshot_toggle} {
        if {[lsearch -exact [lindex $args 1] $scalar] >= 0 &&
            [lsearch -exact [lindex $args 1] "${scalar}~DUPLICATE"] < 0} {
            error "a fitter-duplicated scalar request source was omitted"
        }
    }
    foreach name [concat [lindex $args 1] [lindex $args 3]] {
        if {[regexp {ascal|decoder|ctrl_s2|snapshot_s2|ack_s2|snap_s2} $name]} {
            error "unrelated endpoint or synchronizer second stage was selected"
        }
    }
    lappend ::max_calls $args
}
proc set_false_path {args} {
    if {[llength $args] != 5 || [lindex $args 0] ne "-hold" ||
        [lindex $args 1] ne "-from" || [lindex $args 3] ne "-to"} {
        error "broad or non-hold false path"
    }
    set recent [lindex $::max_calls end]
    if {[lindex $recent 1] ne [lindex $args 2] ||
        [lindex $recent 3] ne [lindex $args 4]} {error "hold/setup endpoint mismatch"}
    lappend ::hold_calls $args
}
proc post_message {args} {}
set mode $::env(CDC_TEST_MODE)
set case $::env(CDC_TEST_CASE)
set max_calls {}
set hold_calls {}
set clocks [list \
 {pll_audio|pll_audio_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
if {$mode eq "85"} {
 lappend clocks {emu|pll|sys85_pll|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}
} else {
 lappend clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}
}
if {$case eq "ambiguous-clock"} {lappend clocks [lindex $clocks end]}
set registers {
 audio_ctrl_data[0] audio_ctrl_data[46]~DUPLICATE audio_ctrl_data[216]
 audio_ctrl_toggle audio_snapshot_toggle
 audio_ctrl_toggle~DUPLICATE audio_snapshot_toggle~DUPLICATE
 alsa:alsa|g_session.command[0] alsa:alsa|g_session.command[46]
 alsa:alsa|g_session.snapshot[40] alsa:alsa|g_session.snapshot[220]
 alsa:alsa|g_session.snapshot[447] alsa:alsa|g_session.snapshot_ack
 alsa:alsa|g_session.ctrl_ack alsa:alsa|g_session.ctrl_s1
 alsa:alsa|g_session.ctrl_s2 alsa:alsa|g_session.snapshot_s1
 alsa:alsa|g_session.snapshot_s2
 emu:emu|audio_session_mailbox:audio_session|snapshot_capture[40]
 emu:emu|audio_session_mailbox:audio_session|snapshot_capture[220]
 emu:emu|audio_session_mailbox:audio_session|snapshot_capture[447]
 emu:emu|audio_session_mailbox:audio_session|ack_s1
 emu:emu|audio_session_mailbox:audio_session|ack_s2
 emu:emu|audio_session_mailbox:audio_session|snap_s1
 emu:emu|audio_session_mailbox:audio_session|snap_s2
 ascal:ascal|o_hfrac[1][4] decoder|unrelated[0]
}
if {$case eq "missing-capture"} {
 set filtered {}
 foreach node $registers {
  if {![string match "*snapshot_capture*" $node]} {lappend filtered $node}
 }
 set registers $filtered
}
if {$case eq "legacy-disabled"} {set registers {}}
set code [catch {source $::env(CDC_TEST_SDC)} message]
if {$case in {"missing-capture" "ambiguous-clock" "zero-period"}} {
 if {!$code} {error "invalid CDC selection was silently accepted"}
 puts "PASS fail-closed $mode $case"
} else {
 if {$code} {error $message}
 set expected [expr {$case eq "legacy-disabled" ? 0 : 6}]
 if {[llength $max_calls] != $expected || [llength $hold_calls] != $expected} {
  error "incorrect number of explicitly scoped crossings"
 }
 puts "PASS scoped CDC $mode $case crossings=$expected"
}
"""
        output = ROOT / "build/verilator/audio-cdc-selectors"
        output.mkdir(parents=True, exist_ok=True)
        interpreter = ([shutil.which("tclsh")] if shutil.which("tclsh") else
                       [str(Path.home() / ".local/oss-cad-suite/bin/yosys"),
                        "-Q", "-T", "-c", "/dev/stdin"])
        (output / "interpreter.json").write_text(json.dumps({
            "command": interpreter,
            "limit": "Existing Tcl interpreter only; no RTL synthesis or timing-netlist API"
        }, indent=2) + "\n")
        for mode in ("20", "85"):
            cases = ("active", "ambiguous-clock", "zero-period", "missing-capture", "legacy-disabled")
            for case in cases:
                env = dict(os.environ, CDC_TEST_MODE=mode, CDC_TEST_CASE=case,
                           CDC_TEST_SDC=str(sdc))
                # Tcl on stdin does not reliably propagate errors as process
                # failures, so the wrapper explicitly exits nonzero on error.
                script = "if {[catch {\n" + harness + "\n} message]} {puts stderr $message; exit 1}\n"
                result = subprocess.run(interpreter, input=script, text=True, env=env,
                                        capture_output=True, check=False)
                (output / f"{mode}-{case}.log").write_text(result.stdout + result.stderr)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("PASS", result.stdout)

    def test_native_content_de_connections(self):
        project = ROOT / "fpga/Plex_MiSTer"
        plex = "".join((project / "Plex.sv").read_text().split())
        present = "".join((project / "rtl/present_core.sv").read_text().split())
        for connection in (".de_pix(native_de)", ".de_in(native_de)", "assignVGA_DE=native_de;"):
            self.assertIn(connection, plex)
        self.assertIn(
            "wirede_out=(FPGA_DECODE_320&&use_ext)?frame_de:(~hb_d&~vb_d);", present
        )
        self.assertIn("assignde_pix=de_out;", present)

    def test_legacy_and_dma_only_routing(self):
        project = ROOT / "fpga/Plex_MiSTer"
        output = ROOT / "build/verilator/fpga_audio_routing"
        scratch = output / "compiler-scratch"
        scratch.mkdir(parents=True, exist_ok=True)
        env = dict(os.environ, TMPDIR=str(scratch))
        sources = [p for p in rtl_lint.discover_sources() if not rtl_lint.is_excluded(p)]
        sources += [project / "rtl/pll.v", project / "rtl/pll/pll_0002.v"]
        stub = rtl_lint.write_intel_stubs()
        source_map = {
            str(path.relative_to(project)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(project.rglob("*")) if path.is_file()
        }
        source_id = hashlib.sha256(json.dumps(source_map, sort_keys=True).encode()).hexdigest()
        defines = check_define_parity.verilator_define_args()
        self.assertIn("-DFPGA_VIDEO_320=1", defines)
        self.assertIn("-DPLEX_H264_INTER=1", defines)
        self.assertIn("-DPLEX_H264_FRAME_DEBLOCK=1", defines)
        self.assertIn("-DPLEX_CLK_SYS_85=1", defines)
        self.assertNotIn("-DPLEX_CLK_SYS_120=1", defines)
        self.assertNotIn("-DPLEX_CLK_SYS_180=1", defines)
        defines += [f"-DFPGA_VIDEO_BUILD_ID=32'h{source_id[:8]}"]
        report = {"source_sha256": source_id, "source_map": source_map,
                  "production_defines": defines, "modes": {},
                  "limitations": "Actual emu elaboration/routing; vendor clocks are not modeled. No fit, PCM-rate or hardware acceptance."}
        variants = {
            "baseline": {"FPGA_VIDEO_320"},
            "fpga320": set(),
            "fpga320-idr": {"PLEX_H264_INTER", "PLEX_H264_FRAME_DEBLOCK"},
            "fpga320-inter-no-filter": {"PLEX_H264_FRAME_DEBLOCK"},
            "fpga320-idr-filter": {"PLEX_H264_INTER"},
        }
        profile_pattern = re.compile(
            r"ELAB_PROFILE features=([0-9a-f]+) build_id=([0-9a-f]+) "
            r"max_width=(\d+) max_height=(\d+) max_au_bytes=(\d+) "
            r"idr_only=(\d+) deblock=(\d+)"
        )
        for mode, excluded in variants.items():
            with self.subTest(mode=mode):
                build = output / mode
                build.mkdir(parents=True, exist_ok=True)
                command = [
                    str(ROOT / "scripts/run_verilator.sh"),
                    "--binary", "--timing", "--assert", "--build", "-j", "1",
                    "--Mdir", str(build), "--top-module", "fpga_audio_routing_tb",
                    "-Wno-fatal", f"-I{project}", f"-I{project / 'rtl'}",
                    f"-I{project / 'sys'}",
                    f"-I{ROOT / 'tests/rtl/fpga_audio_routing'}",
                    *(arg for arg in defines if arg[2:].split("=")[0] not in excluded),
                ]
                command += [
                    str(ROOT / "tests/rtl/fpga_audio_routing_tb.sv"),
                    str(stub), *(str(p) for p in sources),
                ]
                log = output / f"{mode}.log"
                with log.open("w") as stream:
                    compile_result = subprocess.run(
                        command, cwd=ROOT, env=env, stdout=stream,
                        stderr=subprocess.STDOUT, check=False,
                    )
                    self.assertEqual(compile_result.returncode, 0, f"compile failed: {log}")
                    result = subprocess.run(
                        [str(build / "Vfpga_audio_routing_tb")], cwd=ROOT, env=env,
                        stdout=stream, stderr=subprocess.STDOUT, check=False,
                    )
                self.assertEqual(result.returncode, 0, f"routing failed: {log}")
                match = profile_pattern.search(log.read_text())
                self.assertIsNotNone(match, f"missing observed actual-emu profile: {log}")
                values = match.groups()
                report["modes"][mode] = dict(zip(
                    ("features", "build_id", "max_width", "max_height", "max_au_bytes",
                     "idr_only", "deblock"),
                    [int(value, 16 if index < 2 else 10)
                     for index, value in enumerate(values)],
                ))
                (output / "bindings.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    unittest.main()
