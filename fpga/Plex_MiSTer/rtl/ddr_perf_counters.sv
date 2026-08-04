// ddr_perf_counters — fabric-side f2sdram bandwidth/contention instrument.
//
// Domain: clk (DDR bridge, ~90 MHz). M10K: 0 (FF only).
// Default product: not instantiated (`DDR_PERF_COUNTERS` undefined).
//
// Post-arbiter Avalon monitor so DEVICE_BW_VERIFIED can become a measured
// number. Saturating 32-bit counters. Atomic one-cycle snapshot into shadows.
// Multi-word host readout uses mailbox seqlock (ddr_perf_mailbox.sv).
//
// FAULT_MISCOUNT_STALL (sim only): skip stall increments — NEG twin must fail.

`default_nettype none

module ddr_perf_counters #(
	parameter bit FAULT_MISCOUNT_STALL = 1'b0
) (
	input  wire        clk,
	input  wire        reset,

	input  wire        DDRAM_BUSY,
	input  wire        DDRAM_RD,
	input  wire        DDRAM_WE,
	input  wire        DDRAM_DOUT_READY,
	input  wire  [7:0] DDRAM_BURSTCNT,
	input  wire  [1:0] owner,

	input  wire        snap_req,
	input  wire        clear_req,

	output reg  [7:0]  snap_seq,
	output reg  [31:0] sh_cycles,
	output reg  [31:0] sh_wr_beats,
	output reg  [31:0] sh_rd_beats,
	output reg  [31:0] sh_stall_cyc,
	output reg  [31:0] sh_lat_sum,
	output reg  [31:0] sh_lat_max,
	output reg  [31:0] sh_lat_n,
	output reg  [31:0] sh_m0_rd,
	output reg  [31:0] sh_m0_wr,
	output reg  [31:0] sh_m1_rd,
	output reg  [31:0] sh_m1_wr,
	output reg  [31:0] sh_m2_rd,
	output reg  [31:0] sh_m2_wr,
	output reg  [15:0] sh_sat_flags
);

	reg [31:0] c_cycles, c_wr, c_rd, c_stall;
	reg [31:0] c_lat_sum, c_lat_max, c_lat_n;
	reg [31:0] c_m0_rd, c_m0_wr, c_m1_rd, c_m1_wr, c_m2_rd, c_m2_wr;
	reg [15:0] c_sat;

	reg snap_req_d, clear_req_d;
	wire snap_pulse  = snap_req  & ~snap_req_d;
	wire clear_pulse = clear_req & ~clear_req_d;

	wire wr_fire = DDRAM_WE & ~DDRAM_BUSY;
	wire rd_cmd  = DDRAM_RD & ~DDRAM_BUSY;
	wire rd_beat = DDRAM_DOUT_READY;
	wire stall   = (DDRAM_RD | DDRAM_WE) & DDRAM_BUSY;

	reg        lat_active;
	reg        lat_first;
	reg [15:0] lat_cnt;
	reg [7:0]  lat_left;
	reg [1:0]  lat_owner;

	function automatic [31:0] sat_inc32(input [31:0] v, output sat);
		begin
			if (v == 32'hFFFF_FFFF) begin
				sat_inc32 = v;
				sat = 1'b1;
			end else begin
				sat_inc32 = v + 32'd1;
				sat = 1'b0;
			end
		end
	endfunction

	function automatic [31:0] sat_add32(input [31:0] v, input [31:0] a, output sat);
		reg [32:0] s;
		begin
			s = {1'b0, v} + {1'b0, a};
			if (s[32]) begin
				sat_add32 = 32'hFFFF_FFFF;
				sat = 1'b1;
			end else begin
				sat_add32 = s[31:0];
				sat = 1'b0;
			end
		end
	endfunction

	reg satb;
	reg [31:0] nxt;

	always @(posedge clk) begin
		if (reset) begin
			c_cycles <= 32'd0;
			c_wr <= 32'd0;
			c_rd <= 32'd0;
			c_stall <= 32'd0;
			c_lat_sum <= 32'd0;
			c_lat_max <= 32'd0;
			c_lat_n <= 32'd0;
			c_m0_rd <= 32'd0;
			c_m0_wr <= 32'd0;
			c_m1_rd <= 32'd0;
			c_m1_wr <= 32'd0;
			c_m2_rd <= 32'd0;
			c_m2_wr <= 32'd0;
			c_sat <= 16'd0;
			snap_req_d <= 1'b0;
			clear_req_d <= 1'b0;
			snap_seq <= 8'd0;
			lat_active <= 1'b0;
			lat_first <= 1'b0;
			lat_cnt <= 16'd0;
			lat_left <= 8'd0;
			lat_owner <= 2'd0;
			sh_cycles <= 32'd0;
			sh_wr_beats <= 32'd0;
			sh_rd_beats <= 32'd0;
			sh_stall_cyc <= 32'd0;
			sh_lat_sum <= 32'd0;
			sh_lat_max <= 32'd0;
			sh_lat_n <= 32'd0;
			sh_m0_rd <= 32'd0;
			sh_m0_wr <= 32'd0;
			sh_m1_rd <= 32'd0;
			sh_m1_wr <= 32'd0;
			sh_m2_rd <= 32'd0;
			sh_m2_wr <= 32'd0;
			sh_sat_flags <= 16'd0;
		end else begin
			snap_req_d  <= snap_req;
			clear_req_d <= clear_req;

			if (clear_pulse) begin
				c_cycles <= 32'd0;
				c_wr <= 32'd0;
				c_rd <= 32'd0;
				c_stall <= 32'd0;
				c_lat_sum <= 32'd0;
				c_lat_max <= 32'd0;
				c_lat_n <= 32'd0;
				c_m0_rd <= 32'd0;
				c_m0_wr <= 32'd0;
				c_m1_rd <= 32'd0;
				c_m1_wr <= 32'd0;
				c_m2_rd <= 32'd0;
				c_m2_wr <= 32'd0;
				c_sat <= 16'd0;
				lat_active <= 1'b0;
				lat_first <= 1'b0;
				lat_cnt <= 16'd0;
				lat_left <= 8'd0;
			end else begin
				nxt = sat_inc32(c_cycles, satb);
				c_cycles <= nxt;
				if (satb) c_sat[0] <= 1'b1;

				if (wr_fire) begin
					nxt = sat_inc32(c_wr, satb);
					c_wr <= nxt;
					if (satb) c_sat[1] <= 1'b1;
					case (owner)
						2'd0: begin
							nxt = sat_inc32(c_m0_wr, satb);
							c_m0_wr <= nxt;
							if (satb) c_sat[8] <= 1'b1;
						end
						2'd1: begin
							nxt = sat_inc32(c_m1_wr, satb);
							c_m1_wr <= nxt;
							if (satb) c_sat[9] <= 1'b1;
						end
						default: begin
							nxt = sat_inc32(c_m2_wr, satb);
							c_m2_wr <= nxt;
							if (satb) c_sat[10] <= 1'b1;
						end
					endcase
				end

				if (rd_beat) begin
					nxt = sat_inc32(c_rd, satb);
					c_rd <= nxt;
					if (satb) c_sat[2] <= 1'b1;
					case (lat_active ? lat_owner : owner)
						2'd0: begin
							nxt = sat_inc32(c_m0_rd, satb);
							c_m0_rd <= nxt;
							if (satb) c_sat[5] <= 1'b1;
						end
						2'd1: begin
							nxt = sat_inc32(c_m1_rd, satb);
							c_m1_rd <= nxt;
							if (satb) c_sat[6] <= 1'b1;
						end
						default: begin
							nxt = sat_inc32(c_m2_rd, satb);
							c_m2_rd <= nxt;
							if (satb) c_sat[7] <= 1'b1;
						end
					endcase
				end

				if (stall && !FAULT_MISCOUNT_STALL) begin
					nxt = sat_inc32(c_stall, satb);
					c_stall <= nxt;
					if (satb) c_sat[3] <= 1'b1;
				end

				if (rd_cmd && !lat_active) begin
					lat_active <= 1'b1;
					lat_first  <= 1'b1;
					lat_cnt    <= 16'd0;
					lat_left   <= (DDRAM_BURSTCNT == 8'd0) ? 8'd1 : DDRAM_BURSTCNT;
					lat_owner  <= owner;
				end else if (lat_active) begin
					if (!rd_beat)
						lat_cnt <= (lat_cnt == 16'hFFFF) ? lat_cnt : (lat_cnt + 16'd1);
					if (rd_beat) begin
						if (lat_first) begin
							nxt = sat_add32(c_lat_sum, {16'd0, lat_cnt}, satb);
							c_lat_sum <= nxt;
							if (satb) c_sat[4] <= 1'b1;
							if ({16'd0, lat_cnt} > c_lat_max)
								c_lat_max <= {16'd0, lat_cnt};
							nxt = sat_inc32(c_lat_n, satb);
							c_lat_n <= nxt;
							if (satb) c_sat[11] <= 1'b1;
							lat_first <= 1'b0;
						end
						if (lat_left <= 8'd1) begin
							lat_active <= 1'b0;
							lat_left <= 8'd0;
						end else
							lat_left <= lat_left - 8'd1;
					end
				end
			end

			if (snap_pulse) begin
				snap_seq     <= snap_seq + 8'd1;
				sh_cycles    <= c_cycles;
				sh_wr_beats  <= c_wr;
				sh_rd_beats  <= c_rd;
				sh_stall_cyc <= c_stall;
				sh_lat_sum   <= c_lat_sum;
				sh_lat_max   <= c_lat_max;
				sh_lat_n     <= c_lat_n;
				sh_m0_rd     <= c_m0_rd;
				sh_m0_wr     <= c_m0_wr;
				sh_m1_rd     <= c_m1_rd;
				sh_m1_wr     <= c_m1_wr;
				sh_m2_rd     <= c_m2_rd;
				sh_m2_wr     <= c_m2_wr;
				sh_sat_flags <= c_sat;
			end
		end
	end
endmodule

`default_nettype wire
