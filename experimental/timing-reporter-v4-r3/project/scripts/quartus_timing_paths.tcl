# Read-only sidecar. SDC execution traces observe arguments; they never replace constraints.
package require ::quartus::project
package require ::quartus::sta

namespace eval mpx_timing {
    variable directory
    variable project_root
    variable reporter_root [file dirname [file normalize [info script]]]
    variable handles {}
    variable traces {}
    variable pending {}
    variable commands 0
    variable completions 0
    variable objects 0
    variable keepers 0
    variable decoder_count 0
    variable decoder
    variable failures 0
    variable callback_depth 0
    variable read_enters 0
    variable read_leaves 0
    variable read_depth 0
    variable events 0
    variable journal ""
    variable observation_id ""
    variable finished 0
}

proc mpx_timing::hex {value} {
    binary scan [encoding convertto utf-8 $value] H* encoded
    return $encoded
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
    foreach channel $handles {
        if {[catch {close $channel} message]} {failure close-table $message}
    }
    set handles {}
}

proc mpx_timing::event {event id kind code detail} {
    variable journal
    variable events
    set sequence $events
    incr events
    row $journal [list $sequence $event $id $kind $code [hex $detail]]
    flush $journal
}

proc mpx_timing::failure {where message} {
    variable failures
    # A failed error sink must not escape a setter trace or erase the latch.
    incr failures
    if {[catch {event failure -1 $where 1 $message} sink_error]} {
        incr failures
        catch {puts stderr "MPX_OBSERVER_FAILURE_SINK [hex $sink_error]"; flush stderr}
    }
    catch {puts stderr "MPX_OBSERVER_FAILURE [hex "$where: $message"]"; flush stderr}
}

