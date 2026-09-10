#!/usr/bin/env python3
"""Exercise the actual emu audio/aspect boundaries without modeling vendor clocks."""

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import unittest
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import check_define_parity
import rtl_lint


class AudioRoutingTests(unittest.TestCase):
    def _product_macros(self, qsf):
        # Reuse the existing parser without its project-relative lint/date
        # assumptions: the pinned negative may be restored outside this ROOT.
        macros = {}
        for line in qsf.read_text().splitlines():
            line = check_define_parity.strip_hash_comment(line)
            match = re.search(r"\bset_global_assignment\b.*?-name\s+VERILOG_MACRO\s+(.+)$", line)
            if match:
                macro = check_define_parity.parse_verilog_macro(match[1], str(qsf))
                self.assertIsNotNone(macro, "unparseable product macro")
                self.assertNotIn(macro.name, macros, "duplicate/ambiguous product macro")
                macros[macro.name] = macro
        return macros

    def _actual_sys_mhz(self, qsf=None):
        qsf = qsf or ROOT / "fpga/Plex_MiSTer/Plex.qsf"
        macros = self._product_macros(qsf)
        for name in ("FPGA_VIDEO_320", "DDR_FRAME_STORE", "SDRAM_CLK_142"):
            self.assertIn(name, macros, "missing staged product profile")
            self.assertEqual(macros[name].value, "1", "unsupported staged product profile")
        self.assertNotIn("PLEX_SELECTED_ROOT_RESET_SYNC", macros, "private RTL selection is not a QSF override")
        clocks = {name for name in macros if name.startswith("PLEX_CLK_SYS_")}
        self.assertLessEqual(clocks, {"PLEX_CLK_SYS_85"},
                             "reset/routing cases support only the staged SYS20/SYS85 family")
        if "PLEX_CLK_SYS_85" in macros:
            self.assertEqual(macros["PLEX_CLK_SYS_85"].value, "1")
            self.assertNotIn("PLEX_SYS20_RESET_SYNC", macros, "contradictory SYS85/SYS20 reset selectors")
            return 85
        if "PLEX_SYS20_RESET_SYNC" in macros:
            self.assertEqual(macros["PLEX_SYS20_RESET_SYNC"].value, "1")
        return 20

    def _selected_source(self, product, relative, output):
        qsf = product / "Plex.qsf"
        self._actual_sys_mhz(qsf)
        destination = output / relative.replace("/", "__")
        destination.mkdir(parents=True)
        defines = [f"-D{name}={macro.value}"
                   for name, macro in sorted(self._product_macros(qsf).items())]
        stub = ROOT / "tests/rtl/fpga_audio_routing/build_id.v"
        self.assertTrue(stub.is_file(), "existing build-date stub is required")
        command = [str(ROOT / "scripts/run_verilator.sh"), "-E",
                   f"-I{product}", f"-I{product / 'rtl'}", f"-I{product / 'sys'}",
                   f"-I{stub.parent}", *defines, str(product / relative)]
        result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True, timeout=180)
        (destination / "command.json").write_text(json.dumps(command) + "\n")
        (destination / "selected.sv").write_text(result.stdout)
        (destination / "preprocess.log").write_text(result.stderr)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        selected = re.sub(r"(?m)^[ \t]*`line[^\n]*\n?", "", result.stdout)
        self.assertNotRegex(selected, r"(?m)^[ \t]*`(?:ifdef|ifndef|elsif|else|endif|include)\b",
                            "product selection was not preprocessed")
        binding = {
            "product": str(product), "source": relative, "production_defines": defines,
            "input_files": {str(p.relative_to(product)): hashlib.sha256(p.read_bytes()).hexdigest()
                            for p in sorted(product.rglob("*")) if p.is_file()},
            "qsf_sha256": hashlib.sha256(qsf.read_bytes()).hexdigest(),
            "stub_sha256": hashlib.sha256(stub.read_bytes()).hexdigest(),
            "selected_source_sha256": hashlib.sha256(selected.encode()).hexdigest(),
            "preprocessor_exit": result.returncode,
        }
        (destination / "binding.json").write_text(json.dumps(binding, indent=2) + "\n")
        return selected, binding

    def _one_selected(self, source, pattern, label):
        matches = list(re.finditer(pattern, source, re.M | re.S))
        self.assertEqual(len(matches), 1, f"selected product has missing/ambiguous {label}")
        return matches[0].group(0)

    def _selected_process(self, source, clock, reset):
        return self._one_selected(source, r"^([ \t]*)always @\(posedge " + clock +
            r" or posedge " + reset + r"\) begin.*?^\1end\b", clock + "/" + reset)

    def _selected_root(self, product, output):
        selected, binding = self._selected_source(product, "Plex.sv", output)
        self.assertRegex(selected, r"(?m)^[ \t]*assign\s+MPX_AUDIO_RESET\s*=\s*reset\s*;",
                         "actual root-to-audio reset connection is absent")
        wire = self._one_selected(selected, r"^[ \t]*wire\s+reset\s*=[^;]+;", "root reset output")
        compact = "".join(wire.split())
        root = wire
        if compact == "wirereset=reset_sys_sync[1];":
            request = self._one_selected(selected, r"^[ \t]*wire\s+reset_request\s*=[^;]+;", "root request")
            declaration = self._one_selected(selected,
                r"^[ \t]*reg\s+\[1:0\]\s+reset_sys_sync\s*=[^;]+;", "root state")
            process = self._selected_process(selected, "clk_sys", "reset_request")
            self.assertEqual("".join(request.split()),
                "wirereset_request=RESET|status[0]|buttons[1]|~pll_locked;")
            self.assertEqual("".join(declaration.split()), "reg[1:0]reset_sys_sync=2'b11;")
            self.assertEqual("".join(process.split()),
                "always@(posedgeclk_sysorposedgereset_request)begin"
                "if(reset_request)reset_sys_sync<=2'b11;"
                "elsereset_sys_sync<={reset_sys_sync[0],1'b0};end")
            root = "\n".join((request, declaration, process, wire))
            kind = "synchronized"
        elif compact == "wirereset=RESET|status[0]|buttons[1];":
            self.assertNotRegex(selected, r"\b(?:reg|wire)[^;\n]*\b(?:reset_sys_sync|reset_request)\b",
                                "raw output coexists with unexpected root state")
            kind = "raw"
        else:
            self.fail("unknown selected root reset expression: " + compact)
        macros = self._product_macros(product / "Plex.qsf")
        expected_sync = "PLEX_CLK_SYS_85" in macros or "PLEX_SYS20_RESET_SYNC" in macros
        self.assertEqual(kind == "synchronized", expected_sync,
                         "actual selected root does not match the explicit product reset profile")
        binding.update(selected_root=kind, selected_root_sha256=hashlib.sha256(root.encode()).hexdigest(),
                       SYS_MHz=self._actual_sys_mhz(product / "Plex.qsf"),
                       two_edge_retention_supported=kind == "synchronized")
        (output / "root-selection.json").write_text(json.dumps(binding, indent=2) + "\n")
        return root, binding

    def _require_root_retention(self, binding):
        self.assertEqual(binding["selected_root"], "synchronized",
                         "selected raw root cannot claim two-edge retention")

    def _run_reset_harness(self, output, name, harness):
        source = output / (name + ".sv")
        source.write_text(harness)
        command = [str(ROOT / "scripts/run_verilator.sh"), "--binary", "--timing", "--assert",
                   "-j", "1", "--Mdir", str(output / "obj"), "--top-module", name,
                   "-Wno-fatal", str(source)]
        (output / "command.json").write_text(json.dumps(command) + "\n")
        with (output / "build.log").open("w") as log:
            result = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, timeout=180)
        self.assertEqual(result.returncode, 0, (output / "build.log").read_text())
        result = subprocess.run([output / ("obj/V" + name)], text=True, capture_output=True, timeout=60)
        (output / "result.log").write_text(result.stdout + result.stderr)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def test_routed_reset_boundaries(self):
        output = Path(os.environ["AUDIO_BOUNDARY_OUTPUT"]) / "routed-reset"
        output.mkdir(parents=True)
        product = ROOT / "fpga/Plex_MiSTer"
        root, root_binding = self._selected_root(product, output)
        self._require_root_retention(root_binding)
        top, _ = self._selected_source(product, "sys/sys_top.v", output)
        store, _ = self._selected_source(product, "rtl/ddr_frame_store.sv", output)
        blocks = []
        for source, clock, reset in ((top, "clk_sys", "reset_req"),
                                     (top, "clk_audio", "mpx_audio_reset"),
                                     (store, "clk_ddr", "reset")):
            blocks.append(self._selected_process(source, clock, reset))
        blocks.append(self._one_selected(top, r"^([ \t]*)always @\(posedge clk_hdmi\) begin\n"
                                        r"\s*scaler_out_meta.*?^\1end\b", "local HDMI enable"))
        declarations = []
        for source, member in ((top, "mpx_audio_reset_sync"), (top, "scaler_reset_sync"),
                               (store, "reset_ddr_s1"), (top, "scaler_out_meta")):
            declarations.append(self._one_selected(source,
                r"^[ \t]*reg\b[^;\n]*\b" + member + r"\b[^;\n]*;", member + " declaration"))
        harness = r"""
`timescale 1ns/1ps
module routed_reset_tb;
reg clk_sys=0,clk_audio=0,clk_ddr=0,clk_hdmi=0;
reg sys_run=1,audio_run=1,ddr_run=1;
always #5.882 if(sys_run) clk_sys=~clk_sys;
always #20.341 if(audio_run) clk_audio=~clk_audio;
always #5.556 if(ddr_run) clk_ddr=~clk_ddr;
always #3.366 clk_hdmi=~clk_hdmi;
reg RESET=0,reset_req=0,scaler_out=0,pll_locked=1;
reg [127:0] status=0;
reg [1:0] buttons=0;
__ACTUAL_ROOT__
__ACTUAL_DECLARATIONS__
wire mpx_audio_reset=reset;
__ACTUAL_BLOCKS__
localparam realtime SYS_PERIOD_NS=11.764;
realtime minimum_root_width=1000.0;
task automatic drive_request(input bit value, input integer cause);
 case(cause)
  0: RESET=value;
  1: status[0]=value;
  2: buttons[1]=value;
  3: pll_locked=!value;
  default: $fatal(1,"unknown real root request input");
 endcase
endtask
task automatic root_pulse_phase(input realtime offset,
                                input realtime request_ns=0.002, input integer cause=0);
 realtime asserted_at, deasserted_at, width;
 begin
  @(posedge clk_sys); #(offset);
  drive_request(1,cause); asserted_at=$realtime;
  #(request_ns); drive_request(0,cause); deasserted_at=$realtime;
  @(posedge clk_sys); #0.001;
  assert(reset) else $fatal(1,"root released on first release edge");
  @(negedge reset); width=$realtime-asserted_at;
  assert(width >= request_ns+SYS_PERIOD_NS-0.001 &&
         width <= request_ns+2.0*SYS_PERIOD_NS+0.001)
   else $fatal(1,"root pulse differs from Wrequest + phase wait + one period");
  assert($realtime-deasserted_at >= SYS_PERIOD_NS-0.001)
   else $fatal(1,"root lost one complete release-edge interval");
  if(width<minimum_root_width) minimum_root_width=width;
  $display("ROOT_PULSE offset_ns=%0.3f width_ns=%0.3f release_edges=2 request_ns=%0.3f cause=%0d",offset,width,request_ns,cause);
  #200;
 end
endtask
initial begin
 #500;
 assert(!reset && !mpx_audio_reset_sync[1] && !reset_ddr_s2 && !scaler_reset_sync[1])
  else $fatal(1,"initial release");
 @(negedge clk_sys); sys_run=0;
 RESET=1; reset_req=1; #1;
 assert(reset && mpx_audio_reset_sync==3 && reset_ddr_s2 && scaler_reset_sync==3)
  else $fatal(1,"short asynchronous assertion");
 RESET=0; reset_req=0; #100;
 status[0]=1; #0.002; status[0]=0; #100;
 buttons[1]=1; #0.002; buttons[1]=0; #200;
 assert(reset && mpx_audio_reset_sync==3 && reset_ddr_s2 && scaler_reset_sync==3)
  else $fatal(1,"stopped SYS lost reset intent");
 sys_run=1; #500;
 assert(!reset && !mpx_audio_reset_sync[1] && !reset_ddr_s2 && !scaler_reset_sync[1])
  else $fatal(1,"SYS restart release");
 @(negedge clk_audio); audio_run=0;
 @(negedge clk_ddr); ddr_run=0;
 RESET=1; #1; RESET=0; #500;
 assert(!reset && mpx_audio_reset_sync==3 && reset_ddr_s2)
  else $fatal(1,"stopped destination lost reset intent");
 audio_run=1; ddr_run=1;
 @(posedge clk_audio); #0.1;
 assert(mpx_audio_reset_sync[1]) else $fatal(1,"audio released before two edges");
 @(posedge clk_audio); #0.1;
 assert(!mpx_audio_reset_sync[1]) else $fatal(1,"audio failed local release");
 @(negedge clk_hdmi); scaler_out=1;
 @(posedge clk_hdmi); #0.1;
 assert(!scaler_out_hdmi) else $fatal(1,"enable bypassed first stage");
 @(posedge clk_hdmi); #0.1;
 assert(scaler_out_hdmi) else $fatal(1,"HDMI enable failed second stage");
 root_pulse_phase(0.010);
 root_pulse_phase(2.900);
 root_pulse_phase(5.880);
 root_pulse_phase(8.800);
 root_pulse_phase(11.760);
 root_pulse_phase(SYS_PERIOD_NS-0.001,0.004,1);
 root_pulse_phase(0.010,SYS_PERIOD_NS+0.010,2);
 root_pulse_phase(SYS_PERIOD_NS*0.5,0.002,3);
 assert(minimum_root_width < SYS_PERIOD_NS+0.010)
  else $fatal(1,"phase sweep missed the one-period root-pulse corner");
 assert(minimum_root_width < 2.0*SYS_PERIOD_NS-1.0)
  else $fatal(1,"false two-full-period minimum not disproved");
 $display("PASS routed reset: short request, stopped SYS/audio/DDR, two-edge local release, local HDMI enable; root_min_ns=%0.3f (rounded simulation SYS period=%0.3f)",minimum_root_width,SYS_PERIOD_NS);
 $finish;
end
endmodule
"""
        sys_mhz = self._actual_sys_mhz()
        if sys_mhz == 20:
            harness = harness.replace("always #5.882 if(sys_run)", "always #25.000 if(sys_run)")
            harness = harness.replace("SYS_PERIOD_NS=11.764", "SYS_PERIOD_NS=50.000")
            for old, new in (("2.900", "12.500"), ("5.880", "25.000"),
                             ("8.800", "37.500"), ("11.760", "49.996")):
                harness = harness.replace(f"root_pulse_phase({old})", f"root_pulse_phase({new})")
        (output / "clock-binding.json").write_text(json.dumps({
            "qsf_sha256": hashlib.sha256((product / "Plex.qsf").read_bytes()).hexdigest(),
            "SYS_MHz": sys_mhz, "ideal_period_ns": 1000 / sys_mhz,
            "simulation_period_ns": 11.764 if sys_mhz == 85 else 50.0,
            "physical_pulse_guarantee": False,
        }, indent=2) + "\n")
        harness = harness.replace("__ACTUAL_ROOT__", root)
        harness = harness.replace("__ACTUAL_DECLARATIONS__", "\n".join(declarations))
        harness = harness.replace("__ACTUAL_BLOCKS__", "\n".join(blocks))
        self.assertIn("PASS routed reset:", self._run_reset_harness(output, "routed_reset_tb", harness))

    def test_frozen_sys20_raw_reset_negative(self):
        output = Path(os.environ["AUDIO_BOUNDARY_OUTPUT"]) / "frozen0209-raw-reset"
        output.mkdir(parents=True)
        fixture = ROOT / "tests/fixtures/coherent-reset-0209"
        meta = json.loads((fixture / "inputs.json").read_text())
        self.assertEqual(meta["source_sha256"], "0e2b1bd10bb2e6ae3e0833abb647296989977e10a5e7352c2f213e860168ada4")
        self.assertEqual(meta["input_sha256"], "212ed703b16c8c82c60ca59772133b831de0bba6fa35a16b9c00cffa9f06723d")
        self.assertEqual(hashlib.sha256(json.dumps(meta["input_files"], sort_keys=True).encode()).hexdigest(),
                         meta["input_sha256"])
        archive = fixture / "inputs.tar"
        self.assertEqual(hashlib.sha256(archive.read_bytes()).hexdigest(), meta["archive_sha256"])
        product = output / "source"
        product.mkdir()
        restored = {}
        with tarfile.open(archive) as source:
            for member in source:
                relative = PurePosixPath(member.name)
                self.assertTrue(member.isfile() and not relative.is_absolute() and ".." not in relative.parts)
                self.assertNotIn(member.name, restored)
                body = source.extractfile(member).read()
                restored[member.name] = hashlib.sha256(body).hexdigest()
                self.assertEqual(restored[member.name], meta["input_files"][member.name])
                path = product / member.name
                path.parent.mkdir(parents=True, exist_ok=True)
                with path.open("xb") as out:
                    out.write(body)
                path.chmod(0o444)
        self.assertEqual(restored, meta["input_files"])
        root, binding = self._selected_root(product, output)
        self.assertEqual(binding["SYS_MHz"], 20)
        self.assertEqual(binding["selected_root"], "raw")
        self.assertNotIn("reset_sys_sync", root)
        harness = r"""
`timescale 1ns/1ps
module raw_reset_0209_tb;
reg clk_sys=0,sys_run=1,RESET=0,pll_locked=1;
reg [127:0] status=0;
reg [1:0] buttons=0;
always #25 if(sys_run) clk_sys=~clk_sys;
__ACTUAL_ROOT__
initial begin
 #100; @(negedge clk_sys); sys_run=0;
 RESET=1; #0.002;
 assert(reset) else $fatal(1,"frozen selected raw reset failed assertion");
 RESET=0; #0.001;
 assert(!reset) else $fatal(1,"frozen raw reset unexpectedly retained stopped-clock request");
 status[0]=1; #0.002; status[0]=0; #0.001;
 assert(!reset) else $fatal(1,"frozen raw status reset unexpectedly retained");
 buttons[1]=1; #0.002; buttons[1]=0; #100;
 assert(!reset) else $fatal(1,"frozen raw button reset unexpectedly retained");
 $display("RAW_RESET_OBSERVED selected0209=1 stopped_SYS=1 retained_request=0");
 $finish;
end
endmodule
"""
        stdout = self._run_reset_harness(output, "raw_reset_0209_tb", harness.replace("__ACTUAL_ROOT__", root))
        self.assertIn("RAW_RESET_OBSERVED selected0209=1 stopped_SYS=1 retained_request=0", stdout)
        with self.assertRaisesRegex(AssertionError, "selected raw root cannot claim two-edge retention"):
            self._require_root_retention(binding)
        (output / "negative-control.json").write_text(json.dumps({
            "source_sha256": meta["source_sha256"], "input_sha256": meta["input_sha256"],
            "selected_root": binding["selected_root"], "two_edge_retention_claim_rejected": True,
            "compile_and_simulation_succeeded": True, "compile_failure_used_as_negative": False,
        }, indent=2) + "\n")

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
        if self._actual_sys_mhz() == 85:
            self.assertIn("-DPLEX_CLK_SYS_85=1", defines)
        else:
            self.assertNotIn("-DPLEX_CLK_SYS_85=1", defines)
        self.assertNotIn("-DPLEX_CLK_SYS_120=1", defines)
        self.assertNotIn("-DPLEX_CLK_SYS_180=1", defines)
        defines += [f"-DFPGA_VIDEO_BUILD_ID=32'h{source_id[:8]}"]
        report = {"source_sha256": source_id, "source_map": source_map,
                  "production_defines": defines, "modes": {}, "SYS_MHz": self._actual_sys_mhz(),
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
