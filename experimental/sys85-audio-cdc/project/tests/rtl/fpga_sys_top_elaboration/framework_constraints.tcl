# Modeled collection APIs only. This is not a Quartus netlist/STA result.
proc derive_pll_clocks {} {}
proc derive_clock_uncertainty {} {}
proc create_clock {args} {}
proc get_ports {args} { return [lindex $args end] }
proc get_pins {args} { return [lindex $args end] }
proc get_collection_size {value} { return [llength $value] }
proc foreach_in_collection {var collection body} {
	uplevel 1 [list foreach $var $collection $body]
}
proc canonical {name} {
	regsub -all {(^|\|)[^|:]+:} $name {\1} name
	return $name
}
proc tq_match {pattern value} {
	set escaped ""
	for {set i 0} {$i < [string length $pattern]} {incr i} {
		set ch [string index $pattern $i]
		if {$ch eq "\\"} {
			append escaped {\\}
		} elseif {$ch eq "\[" || $ch eq "\]"} { append escaped "\\" $ch } \
		else { append escaped $ch }
	}
	return [string match $escaped $value]
}
proc get_registers {args} {
	set result {}
	foreach name $::registers {
		foreach pattern [lindex $args end] {
			if {$name eq $pattern || [tq_match $pattern $name] || [tq_match $pattern [canonical $name]]} {
				lappend result $name
				break
			}
		}
	}
	return $result
}
proc get_clocks {args} {
	set result {}
	foreach name $::clocks {
		foreach pattern [lindex $args end] {
			if {$name eq $pattern || [tq_match $pattern $name]} { lappend result $name; break }
		}
	}
	return $result
}
proc get_object_info {option node} {
	if {$option ne "-name"} { error "unexpected object option" }
	return $node
}
proc get_register_info {option node} {
	if {$option ne "-clock_edges"} { error "unexpected register option" }
	if {$::case eq "missing-node-clock" && [canonical $node] eq {ascal|cfg_req_meta}} { return {} }
	return [list "clock-edge::$node"]
}
proc get_node_info {option node} {
	if {$option eq "-name"} { return $node }
	if {$option eq "-clock_edges"} { return {} }
	if {$option ne "-synch_edges"} { error "unexpected node option" }
	if {[string first "pin::" $node] != 0} { return {} }
	set reg [string range $node 5 end]
	if {$::case eq "clock-cycle" && [canonical $reg] eq {ascal|cfg_req_meta}} {
		return [list "cycle-edge::$reg"]
	}
	set result [list "wire-edge::$reg"]
	if {$::case eq "mixed-node-clock" && [canonical $reg] eq {ascal|cfg_req_meta}} {
		lappend result "other-edge::$reg"
	}
	return $result
}
proc get_edge_info {option edge} {
	if {$option ne "-src"} { error "unexpected edge option" }
	foreach prefix {clock-edge:: cycle-edge:: wire-edge:: other-edge::} {
		if {[string first $prefix $edge] != 0} { continue }
		set reg [string range $edge [string length $prefix] end]
		if {$prefix in {clock-edge:: cycle-edge::}} { return "pin::$reg" }
		if {$prefix eq "other-edge::"} { return "clock-target::$::memory" }
		return "clock-target::[dict get $::register_clocks $reg]"
	}
	error "unexpected edge"
}
proc get_clock_info {option node} {
	if {[llength $node] != 1} { error "nonunique clock object" }
	set node [lindex $node 0]
	if {$option eq "-name"} { return $node }
	if {$option eq "-period"} { return [dict get $::periods $node] }
	if {$option eq "-targets"} {
		if {$::case eq "missing-clock-target" && $node eq $::hdmi} { return {} }
		return [list "clock-target::$node"]
	}
	error "unexpected clock option"
}
proc post_message {args} { lappend ::messages [lindex $args end] }
proc set_clock_groups {args} {
	set groups {}
	foreach {option value} [lrange $args 1 end] {
		if {$option ne "-group"} { error "unexpected clock-group option" }
		lappend groups $value
	}
	if {[llength $groups] < 2} { error "single-group cut would include unlisted clocks" }
	for {set i 0} {$i < [llength $groups]} {incr i} {
		for {set j [expr {$i+1}]} {$j < [llength $groups]} {incr j} {
			foreach a [lindex $groups $i] {
				foreach b [lindex $groups $j] { dict set ::cuts [lsort [list $a $b]] 1 }
			}
		}
	}
}
proc options {args} {
	set result {}
	for {set i 0} {$i < [llength $args]} {incr i} {
		set key [lindex $args $i]
		if {$key eq "-hold" || $key eq "-setup"} { dict set result $key 1 } \
		elseif {[string index $key 0] eq "-"} { incr i; dict set result $key [lindex $args $i] } \
		else { dict set result value $key }
	}
	return $result
}
proc set_max_delay {args} { lappend ::maximums [options {*}$args] }
proc set_false_path {args} { lappend ::falsepaths [options {*}$args] }
proc set_multicycle_path {args} { lappend ::multicycles [options {*}$args] }
proc add {name clock} {
	lappend ::registers $name
	dict set ::register_clocks $name $clock
}
proc bus {stem width clock} {
	foreach bit [lsort -integer -unique [list 0 1 [expr {$width-1}]]] {
		add "${stem}\[$bit\]" $clock
	}
	add "${stem}\[0\]~DUPLICATE1" $clock
}
proc remove_matching {pattern} {
	set kept {}
	foreach name $::registers { if {![string match $pattern [canonical $name]]} { lappend kept $name } }
	set ::registers $kept
}

