# TimeQuest companion for scripts/l4_sta_onepass.py
# Run AFTER fit, with the project open in quartus_sta / GUI Tcl console:
#
#   quartus_sta -t scripts/l4_sta_dump_paths.tcl <project> <rev> <out_dir>
#
# Example:
#   cd fpga/Plex_MiSTer
#   quartus_sta -t ../../scripts/l4_sta_dump_paths.tcl Plex Plex /path/to/out
#
# Writes:
#   <out_dir>/clk_sys_sameclk_setup.txt
#   <out_dir>/clk_ddr_sameclk_setup.txt
#   <out_dir>/clk_ddr_to_sys_setup.txt
#   <out_dir>/ONEPASS_CMD.txt
#
# Then:
#   python3 scripts/l4_sta_onepass.py \
#     --sta-rpt <out_dir>/Plex.sta.rpt \
#     --path-dump <out_dir>/clk_sys_sameclk_setup.txt

if { $argc < 3 } {
    puts "Usage: quartus_sta -t l4_sta_dump_paths.tcl <project> <revision> <out_dir>"
    exit 1
}

set project  [lindex $argv 0]
set revision [lindex $argv 1]
set out_dir  [lindex $argv 2]

file mkdir $out_dir
project_open $project -revision $revision
create_timing_netlist -model slow
read_sdc
update_timing_netlist

set clk_sys "emu|pll|pll_inst|altera_pll_i|general\[0\].gpll~PLL_OUTPUT_COUNTER|divclk"
set clk_ddr "emu|pll|pll_inst|altera_pll_i|general\[2\].gpll~PLL_OUTPUT_COUNTER|divclk"

report_timing -setup -npaths 20 -detail full_path \
    -from_clock [get_clocks $clk_sys] \
    -to_clock   [get_clocks $clk_sys] \
    -file [file join $out_dir clk_sys_sameclk_setup.txt]

report_timing -setup -npaths 20 -detail full_path \
    -from_clock [get_clocks $clk_ddr] \
    -to_clock   [get_clocks $clk_ddr] \
    -file [file join $out_dir clk_ddr_sameclk_setup.txt]

report_timing -setup -npaths 20 -detail full_path \
    -from_clock [get_clocks $clk_ddr] \
    -to_clock   [get_clocks $clk_sys] \
    -file [file join $out_dir clk_ddr_to_sys_setup.txt]

# Also copy/export Fmax panel if sta already written beside out_dir — parent
# normally keeps Plex.sta.rpt from the fit; we only emit the path dumps here.

set cmd_path [file join $out_dir ONEPASS_CMD.txt]
set sta_guess [file join $out_dir Plex.sta.rpt]
set fd [open $cmd_path w]
puts $fd "python3 scripts/l4_sta_onepass.py \\"
puts $fd "  --sta-rpt $sta_guess \\"
puts $fd "  --path-dump [file join $out_dir clk_sys_sameclk_setup.txt] \\"
puts $fd "  --clk-sys-min-mhz 20.0 \\"
puts $fd "  --clk-ddr-min-mhz 90.0"
close $fd

puts "l4_sta_dump_paths: wrote path dumps under $out_dir"
project_close
