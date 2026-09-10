derive_pll_clocks
derive_clock_uncertainty

# core specific constraints

# MACT/MAST are held buses, not free-running transfers on every clock edge.
# Both receivers wait for two toggle synchronizers before capturing payload;
# the sender cannot replace it until a returned acknowledgement/new request.
# Bound routing by ONE destination period, reserving the second complete
# period for clock insertion/uncertainty and receiver setup. The independent
# clocks' nearest-edge hold relation is not the protocol's capture/hold edge.
# Only the first synchronizers and dedicated held-bus capture registers are
# exempt from that hold relation. Second synchronizer stages remain timed.
namespace eval plex_audio_cdc {
	proc registers {patterns expression} {
		set names {}
		foreach_in_collection node [get_registers -nowarn $patterns] {
			set name [get_object_info -name $node]
			if {[regexp $expression $name]} { lappend names $name }
		}
		if {[llength $names] == 0} { error "MACT/MAST CDC register selection is empty: $expression" }
		return [get_registers $names]
	}
	proc crossing {name from to clock} {
		if {[get_collection_size $clock] != 1} { error "MACT/MAST destination clock is not unique: $name" }
		set period [get_clock_info -period $clock]
		if {$period <= 0} { error "MACT/MAST clock period is invalid: $name" }
		set_max_delay -from $from -to $to $period
		set_false_path -hold -from $from -to $to
		post_message -type info "MACT/MAST CDC $name: [get_collection_size $from] sources, [get_collection_size $to] captures, max $period ns"
	}
	set sys [get_clocks -nowarn {emu|pll|sys85_pll|*|divclk}]
	set sys85 [expr {[get_collection_size $sys] != 0}]
	if {!$sys85} {
		set sys [get_clocks -nowarn {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
	}
	set audio [get_clocks -nowarn {pll_audio|pll_audio_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
	set present [get_registers -nowarn {*|audio_session|snapshot_capture* *|audio_session_mailbox:audio_session|snapshot_capture*}]
	set command_present [get_registers -nowarn {audio_ctrl_data* *|audio_session|audio_ctrl_data*}]
	if {[get_collection_size $command_present] != 0 || [get_collection_size $present] != 0} {
		set command [registers {audio_ctrl_data* *|audio_session|audio_ctrl_data*} {(^|\|)audio_ctrl_data\[[0-9]+\](~.*)?$}]
		set capture [registers {*|g_session.command*} {\|g_session\.command\[[0-9]+\](~.*)?$}]
		crossing command $command $capture $audio
		set snapshot [registers {*|g_session.snapshot*} {\|g_session\.snapshot\[[0-9]+\](~.*)?$}]
		set capture [registers {*|audio_session|snapshot_capture* *|audio_session_mailbox:audio_session|snapshot_capture*} {\|snapshot_capture\[[0-9]+\](~.*)?$}]
		crossing snapshot $snapshot $capture $sys
		foreach {name source source_re sink sink_re clock} [list \
			command-request {audio_ctrl_toggle* *|audio_session|audio_ctrl_toggle*} {(^|\|)audio_ctrl_toggle(~.*)?$} {*|g_session.ctrl_s1*} {\|g_session\.ctrl_s1(~.*)?$} $audio \
			snapshot-request {audio_snapshot_toggle* *|audio_session|audio_snapshot_toggle*} {(^|\|)audio_snapshot_toggle(~.*)?$} {*|g_session.snapshot_s1*} {\|g_session\.snapshot_s1(~.*)?$} $audio \
			command-ack {*|g_session.ctrl_ack*} {\|g_session\.ctrl_ack(~.*)?$} {*|audio_session|ack_s1*} {\|ack_s1(~.*)?$} $sys \
			snapshot-ack {*|g_session.snapshot_ack*} {\|g_session\.snapshot_ack(~.*)?$} {*|audio_session|snap_s1*} {\|snap_s1(~.*)?$} $sys] {
			crossing $name [registers $source $source_re] [registers $sink $sink_re] $clock
		}
	}
}
