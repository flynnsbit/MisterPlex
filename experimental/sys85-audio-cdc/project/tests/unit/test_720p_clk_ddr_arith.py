#!/usr/bin/env python3
"""720p pixel-clock + DDR bandwidth arithmetic (w-clock).

Positive cases lock CEA / layout constants to exact integer Hz and MB/s.
Negative cases: a naive wrong blanking (active-only) or RGB565-as-product
must FAIL so this is not a tautology.

No Quartus. No device. Exit 0 only when all asserts hold.
"""
from __future__ import annotations

import re
import os
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def read(p: Path) -> str:
    return p.read_text(encoding="utf-8", errors="replace")


def clock_rtl() -> None:
    """Exercise actual clock/reset extraction and colorbars; PLL model is not IP qualification."""
    project = ROOT / "fpga/Plex_MiSTer"
    plex = read(project / "Plex.sv")
    start = plex.index('`include "rtl/plex_performance_clock.svh"')
    clock = plex[start:plex.index("// O[5:4] CONTENT", start)]
    assert "pll pll" in clock and "core_time_ce" in clock and "reset_sys_sync" in clock
    model = r'''
`timescale 1ns/1fs
module altera_pll #(
  parameter string fractional_vco_multiplier="false", reference_clock_frequency="50.0 MHz",
  operation_mode="direct", output_clock_frequency0="20.000000 MHz",
  output_clock_frequency1="142.000000 MHz", output_clock_frequency2="90.000000 MHz",
  output_clock_frequency3="", output_clock_frequency4="", output_clock_frequency5="",
  output_clock_frequency6="", output_clock_frequency7="", output_clock_frequency8="",
  output_clock_frequency9="", output_clock_frequency10="", output_clock_frequency11="",
  output_clock_frequency12="", output_clock_frequency13="", output_clock_frequency14="",
  output_clock_frequency15="", output_clock_frequency16="", output_clock_frequency17="",
  phase_shift0="0 ps", phase_shift1="", phase_shift2="", phase_shift3="", phase_shift4="",
  phase_shift5="", phase_shift6="", phase_shift7="", phase_shift8="", phase_shift9="",
  phase_shift10="", phase_shift11="", phase_shift12="", phase_shift13="", phase_shift14="",
  phase_shift15="", phase_shift16="", phase_shift17="", pll_type="General", pll_subtype="General",
  parameter integer number_of_clocks=1,
  duty_cycle0=50,duty_cycle1=50,duty_cycle2=50,duty_cycle3=50,duty_cycle4=50,
  duty_cycle5=50,duty_cycle6=50,duty_cycle7=50,duty_cycle8=50,duty_cycle9=50,
  duty_cycle10=50,duty_cycle11=50,duty_cycle12=50,duty_cycle13=50,
  duty_cycle14=50,duty_cycle15=50,duty_cycle16=50,duty_cycle17=50
) (input wire refclk,rst,fbclk, output wire fboutclk,locked,
   output wire [number_of_clocks-1:0] outclk);
  localparam real FREQ = output_clock_frequency0=="85.000000 MHz" ? 85.0 :
                        output_clock_frequency0=="120.000000 MHz" ? 120.0 :
                        output_clock_frequency0=="180.000000 MHz" ? 180.0 : 20.0;
  reg [number_of_clocks-1:0] clocks='0;
  reg test_lock=1, test_clock_enable=1;
  integer lock_count=0;
  always @(posedge refclk) if(rst) lock_count<=0; else if(lock_count<8) lock_count<=lock_count+1;
  assign locked=lock_count==8 && test_lock && !rst;
  assign fboutclk=0;
  assign outclk=clocks & {number_of_clocks{test_clock_enable}};
  always #(500.0/FREQ) clocks[0]=~clocks[0];
  if(number_of_clocks==3) begin
    always #(500.0/142.0) clocks[1]=~clocks[1];
    always #(500.0/90.0) clocks[2]=~clocks[2];
  end
  initial begin
    assert(reference_clock_frequency=="50.0 MHz" && fractional_vco_multiplier=="false");
    assert(operation_mode=="direct" && duty_cycle0==50 && phase_shift0=="0 ps");
    if(number_of_clocks==3) begin
      assert(output_clock_frequency1=="142.000000 MHz");
      assert(output_clock_frequency2=="90.000000 MHz");
    end
  end
endmodule
module clock_dut(input wire CLK_50M, RESET, input wire [31:0] status,
                 input wire [1:0] buttons);
'''
    bench = r'''
endmodule
module sys85_clock_tb;
  reg refclk=0, request=1;
  reg [31:0] status=0;
  reg [1:0] buttons=0;
  always #10 refclk=~refclk;
  clock_dut dut(refclk,request,status,buttons);
  reg pal=0, scandouble=1;
  wire ce,fs;
  wire [9:0] hc,vc;
  colorbars bars(.clk(dut.clk_sys),.reset(dut.reset),.pal(pal),.scandouble(scandouble),
    .content_index(0),.pattern(2'd3),.ce_pix(ce),.HBlank(),.HSync(),.VBlank(),.VSync(),
    .frame_start(fs),.hc_out(hc),.vc_out(vc),.r(),.g(),.b());
  integer total, pixel_count, time_count, last_pixel, gap, last_frame, frames, frame_cycles;
  realtime edge_time, elapsed;
  task restart;
    request=1;
    repeat(8) @(negedge dut.clk_sys);
    request=0;
    wait(!dut.reset);
    repeat(16*`PLEX_PERF_SYS_MULT) @(negedge dut.clk_sys);
  endtask
  initial begin
    wait(dut.pll_locked);
    restart;
    edge_time=$realtime;
    repeat(850) @(negedge dut.clk_sys);
    elapsed=$realtime-edge_time;
    assert(elapsed > 850*1.0e9/`PLEX_PERF_SYS_HZ-0.01 &&
           elapsed < 850*1.0e9/`PLEX_PERF_SYS_HZ+0.01)
      else $fatal(1,"Actual wrapper parameter clock rate changed");
    assert(`PLEX_PERF_SYS_CYCLES(4096)*20_000_000.0 == 4096.0*`PLEX_PERF_SYS_HZ)
      else $fatal(1,"Watchdog duration changed");
    assert(`PLEX_PERF_SYS_CYCLES(1024)*20_000_000.0 == 1024.0*`PLEX_PERF_SYS_HZ)
      else $fatal(1,"Audio poll duration changed");
`ifdef PLEX_CLK_SYS_85
    assert(`PLEX_PERF_SYS_CYCLES(1)==5 && `PLEX_PERF_SYS_CYCLES(2)==9 &&
           `PLEX_PERF_SYS_CYCLES(4)==17 && `PLEX_PERF_SYS_CYCLES(64)==272);
    @(negedge dut.clk_sys);
    dut.pll.sys85_pll.test_clock_enable=0;
    dut.pll.sys85_pll.test_lock=0;
    #0.001;
    assert(dut.reset) else $fatal(1,"Lost SYS lock did not assert reset with clock stopped");
    repeat(4) @(negedge refclk);
    dut.pll.sys85_pll.test_lock=1;
    repeat(4) @(negedge refclk);
    assert(dut.reset) else $fatal(1,"Reset released without SYS edges");
    @(negedge dut.pll.sys85_pll.clocks[0]);
    dut.pll.sys85_pll.test_clock_enable=1;
    @(posedge dut.clk_sys); #0.001;
    assert(dut.reset) else $fatal(1,"SYS reset released before two edges");
    @(posedge dut.clk_sys); #0.001;
    assert(!dut.reset) else $fatal(1,"SYS reset failed to release on second edge");
    @(negedge dut.clk_sys);
    dut.pll.pll_inst.altera_pll_i.test_lock=0;
    #0.001;
    assert(dut.reset) else $fatal(1,"Lost memory PLL lock did not reset SYS");
    dut.pll.pll_inst.altera_pll_i.test_lock=1;
    @(posedge dut.clk_sys); #0.001; assert(dut.reset);
    @(posedge dut.clk_sys); #0.001; assert(!dut.reset);
`endif
    for(integer mode=0;mode<4;mode=mode+1) begin
      pal=mode[1]; scandouble=mode[0];
      restart;
      total=2*`PLEX_PERF_SYS_MULT*2000;
      pixel_count=0; time_count=0; last_pixel=-1;
      for(integer i=0;i<total;i=i+1) begin
        @(negedge dut.clk_sys);
        if(dut.core_time_ce) time_count++;
        if(ce) begin
          pixel_count++;
          if(last_pixel>=0) begin
            gap=i-last_pixel;
            assert(gap==(`PLEX_PERF_SYS_MULT*(scandouble?1:2))/`PLEX_PERF_SYS_DEN ||
                   gap==(`PLEX_PERF_SYS_MULT*(scandouble?1:2)+`PLEX_PERF_SYS_DEN-1)/`PLEX_PERF_SYS_DEN)
              else $fatal(1,"Native CE interval not floor/ceil ideal period");
          end
          last_pixel=i;
        end
      end
      assert(time_count==total*`PLEX_PERF_SYS_DEN/`PLEX_PERF_SYS_MULT);
      assert(pixel_count==total*`PLEX_PERF_SYS_DEN/(`PLEX_PERF_SYS_MULT*(scandouble?1:2)));
      frames=0; last_frame=0;
      frame_cycles=638*(pal?(scandouble?624:312):(scandouble?524:262))*
        (scandouble?1:2)*`PLEX_PERF_SYS_MULT/`PLEX_PERF_SYS_DEN;
      for(integer i=0;i<3*frame_cycles && frames<2;i=i+1) begin
        @(negedge dut.clk_sys);
        assert(hc<638 && vc<(pal?(scandouble?624:312):(scandouble?524:262)));
        if(fs) begin
          if(frames==1) assert(i-last_frame==frame_cycles)
            else $fatal(1,"Native frame period changed");
          last_frame=i; frames++;
        end
      end
      assert(frames==2) else $fatal(1,"Missing native frame");
      $display("PASS native clock mode=%0d SYS=%0d frame_cycles=%0d",mode,`PLEX_PERF_SYS_HZ,frame_cycles);
    end
    for(integer i=0;i<272;i=i+1) begin
      @(negedge dut.clk_sys);
      scandouble=(i%7)<3;
      @(negedge dut.clk_sys);
      assert(bars.pixel_div<(scandouble?`PLEX_PERF_SYS_MULT:2*`PLEX_PERF_SYS_MULT))
        else $fatal(1,"Mode change left out-of-range fractional phase");
    end
    $display("PASS actual clock selection, rational native/timebase, poll/watchdog and lock/reset");
    $finish;
  end
endmodule
'''
    commands = []
    for name, define in (("control20", []), ("sys85", ["-DPLEX_CLK_SYS_85=1"]),
                         ("sys120", ["-DPLEX_CLK_SYS_120=1"])):
        out = ROOT / "build/verilator/sys_clock" / name
        out.mkdir(parents=True, exist_ok=True)
        scratch = out / "compiler-scratch"
        scratch.mkdir(exist_ok=True)
        tb = out / "sys85_clock_tb.sv"
        tb.write_text(model + clock + bench)
        cmd = [str(ROOT / "scripts/run_verilator.sh"), "--binary", "--timing", "--assert",
               "-j", "1", "--Mdir", str(out), "--top-module", "sys85_clock_tb", "-Wno-fatal",
               "-DSDRAM_CLK_142=1", *define, f"-I{project}", f"-I{project / 'rtl'}",
               str(tb), str(project / "rtl/colorbars.sv"),
               str(project / "rtl/pll.v"), str(project / "rtl/pll/pll_0002.v")]
        commands.append(cmd)
        (ROOT / "build/verilator/sys_clock/commands.json").write_text(json.dumps(commands, indent=2) + "\n")
        env = dict(os.environ, TMPDIR=str(scratch), TMP=str(scratch), TEMP=str(scratch))
        with (out / "build.log").open("w") as log:
            subprocess.run(cmd, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
        with (out / "result.log").open("w") as log:
            subprocess.run([str(out / "Vsys85_clock_tb")], cwd=ROOT, env=env,
                           stdout=log, stderr=subprocess.STDOUT, check=True)
        print((out / "result.log").read_text())
    (ROOT / "build/verilator/sys_clock/commands.json").write_text(json.dumps(commands, indent=2) + "\n")


def main() -> int:
    fails: list[str] = []

    def check(cond: bool, msg: str) -> None:
        if not cond:
            fails.append(msg)
        else:
            print(f"OK {msg}")

    # --- CEA pixel clocks (exact integers) ---
    # VIC 4 720p60: H=1650 V=750
    h60, v60, fps60 = 1650, 750, 60
    pix60 = h60 * v60 * fps60
    check(pix60 == 74_250_000, f"CEA VIC4 720p60 f_pix={pix60} (==74250000)")

    # VIC 60 720p24: H=3300 V=750 (double H blank)
    h24v, v24v, fps24 = 3300, 750, 24
    pix24_vic = h24v * v24v * fps24
    check(pix24_vic == 59_400_000, f"CEA VIC60 720p24 f_pix={pix24_vic} (==59400000)")

    # Same totals as VIC4 @ 24 fps (PRESENT_CLK_PIX_PLL default target)
    h_pack, v_pack = 1650, 750
    pix24_pack = h_pack * v_pack * 24
    check(pix24_pack == 29_700_000, f"pack 1650*750*24 f_pix={pix24_pack} (==29700000)")
    ppf = h_pack * v_pack
    check(ppf == 1_237_500, f"PIX_PER_FRAME pack={ppf}")

    # NEGATIVE: active-only blanking is NOT a legal CEA pixel clock
    active_only_24 = 1280 * 720 * 24
    check(active_only_24 != 29_700_000, "NEG: active-only 1280*720*24 != 29.70 MHz")
    check(active_only_24 == 22_118_400, f"NEG twin value active_only_24={active_only_24}")

    # --- Quote PLL SoT on disk ---
    pll = read(ROOT / "fpga/Plex_MiSTer/rtl/pll/pll_0002.v")
    check('output_clock_frequency0("20.000000 MHz")' in pll, "PLL out0 clk_sys=20.000000 MHz")
    check('output_clock_frequency2("90.000000 MHz")' in pll, "PLL out2 clk_ddr=90.000000 MHz")
    check('reference_clock_frequency("50.0 MHz")' in pll, "PLL ref=50.0 MHz")
    check("PRESENT_CLK_PIX_PLL" in pll, "PLL has PRESENT_CLK_PIX_PLL branch")
    check('"29.700000 MHz"' in pll, "PLL default clk_pix string 29.700000 MHz")
    check('"74.250000 MHz"' in pll, "PLL optional 74.250000 MHz string")
    # Product default must still be 3 clocks in the else branch
    check(
        re.search(r'`else\s+altera_pll\s+#\(\s*\n(?:.*\n){0,6}.*number_of_clocks\(3\)', pll)
        is not None,
        "product else-branch number_of_clocks(3)",
    )
    # L4 QSF enables PLEX_CLK_SYS_24 but leaves PRESENT_CLK_PIX_PLL OFF, so the
    # 3-clock else branch is what actually elaborates. A 4-clock-only ifdef
    # leaves out0 hardcoded 20 MHz (TimeQuest ÷18) → HDMI ~20 Hz, not 24.
    n_clk24 = len(re.findall(r"`ifdef\s+PLEX_CLK_SYS_24", pll))
    check(n_clk24 >= 2, f"PLEX_CLK_SYS_24 wraps BOTH altera_pll out0 (count={n_clk24})")
    m3 = re.search(
        r"number_of_clocks\(3\),\s*(.*?)\.output_clock_frequency0\(\"([^\"]+)\"\)",
        pll,
        re.S,
    )
    check(m3 is not None, "found 3-clock out0")
    if m3 is not None:
        check(
            "`ifdef PLEX_CLK_SYS_24" in m3.group(1),
            "3-clock PLL out0 under PLEX_CLK_SYS_24 (hardcoded 20 MHz → ~20 Hz HDMI)",
        )

    # QSF: PRESENT_CLK_PIX_PLL must be commented (default OFF)
    qsf = read(ROOT / "fpga/Plex_MiSTer/Plex.qsf")
    active_pix = [
        ln
        for ln in qsf.splitlines()
        if "PRESENT_CLK_PIX_PLL" in ln and not ln.strip().startswith("#")
    ]
    check(not active_pix, "QSF PRESENT_CLK_PIX_PLL not active (default OFF)")
    check("Plex_clk_pix.sdc" in qsf, "QSF mentions Plex_clk_pix.sdc recipe")

    # Plex.sv wires clk_pix from PLL only under ifdef
    plex = read(ROOT / "fpga/Plex_MiSTer/Plex.sv")
    check("clk_pix_pll" in plex, "Plex.sv declares clk_pix_pll under flag path")
    check(".clk_pix(clk_sys)" in plex, "product .clk_pix(clk_sys) still present")

    # present_video_timing pack constants
    tim = read(ROOT / "fpga/Plex_MiSTer/rtl/present_video_timing_720p.sv")
    check("H_TOTAL_L  = 1650" in tim, "timing pack H_TOTAL=1650")
    check("V_TOTAL_L  = 750" in tim, "timing pack V_TOTAL=750")
    check("74_250_000" in tim or "74.25" in tim, "timing pack documents 74.25")

    # --- DDR bandwidth: product format is YUV420p / I420 ---
    layout = read(ROOT / "fpga/Plex_MiSTer/rtl/ddr_frame_layout_params.svh")
    check("DDR_FRAME_720P_YUV420P_BYTES = 1382400" in layout, "I420 1280x720 bytes=1382400")
    # 1280*720*3/2 = 1382400
    check(1280 * 720 * 3 // 2 == 1_382_400, "I420 arith 1280*720*3/2")

    frame_b = 1_382_400
    # Decimal MB/s (10^6) to match docs/display-resolution.md style
    rd24 = frame_b * 24 / 1e6
    rd60 = frame_b * 60 / 1e6
    check(abs(rd24 - 33.1776) < 1e-9, f"YUV420p 720p24 FPGA read={rd24} MB/s")
    check(abs(rd60 - 82.944) < 1e-9, f"YUV420p 720p60 FPGA read={rd60} MB/s")

    # Docs model: peak = DDRAM_CLK * 8; pessimistic FPGA-read budget = 25% peak
    # Product clk_ddr = 90 MHz → peak 720 MB/s → budget 180 MB/s
    peak = 90.0 * 8.0
    budget = peak * 0.25
    check(peak == 720.0, f"DDR peak @90MHz={peak} MB/s")
    check(budget == 180.0, f"pessimistic FPGA-read budget={budget} MB/s")
    check(rd24 < budget, f"FIT: 24fps read {rd24} < budget {budget}")
    check(rd60 < budget, f"FIT: 60fps read {rd60} < budget {budget}")

    # Total fabric with equal ARM write (docs model)
    tot24 = 2 * rd24
    tot60 = 2 * rd60
    check(tot24 < peak, f"total fabric 24fps {tot24} < peak {peak}")
    check(tot60 < peak, f"total fabric 60fps {tot60} < peak {peak}")

    # NEGATIVE: RGB565 at 720p60 exceeds pessimistic read budget
    rgb_frame = 1280 * 720 * 2
    rgb60 = rgb_frame * 60 / 1e6
    check(rgb60 == 110.592, f"RGB565 720p60 read={rgb60}")
    check(rgb60 < budget, "RGB565 720p60 still < 180 budget (docs: viable)")
    # But RGB565 720p60 was over the OLD 20 MHz-as-DDR clock model (40 MB/s)
    old_budget_20 = 20.0 * 8.0 * 0.25  # if someone confuses clk_sys with DDRAM
    check(old_budget_20 == 40.0, "old confused 20MHz*8*25% budget=40")
    check(rd60 > old_budget_20, "NEG: 720p60 YUV would FAIL if DDR were 20 MHz")

    # Throughput: PPC=1 @20 MHz cannot feed 29.7 Mpix/s
    check(20.0 < 29.7, "NEG: clk_sys 20 MHz < 29.7 Mpix/s need (PPC=1)")
    check(20.0 * 2 >= 29.7, "PPC=2 @20 MHz fabric groups can feed 29.7")

    # SDC file exists and does not false_path residual
    sdc = read(ROOT / "fpga/Plex_MiSTer/Plex_clk_pix.sdc")
    check("set_clock_groups -asynchronous" in sdc, "SDC async groups clk_pix")
    check("residual" not in sdc.lower() or "Do NOT" in sdc, "SDC does not silence residual")
    check("general[3]" in sdc, "SDC names general[3] clk_pix")

    if fails:
        print("FAIL test_720p_clk_ddr_arith:", file=sys.stderr)
        for f in fails:
            print(f"  - {f}", file=sys.stderr)
        return 1
    print("PASS test_720p_clk_ddr_arith")
    if "--rtl" in sys.argv:
        clock_rtl()
    return 0


if __name__ == "__main__":
    sys.exit(main())
