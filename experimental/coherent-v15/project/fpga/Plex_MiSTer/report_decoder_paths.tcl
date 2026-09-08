package require ::quartus::project
package require ::quartus::sta

# Run only after the parent-owned fit, from that fit's project directory.
# No constraints or clock exceptions are created by this reporter.
project_open Plex -revision Plex
create_timing_netlist
read_sdc
update_timing_netlist
file mkdir timing-decoder

set decoder_regs [get_registers {*|mb_ctrl|*}]
set cavlc_regs [get_registers {*|u_cavlc|*}]
if {[get_collection_size $decoder_regs] == 0 ||
    [get_collection_size $cavlc_regs] == 0} {
    error "Decoder hierarchy absent; refusing an empty timing report"
}
set index 0
foreach_in_collection model [get_available_operating_conditions] {
    set_operating_conditions $model
    update_timing_netlist
    set stem "timing-decoder/corner-$index"
    set handle [open "$stem.model.txt" w]
    puts $handle $model
    close $handle
    report_clocks -file "$stem.clocks.rpt"
    report_clock_fmax_summary -file "$stem.fmax.rpt"
    foreach check {setup hold} {
        report_timing -$check -from $decoder_regs -to $decoder_regs \
            -npaths 100 -nworst 10 -detail full_path -file "$stem.decoder.$check.rpt"
        report_timing -$check -from $cavlc_regs -to $cavlc_regs \
            -npaths 100 -nworst 10 -detail full_path -file "$stem.cavlc.$check.rpt"
        report_timing -$check -npaths 100 -nworst 10 -detail full_path \
            -file "$stem.global.$check.rpt"
    }
    incr index
}
delete_timing_netlist
project_close
