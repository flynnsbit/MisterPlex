# Read-only sidecar. SDC execution traces observe arguments; they never replace constraints.
package require ::quartus::project
package require ::quartus::sta

namespace eval mpx_timing {
    variable directory
    variable project_root
    variable handles {}
    variable traces {}
    variable pending {}
    variable commands 0
    variable objects 0
    variable keepers 0
    variable decoder_count 0
    variable decoder
    variable audits {}
}

proc mpx_timing::field {value} {
    if {[string length $value] > 4096 || [regexp {[\x00-\x1f\x7f]} $value]} {
        error "Invalid timing evidence field"
    }
    return $value
}

proc mpx_timing::row {channel values} {
    foreach value $values {field $value}
    puts $channel [join $values "\t"]
    if {[tell $channel] > 16777216} {
        error "Timing inventory exceeds sixteen MiB"
    }
}

proc mpx_timing::open_table {name header} {
    variable directory
    variable handles
    set channel [open [file join $directory $name] w]
    fconfigure $channel -encoding utf-8 -translation lf
    lappend handles $channel
    row $channel $header
    return $channel
}

proc mpx_timing::close_tables {} {
    variable handles
    foreach channel $handles {close $channel}
    set handles {}
}

proc mpx_timing::relative_source {filename} {
    variable project_root
    set path [file normalize $filename]
    set prefix "$project_root/"
    if {![string equal -length [string length $prefix] $path $prefix] ||
        [file extension $path] ne ".sdc" || ![file isfile $path]} {
        error "SDC source is outside the frozen project: $filename"
    }
    return [field [string range $path [string length $prefix] end]]
}

proc mpx_timing::source_location {} {
    for {set depth -1} {$depth >= -64} {incr depth -1} {
        if {[catch {info frame $depth} frame]} {break}
        if {[dict exists $frame file] && [dict exists $frame line] &&
            [file extension [dict get $frame file]] eq ".sdc"} {
            return [list [relative_source [dict get $frame file]] [dict get $frame line]]
        }
    }
    error "Timing exception has no attributable SDC source"
}

proc mpx_timing::resolve_argument {option value} {
    # Collection handles are already substituted when the execution trace runs.
    if {![catch {get_collection_size $value} size]} {
        return [list collection $value]
    }
    switch -- $option {
        -group - -from_clock - -to_clock -
        -rise_from_clock - -fall_from_clock - -rise_to_clock - -fall_to_clock {
            return [list clock_pattern [get_clocks $value]]
        }
        -through - -rise_through - -fall_through {
            error "Unresolved through-pattern requires an explicit pin/net collection"
        }
        default {
            return [list keeper_pattern [get_keepers $value]]
        }
    }
}

proc mpx_timing::exception_trace {kind command args} {
    variable commands
    variable objects
    variable pending
    variable command_table
    variable argument_table
    variable object_table
    variable keepers
    set operation [lindex $args end]
    if {$operation eq "leave"} {
        if {[llength $pending] == 0} {error "Unpaired timing exception completion"}
        set item [lindex $pending end]
        set pending [lrange $pending 0 end-1]
        lassign $item id file line entered_kind entered_command
        if {$kind ne $entered_kind || $command ne $entered_command} {
            error "Timing exception completion changed command identity"
        }
        row $command_table [list $id $file $line $kind [lindex $args 0] $command]
        return
    }
    if {$operation ne "enter" || $commands >= 512} {
        error "Unsupported/excess timing exception trace"
    }
    lassign [source_location] file line
    set id $commands
    incr commands
    lappend pending [list $id $file $line $kind $command]
    set seen_from 0
    set seen_to 0
    for {set i 1} {$i < [llength $command]} {incr i} {
        set option [lindex $command $i]
        if {$option ni {-group -from -to -through -from_clock -to_clock
                        -rise_from -fall_from -rise_to -fall_to
                        -rise_through -fall_through -rise_from_clock -fall_from_clock
                        -rise_to_clock -fall_to_clock}} {continue}
        if {$i + 1 >= [llength $command]} {error "Missing exception endpoint argument"}
        set position $i
        incr i
        lassign [resolve_argument $option [lindex $command $i]] mode collection
        set size [get_collection_size $collection]
        if {$size > 250000} {error "Exception collection exceeds object limit"}
        row $argument_table [list $id $position $option $mode $size]
        foreach_in_collection object $collection {
            row $object_table [list $id $position [get_object_info -type $object] [get_object_info -name $object]]
            incr objects
            if {$objects > 250000} {error "Exception inventory exceeds object limit"}
        }
        if {[string match "*from*" $option]} {set seen_from 1}
        if {[string match "*to*" $option]} {set seen_to 1}
    }
    if {$kind ne "set_clock_groups"} {
        if {!$seen_from} {row $argument_table [list $id -1 -from implicit_all_keepers $keepers]}
        if {!$seen_to} {row $argument_table [list $id -2 -to implicit_all_keepers $keepers]}
    }
}

