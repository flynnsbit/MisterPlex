project_open Plex -revision Plex
create_timing_netlist -model slow
read_sdc
update_timing_netlist
set outdir "/work/.agent-work-out"

proc dump_intra {pat name n} {
  global outdir
  set c [get_clocks $pat]
  report_timing -setup -npaths $n -detail full_path \
    -from_clock $c -to_clock $c \
    -file "$outdir/${name}_intra_setup.txt" \
    -panel_name "$name intra setup"
}

dump_intra {*general[2]*divclk*} clk_ddr 10
dump_intra {*general[0]*divclk*} clk_sys 10
dump_intra {pll_hdmi*divclk} pll_hdmi 10
puts DONE_INTRA
project_close
