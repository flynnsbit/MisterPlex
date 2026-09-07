# Run the production Tcl in an empty child interpreter. No real Quartus API
# is imported into that interpreter, even when quartus_sh hosts this fixture.
if {![info exists mpx_mock_child]} {
    set child [interp create]
    $child eval {set mpx_mock_child 1}
    $child eval [list set fixture_args $quartus(args)]
    set code [catch {$child eval [list source [info script]]} message options]
    interp delete $child
    if {!$code || ![dict exists $options -errorcode] ||
        [lindex [dict get $options -errorcode] 0] ne "MOCK_REPORTER_EXIT"} {
        puts stderr "Unexpected fixture result: $message"
        if {$code} {puts stderr [dict get $options -errorinfo]}
        exit 2
    }
    exit [lindex [dict get $options -errorcode] 1]
}

package provide ::quartus::project 1.0
package provide ::quartus::sta 1.0
lassign $fixture_args reporter project output variant
cd $project
set quartus(args) [list $output]
set collections {}
set collection_id 0
set object_info [dict create \
    decoder [dict create type reg name {emu|spath|mb_ctrl|counter[0]}] \
    led [dict create type port name out_led] \
    config [dict create type reg name config] \
    sys [dict create type clk name clk_sys period 50.000] \
    ddr [dict create type clk name ddr90 period 11.111] \
    unused [dict create type clk name unused_clock period 20.000]]
set setter_calls {}

proc collection {objects} {
    set handle "mock_collection_[incr ::collection_id]"
    dict set ::collections $handle $objects
    return $handle
}
proc get_collection_size {handle} {
    if {![dict exists $::collections $handle]} {error "Not an SDK collection"}
    return [llength [dict get $::collections $handle]]
}
proc foreach_in_collection {variable handle body} {
    upvar 1 $variable object
    foreach object [dict get $::collections $handle] {uplevel 1 $body}
}
proc select_objects {patterns candidates} {
    set result {}
    foreach candidate $candidates {
        foreach pattern $patterns {
            if {[string match $pattern [dict get $::object_info $candidate name]]} {
                lappend result $candidate
                break
            }
        }
    }
    return [collection $result]
}
proc get_keepers {patterns} {select_objects $patterns {decoder led config}}
proc get_clocks {patterns} {select_objects $patterns {sys ddr unused}}
proc get_object_info {option object} {
    return [dict get $::object_info $object [string range $option 1 end]]
}
proc get_clock_info {option object} {get_object_info $option $object}
proc get_available_operating_conditions {} {collection {condition0 condition1 condition2 condition3}}
proc get_default_sdc_file_names {} {return {Plex.sdc}}
proc project_open {args} {
    if {$args ne {Plex -revision Plex}} {error "Unexpected project-open arguments"}
}
proc create_timing_netlist {} {}
proc update_timing_netlist {} {}
proc delete_timing_netlist {} {}
proc project_close {} {}
proc set_operating_conditions {condition} {}
proc read_sdc {} {source Plex.sdc}
namespace eval mock_sdc {
    namespace export set_*
    proc invoke {kind args} {
        lappend ::setter_calls [list $kind {*}$args]
        if {$::variant eq "setter-error"} {error "Injected original setter failure"}
        return "original setter result"
    }
    proc set_false_path {args} {invoke set_false_path {*}$args}
    proc set_clock_groups {args} {invoke set_clock_groups {*}$args}
    proc set_max_delay {args} {invoke set_max_delay {*}$args}
    proc set_min_delay {args} {invoke set_min_delay {*}$args}
    proc set_multicycle_path {args} {invoke set_multicycle_path {*}$args}
}
namespace import ::mock_sdc::*

proc write_report {path text} {
    set channel [open $path w]
    puts $channel $text
    close $channel
}
proc option_value {args option} {
    set position [lsearch -exact $args $option]
    if {$position < 0} {error "Missing mock API option $option"}
    return [lindex $args [expr {$position + 1}]]
}
proc report_timing {args} {
    set check [expr {"-setup" in $args ? "setup" : "hold"}]
    set count [option_value $args -npaths]
    foreach direction {-from -to} {
        if {$direction in $args} {
            set handle [option_value $args $direction]
            if {[dict get $::collections $handle] ne {decoder} || $count != 1} {
                error "Scoped report did not use the actual decoder collection/minimum"
            }
        }
    }
    set text "Report Timing: Found $count $check paths (0 violated). Worst case slack is 0.250"
    if {[option_value $args -to_clock] eq "unused"} {
        set text "-----------------\n; Report Timing ;\n-----------------\nNothing to report."
    }
    write_report [option_value $args -file] $text
}
proc report_sdc {args} {write_report [option_value $args -file] "Mock SDC audit, not a netlist."}
proc write_sdc {option path} {
    if {$option ne "-expand"} {error "Unexpected write_sdc option"}
    write_report $path "# Mock macro expansion, not wildcard expansion."
}
proc report_exceptions {args} {
    if {"-report_clock_groups" in $args || [option_value $args -npaths] != 1} {
        error "Unsupported/changed exception reporting request"
    }
    write_report [option_value $args -file] "Mock exception audit, not a netlist."
}
proc post_message {args} {puts stderr $args}
proc exit {code} {
    if {$code == 0 && [lindex $::setter_calls 0] ne {set_false_path -to out_led}} {
        error "Observer changed the original setter arguments"
    }
    return -code error -errorcode [list MOCK_REPORTER_EXIT $code] "Reporter exit $code"
}
source $reporter