proc mpx_timing::begin_inventory {output_dir} {
    variable directory $output_dir
    variable project_root [file normalize [pwd]]
    variable decoder
    variable decoder_count
    variable keepers
    variable command_table
    variable argument_table
    variable object_table
    variable traces
    set decoder [get_keepers {*|mb_ctrl|* *|rbsp|* *|stub|*
        *|h264_mb_ctrl:mb_ctrl|* *|h264_slice_rbsp_ram:rbsp|* *|decode_stub:stub|*}]
    set decoder_names {}
    foreach_in_collection object $decoder {
        dict set decoder_names [get_object_info -name $object] 1
    }
    set decoder_count [dict size $decoder_names]
    set nodes [open_table Plex.timing-nodes.tsv {type name decoder}]
    set all [get_keepers *]
    set seen {}
    foreach_in_collection object $all {
        set name [get_object_info -name $object]
        set type [get_object_info -type $object]
        if {[dict exists $seen $name]} {error "Duplicate timing keeper name"}
        dict set seen $name 1
        row $nodes [list $type $name [dict exists $decoder_names $name]]
        incr keepers
        if {$keepers > 250000} {error "Timing keeper inventory exceeds limit"}
    }
    foreach name [dict keys $decoder_names] {
        if {![dict exists $seen $name]} {error "Decoder scope is outside keeper inventory"}
    }
    set sources [open_table Plex.sdc-sources.tsv {file}]
    foreach filename [get_default_sdc_file_names] {
        row $sources [list [relative_source $filename]]
    }
    set command_table [open_table Plex.exception-commands.tsv {id file line kind code command}]
    set argument_table [open_table Plex.exception-arguments.tsv {id argument option mode count}]
    set object_table [open_table Plex.exception-objects.tsv {id argument type name}]
    foreach kind {set_clock_groups set_false_path set_max_delay set_min_delay set_multicycle_path} {
        set origin [namespace origin $kind]
        set callback [list ::mpx_timing::exception_trace $kind]
        trace add execution $origin {enter leave} $callback
        lappend traces [list $origin $callback]
    }
}

proc mpx_timing::end_inventory {} {
    variable traces
    variable pending
    foreach item $traces {
        lassign $item origin callback
        trace remove execution $origin {enter leave} $callback
    }
    set traces {}
    if {[llength $pending]} {error "Incomplete timing exception execution"}
    close_tables
}

set output_dir [lindex $quartus(args) 0]
set byte_limit 134217728
set file_limit 8388608
set total_bytes 0
set extra_bytes 0
set report_count 0
set scoped_count 0
set corner_count 0
set index_file ""
set scoped_file ""
set audit_file ""

proc audit_file {directory channel kind corner basename} {
    set path [file join $directory $basename]
    if {![file isfile $path] || [file size $path] > 16777216} {
        error "Missing/oversized timing audit: $basename"
    }
    mpx_timing::row $channel [list $kind $corner $basename]
    return [file size $path]
}

