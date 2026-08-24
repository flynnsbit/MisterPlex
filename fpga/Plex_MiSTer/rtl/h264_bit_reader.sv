// Shared RBSP bit-reader for full-slice CAVLC.
// Sits on h264_slice_rbsp_ram (8K). Replaces the 48B slice_hdr_parser window
// for everything after the slice header (mb_type, skip_run, CBP, residuals).
// MB0 first residual may still use slice_hdr_parser for 0x14 / 0x3b; after
// that, this cursor is the only reader.
//
// sl_rbsp RAM is synchronous (rd_data <= mem[rd_addr]). Drive ram_addr from
// the current bit_pos combinationally and stall one cycle after load / byte
// change so cur_bit is the new byte. Without that stall, UE/SE/u(n) eat the
// previous byte at a boundary and the walker ST_STOPs after MB0.
//
// Do not read residual from slice_hdr_parser past the first 4x4.

`default_nettype none

module h264_bit_reader #(
	parameter int ADDR_W = 13
)(
	input  wire               clk,
	input  wire               reset,

	input  wire               load,          // snap to bit_pos_i
	input  wire [16:0]        bit_pos_i,
	input  wire [13:0]        rbsp_len,      // bytes

	input  wire [7:0]         ram_rd,
	output wire [ADDR_W-1:0]  ram_addr,

	output reg  [16:0]        bit_pos,
	output wire               cur_bit,
	output wire               aligned,
	output wire               eof,

	input  wire               get_bit,       // 1-cycle consume
	output reg                bit_valid,
	output reg                bit_out,

	input  wire               start_ue,
	input  wire               start_se,
	input  wire               start_u,
	input  wire [4:0]         u_n,
	output reg                syn_busy,
	output reg                syn_done,
	output reg                syn_ok,
	output reg  [15:0]        ue_val,
	output reg signed [15:0]  se_val
);
	wire [13:0] byte_i = bit_pos[16:3];
	assign ram_addr = bit_pos[(ADDR_W+2):3];
	assign eof     = byte_i >= rbsp_len;
	assign aligned = (bit_pos[2:0] == 3'd0);
	assign cur_bit = ram_rd[3'd7 - bit_pos[2:0]];

	// issued = address presented to RAM last cycle. ready when that matches
	// the current byte (1-cycle M10K latency).
	reg [ADDR_W-1:0] issued;
	reg              issued_v;
	wire             ready = issued_v && (issued == ram_addr);

	localparam [2:0]
		ST_IDLE = 3'd0,
		ST_UEZ  = 3'd1,
		ST_UEV  = 3'd2,
		ST_U    = 3'd3,
		ST_BIT  = 3'd4;

	reg [2:0] st;
	reg [5:0] zcnt, nleft;
	reg [15:0] acc;
	reg        se_mode;

	function automatic signed [15:0] se_of;
		input [15:0] k;
		begin
			if (k == 16'd0) se_of = 16'sd0;
			else if (k[0]) se_of = $signed({1'b0, (k + 16'd1) >> 1});
			else se_of = -$signed({1'b0, k[15:1]});
		end
	endfunction

	always @(posedge clk) begin
		bit_valid <= 1'b0;
		syn_done  <= 1'b0;
		if (reset) begin
			bit_pos   <= 17'd0;
			issued    <= {ADDR_W{1'b0}};
			issued_v  <= 1'b0;
			st        <= ST_IDLE;
			syn_busy  <= 1'b0;
			syn_ok    <= 1'b0;
			ue_val    <= 16'd0;
			se_val    <= 16'sd0;
			zcnt      <= 6'd0;
			nleft     <= 6'd0;
			acc       <= 16'd0;
			se_mode   <= 1'b0;
		end else if (load) begin
			bit_pos  <= bit_pos_i;
			issued_v <= 1'b0;
			st       <= ST_IDLE;
			syn_busy <= 1'b0;
		end else begin
			issued   <= ram_addr;
			issued_v <= 1'b1;
			case (st)
			ST_IDLE: begin
				if (start_ue || start_se) begin
					se_mode  <= start_se;
					zcnt     <= 6'd0;
					acc      <= 16'd0;
					syn_busy <= 1'b1;
					syn_ok   <= 1'b0;
					st       <= ST_UEZ;
				end else if (start_u) begin
					nleft    <= {1'b0, u_n};
					acc      <= 16'd0;
					syn_busy <= 1'b1;
					syn_ok   <= 1'b0;
					se_mode  <= 1'b0;
					st       <= ST_U;
				end else if (get_bit && !eof && ready) begin
					bit_valid <= 1'b1;
					bit_out   <= cur_bit;
					bit_pos   <= bit_pos + 17'd1;
				end
			end
			ST_UEZ: begin
				if (!ready) begin
					// wait M10K
				end else if (eof) begin
					syn_busy <= 1'b0; syn_done <= 1'b1; syn_ok <= 1'b0; st <= ST_IDLE;
				end else if (cur_bit == 1'b0) begin
					zcnt    <= zcnt + 6'd1;
					bit_pos <= bit_pos + 17'd1;
					if (zcnt >= 6'd15) begin
						syn_busy <= 1'b0; syn_done <= 1'b1; syn_ok <= 1'b0; st <= ST_IDLE;
					end
				end else begin
					bit_pos <= bit_pos + 17'd1;
					if (zcnt == 6'd0) begin
						ue_val   <= 16'd0;
						se_val   <= 16'sd0;
						syn_busy <= 1'b0; syn_done <= 1'b1; syn_ok <= 1'b1; st <= ST_IDLE;
					end else begin
						nleft <= zcnt;
						acc   <= 16'd0;
						st    <= ST_UEV;
					end
				end
			end
			ST_UEV: begin
				if (!ready) begin
				end else if (eof) begin
					syn_busy <= 1'b0; syn_done <= 1'b1; syn_ok <= 1'b0; st <= ST_IDLE;
				end else begin
					acc     <= {acc[14:0], cur_bit};
					bit_pos <= bit_pos + 17'd1;
					if (nleft == 6'd1) begin
						ue_val   <= ((16'd1 << zcnt) - 16'd1) + {acc[14:0], cur_bit};
						se_val   <= se_of(((16'd1 << zcnt) - 16'd1) + {acc[14:0], cur_bit});
						syn_busy <= 1'b0; syn_done <= 1'b1; syn_ok <= 1'b1; st <= ST_IDLE;
					end else
						nleft <= nleft - 6'd1;
				end
			end
			ST_U: begin
				if (!ready && nleft != 6'd0) begin
				end else if (eof || nleft == 6'd0) begin
					ue_val   <= acc;
					se_val   <= $signed(acc);
					syn_busy <= 1'b0; syn_done <= 1'b1; syn_ok <= !eof || nleft == 6'd0;
					st       <= ST_IDLE;
				end else begin
					acc     <= {acc[14:0], cur_bit};
					bit_pos <= bit_pos + 17'd1;
					nleft   <= nleft - 6'd1;
				end
			end
			default: st <= ST_IDLE;
			endcase
		end
	end
endmodule

`default_nettype wire
