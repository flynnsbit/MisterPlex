// h264_dpb_ddr_backend.sv — DDR-backed DPB1 storage + burst line fetch + area budget.
//
// DELTA framing (rd-duck NACK on file-wide edges + RBF "area paid" claims):
//   Source-graph LIVE helpers ≠ shipping RBF and ≠ area paid. Deployed RBF may
//   only carry decode_stub; PRODUCT_NO_STUB drops the stub branch entirely.
//   This file is the 720p storage option: frames in external DDR, window+nb on M10K.
//   Unwired (qip but DEAD): fit delta = 0. Do not claim area already paid.
// ENABLE_DPB_DDR=0 (product default): 1-cycle local byte RAM (decode_stub contract).
// ENABLE_DPB_DDR=1: banks at w-mem phys (0x30700000, stride 0x180000), multi-cycle
//   reads; sim holds pixels in a model array (not for Quartus without f2sdram client).
// Present doorbell/base are NOT redefined here.
`default_nettype none

module h264_dpb_ddr_backend #(
	parameter int FRAME_W = 624,
	parameter int FRAME_H = 480,
	parameter bit ENABLE_DPB_DDR = 1'b0,
	parameter int DDR_RD_LATENCY = 4
)(
	input  wire        clk,
	input  wire        reset,
	input  wire        mem_we,
	input  wire [31:0] mem_waddr,
	input  wire [7:0]  mem_wdata,
	input  wire        mem_rd,
	input  wire [31:0] mem_raddr,
	output reg         mem_rvalid,
	output wire [7:0]  mem_rdata,
	output wire [31:0] bank0_base,
	output wire [31:0] bank1_base,
	output wire [31:0] frame_bytes,
	output wire [31:0] dual_bank_bytes,
	output wire [31:0] onchip_storage_bytes
);
	`include "h264_dpb_ddr_params.svh"

	localparam int FRAME_BYTES_L = FRAME_W * FRAME_H + 2 * ((FRAME_W / 2) * (FRAME_H / 2));
	localparam int DUAL_BYTES_L  = 2 * FRAME_BYTES_L;
	localparam int AW = (DUAL_BYTES_L <= 1) ? 1 : $clog2(DUAL_BYTES_L);

	assign frame_bytes     = FRAME_BYTES_L[31:0];
	assign dual_bank_bytes = DUAL_BYTES_L[31:0];

	generate
		if (ENABLE_DPB_DDR) begin : g_ddr
			assign bank0_base = H264_DPB_DDR_BANK0[31:0];
			assign bank1_base = H264_DPB_DDR_BANK1[31:0];
			assign onchip_storage_bytes = 32'd0;

			localparam int SIM_SPAN = 2 * H264_DPB_DDR_BANK_STRIDE;
			reg [7:0] ddr_sim [0:SIM_SPAN-1];
			reg [7:0] ddr_rdata_r;
			assign mem_rdata = ddr_rdata_r;

			reg [31:0] pipe_addr [0:15];
			reg        pipe_v    [0:15];
			integer    li;

			function automatic [31:0] off_of(input [31:0] a);
				begin
					if (a >= H264_DPB_DDR_BANK0[31:0])
						off_of = a - H264_DPB_DDR_BANK0[31:0];
					else
						off_of = a;
				end
			endfunction

			always @(posedge clk) begin
				if (reset) begin
					mem_rvalid <= 1'b0;
					ddr_rdata_r <= 8'd0;
					for (li = 0; li < 16; li = li + 1) begin
						pipe_v[li] <= 1'b0;
						pipe_addr[li] <= 32'd0;
					end
				end else begin
					for (li = 15; li > 0; li = li - 1) begin
						pipe_v[li]    <= pipe_v[li - 1];
						pipe_addr[li] <= pipe_addr[li - 1];
					end
					pipe_v[0]    <= mem_rd;
					pipe_addr[0] <= mem_raddr;

					if (mem_we && off_of(mem_waddr) < SIM_SPAN[31:0])
						ddr_sim[off_of(mem_waddr)] <= mem_wdata;

					mem_rvalid <= 1'b0;
					if (DDR_RD_LATENCY >= 1 && pipe_v[DDR_RD_LATENCY - 1]) begin
						mem_rvalid <= 1'b1;
						if (off_of(pipe_addr[DDR_RD_LATENCY - 1]) < SIM_SPAN[31:0])
							ddr_rdata_r <= ddr_sim[off_of(pipe_addr[DDR_RD_LATENCY - 1])];
						else
							ddr_rdata_r <= 8'h00;
					end
				end
			end
		end else begin : g_local
			assign bank0_base = 32'd0;
			assign bank1_base = FRAME_BYTES_L[31:0];
			assign onchip_storage_bytes = DUAL_BYTES_L[31:0];

			(* ramstyle = "no_rw_check, M10K" *) reg [7:0] local_mem [0:DUAL_BYTES_L-1];
			reg [31:0] raddr_q;

			// Match decode_stub: rvalid tracks rd; rdata combo from registered addr.
			assign mem_rdata = (raddr_q < DUAL_BYTES_L[31:0]) ?
			                   local_mem[raddr_q[AW-1:0]] : 8'h00;

			always @(posedge clk) begin
				if (reset) begin
					mem_rvalid <= 1'b0;
					raddr_q    <= 32'd0;
				end else begin
					if (mem_we && mem_waddr < DUAL_BYTES_L[31:0])
						local_mem[mem_waddr[AW-1:0]] <= mem_wdata;
					raddr_q    <= mem_raddr;
					mem_rvalid <= mem_rd;
				end
			end
		end
	endgenerate
