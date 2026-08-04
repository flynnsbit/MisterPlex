// h264_dpb_wide_window_fetch.sv — cycle budget + 8-byte beat window fetch.
//
// rd-duck: one_ref does 603 one-byte reads/partition; part_w/h unused for size.
// 720p P16: 603*3600=2_170_800 cy @20MHz = 108.54ms > 41.67ms (24fps).
// Wide path: 3 beats/Y-row *21 + 2*9*2 chroma = 99 beats → 17.82ms @20MHz.
// Not a shipping-RBF claim. Default product one_ref remains byte-serial.
`default_nettype none

module h264_dpb_fetch_cycle_budget #(
	parameter int MB_COUNT = 3600,
	parameter int CLK_HZ   = 20_000_000,
	parameter int FPS      = 24,
	parameter int FRAME_W  = 1280,
	parameter int FRAME_H  = 720
)(
	output wire [31:0] samples_per_p16_mb,
	output wire [31:0] byte_cycles_frame_p16,
	output wire [31:0] wide_beats_per_p16_mb,
	output wire [31:0] wide_cycles_frame_p16,
	output wire [31:0] frame_budget_cycles,
	output wire        byte_serial_meets_24fps,
	output wire        wide_beat_meets_24fps,
	output wire [31:0] i420_write_byte_cycles,
	output wire        i420_write_byte_meets_24fps
);
	`include "h264_dpb_ddr_params.svh"
	localparam int SAMP    = H264_DPB_FETCH_SAMPLES_P16;
	localparam int BYTE_FR = SAMP * MB_COUNT;
	localparam int WIDE_MB = H264_DPB_WIDE_BEATS_P16;
	localparam int WIDE_FR = WIDE_MB * MB_COUNT;
	localparam int BUDGET  = CLK_HZ / FPS;
	localparam int I420    = FRAME_W * FRAME_H + 2 * ((FRAME_W/2)*(FRAME_H/2));

	assign samples_per_p16_mb       = SAMP[31:0];
	assign byte_cycles_frame_p16    = BYTE_FR[31:0];
	assign wide_beats_per_p16_mb    = WIDE_MB[31:0];
	assign wide_cycles_frame_p16    = WIDE_FR[31:0];
	assign frame_budget_cycles      = BUDGET[31:0];
	assign byte_serial_meets_24fps  = (BYTE_FR <= BUDGET) ? 1'b1 : 1'b0;
	assign wide_beat_meets_24fps    = (WIDE_FR <= BUDGET) ? 1'b1 : 1'b0;
	assign i420_write_byte_cycles   = I420[31:0];
	assign i420_write_byte_meets_24fps = (I420 <= BUDGET) ? 1'b1 : 1'b0;
endmodule

