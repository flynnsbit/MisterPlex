# Specify root clocks
create_clock -period "50.0 MHz"  [get_ports FPGA_CLK1_50]
create_clock -period "50.0 MHz"  [get_ports FPGA_CLK2_50]
create_clock -period "50.0 MHz"  [get_ports FPGA_CLK3_50]
create_clock -period "100.0 MHz" [get_pins -compatibility_mode *|h2f_user0_clk] 
create_clock -period "100.0 MHz" [get_pins -compatibility_mode spi|sclk_out] -name spi_sck
create_clock -period "10.0 MHz"  [get_pins -compatibility_mode hdmi_i2c|out_clk] -name hdmi_sck

derive_pll_clocks
derive_clock_uncertainty

# Preserve the inherited cuts EXCEPT the actual protocol clock pairs below.
# Clock-group cuts outrank numeric max delays. Leaving these pairs in the old
# blanket grouping would silently mask the dedicated bounds in Plex.sdc.
# No formerly timed clock pair is cut here; other newly exposed paths in these
# pairs remain ordinary timed paths and must be accounted for by the new fit.
namespace eval plex_framework_clock_groups {
   proc install {} {
   set patterns [list \
      {*|pll|pll_inst|altera_pll_i|*[*].*|divclk} \
      {pll_hdmi|pll_hdmi_inst|altera_pll_i|*[0].*|divclk} \
      {pll_audio|pll_audio_inst|altera_pll_i|*[0].*|divclk} \
      {spi_sck} {hdmi_sck} {*|h2f_user0_clk} \
      {FPGA_CLK1_50} {FPGA_CLK2_50} {FPGA_CLK3_50}]
   set groups {}
   set membership {}
   foreach pattern $patterns {
      set names {}
      foreach_in_collection clock [get_clocks -nowarn $pattern] {
         lappend names [get_clock_info -name $clock]
         set name [get_clock_info -name $clock]
         if {[dict exists $membership $name]} { error "Inherited clock groups overlap: $name" }
         dict set membership $name 1
      }
      lappend groups $names
   }
   set sys [get_clocks -nowarn {emu|pll|sys85_pll|*|divclk}]
   if {[get_collection_size $sys] == 0} {
      set sys [get_clocks -nowarn {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
   }
   foreach {area pattern} {
      scaler {*scaler_config*|cfg_req* *ascal*|cfg_req_meta*}
      palette {*scaler_palette*|ready_tag* *scaler_palette*|req_meta*}
      measurement {*video_calc*|*src_req* *video_calc*|*req_meta*}
      mode {*pll_hdmi_adj*|llena_meta*}
      audio {*|audio_session|snapshot_capture* *|audio_session_mailbox:audio_session|snapshot_capture* *audio_config*|src_req*}
   } {
      set enabled($area) [expr {[get_collection_size [get_registers -nowarn $pattern]] != 0}]
   }
   if {[get_collection_size $sys] > 1 ||
       (($enabled(scaler) || $enabled(palette) || $enabled(measurement) || $enabled(mode) || $enabled(audio)) &&
        [get_collection_size $sys] != 1)} {
      error "Framework protocol system clock is missing or ambiguous"
   }
   set opened {}
   if {[get_collection_size $sys] == 1} {
      set sys_name [get_clock_info -name $sys]
      foreach group_index {1 2 5 6} {
         if {$group_index == 1 && !$enabled(scaler)} { continue }
         if {$group_index == 2 && !$enabled(palette) && !$enabled(audio)} { continue }
         if {$group_index == 5 && !$enabled(measurement)} { continue }
         if {$group_index == 6 && !$enabled(mode)} { continue }
         foreach other [lindex $groups $group_index] {
            dict set opened [lsort [list $sys_name $other]] 1
         }
      }
   }
   foreach hdmi [lindex $groups 1] {
      foreach group_index {2 5} {
         if {$group_index == 2 && !$enabled(palette)} { continue }
         if {$group_index == 5 && !$enabled(scaler) && !$enabled(measurement)} { continue }
         foreach other [lindex $groups $group_index] {
            dict set opened [lsort [list $hdmi $other]] 1
         }
      }
   }
   for {set i 0} {$i < [llength $groups]} {incr i} {
      for {set j [expr {$i+1}]} {$j < [llength $groups]} {incr j} {
         foreach left [lindex $groups $i] {
            foreach right [lindex $groups $j] {
               if {[dict exists $opened [lsort [list $left $right]]]} {
                  post_message -type info "Framework protocol pair LEFT TIMED: $left <-> $right"
               } else {
                  set_clock_groups -exclusive -group [get_clocks [list $left]] -group [get_clocks [list $right]]
               }
            }
         }
      }
   }
   }
   install
}

set_false_path -from [get_ports {KEY*}]
set_false_path -from [get_ports {BTN_*}]
set_false_path -to   [get_ports {LED_*}]
set_false_path -to   [get_ports {VGA_*}]
set_false_path -from [get_ports {VGA_EN}]
set_false_path -to   [get_ports {AUDIO_SPDIF}]
set_false_path -to   [get_ports {AUDIO_L}]
set_false_path -to   [get_ports {AUDIO_R}]
set_false_path -from {get_ports {SW[*]}}
set_false_path -to   {cfg[*]}
set legacy_cfg {}
foreach_in_collection node [get_registers -nowarn {cfg[*]}] {
   set name [get_object_info -name $node]
   if {![regexp {(^|\|)cfg\[6\](~DUPLICATE[0-9]*)?$} $name]} { lappend legacy_cfg $name }
}
if {[llength $legacy_cfg]} { set_false_path -from [get_registers $legacy_cfg] }
set_false_path -to   {deb_* btn_en btn_up}

set_multicycle_path -to {*_osd|osd_vcnt*} -setup 2
set_multicycle_path -to {*_osd|osd_vcnt*} -hold 1

set_false_path -to   {*_osd|v_cnt*}
set_false_path -to   {*_osd|v_osd_start*}
set_false_path -to   {*_osd|v_info_start*}
set_false_path -to   {*_osd|h_osd_start*}
set_false_path -from {*_osd|v_osd_start*}
set_false_path -from {*_osd|v_info_start*}
set_false_path -from {*_osd|h_osd_start*}
set_false_path -from {*_osd|rot*}
set_false_path -from {*_osd|dsp_width*}
set_false_path -to   {*_osd|half}

set_false_path -to   {FB_BASE[*] FB_BASE[*] FB_WIDTH[*] FB_HEIGHT[*] LFB_HMIN[*] LFB_HMAX[*] LFB_VMIN[*] LFB_VMAX[*]}
set_false_path -from {FB_BASE[*] FB_BASE[*] FB_WIDTH[*] FB_HEIGHT[*] LFB_HMIN[*] LFB_HMAX[*] LFB_VMIN[*] LFB_VMAX[*]}
set_false_path -to   {vol_att[*] led_overtake[*] led_state[*]}
set_false_path -from {led_overtake[*] led_state[*]}
set_false_path -from {vs_line*}
set_false_path -from {ColorBurst_Range* PhaseInc* pal_en cvbs yc_en}

# Legacy live-input metadata is asynchronous only without descriptor capture.
# Handshake-mode consumers are local HDMI logic after the bounded capture.
if {[get_collection_size [get_registers -nowarn {*ascal*|cfg_capture*}]] == 0} {
set_false_path -from {ascal|o_ihsize*}
set_false_path -from {ascal|o_ivsize*}
set_false_path -from {ascal|o_format*}
set_false_path -from {ascal|o_hdown}
set_false_path -from {ascal|o_vdown}
set_false_path -from {ascal|o_hmin* ascal|o_hmax* ascal|o_vmin* ascal|o_vmax* ascal|o_vrrmax* ascal|o_vrr}
set_false_path -from {ascal|o_hdisp* ascal|o_vdisp*}
set_false_path -from {ascal|o_htotal* ascal|o_vtotal*}
set_false_path -from {ascal|o_hsstart* ascal|o_vsstart* ascal|o_hsend* ascal|o_vsend*}
set_false_path -from {ascal|o_hsize* ascal|o_vsize*}
}

set_false_path -from {mcp23009|flg_*}
set_false_path -to   {sysmem|fpga_interfaces|clocks_resets|f2h*}
