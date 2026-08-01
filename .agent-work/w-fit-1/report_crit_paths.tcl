# Analysis-only: dump worst setup paths for clk_ddr / clk_sys / pll_hdmi
# Does not run fitter.
project_open Plex -revision Plex
create_timing_netlist -model slow
read_sdc
update_timing_netlist

set outdir "/work/.agent-work-out"
file mkdir $outdir

proc dump_clock_paths {clk_pat panel fname n} {
  global outdir
  set clks [get_clocks $clk_pat]
  if {[get_collection_size $clks] == 0} {
    set fh [open "$outdir/$fname" w]
    puts $fh "NO_CLOCKS_MATCH $clk_pat"
    close $fh
    return
  }
  report_timing -setup -npaths $n -detail full_path \
    -to_clock $clks \
    -file "$outdir/$fname" \
    -panel_name $panel
}

dump_clock_paths {*general[2]*divclk*} {clk_ddr worst setup} clk_ddr_worst_setup.txt 10
dump_clock_paths {*general[0]*divclk*} {clk_sys worst setup} clk_sys_worst_setup.txt 10
dump_clock_paths {pll_hdmi*divclk} {pll_hdmi worst setup} pll_hdmi_worst_setup.txt 10

# Also top 10 overall
report_timing -setup -npaths 15 -detail full_path \
  -file "$outdir/overall_worst_setup.txt" \
  -panel_name {overall worst setup}

report_clocks -file "$outdir/clocks.txt"
puts "DONE_CRIT_PATHS"
project_close
