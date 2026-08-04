// Byte-port <-> 64-bit DDR bridge for h264_dpb_one_ref mem_* ports.
//
// Read: single-qword cache. Sequential MC window walks hit the same qword
// often (8 consecutive bytes); random seeks pay one beat. Not a full ref
// window cache — see h264_dpb_ref_win_cache for burst window fill + M10K.
//
// Write: coalesce consecutive bytes into one BE-masked qword WE (same as
// h264_dpb_ddr_wr_coalesce).
//
// DDR master shape matches arbiter3. Product attach = w-mem m3 agreement.
// mem_rvalid is 1 cycle after a completed DDR beat (or cache hit).
`default_nettype none

module h264_dpb_ddr_byte_bridge (
	input  wire        clk,
	input  wire        reset,

	// Byte port (h264_dpb_one_ref)
	input  wire        mem_we,
	input  wire [31:0] mem_waddr,
	input  wire [7:0]  mem_wdata,
	input  wire        mem_rd,
	input  wire [31:0] mem_raddr,
	output reg  [7:0]  mem_rdata,
	output reg         mem_rvalid,

	// DDR master
	output reg         ddr_want,
	input  wire        ddr_busy,
	output reg  [7:0]  ddr_burstcnt,
	output reg  [28:0] ddr_addr,
	input  wire [63:0] ddr_dout,
	input  wire        ddr_dout_ready,
	output reg         ddr_rd,
	output reg  [63:0] ddr_din,
	output reg  [7:0]  ddr_be,
	output reg         ddr_we
);
	reg        rq_valid;
	reg [28:0] rq_qaddr;
	reg [2:0]  rq_lane;
	reg        cache_valid;
	reg [28:0] cache_qaddr;
	reg [63:0] cache_data;

	reg        w_have;
	reg [28:0] w_qaddr;
	reg [63:0] w_data;
	reg [7:0]  w_be;

	wire [28:0] rd_q = mem_raddr[31:3];
	wire [2:0]  rd_l = mem_raddr[2:0];
	wire [28:0] wr_q = mem_waddr[31:3];
	wire [2:0]  wr_l = mem_waddr[2:0];

	reg [7:0]  wr_lane_be;
	reg [63:0] wr_lane_data;
	always @* begin
		wr_lane_be = 8'd0;
		wr_lane_data = 64'd0;
		case (wr_l)
		3'd0: begin wr_lane_be = 8'h01; wr_lane_data = {56'd0, mem_wdata}; end
		3'd1: begin wr_lane_be = 8'h02; wr_lane_data = {48'd0, mem_wdata, 8'd0}; end
		3'd2: begin wr_lane_be = 8'h04; wr_lane_data = {40'd0, mem_wdata, 16'd0}; end
		3'd3: begin wr_lane_be = 8'h08; wr_lane_data = {32'd0, mem_wdata, 24'd0}; end
		3'd4: begin wr_lane_be = 8'h10; wr_lane_data = {24'd0, mem_wdata, 32'd0}; end
		3'd5: begin wr_lane_be = 8'h20; wr_lane_data = {16'd0, mem_wdata, 40'd0}; end
		3'd6: begin wr_lane_be = 8'h40; wr_lane_data = {8'd0, mem_wdata, 48'd0}; end
		default: begin wr_lane_be = 8'h80; wr_lane_data = {mem_wdata, 56'd0}; end
		endcase
	end

	function automatic [7:0] pick_byte(input [63:0] d, input [2:0] lane);
		begin
			case (lane)
			3'd0: pick_byte = d[7:0];
			3'd1: pick_byte = d[15:8];
			3'd2: pick_byte = d[23:16];
			3'd3: pick_byte = d[31:24];
			3'd4: pick_byte = d[39:32];
			3'd5: pick_byte = d[47:40];
			3'd6: pick_byte = d[55:48];
			default: pick_byte = d[63:56];
			endcase
		end
	endfunction

	reg rd_inflight;
	reg wr_inflight;

	always @(posedge clk) begin
		mem_rvalid <= 1'b0;
		ddr_burstcnt <= 8'd1;

		if (reset) begin
			rq_valid <= 1'b0;
			rd_inflight <= 1'b0;
			wr_inflight <= 1'b0;
			cache_valid <= 1'b0;
			cache_qaddr <= 29'd0;
			cache_data <= 64'd0;
			w_have <= 1'b0;
			w_qaddr <= 29'd0;
			w_data <= 64'd0;
			w_be <= 8'd0;
			mem_rdata <= 8'd0;
			ddr_addr <= 29'd0;
			ddr_din <= 64'd0;
			ddr_be <= 8'd0;
			ddr_rd <= 1'b0;
			ddr_we <= 1'b0;
			ddr_want <= 1'b0;
			rq_qaddr <= 29'd0;
			rq_lane <= 3'd0;
		end else begin
			// Default: hold command lines only while in-flight.
			if (!rd_inflight)
				ddr_rd <= 1'b0;
			if (!wr_inflight)
				ddr_we <= 1'b0;
			ddr_want <= rq_valid || w_have || rd_inflight || wr_inflight;

			// Complete write accept: model drops busy; we pulse we one cycle
			// and clear inflight next if not held. Simple: we is 1-cycle pulse
			// when accepted (!busy).
			if (wr_inflight) begin
				// Write is posted in one cycle when !busy was true at issue.
				wr_inflight <= 1'b0;
				ddr_we <= 1'b0;
			end

			// --- writes: coalesce ---
			if (mem_we) begin
				if (!w_have) begin
					w_have <= 1'b1;
					w_qaddr <= wr_q;
					w_data <= wr_lane_data;
					w_be <= wr_lane_be;
				end else if (wr_q == w_qaddr) begin
					w_data <= w_data | wr_lane_data;
					w_be <= w_be | wr_lane_be;
				end else if (!rd_inflight && !wr_inflight && !ddr_busy) begin
					// Flush previous qword then start new
					ddr_we <= 1'b1;
					ddr_addr <= w_qaddr;
					ddr_din <= w_data;
					ddr_be <= w_be;
					wr_inflight <= 1'b1;
					if (cache_valid && cache_qaddr == w_qaddr)
						cache_valid <= 1'b0;
					w_qaddr <= wr_q;
					w_data <= wr_lane_data;
					w_be <= wr_lane_be;
				end
			end else if (w_have && !rq_valid && !rd_inflight && !wr_inflight && !ddr_busy) begin
				ddr_we <= 1'b1;
				ddr_addr <= w_qaddr;
				ddr_din <= w_data;
				ddr_be <= w_be;
				wr_inflight <= 1'b1;
				w_have <= 1'b0;
				if (cache_valid && cache_qaddr == w_qaddr)
					cache_valid <= 1'b0;
			end

			// --- reads: cache or issue ---
			if (mem_rd && !rq_valid && !rd_inflight) begin
				if (cache_valid && cache_qaddr == rd_q) begin
					mem_rdata <= pick_byte(cache_data, rd_l);
					mem_rvalid <= 1'b1;
				end else begin
					rq_valid <= 1'b1;
					rq_qaddr <= rd_q;
					rq_lane <= rd_l;
				end
			end

			// Issue / hold read until dout_ready (DDRAM-style handshake).
			// Writes take the bus only while wr_inflight; pending w_have can
			// wait so a posted read is not starved forever in TB/single-master.
			if (rq_valid && !rd_inflight && !wr_inflight && !ddr_busy) begin
				ddr_rd <= 1'b1;
				ddr_addr <= rq_qaddr;
				rd_inflight <= 1'b1;
			end
			if (rd_inflight && ddr_dout_ready) begin
				cache_valid <= 1'b1;
				cache_qaddr <= rq_qaddr;
				cache_data <= ddr_dout;
				mem_rdata <= pick_byte(ddr_dout, rq_lane);
				mem_rvalid <= 1'b1;
				rq_valid <= 1'b0;
				rd_inflight <= 1'b0;
				ddr_rd <= 1'b0;
			end
		end
	end
endmodule

`default_nettype wire