set case $::env(FRAMEWORK_SDC_CASE)
set rate $::env(FRAMEWORK_SDC_RATE)
set main {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}
set ddr {emu|pll|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}
set fast {emu|pll|sys85_pll|gpll~PLL_OUTPUT_COUNTER|divclk}
set hdmi {pll_hdmi|pll_hdmi_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}
set audio {pll_audio|pll_audio_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}
set memory {sysmem|fpga_interfaces|clocks_resets|h2f_user0_clk}
set sys $main
set clocks [list $main $ddr $hdmi $audio $memory FPGA_CLK1_50 FPGA_CLK2_50 FPGA_CLK3_50 spi_sck hdmi_sck unlisted_control_clk]
set periods [dict create $main 50.0 $ddr 11.111 $hdmi 6.732 $audio 40.682 $memory 10.0 \
	FPGA_CLK1_50 20.0 FPGA_CLK2_50 20.0 FPGA_CLK3_50 20.0 spi_sck 10.0 hdmi_sck 100.0 unlisted_control_clk 33.0]
if {$rate == 85} { set sys $fast; lappend clocks $fast; dict set periods $fast 11.764705882352942 }
set registers {}
set register_clocks {}
bus {scaler_config:scaler_config|cfg_data} 270 $sys
add {scaler_config:scaler_config|cfg_req} $sys
add {scaler_config:scaler_config|ack_meta} $sys
add {scaler_config:scaler_config|ack_sync} $sys
bus {ascal:ascal|cfg_capture} 270 $hdmi
foreach name {cfg_req_meta cfg_req_sync cfg_ack_i cfg_initialized pal_ready_meta pal_ready_sync pal_valid_meta pal_valid_sync o_palette_bank o_read o_readack_sync o_readack_sync2} {
	add "ascal:ascal|$name" $hdmi
}
foreach name {o_adrs o_read_base} { bus "ascal:ascal|$name" 32 $hdmi }
bus {ascal:ascal|o_adrs_pre} 24 $hdmi
foreach name {o_adrsa o_adrsb} { add "ascal:ascal|$name" $hdmi }
foreach name {avl_radrs avl_read_base} { bus "ascal:ascal|$name" 32 $memory }
foreach name {avl_read_sync avl_read_sync2 avl_readack} { add "ascal:ascal|$name" $memory }
bus {ascal:ascal|avl_completed_gray} 2 $memory
foreach name {o_completed_meta o_completed_sync} { bus "ascal:ascal|$name" 2 $hdmi }
bus {ascal:ascal|i_native_context} 37 $sys
bus {ascal:ascal|o_native_capture} 37 $hdmi
bus {ascal:ascal|o_native_release} 3 $hdmi
bus {ascal:ascal|i_native_release} 3 $sys
bus {ascal:ascal|i_wadrs} 32 $sys
bus {ascal:ascal|avl_wadrs} 32 $memory
bus {ascal:ascal|i_wbuf} 2 $sys
bus {ascal:ascal|avl_wbuf} 2 $memory
foreach name {i_native_req i_native_ack_meta i_native_ack_sync i_epoch_meta i_epoch_sync i_epoch_seen
              i_stream_meta i_stream_sync i_write_done_meta i_write_done_sync i_write i_walt} {
	add "ascal:ascal|$name" $sys
}
foreach name {o_native_meta o_native_sync o_native_ack o_native_epoch o_epoch_meta o_epoch_sync
              o_native_stream o_native_valid o_ihsize o_native_format} {
	add "ascal:ascal|$name" $hdmi
}
foreach name {avl_write_sync avl_write_sync2 avl_write_sync3 avl_write_done avl_walt} {
	add "ascal:ascal|$name" $memory
}
bus {scaler_palette:scaler_palette|descriptor} 37 $audio
foreach name {req_meta req_sync ack_meta ack_sync active_meta active_sync vs_meta vs_sync ready_tag ready_valid write_bank} {
	add "scaler_palette:scaler_palette|$name" $audio
}
add lowlat $sys
add lowlat~DUPLICATE1 $sys
add {pll_hdmi_adj:pll_hdmi_adj|llena_meta} FPGA_CLK1_50
add {pll_hdmi_adj:pll_hdmi_adj|llena_sync} FPGA_CLK1_50
foreach {instance width origin destination} [list frame_transfer 170 $sys $memory query_transfer 288 $memory $sys] {
	set stem "emu|hps_io:hps_io|video_calc:video_calc|video_measurement_cdc:$instance"
	bus "$stem|src_hold" $width $origin
	bus "$stem|dst_data" $width $destination
	foreach name {src_req ack_meta ack_sync} { add "$stem|$name" $origin }
	foreach name {dst_ack req_meta req_sync} { add "$stem|$name" $destination }
}
bus {emu|hps_io:hps_io|video_calc:video_calc|frame_gray_vid} 32 $sys
bus {emu|hps_io:hps_io|video_calc:video_calc|frame_gray_meta} 32 $memory
bus {emu|hps_io:hps_io|video_calc:video_calc|frame_gray_sync} 32 $memory
foreach name {timing_counter.vs_meta timing_counter.hs_meta timing_counter.de_meta timing_counter.vs_sync timing_counter.hs_sync timing_counter.de_sync hdmi_counter.vs_meta hdmi_counter.vs_sync} {
	add "emu|hps_io:hps_io|video_calc:video_calc|$name" $memory
}
foreach name {mode_meta mode_sync rotated_meta rotated_sync} { add "emu|hps_io:hps_io|video_calc:video_calc|$name" $sys }
bus audio_ctrl_data 320 $sys
bus {alsa:alsa|g_session.command} 320 $audio
bus {alsa:alsa|g_session.snapshot} 320 $audio
bus {emu|audio_session_mailbox:audio_session|snapshot_capture} 320 $sys
foreach name {audio_ctrl_toggle audio_snapshot_toggle} { add $name $sys; add "$name~DUPLICATE" $sys }
foreach name {ctrl_s1 snapshot_s1 ctrl_ack snapshot_ack} { add "alsa:alsa|g_session.$name" $audio }
foreach name {ack_s1 snap_s1} { add "emu|audio_session|$name" $sys }
add {ascal:ascal|unrelated_feedback} $hdmi
add {sysmem|unrelated_status} $memory

