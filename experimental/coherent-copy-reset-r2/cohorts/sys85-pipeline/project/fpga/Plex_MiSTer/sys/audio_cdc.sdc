# Only protocol-owned first captures. No local DSP, second-stage, or whole
# clock-pair exception. Numeric bounds retain clock latency/uncertainty.
namespace eval plex_runtime_audio_cdc {
	variable bindings {}
	proc remember {label from to kind} {
		variable bindings
		if {[dict exists $bindings $label]} { error "Audio CDC duplicate transfer $label" }
		set source_names {}; set capture_names {}
		foreach_in_collection node $from { lappend source_names [get_object_info -name $node] }
		foreach_in_collection node $to { lappend capture_names [get_object_info -name $node] }
		dict set bindings $label [list from $source_names to $capture_names kind $kind]
	}
	proc bit {label stem member width wanted} {
		set selected {}
		foreach_in_collection node [::plex_framework_cdc::reg $label $stem $member $width] {
			set name [get_object_info -name $node]
			if {![regexp {\[([0-9]+)\](~DUPLICATE[0-9]*)?$} $name ignored index]} {
				error "Audio CDC $label is not a vector register"
			}
			if {$index == $wanted} { lappend selected $name }
		}
		if {![llength $selected]} { error "Audio CDC $label required bit $wanted is absent" }
		return [get_registers $selected]
	}
	proc transfer {label from to origin destination maximum} {
		::plex_framework_cdc::require_clock $label-source $from $origin
		::plex_framework_cdc::bound $label $from $to $destination $maximum
		remember $label $from $to setup
	}
	proc gray_transfer {label stem member pointer capture origin destination maximum} {
		set sinks [::plex_framework_cdc::reg $label-capture $stem $capture 12]
		set sources {}; set bits {}
		foreach_in_collection sink $sinks {
			set name [get_object_info -name $sink]
			regexp {\[([0-9]+)\](~DUPLICATE[0-9]*)?$} $name ignored index
			lappend bits $index
			set fanins [get_fanins -synch [list $name]]
			if {[get_collection_size $fanins] != 1} {
				error "Audio CDC $label bit $index has non-direct/ambiguous data ownership"
			}
			foreach_in_collection source $fanins {
				set physical [get_object_info -name $source]
				set normal [::plex_framework_cdc::normalize $physical]
				regsub {~DUPLICATE[0-9]*$} $normal {} normal
				set expected "${stem}|${member}\[$index\]"
				# Gray[AW] == binary[AW]. Q17 can merge just this bit;
				# prove the actual direct D fan-in rather than guessing an alias.
				set upper "${stem}|${pointer}\[11\]"
				if {$normal ne $expected && !($index == 11 && $normal eq $upper)} {
					error "Audio CDC $label unexpected bit $index data source $physical"
				}
				lappend sources $physical
			}
		}
		if {[lsort -integer -unique $bits] ne {0 1 2 3 4 5 6 7 8 9 10 11}} {
			error "Audio CDC $label has missing/constant Gray capture bits"
		}
		set sources [lsort -unique $sources]
		set from [get_registers $sources]
		if {[get_collection_size $from] != [llength $sources]} {
			error "Audio CDC $label contains non-register Gray ownership"
		}
		post_message -type info "Framework CDC $label-source: logical width 12; retained bits [lsort -integer -unique $bits]; physical registers $sources"
		transfer $label $from $sinks $origin $destination $maximum
	}
	proc reset_landing {label stem member destination maximum} {
		set sinks [::plex_framework_cdc::reg $label-capture $stem $member 2]
		set names {}
		foreach_in_collection sink $sinks {
			foreach_in_collection source [get_fanins -asynch [list [get_object_info -name $sink]]] {
				lappend names [get_object_info -name $source]
			}
		}
		set names [lsort -unique $names]
		if {![llength $names]} { error "Audio CDC $label has no actual asynchronous reset driver" }
		set sources [get_keepers $names]
		if {[get_collection_size $sources] != [llength $names]} {
			error "Audio CDC $label reset driver collection is incomplete"
		}
		# Both reset-synchronizer async pins take assertion. Their D/Q chain
		# remains local and timed: none of its registers is a reset driver.
		foreach_in_collection sink $sinks {
			if {[get_object_info -name $sink] in $names} {
				error "Audio CDC $label reset driver includes its local release pipeline"
			}
		}
		foreach_in_collection source $sources {
			if {[lsearch -exact $names [get_object_info -name $source]] < 0} {
				error "Audio CDC $label unexpected reset driver"
			}
		}
		::plex_framework_cdc::bound $label $sources $sinks $destination $maximum
		remember $label $sources $sinks recovery
		post_message -type info "Audio CDC $label asynchronous-only drivers: $names"
	}
	proc install {} {
		set sys_pattern {emu|pll|sys85_pll|*|divclk}
		if {[get_collection_size [get_clocks -nowarn $sys_pattern]] == 0} {
			set sys_pattern {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}
		}
		set sys [::plex_framework_cdc::clock AUDIO-SYS $sys_pattern]
		set audio [::plex_framework_cdc::clock AUDIO {pll_audio|pll_audio_inst|altera_pll_i|*[0].*|divclk}]
		set short [expr {min([get_clock_info -period $sys],[get_clock_info -period $audio])}]
		foreach {label from to width origin destination} [list \
			audio-controls src_hold dst_capture 180 $sys $audio \
			audio-request src_req req_meta 0 $sys $audio \
			audio-ack dst_ack ack_meta 0 $audio $sys] {
			transfer $label [::plex_framework_cdc::reg $label-source audio_config $from $width] \
				[::plex_framework_cdc::reg $label-capture audio_config $to $width] \
				$origin $destination [get_clock_info -period $destination]
		}
		reset_landing audio-reset audio_config reset_pipe $audio $short

		set stem emu|present|afifo
		if {![::plex_framework_cdc::present {*afifo*|wr_gray*}]} {
			error "Core audio FIFO ownership is absent"
		}
		foreach {label from pointer to origin destination} [list \
			fifo-write-gray wr_gray wr_ptr wr_gray_r1 $sys $audio \
			fifo-read-gray rd_gray rd_ptr rd_gray_w1 $audio $sys] {
			gray_transfer $label $stem $from $pointer $to $origin $destination $short
		}
		transfer fifo-has-write [::plex_framework_cdc::reg fifo-has-write-source $stem has_wr 0] \
			[::plex_framework_cdc::reg fifo-has-write-capture $stem has_wr_s1 0] $sys $audio $short
		foreach {label from to origin destination} [list \
			fifo-writer-ready wr_reset_pipe wr_up_r1 $sys $audio \
			fifo-reader-ready rd_reset_pipe rd_up_w1 $audio $sys] {
			transfer $label [bit $label-source $stem $from 2 1] \
				[::plex_framework_cdc::reg $label-capture $stem $to 0] $origin $destination $short
		}
		reset_landing fifo-write-reset $stem wr_reset_pipe $sys $short
		reset_landing fifo-read-reset $stem rd_reset_pipe $audio $short
		foreach {label from index} {audio-has-status has_wr_s2 0 audio-underrun-status underrun 1} {
			transfer $label [::plex_framework_cdc::reg $label-source $stem $from 0] \
				[bit $label-capture emu|present audio_status_s1 2 $index] $audio $sys $short
		}
	}
	install
}
