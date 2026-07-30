// Per-frame reconstructed I420 MB store for self-produced DPB reference commit.
//
// Product decode_stub writes Clip1(pred+residual) (or partial IDR recon) here;
// PH_DPB_FILL reads raster-384 samples back into the deblock writeback / DPB path.
// This closes the golden-prefill cheat: reference bank content comes only from
// samples the RTL itself reconstructed earlier in the sequence.
//
// Interaction:
//   - MV/residual quality is owned by other lanes; this module is content-agnostic.
//   - Deblock may still be bypassed when samples are treated as already-filtered
//     at the writeback seam (score manifests must say pre_deblock when true).
//
`default_nettype none

module h264_recon_frame_store #(
	parameter int MB_COUNT = 300,
	parameter int MB_AW = (MB_COUNT <= 1) ? 1 : $clog2(MB_COUNT)
)(
	input  wire               clk,
	input  wire               reset,

	// Clear whole store to mid-gray (IDR picture start)
	input  wire               clear,
	input  wire [7:0]         clear_y,
	input  wire [7:0]         clear_c,

	// Write one reconstructed MB (arrays stable through write_start pulse)
	input  wire               write_start,
	input  wire [MB_AW-1:0]   write_mb_addr,
	input  wire [7:0]         write_y [0:255],
	input  wire [7:0]         write_u [0:63],
	input  wire [7:0]         write_v [0:63],
	output wire               write_busy,
	output wire               write_done,

	// Read one sample in DPB fill order (Y 0..255, U 256..319, V 320..383)
	input  wire [MB_AW-1:0]   read_mb_addr,
	input  wire [8:0]         read_sample_idx,
	output wire [7:0]         read_sample
);
	(* ram_style = "block" *) reg [7:0] mem [0:MB_COUNT*384-1];

	// Simulation / cold-start: mid-gray until RTL writes reconstructed MBs.
	integer init_i;
	initial begin
		for (init_i = 0; init_i < MB_COUNT * 384; init_i = init_i + 1)
			mem[init_i] = (init_i % 384 < 256) ? 8'd128 : 8'd128;
	end

	reg               wr_active;
	reg [MB_AW-1:0]   wr_mb;
	reg [8:0]         wr_idx;
	reg [7:0]         wr_y [0:255];
	reg [7:0]         wr_u [0:63];
	reg [7:0]         wr_v [0:63];
	reg               wr_done_r;

	// Optional clear walks the store (bounded; TB frames are 300 MB @ 320x240).
	reg               clr_active;
	reg [31:0]        clr_idx;
	localparam int TOTAL = MB_COUNT * 384;

	assign write_busy = wr_active | clr_active;
	assign write_done = wr_done_r;

	wire [31:0] wr_base = {16'd0, wr_mb} * 32'd384;
	wire [31:0] rd_base = {16'd0, read_mb_addr} * 32'd384;
	wire [31:0] rd_addr = rd_base + {23'd0, read_sample_idx};

	// Combinational read for fill path (same-cycle sample)
	assign read_sample = (rd_addr < TOTAL[31:0]) ? mem[rd_addr] : 8'd128;

	integer ci;
`ifdef VERILATOR
	reg [15:0] dbg_wr_start_cy;
	reg        dbg_wr_stuck_printed;
`endif
	always @(posedge clk) begin
		wr_done_r <= 1'b0;
		if (reset) begin
			wr_active <= 1'b0;
			wr_mb <= '0;
			wr_idx <= 9'd0;
			clr_active <= 1'b0;
			clr_idx <= 32'd0;
`ifdef VERILATOR
			dbg_wr_start_cy <= 16'd0;
			dbg_wr_stuck_printed <= 1'b0;
`endif
		end else begin
			if (clear && !clr_active && !wr_active) begin
				clr_active <= 1'b1;
				clr_idx <= 32'd0;
			end else if (clr_active) begin
				if (clr_idx < TOTAL[31:0]) begin
					if (clr_idx % 32'd384 < 32'd256)
						mem[clr_idx] <= clear_y;
					else
						mem[clr_idx] <= clear_c;
					clr_idx <= clr_idx + 32'd1;
				end else begin
					clr_active <= 1'b0;
				end
			end else if (write_start && !wr_active) begin
				wr_active <= 1'b1;
				wr_mb <= write_mb_addr;
				wr_idx <= 9'd0;
				for (ci = 0; ci < 256; ci = ci + 1)
					wr_y[ci] <= write_y[ci];
				for (ci = 0; ci < 64; ci = ci + 1) begin
					wr_u[ci] <= write_u[ci];
					wr_v[ci] <= write_v[ci];
				end
`ifdef VERILATOR
				dbg_wr_start_cy <= 16'd0;
`endif
			end else if (wr_active) begin
`ifdef VERILATOR
				dbg_wr_start_cy <= dbg_wr_start_cy + 16'd1;
				if (!dbg_wr_stuck_printed && dbg_wr_start_cy == 16'd500) begin
					dbg_wr_stuck_printed <= 1'b1;
					$display("STORE_STUCK mb=%0d idx=%0d start=%0d clr=%0d",
						wr_mb, wr_idx, write_start, clr_active);
				end
`endif
				if (wr_idx < 9'd256)
					mem[wr_base + {23'd0, wr_idx}] <= wr_y[wr_idx[7:0]];
				else if (wr_idx < 9'd320)
					mem[wr_base + {23'd0, wr_idx}] <= wr_u[wr_idx[5:0]];
				else
					mem[wr_base + {23'd0, wr_idx}] <= wr_v[wr_idx[5:0]];
				if (wr_idx == 9'd383) begin
					wr_active <= 1'b0;
					wr_done_r <= 1'b1;
					wr_idx <= 9'd0;
				end else begin
					wr_idx <= wr_idx + 9'd1;
				end
			end
		end
	end
endmodule

`default_nettype wire
