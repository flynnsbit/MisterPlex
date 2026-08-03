project_open Plex -revision Plex
create_timing_netlist -model slow
read_sdc
update_timing_netlist
set outdir "/work/nostub-path-dump"
file mkdir $outdir
# Exact product clk_sys only (not pll_audio general[0])
set sys [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
puts "SYS_SIZE=[get_collection_size $sys]"
foreach_in_collection c $sys { puts "CLK=[get_clock_info -name $c]" }

report_timing -setup -npaths 20 -detail full_path \
  -from_clock $sys -to_clock $sys \
  -file "$outdir/clk_sys_emu_sameclk.txt" \
  -panel_name {emu clk_sys same-clock}

# Also list all clocks
report_clocks -file "$outdir/clocks.txt"
puts DONE
project_close
