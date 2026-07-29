// Temporary synthesizable pass-through for h264_deblock_mb.
// The full engine trips a Quartus VRFX internal error
// ("read to RAM wasn't mapped to a specific read port") on multiport
// window gather.  This stub keeps the product hierarchy mappable so the
// transform/dequant DSP cut can be MEASURED.  Behaviour: store the 384
// reconstructed samples and re-emit them in absolute (plane,x,y) order
// with NO filtering (identity loop filter).  Neighbour strips are not
// re-emitted.
//
// OWNER note: restore the real filter once the multiport window is
// rewritten without integer-indexed function RAM reads.

`default_nettype none

module h264_deblock_mb #(
	parameter int FRAME_W = 320,
	parameter int FRAME_H = 240,
	parameter int MB_W = (FRAME_W + 15) / 16,
	parameter int MB_H = (FRAME_H + 15) / 16
) (
	input  wire              clk,
	input  wire              reset,

	input  wire              slice_start,
	input  wire              disable_deblocking,
	input  wire signed [4:0] slice_alpha_c0_offset,
	input  wire signed [4:0] slice_beta_offset,

	input  wire              mb_start,
	input  wire [7:0]        mb_x,
	input  wire [7:0]        mb_y,
	input  wire              mb_is_intra,
	input  wire [5:0]        mb_qp_y,
	input  wire [5:0]        mb_qp_c,
	input  wire [15:0]       mb_nz_luma,
	input  wire signed [15:0] mb_mv_x,
	input  wire signed [15:0] mb_mv_y,
	input  wire [1:0]        mb_ref_idx,

	input  wire              smp_valid,
	input  wire [8:0]        smp_idx,
	input  wire [7:0]        smp_data,
	input  wire              smp_done,

	output reg               out_valid,
	output reg  [1:0]        out_plane,
	output reg  [15:0]       out_x,
	output reg  [15:0]       out_y,
	output reg  [7:0]        out_data,
	output wire              busy,
	output reg               mb_done
);
	localparam [1:0] S_IDLE = 2'd0, S_RECV = 2'd1, S_EMIT = 2'd2;

	reg [1:0] state;
	reg [7:0] mbx_r, mby_r;
	(* ramstyle = "logic" *) reg [7:0] pix [0:383];
	reg [8:0] emit_i;

	assign busy = (state != S_IDLE);

	wire [15:0] blx = {4'd0, mbx_r, 4'd0};
	wire [15:0] bly = {4'd0, mby_r, 4'd0};
	wire [15:0] bcx = {5'd0, mbx_r, 3'd0};
	wire [15:0] bcy = {5'd0, mby_r, 3'd0};

	// silence unused
	wire _u = slice_start | disable_deblocking | mb_is_intra |
	          |mb_qp_y | |mb_qp_c | |mb_nz_luma |
	          |mb_mv_x | |mb_mv_y | |mb_ref_idx |
	          |slice_alpha_c0_offset | |slice_beta_offset;

	always @(posedge clk) begin
		out_valid <= 1'b0;
		mb_done   <= 1'b0;
		if (reset) begin
			state <= S_IDLE;
			emit_i <= 9'd0;
			mbx_r <= 8'd0;
			mby_r <= 8'd0;
			out_plane <= 2'd0;
			out_x <= 16'd0;
			out_y <= 16'd0;
			out_data <= 8'd0;
		end else begin
			case (state)
			S_IDLE: begin
				if (mb_start) begin
					mbx_r <= mb_x;
					mby_r <= mb_y;
					state <= S_RECV;
				end
			end
			S_RECV: begin
				if (smp_valid && (smp_idx < 9'd384))
					pix[smp_idx] <= smp_data;
				if (smp_done) begin
					emit_i <= 9'd0;
					state <= S_EMIT;
				end
			end
			S_EMIT: begin
				out_valid <= 1'b1;
				out_data  <= pix[emit_i];
				if (emit_i < 9'd256) begin
					out_plane <= 2'd0;
					out_x <= blx + {12'd0, emit_i[3:0]};
					out_y <= bly + {12'd0, emit_i[7:4]};
				end else if (emit_i < 9'd320) begin
					out_plane <= 2'd1;
					out_x <= bcx + {13'd0, emit_i[2:0]};
					out_y <= bcy + {13'd0, emit_i[5:3]};
				end else begin
					out_plane <= 2'd2;
					out_x <= bcx + {13'd0, emit_i[2:0]};
					out_y <= bcy + {13'd0, emit_i[5:3]};
				end
				if (emit_i == 9'd383) begin
					mb_done <= 1'b1;
					state <= S_IDLE;
				end else begin
					emit_i <= emit_i + 9'd1;
				end
			end
			default: state <= S_IDLE;
			endcase
		end
	end
endmodule

`default_nettype wire
