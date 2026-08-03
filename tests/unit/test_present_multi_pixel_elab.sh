#!/usr/bin/env bash
# Red/green: PRESENT_MULTI_PIXEL connected path must elaborate (default OFF in QSF).
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

BUILD="$ROOT/build/verilator/present_mp_elab"
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
  present_core #(.FRAME_W(640), .FRAME_H(480), .FRAME_STRIDE(640), .FRAME_LINE_COUNT(8)) u (
    .clk(clk), .clk_sdram(clk_sdram), .clk_audio(clk_audio), .clk_pix(clk), .reset(reset),
    .pal(1'b0), .scandouble(1'b1), .content_fps(8'd24), .display_hz(8'd60),
    .pattern(2'd0), .audio_en(1'b0), .use_frame_store(1'b0),
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

RTL="$ROOT/fpga/Plex_MiSTer/rtl"
COMMON=(
  --cc --build --no-timing
  -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-UNOPTFLAT -Wno-PINMISSING
  -Wno-INITIALDLY -Wno-BLKANDNBLK
  -DDDR_FRAME_STORE
  -I"$RTL" -I"$ROOT/fpga/Plex_MiSTer"
  --top-module wrap
  "$WRAP"
  "$RTL/present_core.sv" "$RTL/present_cadence.sv" "$RTL/colorbars.sv"
  "$RTL/ddr_frame_store.sv" "$RTL/present_beam_ppc.sv" "$RTL/present_npx_path.sv"
  "$RTL/present_video_timing_720p.sv"
  "$RTL/yuv_bt601_npx.sv" "$RTL/async_fifo.sv" "$RTL/line_buf_ram.sv"
  "$RTL/audio_fifo.sv"
)

# RED: without PRESENT_MULTI_PIXEL, u_mp_npx_path must not appear in hierarchy dump.
# We check source: present_core must contain the connected chain markers.
if ! grep -q "u_mp_npx_path" "$RTL/present_core.sv"; then
  echo "FAIL RED setup: present_core missing u_mp_npx_path instance"
  exit 1
fi
if ! grep -q "fstore_rd_x" "$RTL/present_core.sv"; then
  echo "FAIL RED setup: present_core missing fstore_rd mux"
  exit 1
fi
if ! grep -q "u_mp_timing" "$RTL/present_core.sv"; then
  echo "FAIL RED setup: present_core missing u_mp_timing (720p mode)"
  exit 1
fi
if ! grep -q "present_video_timing_720p" "$ROOT/fpga/Plex_MiSTer/files.qip"; then
  echo "FAIL RED setup: files.qip missing present_video_timing_720p.sv"
  exit 1
fi
# Template H_DE=529 must remain on the default (macro OFF) path.
if ! grep -q "localparam H_DE    = 10'd529" "$RTL/present_core.sv"; then
  echo "FAIL RED setup: Template H_DE=529 lock missing in present_core"
  exit 1
fi
echo "OK mp_elab structural markers present"

# Anti-elision / telemetry (rd-duck): underrun must be status-visible, not only _unused
for m in mp_rd_ur_sticky MP_UR_STICKY mp_stat_frame_underruns 'PREFILL_GROUPS(16)' mp_reset_pix MP_PROD_LEAD_PPM; do
  if ! grep -qF "$m" "$RTL/present_core.sv"; then
    echo "FAIL mp_elab missing marker $m"
    exit 1
  fi
done
echo "OK mp_elab underrun telemetry + reset_pix + lead markers"

# GREEN: elaborate with macro ON
GBUILD="$BUILD/green"
mkdir -p "$GBUILD"
set +e
"$RUN_VERILATOR" "${COMMON[@]}" \
  -DPRESENT_MULTI_PIXEL -DPRESENT_PX_PER_CLK=2 \
  -Mdir "$GBUILD" >"$GBUILD/log.txt" 2>&1
GRC=$?
set -e
if [[ "$GRC" -ne 0 ]]; then
  echo "FAIL mp_elab GREEN rc=$GRC"
  tail -40 "$GBUILD/log.txt"
  exit 1
fi
echo "OK mp_elab GREEN rc=0"
echo "PASS test_present_multi_pixel_elab"
