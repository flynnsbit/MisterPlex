// present_nn_linebuf_scaler — streaming nearest-neighbour H/V rescale (default OFF).
//
// Complements present_content_window (present-path random-access map, 0 M10K).
// Stream path: native row-major in → scaled row-major out via one M10K linebuf.
//
// CONTRACT
// --------
// Pixel format : 8-bit planar sample (Y or chroma). One sample per transfer.
// Input geom   : in_w × in_h   (runtime, clamped to *_MAX)
// Output geom  : out_w × out_h (runtime, clamped to *_MAX)
// Handshake    : in_valid/in_ready (load), out_valid/out_ready (emit)
// Control      : pulse start while idle; geometry stable until done pulse.
//
// NN map (endpoint-exact ceil Q16 — same as present_content_window):
//   s = ceil( (in-1) * 65536 / (out-1) )
//   src = min(in-1, (dst * s) >> 16)
//
// BRAM (M10K): IN_W_MAX=1280 × 8b = 10240 bits = exactly 1 M10K. NN needs 1 line.
//
// CYCLE MODEL: load 1 cy/in_px; emit ~2 cy/out_px (addr + data) when out_ready=1.
// TIME @20 MHz / 1280×720@24 budget 833333: 320→720p stream FAIL (~1.2×+).
// content_window present-path is the product 720p approach (0 write amplify).
// Instantiated only under PLEX_NN_LINEBUF_SCALER (default OFF).