set result [catch {
    if {$output_dir eq "" || ![file isdirectory $output_dir]} {
        error "Timing report output directory is required"
    }
    set index_file [open [file join $output_dir index.tsv] w]
    puts $index_file "corner\tclock_index\tcondition\tclock\tperiod_ns\tcheck\tfile"
    set scoped_file [open [file join $output_dir scoped-index.tsv] w]
    puts $scoped_file "corner\tclock_index\tcondition\tclock\tperiod_ns\tscope\tcheck\tfile"
    set audit_file [open [file join $output_dir audit-index.tsv] w]
    puts $audit_file "kind\tcorner\tfile"
    project_open Plex -revision Plex
    create_timing_netlist
    mpx_timing::begin_inventory $output_dir
    read_sdc
    mpx_timing::end_inventory
    update_timing_netlist
    foreach kind {timing-nodes sdc-sources exception-commands exception-arguments exception-objects} {
        incr extra_bytes [audit_file $output_dir $audit_file $kind -1 "Plex.$kind.tsv"]
    }

    foreach_in_collection condition [get_available_operating_conditions] {
        if {$corner_count >= 8} {
            error "Timing reporter exceeds eight operating conditions"
        }
        set_operating_conditions $condition
        update_timing_netlist
        set clock_index 0
        foreach_in_collection clock [get_clocks *] {
            if {$clock_index >= 64} {
                error "Timing reporter exceeds 64 clocks per condition"
            }
            set clock_name [get_clock_info -name $clock]
            set period [get_clock_info -period $clock]
            if {[string length $clock_name] > 1024 || [regexp {[\t\r\n]} "$condition$clock_name$period"]} {
                error "Unsupported clock/condition label"
            }
            foreach check {setup hold} {
                if {$total_bytes >= $byte_limit} {
                    error "Timing reporter exceeds total byte limit"
                }
                set basename [format "Plex.corner-%02d.clock-%02d.%s.rpt" $corner_count $clock_index $check]
                set filename [file join $output_dir $basename]
                if {$check eq "setup"} {
                    report_timing -setup -to_clock $clock -npaths 10 -nworst 10 -detail full_path -file $filename
                } else {
                    report_timing -hold -to_clock $clock -npaths 10 -nworst 10 -detail full_path -file $filename
                }
                set size [file size $filename]
                set allowance [expr {min($file_limit, $byte_limit - $total_bytes)}]
                if {$size > $allowance} {
                    set input [open $filename r]
                    fconfigure $input -translation binary
                    set prefix [read $input $allowance]
                    close $input
                    set output [open $filename w]
                    fconfigure $output -translation binary
                    puts -nonewline $output $prefix
                    close $output
                    error "Timing report truncated at byte limit: $basename"
                }
                puts $index_file "$corner_count\t$clock_index\t$condition\t$clock_name\t$period\t$check\t$basename"
                flush $index_file
                incr report_count
                incr total_bytes $size
                if {$mpx_timing::decoder_count > 0} {
                    foreach scope {decoder-from decoder-to} {
                        set scoped_basename [format "Plex.corner-%02d.clock-%02d.%s.%s.rpt" $corner_count $clock_index $scope $check]
                        set scoped_name [file join $output_dir $scoped_basename]
                        if {$scope eq "decoder-from"} {
                            if {$check eq "setup"} {
                                report_timing -setup -from $mpx_timing::decoder -to_clock $clock -npaths 1 -nworst 1 -detail full_path -file $scoped_name
                            } else {
                                report_timing -hold -from $mpx_timing::decoder -to_clock $clock -npaths 1 -nworst 1 -detail full_path -file $scoped_name
                            }
                        } else {
                            if {$check eq "setup"} {
                                report_timing -setup -to $mpx_timing::decoder -to_clock $clock -npaths 1 -nworst 1 -detail full_path -file $scoped_name
                            } else {
                                report_timing -hold -to $mpx_timing::decoder -to_clock $clock -npaths 1 -nworst 1 -detail full_path -file $scoped_name
                            }
                        }
                        set scoped_size [file size $scoped_name]
                        if {$scoped_size > $file_limit} {error "Scoped timing report exceeds byte limit"}
                        puts $scoped_file "$corner_count\t$clock_index\t$condition\t$clock_name\t$period\t$scope\t$check\t$scoped_basename"
                        incr scoped_count
                        incr extra_bytes $scoped_size
                    }
                }
                if {$total_bytes + $extra_bytes > $byte_limit} {
                    error "Complete timing evidence exceeds byte limit"
                }
            }
            incr clock_index
        }
        if {$clock_index == 0} {
            error "Timing netlist has no clocks"
        }
        set prefix [format "Plex.corner-%02d" $corner_count]
        report_sdc -file [file join $output_dir "$prefix.sdc-used.rpt"]
        report_sdc -ignored -file [file join $output_dir "$prefix.sdc-ignored.rpt"]
        write_sdc -expand [file join $output_dir "$prefix.sdc-macros.txt"]
        # Clock-group path reporting is Spectra-Q-only. Membership comes from
        # actual substituted collection arguments above, not sampled paths.
        report_exceptions -setup -npaths 1 -detail summary -file [file join $output_dir "$prefix.exceptions-setup.rpt"]
        report_exceptions -hold -npaths 1 -detail summary -file [file join $output_dir "$prefix.exceptions-hold.rpt"]
        foreach kind {sdc-used sdc-ignored sdc-macros exceptions-setup exceptions-hold} {
            set extension [expr {$kind eq "sdc-macros" ? "txt" : "rpt"}]
            incr extra_bytes [audit_file $output_dir $audit_file $kind $corner_count "$prefix.$kind.$extension"]
        }
        if {$total_bytes + $extra_bytes > $byte_limit} {
            error "Complete timing evidence exceeds byte limit"
        }
        incr corner_count
    }
    if {$corner_count == 0 || $report_count == 0} {
        error "Timing netlist has no operating conditions/reports"
    }
    close $index_file
    set index_file ""
    set summary [open [file join $output_dir complete.summary] w]
    puts $summary "corners=$corner_count"
    puts $summary "reports=$report_count"
    puts $summary "bytes=$total_bytes"
    close $summary
    close $scoped_file
    set scoped_file ""
    close $audit_file
    set audit_file ""
    set summary [open [file join $output_dir extended.summary] w]
    puts $summary "schema=misterplex.timing-extended.v1"
    puts $summary "scoped_reports=$scoped_count"
    puts $summary "audit_files=[expr {5 + $corner_count * 5}]"
    puts $summary "keeper_nodes=$mpx_timing::keepers"
    puts $summary "decoder_nodes=$mpx_timing::decoder_count"
    puts $summary "exception_commands=$mpx_timing::commands"
    puts $summary "exception_objects=$mpx_timing::objects"
    puts $summary "extra_bytes=$extra_bytes"
    close $summary
} message]

foreach channel [list $index_file $scoped_file $audit_file] {
    if {$channel ne ""} {catch {close $channel}}
}
catch {mpx_timing::end_inventory}
catch {delete_timing_netlist}
catch {project_close}
if {$result} {
    post_message -type error "Detailed timing reporter failed: $message"
    exit 1
}
exit 0
