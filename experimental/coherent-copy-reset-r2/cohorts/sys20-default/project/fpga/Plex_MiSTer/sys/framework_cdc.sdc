# Held-data/first-stage bounds only. Quartus17 includes clock latency/skew in
# numeric max-delay. No datapath_only semantics or setup false-path waiver.
# sys_top.sdc opens these protocol clock pairs; unrelated paths stay timed.
namespace eval plex_framework_cdc {
	proc normalize {name} {
		set parts {}
		foreach part [split $name |] { lappend parts [lindex [split $part :] end] }
		set name [join $parts |]
		regsub {^sys_top\|} $name {} name
		set name [string map {video_calc|timing_counter| video_calc|timing_counter. video_calc|hdmi_counter| video_calc|hdmi_counter.} $name]
		foreach {alias canonical} {
			scaler_cfg_data scaler_config|cfg_data scaler_cfg_req scaler_config|cfg_req
			scaler_cfg_ack ascal|cfg_ack_i scaler_cfg_active ascal|cfg_initialized
			scaler_pal_ready scaler_palette|ready_tag scaler_pal_valid scaler_palette|ready_valid
			scaler_pal_bank scaler_palette|write_bank
			scaler_palette|request scaler_palette|write_bank
			emu|hps_io|video_calc|frame_100 emu|hps_io|video_calc|frame_transfer|dst_data
			emu|hps_io|video_calc|measurement_sys emu|hps_io|video_calc|query_transfer|dst_data
		} {
			if {[string first $alias $name] == 0} {
				set suffix [string range $name [string length $alias] end]
				if {[regexp {^(\[[0-9]+\])?(~DUPLICATE[0-9]*)?$} $suffix]} { set name "$canonical$suffix" }
			}
		}
		return $name
	}
	proc present {patterns} { return [expr {[get_collection_size [get_registers -nowarn $patterns]] != 0}] }
	proc reg {label stem member width {aliases {}}} {
		set bases [list "*[lindex [split $stem |] end]*|$member"]
		if {[string first . $member] >= 0} {
			lappend bases "*[lindex [split $stem |] end]*|[string map {. |} $member]"
		}
		if {$stem eq ""} { set bases [list $member "sys_top*|$member"] }
		foreach alias $aliases { lappend bases $alias "sys_top*|$alias" }
		set patterns {}
		foreach base $bases {
			if {$width > 0} { lappend patterns [format {%s[*]*} $base] } \
			else { lappend patterns $base "$base~*" }
		}
		set member_re [string map {. {\.}} $member]
		set bit_re ""
		if {$width > 0} { set bit_re {\[([0-9]+)\]} }
		set expression [format {^%s%s(~DUPLICATE[0-9]*)?$} $member_re $bit_re]
		set names {}; set bits {}
		foreach_in_collection node [get_registers -nowarn $patterns] {
			set name [get_object_info -name $node]
			set normal [normalize $name]
			set path [split $normal |]
			if {[join [lrange $path 0 end-1] |] ne $stem ||
			    ![regexp $expression [lindex $path end] ignored bit]} {
				error "Framework CDC $label has unexpected/ambiguous register $name"
			}
			if {$width > 0} {
				if {$bit >= $width} { error "Framework CDC $label has out-of-range bit $name" }
				lappend bits $bit
			}
			lappend names $name
		}
		if {[llength $names] == 0} { error "Framework CDC $label has an empty collection" }
		post_message -type info "Framework CDC $label: logical width $width; retained bits [lsort -integer -unique $bits]; physical registers $names"
		return [get_registers $names]
	}
	proc clock {label patterns} {
		set result [get_clocks -nowarn $patterns]
		if {[get_collection_size $result] != 1} { error "Framework CDC $label clock is missing or ambiguous" }
		set period [get_clock_info -period $result]
		if {![string is double -strict $period] || !($period > 0 && $period < 1.0e9)} {
			error "Framework CDC $label clock has invalid period"
		}
		return $result
	}
	proc bound {label from to destination {maximum ""}} {
		require_clock $label-capture $to $destination
		set period [get_clock_info -period $destination]
		if {$maximum ne ""} { set period [expr {min($period,$maximum)}] }
		set_max_delay -from $from -to $to $period
		set_false_path -hold -from $from -to $to
		post_message -type info "Framework CDC $label: max $period ns, first-stage/held capture nearest-edge hold only excluded"
	}
	proc nearest_clocks {node visited} {
		variable clock_targets
		variable clock_cache
		if {[dict exists $clock_targets $node]} { return [dict get $clock_targets $node] }
		if {[dict exists $clock_cache $node]} { return [dict get $clock_cache $node] }
		if {$node in $visited} { error "Framework CDC clock graph has a cycle at $node" }
		lappend visited $node
		set found {}
		foreach edge [concat [get_node_info -synch_edges $node] [get_node_info -clock_edges $node]] {
			lappend found {*}[nearest_clocks [get_edge_info -src $edge] $visited]
		}
		set found [lsort -unique $found]
		dict set clock_cache $node $found
		return $found
	}
	proc require_clock {label registers clock} {
		set expected [get_clock_info -name $clock]
		foreach_in_collection node $registers {
			set name [get_object_info -name $node]
			set actual {}
			foreach edge [get_register_info -clock_edges $node] {
				lappend actual {*}[nearest_clocks [get_edge_info -src $edge] {}]
			}
			if {[lsort -unique $actual] ne [list $expected]} {
				error "Framework CDC $label has wrong/missing clock at $name; expected $expected; actual $actual"
			}
		}
		post_message -type info "Framework CDC $label: verified nearest clock $expected; physical count [get_collection_size $registers]"
	}
	proc pair {label from to destination origin} {
		set source [reg $label-source {*}$from]
		require_clock $label-source $source $origin
		bound $label $source [reg $label-capture {*}$to] $destination
	}
	proc gray_budget {destination min_high min_low} {
		foreach interval [list $min_high $min_low] {
			if {![string is double -strict $interval] || !($interval > 0 && $interval < 1.0e9)} {
				error "Framework Gray event has invalid minimum HIGH/LOW spacing"
			}
		}
		return [expr {min([get_clock_info -period $destination],$min_high,$min_low)}]
	}
	proc first_clock {label source destination target} {
		set sink [reg $label-capture {*}$target]
		require_clock $label-capture $sink $destination
		foreach_in_collection launch $source {
			if {[get_clock_info -name $launch] eq [get_clock_info -name $destination]} {
				post_message -type info "Framework $label is same-clock: no exception"
			} else {
				bound $label [get_clocks [list [get_clock_info -name $launch]]] $sink $destination
			}
		}
	}
	proc install {} {
		variable clock_targets {}
		variable clock_cache {}
		foreach_in_collection clock [get_clocks -nowarn {*} ] {
			foreach_in_collection target [get_clock_info -targets $clock] {
				dict lappend clock_targets $target [get_clock_info -name $clock]
			}
		}
		set scaler [present {*scaler_config*|cfg_req* scaler_cfg_req* *ascal*|cfg_capture*}]
		set palette [present {*scaler_palette*|descriptor* *scaler_palette*|req_meta*}]
		set measurement [present {*video_calc*|*src_hold* *video_calc*|frame_gray_meta*}]
		set mode [present {*pll_hdmi_adj*|llena_meta* *pll_hdmi_adj*|llena_sync*}]
		if {!$scaler && !$palette && !$measurement && !$mode} { return }
		set sys_pattern {emu|pll|sys85_pll|*|divclk}
		if {[get_collection_size [get_clocks -nowarn $sys_pattern]] == 0} {
			set sys_pattern {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}
		}
		set sys [clock SYS $sys_pattern]
		if {$scaler || $palette || $measurement} {
			set hdmi [clock HDMI {pll_hdmi|pll_hdmi_inst|altera_pll_i|*[0].*|divclk}]
			set memory [clock CLK100 {*|h2f_user0_clk}]
		}
		if {$mode} {
			pair pll-mode {{} lowlat 0} {pll_hdmi_adj llena_meta 0} [clock PLL-MANAGEMENT {FPGA_CLK1_50}] $sys
		}
		set source_descriptor {scaler_config cfg_data 270 {scaler_cfg_data}}
		set source_request {scaler_config cfg_req 0 {scaler_cfg_req}}
		set scaler_ack {ascal cfg_ack_i 0 {scaler_cfg_ack}}
		if {$scaler} {
			if {!$palette} { error "Scaler descriptor has no palette completion owner" }
			pair scaler-descriptor $source_descriptor {ascal cfg_capture 270} $hdmi $sys
			pair scaler-request $source_request {ascal cfg_req_meta 0} $hdmi $sys
			pair scaler-ack $scaler_ack {scaler_config ack_meta 0} $sys $hdmi
			foreach {from to} {o_adrs avl_radrs o_read_base avl_read_base} {
				pair scaler-$from [list ascal $from 32] [list ascal $to 32] $memory $hdmi
			}
			pair scaler-read-request {ascal o_read 0} {ascal avl_read_sync 0} $memory $hdmi
			pair scaler-read-ack {ascal avl_readack 0} {ascal o_readack_sync 0} $hdmi $memory
			# A Gray completion advances no faster than one16-word burst on
			# CLK100. The HDMI-period bound includes clock latency/skew and is
			# tighter than that160ns spacing. Second stage and credit decode
			# remain ordinarily timed; stopped output clocks retain two credits.
			set completed [reg scaler-completion-source ascal avl_completed_gray 2]
			require_clock scaler-completion-source $completed $memory
			bound scaler-completion $completed \
				[reg scaler-completion-capture ascal o_completed_meta 2] $hdmi \
				[expr {16 * [get_clock_info -period $memory]}]
			# Completed native contexts and release ownership are held through
			# their request/ACK round trip. Decode after o_native_capture is
			# ordinary same-clock logic; no consumer/second-stage exception.
			pair native-context {ascal i_native_context 37} {ascal o_native_capture 37} $hdmi $sys
			pair native-request {ascal i_native_req 0} {ascal o_native_meta 0} $hdmi $sys
			pair native-ack {ascal o_native_ack 0} {ascal i_native_ack_meta 0} $sys $hdmi
			pair native-release {ascal o_native_release 3} {ascal i_native_release 3} $sys $hdmi
			pair native-refresh {ascal o_native_epoch 0} {ascal i_epoch_meta 0} $sys $hdmi
			pair native-refresh-ack {ascal i_epoch_seen 0} {ascal o_epoch_meta 0} $hdmi $sys
			pair native-stream {ascal o_native_stream 0} {ascal i_stream_meta 0} $sys $hdmi
			# A write's bank/address/staging-half stay fixed until its last
			# actual accepted beat, then the returned phase releases that half.
			foreach {from to width} {i_wadrs avl_wadrs 32 i_walt avl_walt 0 i_wbuf avl_wbuf 2} {
				pair native-write-$from [list ascal $from $width] [list ascal $to $width] $memory $sys
			}
			pair native-write-request {ascal i_write 0} {ascal avl_write_sync 0} $memory $sys
			pair native-write-retired {ascal avl_write_done 0} {ascal i_write_done_meta 0} $sys $memory
		}
		if {$palette} {
			if {!$scaler} { error "Palette completion has no scaler descriptor owner" }
			set audio [clock PALETTE {pll_audio|pll_audio_inst|altera_pll_i|*[0].*|divclk}]
			pair palette-descriptor $source_descriptor {scaler_palette descriptor 37} $audio $sys
			pair palette-request $source_request {scaler_palette req_meta 0} $audio $sys
			pair palette-ack $scaler_ack {scaler_palette ack_meta 0} $audio $hdmi
			pair palette-active {ascal cfg_initialized 0 {scaler_cfg_active}} {scaler_palette active_meta 0} $audio $hdmi
			first_clock palette-vsync $hdmi $audio {scaler_palette vs_meta 0}
			foreach {from to alias} {ready_tag pal_ready_meta scaler_pal_ready ready_valid pal_valid_meta scaler_pal_valid write_bank o_palette_bank scaler_pal_bank} {
				set aliases [list $alias]
				# Identical initialized, unreset WAIT_FRAME toggles merge in Q17.
				if {$from eq "write_bank"} { lappend aliases {*scaler_palette*|request} }
				pair palette-$from [list scaler_palette $from 0 $aliases] [list ascal $to 0] $hdmi $audio
			}
		}
		if {$measurement} {
			foreach {instance width destination origin alias} [list frame_transfer 170 $memory $sys frame_100 query_transfer 288 $sys $memory measurement_sys] {
				set stem "emu|hps_io|video_calc|$instance"
				pair measurement-$instance [list $stem src_hold $width] \
					[list $stem dst_data $width [list "*video_calc*|$alias"]] $destination $origin
				pair $instance-request [list $stem src_req 0] [list $stem req_meta 0] $destination $origin
				pair $instance-ack [list $stem dst_ack 0] [list $stem ack_meta 0] $origin $destination
			}
			set stem "emu|hps_io|video_calc"
			# The approved sequence advances on BOTH CE-qualified VS edges.
			# Conservatively allow an edge every SYS cycle, even without the
			# native4/17 CE spacing. Bound HIGH and LOW, never a frame period.
			set min_high [get_clock_info -period $sys]
			set min_low $min_high
			set gray_max [gray_budget $memory $min_high $min_low]
			set gray [reg measurement-gray-source $stem frame_gray_vid 32]
			require_clock measurement-gray-source $gray $sys
			bound measurement-gray $gray \
				[reg measurement-gray-capture $stem frame_gray_meta 32] $memory $gray_max
			post_message -type info "Framework Gray both-edge: minimum HIGH $min_high ns LOW $min_low ns; numeric route budget $gray_max ns"
			# Quartus17 numeric max-delay includes clock insertion/uncertainty.
			# Physical admission must check actual arrival spread/raw routing
			# against BOTH intervals; this is not a datapath_only/skew report.
			# frame_gray_sync, last_event_100, event_join and assembly stay timed.
			foreach input {vs hs de} {
				first_clock measurement-$input $sys $memory [list $stem "timing_counter.${input}_meta" 0]
			}
			# HDMI_TX_VS also has a direct-video source; retain both clock paths.
			set video_clocks [get_clocks [list [get_clock_info -name $sys] [get_clock_info -name $hdmi]]]
			first_clock measurement-hdmi-vs $video_clocks $memory [list $stem hdmi_counter.vs_meta 0]
			foreach input {mode rotated} {
				if {[present "*video_calc*|${input}_meta*"]} {
					first_clock measurement-$input $sys $sys [list $stem "${input}_meta" 0]
				} else { post_message -type info "Framework measurement $input is an absent optional constant in Plex" }
			}
		}
	}
	install
}
