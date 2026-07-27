// Phase 3.3b/3.3d/3.3j/k: stand-in for H.264 soft-core.
// On each VCL NAL, wait for slice/residual probe then paint 320×240 RGB565
// diagnostic into frame_store (or residual MB0 gray when residual_ok).
// 3.3j: paint after residual_ok/slice_valid so MB0 gray matches probe;
//       hybrid product present is host F1 (see Plex.sv host_owns_fs).

module decode_stub #(
	parameter int WIDTH  = 320,
	parameter int HEIGHT = 240
)(
	input  wire        clk,
	input  wire        reset,

	input  wire        vcl_pulse,
	input  wire [7:0]  last_nal_type,
	input  wire [15:0] nalu_count,
	input  wire [7:0]  idr_count,
	input  wire        has_idr,

	input  wire        sps_valid,
	input  wire [7:0]  mb_w,
	input  wire [7:0]  mb_h,
	input  wire [7:0]  slice_type,
	input  wire        slice_is_i,
	input  wire        slice_valid,
	// 3.3g/j/k: first-MB residual cue for eyes-on recon stub
	input  wire        residual_ok,
	input  wire [4:0]  residual_tc,
	input  wire signed [7:0] residual_dc,
	input  wire [5:0]  slice_qp,
	input  wire signed [8:0] residual_coeff [0:15],

	output reg  [7:0]  recon_sig,
	output reg         recon_valid,

	output reg         wr_en,
	output reg  [15:0] wr_pixel,
	output reg         wr_reset_ptr,
	output reg         swap_req,
	output reg         busy,
	output reg  [15:0] frames_out
);

	localparam int PIXELS = WIDTH * HEIGHT;
	localparam int ADDR_W = $clog2(PIXELS);
	// Slice RBSP cap is 48B; bit-walk + residual token ≪ 4096 cycles @ clk_sys
	localparam int WAIT_MAX = 4095;

	reg [ADDR_W:0] pix_i;
	reg [9:0]      x, y;
	// 0 idle, 1 wait residual/slice, 2 paint
	reg [1:0]      phase;
	reg            is_idr_frame;
	reg            is_i_frame;
	reg [7:0]      lat_type;
	reg [15:0]     lat_nalu;
	reg [7:0]      lat_idr;
	reg [7:0]      lat_mb_w, lat_mb_h;
	reg            lat_sps;
	reg            lat_res_ok;
	reg [4:0]      lat_res_tc;
	reg signed [7:0] lat_res_dc;
	reg [5:0]      lat_qp;
	reg signed [8:0] lat_coeff [0:15];
	reg [11:0]     wait_cnt;
	reg            slice_valid_d;
	reg            residual_ok_d;
	integer        coeff_i;

	wire [9:0] width_w  = WIDTH[9:0];
	wire [9:0] height_w = HEIGHT[9:0];
	wire border = (x < 10'd4) || (x >= (width_w - 10'd4)) ||
	              (y < 10'd4) || (y >= (height_w - 10'd4));
	wire strip  = (y < 10'd16);

	// Macroblock grid lines every 16 px when SPS known
	wire mb_line = lat_sps && ((x[3:0] == 4'd0) || (y[3:0] == 4'd0));
	// MB index colour hash
	wire [7:0] mbx = x[9:4];
	wire [7:0] mby = y[9:4];
	wire [7:0] mb_hash = mbx + mby + lat_nalu[7:0];
	// First MB (0,0) filled with recon stub gray when residual_ok
	wire mb0 = (x < 10'd16) && (y < 10'd16);
	// 3.3l-2: first 4x4 inv_quant + IDCT (pred=128) from the shared
	// h264_iq_idct_4x4.sv RTL. The signature is XOR of reconstructed samples.
	wire signed [17:0] idct_dequant [0:15];
	wire signed [17:0] idct_residual [0:15];
	wire [7:0] idct_pred [0:15];
	wire [7:0] recon_px [0:15];
	wire [7:0] recon_sig_comb = recon_px[0]  ^ recon_px[1]  ^ recon_px[2]  ^ recon_px[3] ^
	                            recon_px[4]  ^ recon_px[5]  ^ recon_px[6]  ^ recon_px[7] ^
	                            recon_px[8]  ^ recon_px[9]  ^ recon_px[10] ^ recon_px[11] ^
	                            recon_px[12] ^ recon_px[13] ^ recon_px[14] ^ recon_px[15];

	genvar pred_i;
	generate
		for (pred_i = 0; pred_i < 16; pred_i = pred_i + 1) begin : gen_idct_pred
			assign idct_pred[pred_i] = 8'd128;
		end
	endgenerate

	h264_dequant4x4 u_h264_dequant4x4 (
		.coeff(lat_coeff),
		.qp(lat_qp),
		.max_coeff(5'd16),
		.dequant(idct_dequant)
	);

	h264_idct4x4 u_h264_idct4x4 (
		.dequant(idct_dequant),
		.residual(idct_residual)
	);

	h264_recon4x4 u_h264_recon4x4 (
		.pred(idct_pred),
		.residual(idct_residual),
		.recon(recon_px)
	);

	// 3.3k fallback: paint from residual_dc (scan coeff0 → 128+dc)
	wire signed [9:0] recon_sum = 10'sd128 + lat_res_dc;
	wire [7:0] recon_from_dc =
		(recon_sum < 10'sd0)   ? 8'd0 :
		(recon_sum > 10'sd255) ? 8'd255 : recon_sum[7:0];
	wire first4 = mb0 && (x < 10'd4) && (y < 10'd4);
	wire [3:0] first4_idx = {y[1:0], x[1:0]};
	wire [7:0] recon_y = (lat_res_ok && first4) ? recon_px[first4_idx] :
	                     (lat_res_ok ? recon_from_dc : (8'd128 + {3'b0, lat_res_tc}));

	wire idr_style = is_idr_frame || (lat_type[4:0] == 5'd5);

	wire [7:0] rr =
		border   ? 8'h10 :
		(mb0 && lat_res_ok) ? recon_y :
		strip    ? {lat_type[4:0], 3'b000} :
		mb_line  ? (is_i_frame ? 8'h20 : 8'h80) :
		           (8'h08 + {4'b0, mb_hash[3:0]});
	wire [7:0] gg =
		border   ? (idr_style ? 8'hE0 : 8'hC0) :
		(mb0 && lat_res_ok) ? recon_y :
		strip    ? lat_idr :
		mb_line  ? (is_i_frame ? 8'hE0 : 8'h40) :
		           (8'h18 + {3'b0, mb_hash[4:0]});
	wire [7:0] bb =
		border   ? (idr_style ? 8'h20 : 8'hE0) :
		(mb0 && lat_res_ok) ? recon_y :
		strip    ? 8'h20 :
		mb_line  ? 8'h30 :
		           (8'h40 + {mb_hash[5:0], 2'b00});
	wire [15:0] px_comb = {rr[7:3], gg[7:2], bb[7:3]};

	// Only rising residual/slice after VCL — ignore sticky previous-NAL values
	wire res_rise   = residual_ok & ~residual_ok_d;
	wire slice_rise = slice_valid & ~slice_valid_d;
	wire wait_done  = res_rise | slice_rise | (wait_cnt == 12'd0);

	always @(posedge clk) begin
		wr_en         <= 1'b0;
		wr_reset_ptr  <= 1'b0;
		swap_req      <= 1'b0;
		slice_valid_d <= slice_valid;
		residual_ok_d <= residual_ok;

		if (reset) begin
			phase         <= 2'd0;
			busy          <= 0;
			pix_i         <= 0;
			x             <= 0;
			y             <= 0;
			frames_out    <= 0;
			is_idr_frame  <= 0;
			is_i_frame    <= 0;
			lat_type      <= 0;
			lat_nalu      <= 0;
			lat_idr       <= 0;
			lat_mb_w      <= 0;
			lat_mb_h      <= 0;
			lat_sps       <= 0;
			lat_res_ok    <= 0;
			lat_res_tc    <= 0;
			lat_res_dc    <= 0;
			lat_qp        <= 0;
			for (coeff_i = 0; coeff_i < 16; coeff_i = coeff_i + 1)
				lat_coeff[coeff_i] <= 9'sd0;
			recon_sig     <= 0;
			recon_valid   <= 0;
			wait_cnt      <= 0;
			wr_pixel      <= 0;
			slice_valid_d <= 0;
			residual_ok_d <= 0;
		end else if (phase == 2'd0) begin
			// Idle: on VCL always wait for *this* NAL's residual/slice rise
			if (vcl_pulse) begin
				phase    <= 2'd1;
				busy     <= 1'b1;
				wait_cnt <= WAIT_MAX[11:0];
				lat_type <= last_nal_type;
				lat_nalu <= nalu_count;
				lat_idr  <= idr_count;
			end
		end else if (phase == 2'd1) begin
			if (wait_cnt != 12'd0)
				wait_cnt <= wait_cnt - 12'd1;
			if (wait_done) begin
				phase        <= 2'd2;
				pix_i        <= 0;
				x            <= 0;
				y            <= 0;
				wr_reset_ptr <= 1'b1;
				is_idr_frame <= (lat_type[4:0] == 5'd5);
				is_i_frame   <= slice_is_i || (lat_type[4:0] == 5'd5);
				lat_sps      <= sps_valid;
				lat_mb_w     <= (mb_w == 0) ? 8'd20 : mb_w;
				lat_mb_h     <= (mb_h == 0) ? 8'd15 : mb_h;
				lat_res_ok   <= residual_ok;
				lat_res_tc   <= residual_tc;
				lat_res_dc   <= residual_dc;
				lat_qp       <= slice_qp;
				for (coeff_i = 0; coeff_i < 16; coeff_i = coeff_i + 1)
					lat_coeff[coeff_i] <= residual_coeff[coeff_i];
				recon_valid  <= 1'b0;
			end
		end else begin
			// Paint full frame
			wr_en    <= 1'b1;
			wr_pixel <= px_comb;
			if (pix_i == 0) begin
				recon_sig   <= lat_res_ok ? recon_sig_comb : 8'd0;
				recon_valid <= lat_res_ok;
			end

			if (pix_i == PIXELS[ADDR_W:0] - 1'd1) begin
				phase      <= 2'd0;
				busy       <= 1'b0;
				swap_req   <= 1'b1;
				frames_out <= frames_out + 1'd1;
				pix_i      <= 0;
				x          <= 0;
				y          <= 0;
			end else begin
				pix_i <= pix_i + 1'd1;
				if (x == (width_w - 10'd1)) begin
					x <= 0;
					y <= y + 1'd1;
				end else
					x <= x + 1'd1;
			end
		end
	end

endmodule
