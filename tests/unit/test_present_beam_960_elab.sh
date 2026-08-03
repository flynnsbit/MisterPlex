#!/usr/bin/env bash
# Red/green: PRESENT_BEAM_960 + FRAME 960x540 must elaborate (default OFF).
# Catches constants-only false fit claims (rd-duck): beam+timing must be in tree.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  echo "SKIP-NOT-PASS: Verilator missing" >&2
  exit 77
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed" >&2
  exit "$VERILATOR_RC"
fi

RTL="$ROOT/fpga/Plex_MiSTer/rtl"
PC="$RTL/present_core.sv"
# RED structural: timing alone is NOT a raster generator / fit candidate.
if ! grep -q "present_beam_content_de" "$PC"; then
  echo "FAIL RED: present_core missing present_beam_content_de instance path"
  exit 1
fi
if ! grep -q "PRESENT_BEAM_960" "$PC"; then
  echo "FAIL RED: PRESENT_BEAM_960 path missing"
  exit 1
fi
if ! grep -q "present_video_timing_960.sv" "$ROOT/fpga/Plex_MiSTer/files.qip"; then
  echo "FAIL RED: files.qip missing present_video_timing_960.sv"
  exit 1
fi
if ! grep -q "present_beam_content_de.sv" "$ROOT/fpga/Plex_MiSTer/files.qip"; then
  echo "FAIL RED: files.qip missing present_beam_content_de.sv"
  exit 1
fi
# B2b: timing_960 is math-only; beam is sole raster SoT in present_core
if ! grep -qE "NOT a raster generator|CONSTANT / MATH|math-only|not a generator" \
    "$RTL/present_video_timing_960.sv"; then
  echo "FAIL RED: timing_960 missing demotion/math-only banner"
  exit 1
fi
if grep -qE "u_timing_960|present_video_timing_960[[:space:]]*#\(" "$PC"; then
  echo "FAIL RED: present_core still instantiates timing_960 (dual SoT)"
  exit 1
fi
if ! grep -q "u_beam_960" "$PC"; then
  echo "FAIL RED: present_core missing u_beam_960 raster SoT"
  exit 1
fi
if ! grep -q "B2b RASTER SOURCE OF TRUTH" "$RTL/present_beam_content_de.sv"; then
  echo "FAIL RED: beam missing B2b SoT banner"
  exit 1
fi
# Template 529 remains on default path
if ! grep -qE "localparam[[:space:]]+H_DE[[:space:]]*=[[:space:]]*10'd529" "$PC"; then
  echo "FAIL RED: Template H_DE=529 missing on non-BEAM path"
  exit 1
fi
# B13: runtime DE driven from content_w/h (not fixed 960 bind-only)
if ! grep -q "use_rt_geom(1'b1)" "$PC"; then
  echo "FAIL RED B13: present_core must drive use_rt_geom(1'b1)"
  exit 1
fi
if ! grep -q "input  wire \[10:0\] content_w" "$PC"; then
  echo "FAIL RED B13: present_core missing content_w port"
  exit 1
fi
if grep -q "use_rt_geom(1'b0)" "$PC"; then
  echo "FAIL RED B13: use_rt_geom still tied off"
  exit 1
fi
echo "OK beam960_elab structural markers"