endmodule

// 64-bit line fetch; FAULT_SINGLE_BEAT drops second beat across boundary (NEG).
module h264_dpb_ddr_line_fetch #(
	parameter bit FAULT_SINGLE_BEAT = 1'b0
)(
	input  wire        clk,
	input  wire        reset,
	input  wire        start,
	input  wire [31:0] line_base,
	input  wire [4:0]  nbytes,
	output reg         ddr_rd,
	output reg  [31:0] ddr_raddr,
	input  wire [63:0] ddr_rdata,
	input  wire        ddr_rvalid,
	output reg         done,
	output reg  [7:0]  out_b [0:15],
	output reg  [5:0]  out_count
);
	localparam [2:0] S_IDLE = 3'd0;
	localparam [2:0] S_RD0  = 3'd1;
	localparam [2:0] S_RD1  = 3'd2;
	localparam [2:0] S_PACK = 3'd3;

	reg [2:0]  st;
	reg [2:0]  skip;
	reg [4:0]  need;
	reg [31:0] a0;
	reg        want1;
	reg [63:0] b0, b1;
	integer    k;

	wire [31:0] last_a = line_base + {27'd0, nbytes} - 32'd1;
	wire        crosses = ({last_a[31:3], 3'd0} != {line_base[31:3], 3'd0});

	always @(posedge clk) begin
		if (reset) begin
			st <= S_IDLE;
			ddr_rd <= 1'b0;
			done <= 1'b0;
			out_count <= 6'd0;
			b0 <= 64'd0;
			b1 <= 64'd0;
			for (k = 0; k < 16; k = k + 1)
				out_b[k] <= 8'd0;
		end else begin
			ddr_rd <= 1'b0;
			done <= 1'b0;
			case (st)
			S_IDLE: begin
				if (start) begin
					skip <= line_base[2:0];
					need <= nbytes;
					a0 <= {line_base[31:3], 3'd0};
					want1 <= crosses && !FAULT_SINGLE_BEAT;
					st <= S_RD0;
				end
			end
			S_RD0: begin
				ddr_rd <= 1'b1;
				ddr_raddr <= a0;
				if (ddr_rvalid) begin
					b0 <= ddr_rdata;
					ddr_rd <= 1'b0;
					if (want1)
						st <= 3'd4; // S_GAP
					else begin
						b1 <= 64'd0;
						st <= S_PACK;
					end
				end
			end
			3'd4: begin // S_GAP — drop beat so next rvalid is fresh
				ddr_rd <= 1'b0;
				st <= S_RD1;
			end
			S_RD1: begin
				ddr_rd <= 1'b1;
				ddr_raddr <= a0 + 32'd8;
				if (ddr_rvalid) begin
					b1 <= ddr_rdata;
					ddr_rd <= 1'b0;
					st <= S_PACK;
				end
			end
			S_PACK: begin
				// little-endian lanes: byte0 @ align+0
				for (k = 0; k < 16; k = k + 1) begin
					if (k < 8)
						; // filled below
				end
				begin : pack
					reg [7:0] stream [0:15];
					stream[0]  = b0[7:0];
					stream[1]  = b0[15:8];
					stream[2]  = b0[23:16];
					stream[3]  = b0[31:24];
					stream[4]  = b0[39:32];
					stream[5]  = b0[47:40];
					stream[6]  = b0[55:48];
					stream[7]  = b0[63:56];
					stream[8]  = b1[7:0];
					stream[9]  = b1[15:8];
					stream[10] = b1[23:16];
					stream[11] = b1[31:24];
					stream[12] = b1[39:32];
					stream[13] = b1[47:40];
					stream[14] = b1[55:48];
					stream[15] = b1[63:56];
					for (k = 0; k < 16; k = k + 1) begin
						if (k < need)
							out_b[k] <= stream[4'(skip) + 4'(k)];
						else
							out_b[k] <= 8'd0;
					end
				end
				out_count <= {1'b0, need};
				done <= 1'b1;
				st <= S_IDLE;
			end
			default: st <= S_IDLE;
			endcase
		end
	end
endmodule

module h264_dpb_area_budget #(
	parameter int FRAME_W = 1280,
	parameter int FRAME_H = 720,
	parameter int NUM_REF = 1
)(
	output wire [31:0] bytes_per_ref_frame,
	output wire [31:0] bytes_dpb1_total,
	output wire [31:0] onchip_window_bytes,
	output wire [31:0] onchip_nb_bytes,
	output wire [31:0] onchip_ddr_path_bytes,
	output wire        full_frame_onchip_illegal,
	output wire [31:0] m10k_lower_bound_full_dpb,
	// DELTA vs LIVE baseline: helpers have 0 frame bytes; stub BRAM would hold DPB.
	// ddr_path_delta_onchip = working set ADDED when ENABLE_DPB_DDR path is wired.
	// m10k_delta_vs_stub_bram = path_m10k - full_dpb_m10k (negative => savings).
	output wire [31:0] live_helper_frame_storage_bytes,
	output wire [31:0] stub_bram_bytes_if_kept,
	output wire [31:0] ddr_path_delta_onchip_bytes,
	output wire signed [31:0] m10k_delta_vs_stub_bram
);
	`include "h264_dpb_ddr_params.svh"
	localparam int FB = FRAME_W * FRAME_H + 2 * ((FRAME_W / 2) * (FRAME_H / 2));
	localparam int DPB = FB * (NUM_REF + 1);
	localparam int NB = FRAME_W + FRAME_W + 16 + (FRAME_W / 2) + (FRAME_W / 2) + 16;
	localparam int WIN = H264_DPB_WIN_TOTAL;
	localparam int ONCHIP = WIN + NB;
	localparam int M10K_FULL = (DPB * 8 + 10239) / 10240;
	localparam int M10K_PATH = (ONCHIP * 8 + 10239) / 10240;
	localparam int M10K_DELTA = M10K_PATH - M10K_FULL;

	assign bytes_per_ref_frame = FB[31:0];
	assign bytes_dpb1_total = DPB[31:0];
	assign onchip_window_bytes = WIN[31:0];
	assign onchip_nb_bytes = NB[31:0];
	assign onchip_ddr_path_bytes = ONCHIP[31:0];
	assign full_frame_onchip_illegal = (DPB > 200_000);
	assign m10k_lower_bound_full_dpb = M10K_FULL[31:0];
	assign live_helper_frame_storage_bytes = 32'd0;
	assign stub_bram_bytes_if_kept = DPB[31:0];
	assign ddr_path_delta_onchip_bytes = ONCHIP[31:0];
	assign m10k_delta_vs_stub_bram = M10K_DELTA[31:0];
endmodule

`default_nettype wire