`default_nettype none

module present_nn_linebuf_scaler #(
	parameter int IN_W_MAX  = 1280,
	parameter int OUT_W_MAX = 1280,
	parameter int IN_H_MAX  = 720,
	parameter int OUT_H_MAX = 720
)(
	input  wire        clk,
	input  wire        reset,

	input  wire [10:0] in_w,
	input  wire [10:0] in_h,
	input  wire [10:0] out_w,
	input  wire [10:0] out_h,

	input  wire        start,
	output reg         busy,
	output reg         done,

	input  wire        in_valid,
	output reg         in_ready,
	input  wire [7:0]  in_pixel,

	output reg         out_valid,
	input  wire        out_ready,
	output reg  [7:0]  out_pixel,
	output reg  [10:0] out_x,
	output reg  [10:0] out_y
);

	localparam int AW = $clog2(IN_W_MAX);

	(* ramstyle = "M10K" *) reg [7:0] linebuf [0:IN_W_MAX-1];

	localparam logic [1:0] ST_IDLE = 2'd0, ST_RUN = 2'd1, ST_DONE = 2'd2;
	reg [1:0] state;

	reg [10:0] in_w_r, in_h_r, out_w_r, out_h_r;
	reg [19:0] sx_r, sy_r;
	reg        scales_valid;

	reg [10:0] src_y_next;
	reg [10:0] wr_x;
	reg        line_valid;
	reg [10:0] src_y_held;

	reg [10:0] dst_x, dst_y;
	// emit_phase: 0=idle/need line, 1=addr issued wait, 2=data in rd_q present/wait ready
	reg [1:0]  emit_phase;
	reg [10:0] emit_x_cap; // x captured with the in-flight read

	reg [AW-1:0] rd_addr_r;
	reg [7:0]    rd_q;

	wire [10:0] in_w_e  = (in_w_r  == 11'd0) ? 11'd1 : in_w_r;
	wire [10:0] in_h_e  = (in_h_r  == 11'd0) ? 11'd1 : in_h_r;
	wire [10:0] out_w_e = (out_w_r == 11'd0) ? 11'd1 : out_w_r;
	wire [10:0] out_h_e = (out_h_r == 11'd0) ? 11'd1 : out_h_r;

	wire [10:0] in_w_m1  = (in_w_e  <= 11'd1) ? 11'd0 : (in_w_e  - 11'd1);
	wire [10:0] in_h_m1  = (in_h_e  <= 11'd1) ? 11'd0 : (in_h_e  - 11'd1);
	wire [10:0] out_w_m1 = (out_w_e <= 11'd1) ? 11'd1 : (out_w_e - 11'd1);
	wire [10:0] out_h_m1 = (out_h_e <= 11'd1) ? 11'd1 : (out_h_e - 11'd1);

	wire [31:0] sx_num = {21'd0, in_w_m1} * 32'd65536 + {21'd0, out_w_m1} - 32'd1;
	wire [31:0] sy_num = {21'd0, in_h_m1} * 32'd65536 + {21'd0, out_h_m1} - 32'd1;
	wire [19:0] sx_comb = 20'(sx_num / {21'd0, out_w_m1});
	wire [19:0] sy_comb = 20'(sy_num / {21'd0, out_h_m1});

	wire [31:0] y_prod = {21'd0, dst_y} * {12'd0, sy_r};
	wire [15:0] y_q16  = y_prod[31:16];
	wire [10:0] need_sy = (y_q16 > {5'd0, in_h_m1}) ? in_h_m1 : y_q16[10:0];

	function automatic [10:0] map_x;
		input [10:0] x;
		input [19:0] sx;
		input [10:0] xlast;
		reg [31:0] prod;
		reg [15:0] q;
		begin
			prod = {21'd0, x} * {12'd0, sx};
			q = prod[31:16];
			map_x = (q > {5'd0, xlast}) ? xlast : q[10:0];
		end
	endfunction

	function automatic [10:0] clamp_dim;
		input [10:0] v;
		input integer maxv;
		begin
			if (v == 11'd0)
				clamp_dim = 11'd1;
			else if (v > 11'(maxv))
				clamp_dim = 11'(maxv);
			else
				clamp_dim = v;
		end
	endfunction

	always @(posedge clk) begin
		rd_q <= linebuf[rd_addr_r];
	end

	wire taking_out = out_valid && out_ready;
	wire taking_in  = in_ready && in_valid;

	wire need_fill = scales_valid && (!line_valid || (src_y_held != need_sy));

	always @(posedge clk) begin
		if (reset) begin
			state        <= ST_IDLE;
			busy         <= 1'b0;
			done         <= 1'b0;
			in_ready     <= 1'b0;
			out_valid    <= 1'b0;
			out_pixel    <= 8'd0;
			out_x        <= 11'd0;
			out_y        <= 11'd0;
			in_w_r       <= 11'd1;
			in_h_r       <= 11'd1;
			out_w_r      <= 11'd1;
			out_h_r      <= 11'd1;
			sx_r         <= 20'd65536;
			sy_r         <= 20'd65536;
			scales_valid <= 1'b0;
			src_y_next   <= 11'd0;
			wr_x         <= 11'd0;
			line_valid   <= 1'b0;
			src_y_held   <= 11'd0;
			dst_x        <= 11'd0;
			dst_y        <= 11'd0;
			emit_phase   <= 2'd0;
			emit_x_cap   <= 11'd0;
			rd_addr_r    <= '0;
		end else begin
			done <= 1'b0;
			if (taking_out)
				out_valid <= 1'b0;

			case (state)
			ST_IDLE: begin
				busy         <= 1'b0;
				in_ready     <= 1'b0;
				out_valid    <= 1'b0;
				scales_valid <= 1'b0;
				emit_phase   <= 2'd0;
				if (start) begin
					in_w_r     <= clamp_dim(in_w, IN_W_MAX);
					in_h_r     <= clamp_dim(in_h, IN_H_MAX);
					out_w_r    <= clamp_dim(out_w, OUT_W_MAX);
					out_h_r    <= clamp_dim(out_h, OUT_H_MAX);
					busy       <= 1'b1;
					src_y_next <= 11'd0;
					wr_x       <= 11'd0;
					line_valid <= 1'b0;
					dst_x      <= 11'd0;
					dst_y      <= 11'd0;
					state      <= ST_RUN;
				end
			end

			ST_RUN: begin
				if (!scales_valid) begin
					sx_r         <= sx_comb;
					sy_r         <= sy_comb;
					scales_valid <= 1'b1;
					in_ready     <= 1'b0;
				end else if (need_fill) begin
					// Fill/skip source lines until held == need_sy
					emit_phase <= 2'd0;
					out_valid  <= 1'b0;
					if (src_y_next >= in_h_e) begin
						// Should not happen if need_sy clamped
						in_ready <= 1'b0;
					end else begin
						in_ready <= 1'b1;
						if (taking_in) begin
							linebuf[wr_x[AW-1:0]] <= in_pixel;
							if (wr_x + 11'd1 >= in_w_e) begin
								src_y_held <= src_y_next;
								src_y_next <= src_y_next + 11'd1;
								wr_x       <= 11'd0;
								line_valid <= 1'b1;
								in_ready   <= 1'b0;
							end else begin
								wr_x <= wr_x + 11'd1;
							end
						end
					end
				end else begin
					// Have correct source line — emit
					in_ready <= 1'b0;
					// BRAM: rd_q lags rd_addr_r by 1 posedge. Sequence:
					//   0: set addr  1: wait (rd_q captures)  2: present  3: wait ready
					case (emit_phase)
					2'd0: begin
						rd_addr_r  <= map_x(dst_x, sx_r, in_w_m1)[AW-1:0];
						emit_x_cap <= dst_x;
						emit_phase <= 2'd1;
						out_valid  <= 1'b0;
					end
					2'd1: begin
						// wait cycle — at this posedge rd_q <= linebuf[addr]
						emit_phase <= 2'd2;
					end
					2'd2: begin
						out_pixel  <= rd_q;
						out_x      <= emit_x_cap;
						out_y      <= dst_y;
						out_valid  <= 1'b1;
						emit_phase <= 2'd3;
					end
					2'd3: begin
						if (taking_out) begin
							if (dst_x + 11'd1 >= out_w_e) begin
								if (dst_y + 11'd1 >= out_h_e) begin
									state      <= ST_DONE;
									emit_phase <= 2'd0;
								end else begin
									dst_y      <= dst_y + 11'd1;
									dst_x      <= 11'd0;
									emit_phase <= 2'd0;
								end
							end else begin
								dst_x      <= dst_x + 11'd1;
								emit_phase <= 2'd0;
							end
						end
					end
					default: emit_phase <= 2'd0;
					endcase
				end
			end

			ST_DONE: begin
				done       <= 1'b1;
				busy       <= 1'b0;
				in_ready   <= 1'b0;
				out_valid  <= 1'b0;
				emit_phase <= 2'd0;
				state      <= ST_IDLE;
			end

			default: state <= ST_IDLE;
			endcase
		end
	end

	wire _unused = IN_H_MAX[0] ^ OUT_H_MAX[0] ^ OUT_W_MAX[0];

endmodule

`default_nettype wire