BUILD="$ROOT/build/verilator/present_beam960_elab"
mkdir -p "$BUILD"
WRAP="$BUILD/wrap.sv"
cat > "$WRAP" << 'SV'
module wrap;
  reg clk=0, clk_sdram=0, clk_audio=0, reset=1, clk_ddr=0;
  wire ce_pix, HBlank, HSync, VBlank, VSync;
  wire [7:0] r,g,b;
  wire [15:0] al,ar;
  wire [31:0] s1,s2,s3;
  wire s4,s5,s6,s7;
  wire [15:0] s8;
  wire [7:0] s9;
  wire [15:0] dfd;
  wire ddo;
  wire [7:0] DBC;
  wire [28:0] DA;
  wire DR, DW;
  wire [63:0] DD;
  wire [7:0] DBE;
  wire DCLK;
  // Fit macro set: BEAM_960 + store 960x540 (ascal-native first fit)
  present_core #(.FRAME_W(960), .FRAME_H(540), .FRAME_STRIDE(960), .FRAME_LINE_COUNT(8)) u (
    .clk(clk), .clk_sdram(clk_sdram), .clk_audio(clk_audio), .clk_pix(clk), .reset(reset),
    .pal(1'b0), .scandouble(1'b0), .content_fps(8'd30), .display_hz(8'd60),
    .pattern(2'd0), .audio_en(1'b0), .use_frame_store(1'b0),
    .content_w(11'd960), .content_h(11'd540),
    .fs_wr_en(1'b0), .fs_wr_pixel(16'd0), .fs_wr_reset(1'b0), .fs_swap(1'b0), .fs_wr_ready(),
    .sdram_dout(16'd0), .sdram_ready(1'b0), .sdram_sel(), .sdram_addr(), .sdram_din(),
    .sdram_wr(), .sdram_rd(), .sdram_bs(), .sdram_refresh(),
    .ddr_start_req(1'b0), .ddr_bank_sel(1'b0), .ddr_status_osd(16'd0),
    .ddr_input_cmd_valid(1'b0), .ddr_input_cmd(8'd0),
    .ddr_sdram_test_state(4'd0), .ddr_sdram_size_code(4'd0), .ddr_sdram_error_count(16'd0),
    .clk_ddr(clk_ddr), .DDRAM_CLK(DCLK), .DDRAM_BUSY(1'b0), .DDRAM_BURSTCNT(DBC),
    .DDRAM_ADDR(DA), .DDRAM_DOUT(64'd0), .DDRAM_DOUT_READY(1'b0), .DDRAM_RD(DR),
    .DDRAM_DIN(DD), .DDRAM_BE(DBE), .DDRAM_WE(DW),
    .ddr_frames_done(dfd), .ddr_doorbell_ok(ddo),
    .af_wr_en(1'b0), .af_wr_data(32'd0), .af_wr_flush(1'b0),
    .ce_pix(ce_pix), .HBlank(HBlank), .HSync(HSync), .VBlank(VBlank), .VSync(VSync),
    .r(r), .g(g), .b(b), .audio_l(al), .audio_r(ar),
    .stat_display_index(s1), .stat_content_index(s2), .stat_advance(s4),
    .stat_has_frame(s5), .stat_wr_count(s3), .stat_has_audio(s6),
    .stat_audio_underrun(s7), .stat_swap_pending(), .stat_frame_underruns(s8),
    .stat_frame_sdram_state(s9)
  );
endmodule
SV

COMMON=(
  --cc --build --no-timing
  -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-UNOPTFLAT -Wno-PINMISSING
  -Wno-INITIALDLY -Wno-BLKANDNBLK
  -DDDR_FRAME_STORE
  -I"$RTL" -I"$ROOT/fpga/Plex_MiSTer"
  --top-module wrap
  "$WRAP"
  "$RTL/present_core.sv" "$RTL/present_cadence.sv" "$RTL/colorbars.sv"
  "$RTL/ddr_frame_store.sv" "$RTL/frame_store.sv"
  "$RTL/present_video_timing_960.sv" "$RTL/present_beam_content_de.sv"
  "$RTL/present_video_timing_720p.sv" "$RTL/present_npx_path.sv"
  "$RTL/present_beam_ppc.sv" "$RTL/present_pix_rate_match.sv"
  "$RTL/yuv_bt601_npx.sv" "$RTL/async_fifo.sv" "$RTL/line_buf_ram.sv"
  "$RTL/audio_fifo.sv" "$RTL/audio_tone.sv"
)

# GREEN: BEAM_960 ON + 960x540
GBUILD="$BUILD/green"
mkdir -p "$GBUILD"
set +e
"$RUN_VERILATOR" "${COMMON[@]}" \
  -DPRESENT_BEAM_960 \
  -Mdir "$GBUILD" >"$GBUILD/log.txt" 2>&1
GRC=$?
set -e
if [[ "$GRC" -ne 0 ]]; then
  echo "FAIL beam960_elab GREEN rc=$GRC"
  tail -60 "$GBUILD/log.txt"
  exit 1
fi
echo "OK beam960_elab GREEN rc=0"

# RED: wrong FRAME size must $error (Verilator treats as error)
RBUILD="$BUILD/red_frame"
mkdir -p "$RBUILD"
cat > "$RBUILD/wrap_bad.sv" << 'SV'
module wrap;
  reg clk=0, clk_sdram=0, clk_audio=0, reset=1, clk_ddr=0;
  wire ce_pix, HBlank, HSync, VBlank, VSync;
  wire [7:0] r,g,b;
  wire [15:0] al,ar;
  wire [31:0] s1,s2,s3;
  wire s4,s5,s6,s7;
  wire [15:0] s8;
  wire [7:0] s9;
  wire [15:0] dfd;
  wire ddo;
  wire [7:0] DBC;
  wire [28:0] DA;
  wire DR, DW;
  wire [63:0] DD;
  wire [7:0] DBE;
  wire DCLK;
  present_core #(.FRAME_W(640), .FRAME_H(480), .FRAME_STRIDE(640), .FRAME_LINE_COUNT(8)) u (
    .clk(clk), .clk_sdram(clk_sdram), .clk_audio(clk_audio), .clk_pix(clk), .reset(reset),
    .pal(1'b0), .scandouble(1'b0), .content_fps(8'd30), .display_hz(8'd60),
    .pattern(2'd0), .audio_en(1'b0), .use_frame_store(1'b0),
    .content_w(11'd960), .content_h(11'd540),
    .fs_wr_en(1'b0), .fs_wr_pixel(16'd0), .fs_wr_reset(1'b0), .fs_swap(1'b0), .fs_wr_ready(),
    .sdram_dout(16'd0), .sdram_ready(1'b0), .sdram_sel(), .sdram_addr(), .sdram_din(),
    .sdram_wr(), .sdram_rd(), .sdram_bs(), .sdram_refresh(),
    .ddr_start_req(1'b0), .ddr_bank_sel(1'b0), .ddr_status_osd(16'd0),
    .ddr_input_cmd_valid(1'b0), .ddr_input_cmd(8'd0),
    .ddr_sdram_test_state(4'd0), .ddr_sdram_size_code(4'd0), .ddr_sdram_error_count(16'd0),
    .clk_ddr(clk_ddr), .DDRAM_CLK(DCLK), .DDRAM_BUSY(1'b0), .DDRAM_BURSTCNT(DBC),
    .DDRAM_ADDR(DA), .DDRAM_DOUT(64'd0), .DDRAM_DOUT_READY(1'b0), .DDRAM_RD(DR),
    .DDRAM_DIN(DD), .DDRAM_BE(DBE), .DDRAM_WE(DW),
    .ddr_frames_done(dfd), .ddr_doorbell_ok(ddo),
    .af_wr_en(1'b0), .af_wr_data(32'd0), .af_wr_flush(1'b0),
    .ce_pix(ce_pix), .HBlank(HBlank), .HSync(HSync), .VBlank(VBlank), .VSync(VSync),
    .r(r), .g(g), .b(b), .audio_l(al), .audio_r(ar),
    .stat_display_index(s1), .stat_content_index(s2), .stat_advance(s4),
    .stat_has_frame(s5), .stat_wr_count(s3), .stat_has_audio(s6),
    .stat_audio_underrun(s7), .stat_swap_pending(), .stat_frame_underruns(s8),
    .stat_frame_sdram_state(s9)
  );
endmodule
SV
set +e
"$RUN_VERILATOR" --cc --build --no-timing \
  -Wno-WIDTH -Wno-UNUSED -Wno-UNOPTFLAT -Wno-PINMISSING \
  -Wno-INITIALDLY -Wno-BLKANDNBLK \
  -DDDR_FRAME_STORE -DPRESENT_BEAM_960 \
  -I"$RTL" -I"$ROOT/fpga/Plex_MiSTer" \
  --top-module wrap \
  "$RBUILD/wrap_bad.sv" \
  "$RTL/present_core.sv" "$RTL/present_cadence.sv" "$RTL/colorbars.sv" \
  "$RTL/ddr_frame_store.sv" "$RTL/frame_store.sv" \
  "$RTL/present_video_timing_960.sv" "$RTL/present_beam_content_de.sv" \
  "$RTL/present_video_timing_720p.sv" "$RTL/present_npx_path.sv" \
  "$RTL/present_beam_ppc.sv" "$RTL/present_pix_rate_match.sv" \
  "$RTL/yuv_bt601_npx.sv" "$RTL/async_fifo.sv" "$RTL/line_buf_ram.sv" \
  "$RTL/audio_fifo.sv" "$RTL/audio_tone.sv" \
  -Mdir "$RBUILD" >"$RBUILD/log.txt" 2>&1
RRC=$?
set -e
# Expect fail: $error on FRAME size OR run_verilator HARD FAIL on %Error
if [[ "$RRC" -eq 0 ]] && ! grep -qE '%Error|PRESENT_BEAM_960 requires' "$RBUILD/log.txt"; then
  echo "FAIL RED_FRAME should not pass silently"
  tail -20 "$RBUILD/log.txt"
  exit 1
fi
echo "OK beam960_elab RED_FRAME rc=$RRC (expect non-zero or %Error)"

# Default path (macro OFF) still elaborates with 640x480
DBUILD="$BUILD/default"
mkdir -p "$DBUILD"
# reuse multi-pixel wrap style with 640 and no BEAM
cat > "$DBUILD/wrap.sv" << 'SV'
module wrap;
  reg clk=0, clk_sdram=0, clk_audio=0, reset=1, clk_ddr=0;
  wire ce_pix, HBlank, HSync, VBlank, VSync;
  wire [7:0] r,g,b;
  wire [15:0] al,ar;
  wire [31:0] s1,s2,s3;
  wire s4,s5,s6,s7;
  wire [15:0] s8;
  wire [7:0] s9;
  wire [15:0] dfd;
  wire ddo;
  wire [7:0] DBC;
  wire [28:0] DA;
  wire DR, DW;
  wire [63:0] DD;
  wire [7:0] DBE;
  wire DCLK;
  present_core #(.FRAME_W(640), .FRAME_H(480), .FRAME_STRIDE(640), .FRAME_LINE_COUNT(8)) u (
    .clk(clk), .clk_sdram(clk_sdram), .clk_audio(clk_audio), .clk_pix(clk), .reset(reset),
    .pal(1'b0), .scandouble(1'b1), .content_fps(8'd24), .display_hz(8'd60),
    .pattern(2'd0), .audio_en(1'b0), .use_frame_store(1'b0),
    .content_w(11'd960), .content_h(11'd540),
    .fs_wr_en(1'b0), .fs_wr_pixel(16'd0), .fs_wr_reset(1'b0), .fs_swap(1'b0), .fs_wr_ready(),
    .sdram_dout(16'd0), .sdram_ready(1'b0), .sdram_sel(), .sdram_addr(), .sdram_din(),
    .sdram_wr(), .sdram_rd(), .sdram_bs(), .sdram_refresh(),
    .ddr_start_req(1'b0), .ddr_bank_sel(1'b0), .ddr_status_osd(16'd0),
    .ddr_input_cmd_valid(1'b0), .ddr_input_cmd(8'd0),
    .ddr_sdram_test_state(4'd0), .ddr_sdram_size_code(4'd0), .ddr_sdram_error_count(16'd0),
    .clk_ddr(clk_ddr), .DDRAM_CLK(DCLK), .DDRAM_BUSY(1'b0), .DDRAM_BURSTCNT(DBC),
    .DDRAM_ADDR(DA), .DDRAM_DOUT(64'd0), .DDRAM_DOUT_READY(1'b0), .DDRAM_RD(DR),
    .DDRAM_DIN(DD), .DDRAM_BE(DBE), .DDRAM_WE(DW),
    .ddr_frames_done(dfd), .ddr_doorbell_ok(ddo),
    .af_wr_en(1'b0), .af_wr_data(32'd0), .af_wr_flush(1'b0),
    .ce_pix(ce_pix), .HBlank(HBlank), .HSync(HSync), .VBlank(VBlank), .VSync(VSync),
    .r(r), .g(g), .b(b), .audio_l(al), .audio_r(ar),
    .stat_display_index(s1), .stat_content_index(s2), .stat_advance(s4),
    .stat_has_frame(s5), .stat_wr_count(s3), .stat_has_audio(s6),
    .stat_audio_underrun(s7), .stat_swap_pending(), .stat_frame_underruns(s8),
    .stat_frame_sdram_state(s9)
  );
endmodule
SV
set +e
"$RUN_VERILATOR" --cc --build --no-timing \
  -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-UNOPTFLAT -Wno-PINMISSING \
  -Wno-INITIALDLY -Wno-BLKANDNBLK \
  -DDDR_FRAME_STORE \
  -I"$RTL" -I"$ROOT/fpga/Plex_MiSTer" \
  --top-module wrap \
  "$DBUILD/wrap.sv" \
  "$RTL/present_core.sv" "$RTL/present_cadence.sv" "$RTL/colorbars.sv" \
  "$RTL/ddr_frame_store.sv" "$RTL/frame_store.sv" \
  "$RTL/present_video_timing_960.sv" "$RTL/present_beam_content_de.sv" \
  "$RTL/present_video_timing_720p.sv" "$RTL/present_npx_path.sv" \
  "$RTL/present_beam_ppc.sv" "$RTL/present_pix_rate_match.sv" \
  "$RTL/yuv_bt601_npx.sv" "$RTL/async_fifo.sv" "$RTL/line_buf_ram.sv" \
  "$RTL/audio_fifo.sv" "$RTL/audio_tone.sv" \
  -Mdir "$DBUILD" >"$DBUILD/log.txt" 2>&1
DRC=$?
set -e
if [[ "$DRC" -ne 0 ]]; then
  echo "FAIL beam960_elab DEFAULT (macro OFF) rc=$DRC"
  tail -40 "$DBUILD/log.txt"
  exit 1
fi
echo "OK beam960_elab DEFAULT rc=0"
echo "PASS test_present_beam_960_elab true rc=0"
exit 0
