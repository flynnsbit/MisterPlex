# Run the production Tcl in an empty child interpreter. No real Quartus API
# is imported into that interpreter, even when quartus_sh hosts this fixture.
if {![info exists mpx_mock_child]} {
    set child [interp create]
    $child eval {set mpx_mock_child 1}
    if {[info exists quartus(args)]} {
        $child eval [list set fixture_args $quartus(args)]
    } else {
        $child eval [list set fixture_args $argv]
    }
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
set unobserved [string match "unobserved:*" $variant]
if {$unobserved} {set variant [string range $variant 11 end]}
cd $project
set quartus(args) [list $output]
set collections {}
set collection_id 0
set object_info [dict create \
    decoder [dict create type reg name {emu|spath|mb_ctrl|counter[0]}] \
    led [dict create type port name out_led] \
    config [dict create type reg name config] \
    sync [dict create type reg name {altera_std_synchronizer:test|din_s1}] \
    sys [dict create type clk name clk_sys period 50.000] \
    ddr [dict create type clk name ddr90 period 11.111] \
    unused [dict create type clk name unused_clock period 20.000]]
set setter_calls {}
set observations {}
set hdl_statement {set_false_path -to [get_keepers {*altera_std_synchronizer:*|din_s1}]}
if {$variant eq "hdl-decoder"} {
    dict set object_info sync name {emu|spath|mb_ctrl|altera_std_synchronizer:test|din_s1}
}

proc collection {objects} {
    set handle "_col[incr ::collection_id]"
    dict set ::collections $handle $objects
    return $handle
}
proc get_collection_size {handle} {
    if {![dict exists $::collections $handle]} {error "Not an SDK collection"}
    if {$::variant eq "collection-size-error"} {error "Injected collection resolution failure"}
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
proc get_keepers {patterns} {
    if {$::variant eq "begin-query-error" && [info exists ::mpx_timing::callback_depth] &&
        $::mpx_timing::callback_depth == 0} {error "Injected initial keeper inventory failure"}
    if {$::variant eq "keeper-query-error" && [info exists ::mpx_timing::callback_depth] &&
        $::mpx_timing::callback_depth > 0} {error "Injected keeper query failure"}
    select_objects $patterns {decoder led config sync}
}
proc get_clocks {patterns} {select_objects $patterns {sys ddr unused}}
proc get_object_info {option object} {
    if {$::variant eq "object-info-error" && [info exists ::mpx_timing::callback_depth] &&
        $::mpx_timing::callback_depth > 0} {error "Injected object-info failure"}
    return [dict get $::object_info $object [string range $option 1 end]]
}
proc get_clock_info {option object} {get_object_info $option $object}
proc get_available_operating_conditions {} {collection {condition0 condition1 condition2 condition3}}
proc get_default_sdc_file_names {} {
    if {$::variant eq "source-inventory-error"} {error "Injected SDC source inventory failure"}
    return {Plex.sdc}
}
proc project_open {args} {
    if {$args ne {Plex -revision Plex}} {error "Unexpected project-open arguments"}
    if {$::variant in {hdl-enter-error hdl-no-frame}} {
        rename ::mpx_timing::source_location ::mpx_timing::original_source_location
        proc ::mpx_timing::source_location {kind} {
            if {$::variant eq "hdl-no-frame"} {
                error "Timing exception has neither an SDC source nor an original Tcl frame"
            }
            error "Timing exception has no attributable SDC source"
        }
    }
    if {$::variant eq "origin-resolution-error"} {rename ::set_max_delay {}}
    if {$::variant in {status-write-error begin-write-error}} {
        rename ::open ::original_open
        set ::status_writes 0
        proc ::open {path args} {
            if {[file tail $path] eq "observer.summary" &&
                ([incr ::status_writes] > 1 || $::variant eq "begin-write-error")} {
                error "Injected observer status write failure"
            }
            return [::original_open $path {*}$args]
        }
    }
    if {$::variant eq "reentrant-observer"} {
        rename ::mpx_timing::resolve_argument ::mpx_timing::original_resolve_argument
        proc ::mpx_timing::resolve_argument {option value} {
            set_min_delay -to out_led 0.0
            return [original_resolve_argument $option $value]
        }
    }
}
proc create_timing_netlist {} {}
proc update_timing_netlist {} {}
proc delete_timing_netlist {} {}
proc project_close {} {}
proc set_operating_conditions {condition} {}
proc record_script {label script} {
    set ::errorInfo native-error-info-sentinel
    set ::errorCode {NATIVE ERRORCODE SENTINEL}
    set code [catch {uplevel 1 $script} result options]
    lappend ::observations [list $label $code $result $options $::errorInfo $::errorCode]
    return -options $options $result
}
proc read_sdc {} {
    set prefix_case [string match "trace-prefix:*" $::variant]
    if {$prefix_case && [info exists ::mpx_timing::traces]} {
        lassign [split $::variant :] label remove_op remove_type add_op add_type qualification
        set trace_command [expr {$qualification eq "qualified" ? "::trace" : "trace"}]
        set prefix_callbacks [list \
            {::mpx_timing::exception_trace set_false_path} \
            {::mpx_timing::execution_trace set_false_path}]
        set prefix_registry [trace info execution ::mock_sdc::set_false_path]
        set prefix_native [llength $::setter_calls]
        set prefix_primary $::mpx_timing::commands
        set prefix_witness $::mpx_timing::step_enters
        set prefix_failures $::mpx_timing::failures
        foreach callback $prefix_callbacks {
            $trace_command $remove_op $remove_type ::mock_sdc::set_false_path {enter leave} $callback
        }
        set prefix_absent [expr {[trace info execution ::mock_sdc::set_false_path] eq ""}]
        if {!$prefix_absent} {error "Fixture failed to remove both setter callbacks"}
    }
    if {$::variant eq "trace-prefix-queries"} {
        set query_count 0
        foreach trace_command {trace ::trace} {
            for {set operation_length 1} {$operation_length <= 4} {incr operation_length} {
                set operation [string range info 0 [expr {$operation_length - 1}]]
                for {set type_length 1} {$type_length <= 9} {incr type_length} {
                    set type [string range execution 0 [expr {$type_length - 1}]]
                    set expected [trace info execution ::mock_sdc::set_false_path]
                    if {[$trace_command $operation $type ::mock_sdc::set_false_path] ne $expected} {
                        error "Abbreviated nonmutating query changed native result"
                    }
                    incr query_count
                }
            }
            $trace_command a v ::fixture_query_variable write ::fixture_query_callback
            if {[$trace_command i v ::fixture_query_variable] ne
                [trace info variable ::fixture_query_variable]} {error "Variable query mismatch"}
            $trace_command r v ::fixture_query_variable write ::fixture_query_callback
            $trace_command a c ::fixture_query_callback rename ::fixture_query_callback
            if {[$trace_command i c ::fixture_query_callback] ne
                [trace info command ::fixture_query_callback]} {error "Command query mismatch"}
            $trace_command r c ::fixture_query_callback rename ::fixture_query_callback
        }
        foreach bad_type {e* {} execution_extra unknown} {
            record_script trace-query-error {
                set code [catch {::trace i $bad_type ::mock_sdc::set_false_path} value options]
                if {$code != 1} {error "Expected a native invalid query error"}
                list $code $value $options
            }
        }
        write_report [file join $::output mock-trace-queries.summary] "equivalent_execution_queries=$query_count"
    }
    if {[info exists ::mpx_timing::argument_table] && $::variant eq "argument-write-error"} {
        close $::mpx_timing::argument_table
    }
    if {[info exists ::mpx_timing::command_table] &&
        $::variant in {command-write-error setter-error-and-command-write-error}} {
        close $::mpx_timing::command_table
    }
    if {[info exists ::mpx_timing::journal] && $::variant eq "journal-write-error"} {
        close $::mpx_timing::journal
    }
    if {[info exists ::mpx_timing::step_journal] && $::variant eq "witness-write-error"} {
        close $::mpx_timing::step_journal
    }
    if {[info exists ::mpx_timing::traces] && $::variant eq "trace-removed"} {
        trace remove execution ::mock_sdc::set_false_path {enter leave} \
            {::mpx_timing::exception_trace set_false_path}
    }
    set restored_traces {}
    if {[info exists ::mpx_timing::traces] &&
        $::variant in {witness-trace-removed both-traces-restored continuity-guard-restored}} {
        if {$::variant eq "continuity-guard-restored"} {
            lappend restored_traces [list ::trace enter {::mpx_timing::execution_trace trace_guard}]
        }
        if {$::variant ne "witness-trace-removed"} {
            lappend restored_traces [list ::mock_sdc::set_false_path {enter leave} \
                                         {::mpx_timing::exception_trace set_false_path}]
        }
        lappend restored_traces [list ::mock_sdc::set_false_path {enter leave} \
                                     {::mpx_timing::execution_trace set_false_path}]
        foreach item $restored_traces {
            lassign $item origin operations callback
            trace remove execution $origin $operations $callback
        }
    }
    if {[string match "hdl-*" $::variant]} {
        puts "Info (332164): Evaluating HDL-embedded SDC commands"
        puts "    Info (332165): Entity altera_std_synchronizer"
        puts "        Info (332166): $::hdl_statement"
        flush stdout
        set code [catch {record_script hdl $::hdl_statement} result]
        if {$code} {
            puts "Error (332000): $result"
            puts "Critical Warning (332008): Read_sdc failed due to errors in the SDC file"
        }
        # Model Quartus catching HDL errors internally and continuing.
        puts "Info (332104): Reading SDC File: 'Plex.sdc'"
    }
    if {$::variant eq "swallowed-native-error"} {
        puts "Error (332000): Timing exception has no attributable SDC source"
        puts "Critical Warning (332008): Read_sdc failed due to errors in the SDC file"
    }
    set result [record_script file {source Plex.sdc}]
    if {$prefix_case && [info exists ::mpx_timing::traces]} {
        set prefix_native [expr {[llength $::setter_calls] - $prefix_native}]
        set prefix_primary [expr {$::mpx_timing::commands - $prefix_primary}]
        set prefix_witness [expr {$::mpx_timing::step_enters - $prefix_witness}]
        foreach callback $prefix_callbacks {
            $trace_command $add_op $add_type ::mock_sdc::set_false_path {enter leave} $callback
        }
        set restored [expr {[trace info execution ::mock_sdc::set_false_path] eq $prefix_registry}]
        write_report [file join $::output mock-trace-state.summary] \
            "native=$prefix_native\nprimary=$prefix_primary\nwitness=$prefix_witness\nfailures=[expr {$::mpx_timing::failures - $prefix_failures}]\nabsent_before_native=$prefix_absent\nregistry_restored=$restored"
        if {!$restored} {error "Fixture failed to restore the original setter registrations"}
    }
    if {$::variant in {both-traces-restored continuity-guard-restored}} {
        foreach item $restored_traces {
            lassign $item origin operations callback
            trace add execution $origin $operations $callback
        }
    }
    if {$::variant eq "read-sdc-error"} {error "Native read_sdc failure after original setter"}
    return $result
}
proc fixture_query_callback {args} {}
namespace eval mock_sdc {
    namespace export set_*
    proc invoke {kind args} {
        lappend ::setter_calls [list $kind {*}$args]
        if {$::variant in {setter-error hdl-setter-error setter-error-and-command-write-error}} {
            return -code error -errorcode {NATIVE SETTER FAILURE} "Injected original setter failure"
        }
        if {$::variant eq "setter-return"} {return -code return -level 2 "Native setter return"}
        if {$::variant eq "setter-break"} {return -code break "Native setter break"}
        if {$::variant eq "setter-continue"} {return -code continue "Native setter continue"}
        if {$::variant eq "setter-custom-code"} {return -code 7 "Native setter custom code"}
        if {$::variant in {nested-original nested-same-setter} && [llength $::setter_calls] == 1} {
            native_inner
        }
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
            set expected [expr {$::variant eq "hdl-decoder" ? "decoder sync" : "decoder"}]
            if {[dict get $::collections $handle] ne $expected || $count != 1} {
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
proc fixture_hex {value} {
    binary scan [encoding convertto utf-8 $value] H* result
    return $result
}
proc write_semantics {} {
    set channel [open [file join $::output mock-collections.tsv] w]
    puts $channel "handle\tobjects"
    foreach handle [dict keys $::collections] {
        puts $channel "$handle\t[dict get $::collections $handle]"
    }
    close $channel
    set channel [open [file join $::output mock-semantics.tsv] w]
    puts $channel "event\tname\tcode\tresult_hex\toptions_hex\terrorinfo_hex\terrorcode_hex"
    foreach item $::observations {
        lassign $item name code result options errorinfo errorcode
        puts $channel [join [list result $name $code [fixture_hex $result] [fixture_hex $options] \
                            [fixture_hex $errorinfo] [fixture_hex $errorcode]] "\t"]
    }
    foreach call $::setter_calls {
        set normalized {}
        foreach value [lrange $call 1 end] {
            if {[dict exists $::collections $value]} {
                lappend normalized [list collection {*}[dict get $::collections $value]]
            } else {
                lappend normalized $value
            }
        }
        puts $channel [join [list setter [lindex $call 0] 0 [fixture_hex $normalized] "" "" ""] "\t"]
    }
    close $channel
}
proc exit {code} {
    write_semantics
    return -code error -errorcode [list MOCK_REPORTER_EXIT $code] "Reporter exit $code"
}
if {$unobserved} {
    catch {read_sdc}
    exit 0
}
source $reporter