proc mpx_timing::status {state} {
    variable directory
    variable observation_id
    variable failures
    variable commands
    variable completions
    variable pending
    variable read_enters
    variable read_leaves
    variable read_depth
    variable events
    set channel [open [file join $directory observer.summary] w]
    set code [catch {
        fconfigure $channel -encoding utf-8 -translation lf
        puts $channel "schema=misterplex.timing-observer.v1"
        puts $channel "observation_id=$observation_id"
        puts $channel "state=$state"
        puts $channel "failures=$failures"
        puts $channel "enters=$commands"
        puts $channel "leaves=$completions"
        puts $channel "read_enters=$read_enters"
        puts $channel "read_leaves=$read_leaves"
        puts $channel "pending=[expr {[llength $pending] + $read_depth}]"
        puts $channel "events=$events"
    } message options]
    set close_code [catch {close $channel} close_message close_options]
    if {$code} {return -options $options $message}
    if {$close_code} {return -options $close_options $close_message}
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

proc mpx_timing::source_location {kind} {
    set raw ""
    for {set depth -1} {$depth >= -64} {incr depth -1} {
        if {[catch {info frame $depth} frame]} {break}
        if {![dict exists $frame cmd]} {continue}
        set text [dict get $frame cmd]
        if {![regexp {^\s*((?:::)?[A-Za-z0-9_:]+)(?:\s|$)} $text matched head] ||
            [namespace tail $head] ne $kind} {continue}
        if {$raw eq ""} {set raw $text}
        if {[dict exists $frame file] && [dict exists $frame line] &&
            [file extension [dict get $frame file]] eq ".sdc"} {
            return [list sdc [relative_source [dict get $frame file]] [dict get $frame line] $text]
        }
    }
    if {$raw eq ""} {error "Timing exception has neither an SDC source nor an original Tcl frame"}
    # This is a candidate, not HDL attribution. The bound host collector must
    # join the native HDL entity/statement log to a hash-bound source attribute.
    return [list hdl_pending "" 0 $raw]
}

proc mpx_timing::resolve_argument {option value} {
    # Collection handles are already substituted when the execution trace runs.
    if {![catch {get_collection_size $value} size]} {
        return [list collection $value]
    }
    if {![regexp {Not an SDK collection|Collection does not exist with name:} $size] ||
        [regexp {^_col[0-9]+$} $value]} {
        error "Exception collection resolution failed: $size"
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

proc mpx_timing::observe_exception {kind command arguments} {
    variable commands
    variable completions
    variable objects
    variable pending
    variable command_table
    variable argument_table
    variable object_table
    variable keepers
    set operation [lindex $arguments end]
    if {$operation eq "leave"} {
        if {[llength $pending] == 0} {error "Unpaired timing exception completion"}
        set item [lindex $pending end]
        set pending [lrange $pending 0 end-1]
        lassign $item id origin file line raw entered_kind entered_command
        if {$kind ne $entered_kind || $command ne $entered_command} {
            error "Timing exception completion changed command identity"
        }
        incr completions
        set code [lindex $arguments 0]
        event leave $id $kind $code [lindex $arguments 1]
        puts "MPX_OBSERVER_LEAVE $id $kind $code"
        flush stdout
        if {$code != 0} {failure original-setter "$kind returned code $code: [lindex $arguments 1]"}
        row $command_table [list $id $origin $file $line $kind $code $command [hex $raw]]
        return
    }
    if {$operation ne "enter" || $commands >= 512} {
        error "Unsupported/excess timing exception trace"
    }
    set id $commands
    incr commands
    # Pairing is established before any fallible provenance/collection work.
    lappend pending [list $id unknown "" 0 "" $kind $command]
    event enter $id $kind 0 $command
    lassign [source_location $kind] origin file line raw
    lset pending end [list $id $origin $file $line $raw $kind $command]
    puts "MPX_OBSERVER_ENTER $id $kind [hex $raw]"
    flush stdout
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

proc mpx_timing::observe_read {command arguments} {
    variable read_enters
    variable read_leaves
    variable read_depth
    set operation [lindex $arguments end]
    if {$operation eq "enter"} {
        incr read_enters
        incr read_depth
        event read-enter $read_depth read_sdc 0 $command
    } elseif {$operation eq "leave" && $read_depth > 0} {
        incr read_leaves
        event read-leave $read_depth read_sdc [lindex $arguments 0] [lindex $arguments 1]
        incr read_depth -1
        if {[lindex $arguments 0] != 0} {
            failure original-read-sdc "read_sdc returned code [lindex $arguments 0]"
        }
    } else {
        error "Unpaired/unsupported read_sdc trace"
    }
}

proc mpx_timing::exception_trace {kind command args} {
    variable callback_depth
    # Tcl execution traces must always return normally. They do not invoke or
    # replace the original setter, so its result, code and options stay native.
    set saved {}
    foreach name {::errorInfo ::errorCode} {
        if {[info exists $name]} {dict set saved $name [set $name]}
    }
    incr callback_depth
    set code [catch {
        if {$callback_depth != 1} {error "Reentrant timing observer callback"}
        if {$kind eq "read_sdc"} {
            observe_read $command $args
        } else {
            observe_exception $kind $command $args
        }
    } message]
    if {$code} {failure "$kind-[lindex $args end]" $message}
    incr callback_depth -1
    foreach name {::errorInfo ::errorCode} {
        if {[dict exists $saved $name]} {
            set $name [dict get $saved $name]
        } else {
            unset -nocomplain $name
        }
    }
    return
}

proc mpx_timing::inventory_tables {} {
    variable decoder
    variable decoder_count
    variable keepers
    variable command_table
    variable argument_table
    variable object_table
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
    set command_table [open_table Plex.exception-commands.tsv {id origin file line kind code command raw_hex}]
    set argument_table [open_table Plex.exception-arguments.tsv {id argument option mode count}]
    set object_table [open_table Plex.exception-objects.tsv {id argument type name}]
}

proc mpx_timing::begin_inventory {output_dir} {
    variable directory $output_dir
    variable project_root [file normalize [pwd]]
    variable reporter_root
    variable observation_id
    variable journal
    variable traces
    if {[catch {
        foreach name {observer.summary observer.complete Plex.observer-events.tsv} {
            if {[file exists [file join $directory $name]]} {error "Stale observer evidence: $name"}
        }
        set channel [open [file join $reporter_root observation.id] r]
        set observation_id [string trim [read $channel 128]]
        close $channel
        if {![regexp {^[0-9a-f]{32}$} $observation_id]} {error "Missing/invalid observation identity"}
        status running
        set journal [open_table Plex.observer-events.tsv {sequence event id kind code detail_hex}]
        event begin -1 observer 0 $observation_id
        puts "MPX_OBSERVER_BEGIN $observation_id"
        flush stdout
        inventory_tables
    } message]} {failure begin-inventory $message}
    # Even a failed inventory must not suppress read_sdc or its real setters.
    foreach kind {set_clock_groups set_false_path set_max_delay set_min_delay set_multicycle_path read_sdc} {
        if {[catch {
            set origin [namespace origin $kind]
            set callback [list ::mpx_timing::exception_trace $kind]
            trace add execution $origin {enter leave} $callback
            lappend traces [list $kind $origin $callback]
        } message]} {failure install-trace "$kind: $message"}
    }
}

proc mpx_timing::end_inventory {} {
    variable traces
    variable pending
    variable commands
    variable completions
    variable read_enters
    variable read_leaves
    variable read_depth
    variable failures
    variable finished
    if {$finished} {return}
    set finished 1
    foreach item $traces {
        lassign $item kind origin callback
        if {[catch {
            if {[namespace origin $kind] ne $origin ||
                [lsearch -exact [trace info execution $origin] [list {enter leave} $callback]] < 0} {
                error "Timing observation trace removed/replaced during read_sdc"
            }
            trace remove execution $origin {enter leave} $callback
        } message]} {failure remove-trace "$kind: $message"}
    }
    set traces {}
    if {[llength $pending] || $commands != $completions || $read_depth ||
        $read_enters == 0 || $read_enters != $read_leaves} {
        failure coverage "Incomplete timing exception/read_sdc execution"
    }
    if {[catch {event end -1 observer 0 ""} message]} {failure end-event $message}
    close_tables
    if {[catch {status [expr {$failures ? "failed" : "complete"}]} message]} {
        failure final-status $message
    }
    if {$failures} {error "Timing observer failed ($failures recorded failures); original setters were not replaced"}
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
    set read_code [catch {read_sdc} read_message read_options]
    set observation_code [catch {mpx_timing::end_inventory} observation_message observation_options]
    if {$read_code} {return -options $read_options $read_message}
    if {$observation_code} {return -options $observation_options $observation_message}
    update_timing_netlist
    foreach kind {timing-nodes sdc-sources exception-commands exception-arguments exception-objects observer-events} {
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
    puts $summary "schema=misterplex.timing-extended.v2"
    puts $summary "scoped_reports=$scoped_count"
    puts $summary "audit_files=[expr {6 + $corner_count * 5}]"
    puts $summary "keeper_nodes=$mpx_timing::keepers"
    puts $summary "decoder_nodes=$mpx_timing::decoder_count"
    puts $summary "exception_commands=$mpx_timing::commands"
    puts $summary "exception_objects=$mpx_timing::objects"
    puts $summary "extra_bytes=$extra_bytes"
    close $summary
    puts "MPX_OBSERVER_COMPLETE $mpx_timing::observation_id"
    flush stdout
    set summary [open [file join $output_dir observer.complete] w]
    puts $summary "misterplex.timing-observer.v1:$mpx_timing::observation_id"
    close $summary
} message]

foreach channel [list $index_file $scoped_file $audit_file] {
    if {$channel ne ""} {catch {close $channel}}
}
if {[catch {mpx_timing::end_inventory} cleanup_message] && !$result} {
    set result 1
    set message $cleanup_message
}
catch {delete_timing_netlist}
catch {project_close}
if {$result} {
    post_message -type error "Detailed timing reporter failed: $message"
    exit 1
}
exit 0