// Fill 21x21 Y + 9x9 U + 9x9 V via 8-byte beats (or FAULT one-byte-per-sample).
// Memory model: mem_rdata[63:0] holds 8 consecutive bytes at mem_raddr (byte addr).
module h264_dpb_wide_window_fetch #(
	parameter int FRAME_W = 1280,
	parameter int FRAME_H = 720,
	parameter bit FAULT_BYTE_SERIAL = 1'b0
)(
	input  wire        clk,
	input  wire        reset,
	input  wire        start,
	input  wire [31:0] ref_base,
	input  wire signed [15:0] luma_ox,
	input  wire signed [15:0] luma_oy,
	input  wire signed [15:0] chroma_ox,
	input  wire signed [15:0] chroma_oy,
	output reg         mem_rd,
	output reg  [31:0] mem_raddr,
	input  wire [63:0] mem_rdata,
	input  wire        mem_rvalid,
	output reg         done,
	output reg         busy,
	output reg         luma_window_valid,
	output reg  [8:0]  luma_window_idx,
	output reg  [7:0]  luma_window_sample,
	output reg         chroma_u_window_valid,
	output reg         chroma_v_window_valid,
	output reg  [6:0]  chroma_window_idx,
	output reg  [7:0]  chroma_window_sample,
	output reg  [15:0] beats_issued
);
	localparam int C_W = FRAME_W / 2;
	localparam int C_H = FRAME_H / 2;

	// phase: 0=Y 1=U 2=V 3=done
	reg [1:0] phase;
	reg [4:0] row;
	reg [4:0] bcol; // beat column index
	reg [8:0] out_idx;
	reg [3:0] emit_i;
	reg [3:0] emit_n;
	reg [63:0] beat_q;
	reg        have_beat;
	reg        issued;

	wire [5:0] rows = (phase == 2'd0) ? 6'd21 : 6'd9;
	wire [5:0] width = (phase == 2'd0) ? 6'd21 : 6'd9;
	wire [5:0] beats_row = FAULT_BYTE_SERIAL ? width :
	                       ((width + 6'd7) / 6'd8);

	function automatic [15:0] clampu(input signed [15:0] v, input [31:0] lim);
		begin
			if (v < 0) clampu = 16'd0;
			else if ({16'd0, v} >= lim) clampu = lim[15:0] - 16'd1;
			else clampu = v[15:0];
		end
	endfunction

	function automatic [31:0] addr_at(
		input [1:0] pl,
		input [5:0] rr,
		input [5:0] cc
	);
		reg signed [15:0] sx, sy;
		reg [15:0] cx, cy;
		begin
			if (pl == 2'd0) begin
				sx = luma_ox + $signed({10'b0, cc}) - 16'sd2;
				sy = luma_oy + $signed({10'b0, rr}) - 16'sd2;
				cx = clampu(sx, FRAME_W[31:0]);
				cy = clampu(sy, FRAME_H[31:0]);
				addr_at = ref_base + cy * FRAME_W + {16'd0, cx};
			end else begin
				sx = chroma_ox + $signed({10'b0, cc});
				sy = chroma_oy + $signed({10'b0, rr});
				cx = clampu(sx, C_W[31:0]);
				cy = clampu(sy, C_H[31:0]);
				if (pl == 2'd1)
					addr_at = ref_base + FRAME_W*FRAME_H + cy*C_W + {16'd0, cx};
				else
					addr_at = ref_base + FRAME_W*FRAME_H + C_W*C_H + cy*C_W + {16'd0, cx};
			end
		end
	endfunction

	wire [5:0] col0 = FAULT_BYTE_SERIAL ? {1'b0, bcol} : ({1'b0, bcol} * 6'd8);
	wire [5:0] remain = (width > col0) ? (width - col0) : 6'd0;
	// nbytes must be 4 bits: 8 does not fit in 3'd (WIDTHTRUNC → 0, silent empty beats).
	wire [3:0] nbytes = FAULT_BYTE_SERIAL ? 4'd1 :
	                    ((remain >= 6'd8) ? 4'd8 : remain[3:0]);

	always @(posedge clk) begin
		mem_rd <= 1'b0;
		luma_window_valid <= 1'b0;
		chroma_u_window_valid <= 1'b0;
		chroma_v_window_valid <= 1'b0;
		done <= 1'b0;

		if (reset) begin
			busy <= 1'b0;
			phase <= 2'd0;
			row <= 5'd0;
			bcol <= 5'd0;
			out_idx <= 9'd0;
			have_beat <= 1'b0;
			issued <= 1'b0;
			beats_issued <= 16'd0;
			emit_i <= 4'd0;
			emit_n <= 4'd0;
			mem_raddr <= 32'd0;
			beat_q <= 64'd0;
		end else if (!busy) begin
			if (start) begin
				busy <= 1'b1;
				phase <= 2'd0;
				row <= 5'd0;
				bcol <= 5'd0;
				out_idx <= 9'd0;
				have_beat <= 1'b0;
				issued <= 1'b0;
				beats_issued <= 16'd0;
			end
		end else if (have_beat) begin
			// emit one byte per cycle from beat_q
			if (phase == 2'd0) begin
				luma_window_valid <= 1'b1;
				luma_window_idx <= out_idx;
				luma_window_sample <= beat_q[8*emit_i +: 8];
			end else if (phase == 2'd1) begin
				chroma_u_window_valid <= 1'b1;
				chroma_window_idx <= out_idx[6:0];
				chroma_window_sample <= beat_q[8*emit_i +: 8];
			end else begin
				chroma_v_window_valid <= 1'b1;
				chroma_window_idx <= out_idx[6:0];
				chroma_window_sample <= beat_q[8*emit_i +: 8];
			end
			out_idx <= out_idx + 9'd1;
			if (emit_n == 4'd0) begin
				// defensive: never stall on empty beat
				have_beat <= 1'b0;
				issued <= 1'b0;
			end else if (emit_i + 4'd1 >= emit_n) begin
				have_beat <= 1'b0;
				issued <= 1'b0;
				// next beat / row / phase
				if (bcol + 5'd1 >= beats_row[4:0]) begin
					bcol <= 5'd0;
					if (row + 5'd1 >= rows[4:0]) begin
						row <= 5'd0;
						out_idx <= 9'd0;
						if (phase == 2'd0) phase <= 2'd1;
						else if (phase == 2'd1) phase <= 2'd2;
						else begin
							busy <= 1'b0;
							done <= 1'b1;
						end
					end else begin
						row <= row + 5'd1;
					end
				end else begin
					bcol <= bcol + 5'd1;
				end
			end else begin
				emit_i <= emit_i + 4'd1;
			end
		end else if (!issued) begin
			mem_rd <= 1'b1;
			mem_raddr <= addr_at(phase, {1'b0, row}, col0);
			issued <= 1'b1;
			beats_issued <= beats_issued + 16'd1;
		end else if (mem_rvalid) begin
			beat_q <= mem_rdata;
			have_beat <= 1'b1;
			emit_i <= 4'd0;
			emit_n <= nbytes;
		end
	end
endmodule

// Use part_w/part_h to size the fetch window (not observe-only).
// luma samples = (part_w+5)*(part_h+5); chroma = (part_w/2+1)*(part_h/2+1)*2
module h264_dpb_part_window_samples (
	input  wire [4:0] part_w,
	input  wire [4:0] part_h,
	output wire [15:0] luma_samples,
	output wire [15:0] chroma_plane_samples,
	output wire [15:0] total_samples
);
	wire [5:0] lw = {1'b0, part_w} + 6'd5;
	wire [5:0] lh = {1'b0, part_h} + 6'd5;
	wire [5:0] cw = {1'b0, part_w[4:1]} + 6'd1;
	wire [5:0] ch = {1'b0, part_h[4:1]} + 6'd1;
	assign luma_samples = {4'd0, lw} * {4'd0, lh};
	assign chroma_plane_samples = {4'd0, cw} * {4'd0, ch};
	assign total_samples = luma_samples + (chroma_plane_samples << 1);
endmodule

`default_nettype wire
