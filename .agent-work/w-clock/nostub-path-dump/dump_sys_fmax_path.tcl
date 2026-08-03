# Analysis-only. No fitter. Dump same-clock clk_sys Fmax-setting paths.
project_open Plex -revision Plex
create_timing_netlist -model slow
read_sdc
update_timing_netlist

set outdir "/work/nostub-path-dump"
file mkdir $outdir

set sys [get_clocks {*general[0]*divclk*}]
puts "SYS_CLOCKS=[get_collection_size $sys]"

# Same-clock paths that determine Fmax (from and to general[0])
report_timing -setup -npaths 15 -detail full_path \
  -from_clock $sys -to_clock $sys \
  -file "$outdir/clk_sys_sameclk_setup.txt" \
  -panel_name {clk_sys same-clock setup}

report_timing -setup -npaths 10 -detail full_path \
  -to_clock $sys \
  -file "$outdir/clk_sys_to_setup.txt" \
  -panel_name {clk_sys to-clock setup}

report_fmax_summary -file "$outdir/fmax_summary.txt"
report_clocks -file "$outdir/clocks.txt"
puts "DONE_NOSTUB_PATH_DUMP"
project_close
