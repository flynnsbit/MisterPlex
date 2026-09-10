# Routed SYS85 first-hop corrections. All local release chains, second stages,
# data consumers, and ordinary same-clock setup/hold remain timed.
namespace eval plex_routed_cdc {
	proc pair {label stem source sink width origin destination} {
		::plex_framework_cdc::pair $label [list $stem $source $width] \
			[list $stem $sink $width] $destination $origin
	}
	proc tags {label source sink origin destination maximum} {
		set from {}; set to {}
		foreach {member role} [list $source from $sink to] {
			foreach_in_collection node [get_registers -nowarn "*fstore*|${member}*"] {
				set name [get_object_info -name $node]
				set canonical [::plex_framework_cdc::normalize $name]
				if {[regexp [format {^emu\|present\|fstore\|%s\[[0-9]+\]\[[0-9]+\](~DUPLICATE[0-9]*)?$} $member] $canonical]} {
					lappend $role $name
				}
			}
		}
		if {![llength $from] || ![llength $to]} { error "Routed tag $label has missing data registers" }
		set from [get_registers $from]; set to [get_registers $to]
		::plex_framework_cdc::require_clock $label-source $from $origin
		::plex_framework_cdc::bound $label $from $to $destination $maximum
	}
	proc scalar_reset {label stem first second destination} {
		set sinks [add_to_collection \
			[::plex_framework_cdc::reg $label-first $stem $first 0] \
			[::plex_framework_cdc::reg $label-second $stem $second 0]]
		set source [::plex_framework_cdc::reg $label-request {} reset_req 0]
		foreach_in_collection sink $sinks {
			set actual {}
			foreach_in_collection driver [get_fanins -asynch [list [get_object_info -name $sink]]] {
				lappend actual [get_object_info -name $driver]
			}
			set expected {}
			foreach_in_collection driver $source { lappend expected [get_object_info -name $driver] }
			if {[lsort $actual] ne [lsort $expected]} { error "Routed reset $label has unexpected assertion topology: $actual" }
		}
		::plex_framework_cdc::bound $label $source $sinks $destination
	}
	proc gray {label stem source binary sink origin destination maximum} {
		set captures [get_registers -nowarn [format {*%s*|%s[*]*} [lindex [split $stem |] end] $sink]]
		if {[get_collection_size $captures] == 0} { error "Routed Gray $label is absent" }
		set sources {}
		foreach_in_collection capture $captures {
			set name [get_object_info -name $capture]
			set normal [::plex_framework_cdc::normalize $name]
			regsub {~DUPLICATE[0-9]*$} $normal {} normal
			if {![regexp {\[([0-9]+)\]$} $normal ignored bit] ||
			    $normal ne "${stem}|${sink}\[$bit\]"} { error "Routed Gray $label ambiguous capture $name" }
			set matched {}
			foreach_in_collection node [get_fanins -synch [list $name]] {
				set n [get_object_info -name $node]
				set canonical [::plex_framework_cdc::normalize $n]
				regsub {~DUPLICATE[0-9]*$} $canonical {} canonical
				if {$canonical eq "${stem}|${source}\[$bit\]" ||
				    $canonical eq "${stem}|${binary}\[$bit\]"} { lappend matched $n }
			}
			if {![llength $matched]} { error "Routed Gray $label bit $bit lacks a data owner: $matched" }
			lappend sources {*}$matched
		}
		set sources [get_registers [lsort -unique $sources]]
		::plex_framework_cdc::require_clock $label-source $sources $origin
		::plex_framework_cdc::bound $label $sources $captures $destination $maximum
	}
	proc install {} {
		set sys [::plex_framework_cdc::clock ROUTED-SYS {emu|pll|sys85_pll|*|divclk}]
		set ddr [::plex_framework_cdc::clock ROUTED-DDR {emu|pll|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}]
		set audio [::plex_framework_cdc::clock ROUTED-AUDIO {pll_audio|pll_audio_inst|altera_pll_i|*[0].*|divclk}]
		set hdmi [::plex_framework_cdc::clock ROUTED-HDMI {pll_hdmi|pll_hdmi_inst|altera_pll_i|*[0].*|divclk}]
		set memory [::plex_framework_cdc::clock ROUTED-MEMORY {*|h2f_user0_clk}]
		set shortest [expr {min([get_clock_info -period $sys],[get_clock_info -period $ddr])}]
		# The asynchronous assertion network terminates at these two-stage
		# release synchronizers only. Numeric recovery is bounded; nearest-
		# edge removal is inapplicable to their asynchronous assertion pins.
		# Their Q->D chains and Q->consumer release timing are not excluded.
		foreach {label stem member clock} [list \
			root-reset emu reset_sys_sync $sys \
			mixer-reset {} mpx_audio_reset_sync $audio \
			scaler-source-reset {} scaler_reset_sync $sys] {
			::plex_runtime_audio_cdc::reset_landing $label $stem $member $clock \
				[expr {min([get_clock_info -period $sys],[get_clock_info -period $clock])}]
		}
		scalar_reset scaler-input-reset ascal i_reset_meta i_reset_na $sys
		scalar_reset scaler-output-reset ascal o_reset_meta o_reset_na $hdmi
		# Avalon state intentionally survives reset in CONFIG_HANDSHAKE mode;
		# do not require or cut optimized-away Avalon reset synchronizers.
		::plex_framework_cdc::pair scaler-output-enable {{} scaler_out 0} \
			{{} scaler_out_meta 0} $hdmi $sys

		set stem emu|present|fstore
		set first [::plex_framework_cdc::reg fstore-reset-first $stem reset_ddr_s1 0]
		set second [::plex_framework_cdc::reg fstore-reset-second $stem reset_ddr_s2 0]
		set request [::plex_runtime_audio_cdc::bit fstore-reset-source emu reset_sys_sync 2 1]
		set landings [add_to_collection $first $second]
		foreach_in_collection sink $landings {
			set drivers {}
			foreach_in_collection driver [get_fanins -asynch [list [get_object_info -name $sink]]] {
				lappend drivers [get_object_info -name $driver]
			}
			if {[llength $drivers] != 1 || [get_object_info -name $request] ne [lindex $drivers 0]} {
				error "Fstore reset assertion owner changed: $drivers"
			}
		}
		::plex_framework_cdc::bound fstore-reset $request $landings $ddr $shortest
		foreach {source sink width} {
			pending_ready_ddr pending_ready_s1 0
			pending_ready_id_ddr pending_ready_id_s1 0
			swap_req_t_ddr swap_req_s1 0
			pending_bank_ddr pending_bank_s1 0
			generation_ack generation_ack_s1 0
			generation_start generation_start_s1 0
			status_osd_tog_seen status_osd_ack_meta 0
			status_osd_ddr_ready status_osd_ready_meta 0
		} { pair fstore-$sink $stem $source $sink $width $ddr $sys }
		foreach {source sink width} {
			pending_bank pending_bank_d1 0
			pending_crop_top pending_top_d1 16
			disp_bank disp_bank_d1 0
			disp_buf disp_buf_d1 0
			has_frame has_frame_d1 0
			swap_pending swap_pending_d1 0
			generation_req generation_req_d1 0
			vsync_toggle vsync_t_d1 0
			status_osd_toggle status_osd_tog_s1 0
			status_osd_hold status_osd_safe 16
		} { pair fstore-$sink $stem $source $sink $width $sys $ddr }
		::plex_framework_cdc::pair fstore-start-request \
			{emu|g_fpga_publish.publisher swap_toggle 0} \
			[list $stem start_d1 0] $ddr $sys
		gray fstore-beam $stem want_y_gray unused_binary want_y_gray_s1 $sys $ddr $shortest
		# Cache tags precede visibility through the existing valid synchronizer;
		# bound their first capture, not the local tag comparators/second stage.
		tags fstore-y-tags y_line y_line_v1 $ddr $sys $shortest
		tags fstore-c-tags c_line c_line_v1 $ddr $sys $shortest
		foreach {source sink} {y_valid y_valid_v1 c_valid c_valid_v1 y_bank y_bank_v1 c_bank c_bank_v1} {
			pair fstore-$sink $stem $source $sink 32 $ddr $sys
		}
		foreach {source sink width} {ack_x plxj_x 12 ack_y plxj_y 12 ack_token plxj_token 8} {
			::plex_framework_cdc::pair fstore-$sink [list $stem|u_plxa $source $width] \
				[list $stem $sink $width] $ddr $sys
		}
		foreach fifo {emu|present|fstore|input_fifo emu|ddr_arb|g_held.m1_responses emu|ddr_arb|g_held.m1_commands} {
			# Response writers are DDR and readers SYS; input FIFO is opposite.
			set wr $ddr; set rd $sys
			if {$fifo ne "emu|ddr_arb|g_held.m1_responses"} { set wr $sys; set rd $ddr }
			gray $fifo-write $fifo wr_gray wr_bin wr_gray_r1 $wr $rd $shortest
			gray $fifo-read $fifo rd_gray rd_bin rd_gray_w1 $rd $wr $shortest
		}
	}
	install
}