if {$case eq "aliases"} {
	set replaced {}
	foreach name $registers {
		set normal [canonical $name]
		set new $name
		foreach {prefix alias} {
			scaler_config|cfg_data scaler_cfg_data
			scaler_config|cfg_req scaler_cfg_req
			ascal|cfg_ack_i scaler_cfg_ack
			ascal|cfg_initialized scaler_cfg_active
			scaler_palette|ready_tag scaler_pal_ready
			scaler_palette|ready_valid scaler_pal_valid
			scaler_palette|write_bank scaler_pal_bank
			emu|hps_io|video_calc|frame_transfer|dst_data emu|hps_io|video_calc|frame_100
			emu|hps_io|video_calc|query_transfer|dst_data emu|hps_io|video_calc|measurement_sys
		} {
			if {[string first $prefix $normal] == 0} {
				set new "$alias[string range $normal [string length $prefix] end]"
			}
		}
		lappend replaced $new
		dict set register_clocks $new [dict get $register_clocks $name]
	}
	set registers $replaced
}
if {$case eq "disabled"} { set registers {} }
if {$case eq "optimized-bank"} {
	remove_matching {scaler_palette|write_bank}
	add {scaler_palette:scaler_palette|request} $audio
}
if {$case eq "partial-constants"} {
	set retained {}
	foreach name $registers {
		if {![regexp {^scaler_config\|cfg_data\[[01]\]} [canonical $name]]} { lappend retained $name }
	}
	set registers $retained
}
foreach {scenario node wrong} [list wrong-source-clock {scaler_config:scaler_config|cfg_data[0]} $memory \
	wrong-capture-clock {ascal:ascal|cfg_req_meta} $sys \
	wrong-root-clock {pll_hdmi_adj:pll_hdmi_adj|llena_meta} $hdmi \
	wrong-duplicate-clock {scaler_config:scaler_config|cfg_data[0]~DUPLICATE1} $hdmi] {
	if {$case eq $scenario} { dict set register_clocks $node $wrong }
}
if {$case eq "missing-bank"} { remove_matching {scaler_palette|write_bank} }
if {$case eq "missing-source"} { remove_matching {scaler_config|cfg_data*} }
if {$case eq "missing-capture"} { remove_matching {ascal|cfg_capture*} }
if {$case eq "missing-completion-source"} { remove_matching {ascal|avl_completed_gray*} }
if {$case eq "missing-completion-capture"} { remove_matching {ascal|o_completed_meta*} }
if {$case eq "invalid-completion-bit"} { add {ascal:ascal|avl_completed_gray[2]} $memory }
foreach {scenario pattern} {
	missing-native-source ascal|i_native_context*
	missing-native-capture ascal|o_native_capture*
	missing-native-release ascal|o_native_release*
	missing-native-refresh ascal|i_epoch_seen*
	missing-write-source ascal|i_write
	missing-write-capture ascal|avl_wadrs*
} {
	if {$case eq $scenario} { remove_matching $pattern }
}
if {$case eq "invalid-native-bit"} { add {ascal:ascal|o_native_capture[37]} $hdmi }
if {$case eq "missing-palette"} { remove_matching {scaler_palette|*} }
if {$case eq "unexpected-register"} { add {scaler_config:scaler_config|cfg_data[0]~UNKNOWN_COPY} $sys }
foreach member {event_join|phase[0] event_join|cut_data[0] last_event_100[0] timing_edge timing_cut[0]} {
	add "emu|hps_io|video_calc|$member" $memory
}
if {$case eq "invalid-bit"} { add {scaler_config:scaler_config|cfg_data[270]} $sys }
if {$case eq "ambiguous-instance"} { add {replica|scaler_config:scaler_config|cfg_data[0]} $sys }
if {$case eq "missing-measurement"} { remove_matching {emu|hps_io|video_calc|query_transfer|dst_data*} }
if {$case eq "missing-clock"} { set clocks [lsearch -all -inline -not -exact $clocks $memory] }
if {$case eq "zero-period"} { dict set periods $hdmi 0.0 }
if {$case eq "ambiguous-clock"} {
	set other {pll_hdmi|pll_hdmi_inst|altera_pll_i|spare[0].gpll~PLL_OUTPUT_COUNTER|divclk}
	lappend clocks $other; dict set periods $other 6.732
}
set cuts {}; set maximums {}; set falsepaths {}; set multicycles {}; set messages {}
set fixture_roles [list $sys $hdmi $audio $memory]
source $::env(FRAMEWORK_SDC_REFERENCE)
set before $cuts
set cuts {}; set maximums {}; set falsepaths {}; set multicycles {}; set messages {}
set failure [catch {
	source $::env(FRAMEWORK_SDC_SYSTEM)
	source $::env(FRAMEWORK_SDC_PRODUCT)
	source $::env(FRAMEWORK_SDC_HELPER)
	if {$case eq "invalid-gray-interval"} {
		plex_framework_cdc::gray_budget [get_clocks [list $memory]] 10.0 0.0
	}
} message]
lassign $fixture_roles sys hdmi audio memory
set negative [expr {$case ni {active aliases disabled gray-intervals optimized-bank partial-constants}}]
if {$negative} {
	if {!$failure} { error "Expected fail-closed rejection for $case" }
	if {$case eq "invalid-gray-interval" && ![string match "*invalid minimum HIGH/LOW spacing*" $message]} {
		error "Wrong Gray rejection reason: $message"
	}
	puts "PASS rejected $rate/$case: $message"
} else {
	if {$failure} { error $message }
	if {$case eq "gray-intervals"} {
		set clock [get_clocks [list $memory]]
		if {[plex_framework_cdc::gray_budget $clock 4.0 50.0] != 4.0 ||
		    [plex_framework_cdc::gray_budget $clock 50.0 3.0] != 3.0 ||
		    [plex_framework_cdc::gray_budget $clock 50.0 50.0] != 10.0} {
			error "Gray bound did not honor BOTH minimum HIGH and LOW spacing"
		}
	}
	foreach pair [dict keys $cuts] {
		if {![dict exists $before $pair]} { error "A formerly timed pair was cut: $pair" }
	}
	set removed {}
	foreach pair [dict keys $before] { if {![dict exists $cuts $pair]} { lappend removed $pair } }
	set expected {}
	if {$case ne "disabled"} {
		foreach pair [list [list $sys $hdmi] [list $sys $audio] [list $sys $memory] \
			[list $sys FPGA_CLK1_50] [list $hdmi $audio] [list $hdmi $memory]] {
			set pair [lsort $pair]
			if {[dict exists $before $pair]} { lappend expected $pair }
		}
	}
	if {[lsort $removed] ne [lsort $expected]} { error "Wrong opened clock pairs: $removed; expected $expected; sys=$sys hdmi=$hdmi" }
	set checks 0
	foreach constraint $maximums {
		if {![dict exists $constraint -from] || ![dict exists $constraint -to] ||
		    [dict get $constraint value] <= 0} { error "Unbounded maximum" }
		foreach destination [dict get $constraint -to] {
			set name [canonical $destination]
			if {[string match {ascal|o_completed_meta*} $name] &&
			    [dict get $constraint value] != min([dict get $periods $hdmi],16*[dict get $periods $memory])} {
				error "Wrong completion Gray spacing/clock-latency budget"
			}
			if {[regexp {event_join|last_event_100|event_decode|timing_(edge|level|qualified|cut)} $name]} {
				error "Ordinary event association logic was exempted"
			}
			if {[regexp {(^|\|)(o_native_sync|o_epoch_sync|i_native_ack_sync|i_epoch_sync|i_stream_sync|i_write_done_sync|avl_write_sync2|avl_write_sync3|o_native_valid|o_ihsize|o_native_format)(\[.*\])?(~.*)?$} $name]} {
				error "Native second-stage/local context decoding was exempted: $destination"
			}
			if {[regexp {(^|\|)(o_native_capture|o_native_meta|o_epoch_meta)(\[.*\])?(~.*)?$} $name] &&
				[dict get $constraint value] != [dict get $periods $hdmi]} {
				error "Wrong native first-capture HDMI clock-latency budget"
			}
			if {[regexp {(^|\|)(llena_sync|cfg_req_sync|pal_ready_sync|pal_valid_sync|avl_read_sync2|o_readack_sync2|o_completed_sync|frame_gray_sync|ack_sync|req_sync|timing_counter\.[a-z]+_sync|hdmi_counter\.vs_sync)(\[.*\])?(~.*)?$} $name]} {
				error "Second-stage/same-clock path relaxed: $destination"
			}
			foreach source [dict get $constraint -from] {
				if {[dict exists $periods $source]} { set origin $source } \
				else { set origin [dict get $register_clocks $source] }
				set target [dict get $register_clocks $destination]
				if {$origin eq $target} { error "Same-clock path overridden: $source -> $destination" }
				if {[dict exists $cuts [lsort [list $origin $target]]]} {
					error "Maximum hidden by inherited clock-group cut: $source -> $destination"
				}
				incr checks
			}
		}
	}
	if {$case eq "disabled"} {
		if {[llength $maximums]} { error "Disabled endpoints received constraints" }
	} elseif {$checks < 100} { error "Missing relevant endpoint coverage" }
	foreach constraint $falsepaths {
		if {[dict exists $constraint -hold]} { continue }
		# New descriptor, bank, and measurement capture points must never be
		# waived by an old whole-endpoint setup exception.
		foreach option {-from -to} {
			if {![dict exists $constraint $option]} { continue }
			foreach pattern [dict get $constraint $option] {
				foreach reg [get_registers [list $pattern]] {
					if {[regexp {cfg_capture|cfg_data|descriptor|src_hold|dst_data|o_palette_bank|frame_gray_meta|o_completed_meta|avl_completed_gray|native_(context|capture|release)|i_wadrs|avl_wadrs|o_ihsize|o_native_format} [canonical $reg]]} {
						error "Held channel is hidden by setup false path: $reg"
					}
				}
			}
		}
	}
	puts "PASS framework constraints $rate/$case: [llength $maximums] bounded transfers, $checks source/capture pairs, [llength $removed] old clock cuts removed"
}
