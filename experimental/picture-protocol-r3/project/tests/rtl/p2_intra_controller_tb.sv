// Composed syntax/controller test. Only encoded RBSP and SPS/PPS metadata
// enter this test; the reference YUV file is never connected to the DUT.
module p2_intra_controller_tb #(
	parameter int RBSP_ADDR_W = 13,
	parameter bit NATIVE_PUBLISH_LEASE = 1'b0,
	parameter bit STATIC_IDR_ONLY = 1'b0
) (
	input wire clk, reset, vcl, clear, byte_en, header_end, rbsp_end,
	input wire [7:0] byte_data,
	input wire [RBSP_ADDR_W:0] rbsp_len,
	input wire [4:0] frame_bits, poc_bits,
	input wire [2:0] poc_type,
	input wire signed [7:0] initial_qp,
	input wire signed [5:0] chroma_offset,
	input wire deblock_control, idr, wr_ready,
	input wire constrained_intra,
	input wire full_range,
	input wire [7:0] matrix,
	input wire [1:0] nri,
	input wire [7:0] max_refs,
	input wire idr_only,
	input wire [7:0] mb_cols, mb_rows,
	input wire geometry_valid,
	input wire [15:0] crop_left, crop_right, crop_top, crop_bottom, sar_width, sar_height,
	input wire sar_known,
	input wire native_release, pub_rd,
	input wire [31:0] pub_addr,
	output wire native_valid, native_lease_enabled, pub_ready,
	output wire static_idr_only_enabled,
	output wire [31:0] native_base,
	output reg pub_rvalid,
	output reg [7:0] pub_rdata,
	output wire busy, done, wr_en, swap_req,
	output wire [15:0] wr_pixel, frames_out, mb_index,
	output wire native_we, native_accept,
	output wire [31:0] native_addr,
	output wire [7:0] native_data,
	output wire [4:0] phase,
	output wire [7:0] error,
	output wire [RBSP_ADDR_W+3:0] bit_pos,
	output wire [31:0] rbsp_capacity, capture_len, capture_count, bit_length,
	output wire [7:0] capture_first, capture_last,
	output wire capture_done, capture_overflow, reader_eof, reader_error,
	output wire header_valid, header_error,
	output wire native_promoted,
	output wire prediction_reference_valid,
	output wire present_meta_valid,
	output wire [15:0] present_coded_width, present_coded_height, present_width, present_height,
	output wire [15:0] present_crop_left, present_crop_right, present_crop_top, present_crop_bottom,
	output wire [15:0] present_sar_width, present_sar_height, native_luma_stride, native_chroma_stride,
	output wire present_sar_known,
	output wire [31:0] present_dar_num, present_dar_den,
	output wire [1:0] filter_idc,
	output reg [15:0] max_abs_coeff,
	output reg [8:0] i4_modes,
	output reg [3:0] i16_modes, chroma_modes,
	output reg [15:0] chroma_ac_blocks, intra_in_p, qpel_phases,
	output reg [3:0] mc_borders,
	output wire chroma_start, chroma_pending, chroma_done, chroma_retire,
	output wire [2:0] chroma_stage,
	output wire hdc_accept, hdc_retire, hdc_busy, hdc_done, hdc_valid,
	output wire [4:0] hdc_stage
);
	wire [15:0] first_mb;
	wire [7:0] slice_type;
	wire slice_i;
	wire [5:0] qp;
	wire [RBSP_ADDR_W+3:0] header_pos, residual_pos;
	wire pos_valid;
	wire signed [8:0] diagnostic_coeff [0:15];
	genvar i;
	generate for(i=0;i<16;i=i+1) begin: zeros
		assign diagnostic_coeff[i]=0;
	end endgenerate
	slice_hdr_parser #(.BIT_W(RBSP_ADDR_W+4)) header (
		.clk(clk),.reset(reset),.cap_clear(clear),.cap_en(byte_en),
		.cap_data(byte_data),.cap_end(header_end),
		.is_idr_nal(idr),.nal_ref_idc(nri),
		.log2_max_frame_num(frame_bits),.log2_max_pic_order_cnt_lsb(poc_bits),
		.poc_type(poc_type),.sps_ready(1'b1),.pps_ready(1'b1),
		.deblock_ctrl(deblock_control),.pic_init_qp(initial_qp),
		.active_pps_id(8'd0),.num_ref_l0(8'd0),
		.valid(header_valid),.error(header_error),.first_mb(first_mb),
		.slice_type(slice_type),.is_i_slice(slice_i),.slice_qp(qp),
		.disable_deblocking_idc(filter_idc),.bit_pos_hdr(header_pos),
		.bit_pos_resid(residual_pos),.bit_pos_valid(pos_valid)
	);
	wire rd;
	wire [31:0] raddr;
	reg [7:0] rdata;
	reg rvalid;
	reg [7:0] picture [0:230399];
	assign native_lease_enabled=NATIVE_PUBLISH_LEASE;
	assign static_idr_only_enabled=STATIC_IDR_ONLY;
	assign pub_ready=native_valid && !native_accept && !reset;
	always @(posedge clk) begin
		if(native_accept) picture[native_addr]<=native_data;
		else if(pub_rd && pub_ready)pub_rdata<=picture[pub_addr];
		pub_rvalid<=pub_rd && pub_ready;
		rvalid<=rd;
		if(rd)rdata<=picture[raddr];
	end
	h264_mb_ctrl #(.RBSP_ADDR_W(RBSP_ADDR_W),.NATIVE_PUBLISH_LEASE(NATIVE_PUBLISH_LEASE),
	              .STATIC_IDR_ONLY(STATIC_IDR_ONLY)) dut (
		.clk(clk),.reset(reset),.vcl_pulse(vcl),.sps_valid(1'b1),
		.mb_w(mb_cols),.mb_h(mb_rows),.slice_type(slice_type),.slice_is_i(slice_i),
		.picture_geometry_valid(geometry_valid),.picture_is_idr(idr),
		.picture_nal_ref_idc(nri),
		.picture_max_num_ref_frames(max_refs),.picture_idr_only(idr_only),
		.picture_crop_left(crop_left),.picture_crop_right(crop_right),
		.picture_crop_top(crop_top),.picture_crop_bottom(crop_bottom),
		.picture_sar_width(sar_width),.picture_sar_height(sar_height),
		.picture_sar_known(sar_known),
		.native_picture_release(native_release),
		.native_picture_valid(native_valid),.native_picture_base(native_base),
		.present_meta_valid(present_meta_valid),
		.present_coded_width(present_coded_width),.present_coded_height(present_coded_height),
		.present_width(present_width),.present_height(present_height),
		.present_crop_left(present_crop_left),.present_crop_right(present_crop_right),
		.present_crop_top(present_crop_top),.present_crop_bottom(present_crop_bottom),
		.present_sar_width(present_sar_width),.present_sar_height(present_sar_height),
		.present_sar_known(present_sar_known),
		.present_dar_num(present_dar_num),.present_dar_den(present_dar_den),
		.native_luma_stride(native_luma_stride),.native_chroma_stride(native_chroma_stride),
		.slice_valid(header_valid),.slice_error(header_error),.slice_qp(qp),.residual_ok(1'b0),
		.residual_coeff(diagnostic_coeff),.residual_place_pulse(1'b0),
		.first_mb(first_mb),.first_mb_type(8'd0),.pps_nref(8'd1),
		.pps_deblock(deblock_control),.slice_disable_deblocking_filter_idc(filter_idc),
		.pps_chroma_qp_index_offset(chroma_offset),
		.pps_constrained_intra_pred(constrained_intra),
		.video_full_range(full_range), .video_matrix_coefficients(matrix),
		.sl_rbsp_clear(clear),.sl_rbsp_en(byte_en),.sl_rbsp_data(byte_data),
		.sl_rbsp_end(rbsp_end),.sl_rbsp_len(rbsp_len),
		.bit_pos_hdr(header_pos),.bit_pos_resid(residual_pos),.bit_pos_valid(pos_valid),
		.wr_ready(wr_ready),.present_sel(1'b1),.wr_en(wr_en),.wr_pixel(wr_pixel),
		.swap_req(swap_req),.busy(busy),.done(done),.frames_out(frames_out),.mb_index(mb_index),
		.dpb_mem_we(native_we),.dpb_mem_waddr(native_addr),.dpb_mem_wdata(native_data),
		.dpb_mem_rd(rd),.dpb_mem_raddr(raddr),.dpb_mem_rdata(rdata),.dpb_mem_rvalid(rvalid)
	);
	assign phase=dut.phase;
	assign chroma_start=dut.chr_start;
	assign chroma_pending=dut.chr_pending;
	assign chroma_done=dut.chr_done;
	assign chroma_stage=dut.u_chr_pred.state;
	assign chroma_retire=!reset && dut.chr_owner && !dut.chr_mode_bad &&
		dut.chr_pending && dut.chr_done && !dut.frame_abort;
	assign hdc_accept=dut.hdc_start && !dut.hdc_reset && !dut.u_i16_dc.busy;
	assign hdc_retire=dut.hdc_done && !dut.hdc_reset && !dut.hdc_start;
	assign hdc_busy=dut.u_i16_dc.busy;
	assign hdc_done=dut.hdc_done;
	assign hdc_valid=dut.hdc_valid;
	assign hdc_stage=dut.hdc_done ? 5'd19 :
		dut.u_i16_dc.columns_pending ? 5'd0 :
		!dut.u_i16_dc.issued_all ? 5'd1+{1'b0,dut.u_i16_dc.mi} :
		dut.u_i16_dc.product_valid ? 5'd17 : 5'd18;
	assign error=dut.decode_error;
	assign bit_pos=dut.br_bit_pos;
	assign native_promoted=dut.dpb_frame_promoted;
	assign native_accept=dut.dpb_mem_waccept;
	assign prediction_reference_valid=dut.prediction_reference_valid;
	assign rbsp_capacity=1<<RBSP_ADDR_W;
	assign capture_len=dut.rbsp_bytes;
	assign capture_count=dut.captured_bytes;
	assign bit_length=dut.bit_len;
	assign capture_first=dut.u_sl_rbsp.mem[0];
	assign capture_last=dut.u_sl_rbsp.mem[(1<<RBSP_ADDR_W)-1];
	assign capture_done=dut.rbsp_done;
	assign capture_overflow=dut.capture_overflow || dut.rbsp_ram_overflow;
	assign reader_eof=dut.br_eof;
	assign reader_error=dut.br_error;
	integer c;
	integer maximum, magnitude;
	always @(posedge clk) begin
		if(reset) begin
			max_abs_coeff<=0;i4_modes<=0;i16_modes<=0;chroma_modes<=0;chroma_ac_blocks<=0;intra_in_p<=0;
			qpel_phases<=0;mc_borders<=0;
		end else begin
			if(dut.phase==25 && dut.mc_hold) begin
				qpel_phases[{dut.dpb_lfy,dut.dpb_lfx}]<=1;
				if(!dut.pel_copy) begin
					if(int'(dut.dpb_lox)-2<0)mc_borders[0]<=1;
					if(int'(dut.dpb_lox)+18>=int'(dut.present_coded_width))mc_borders[1]<=1;
					if(int'(dut.dpb_loy)-2<0)mc_borders[2]<=1;
					if(int'(dut.dpb_loy)+18>=int'(dut.present_coded_height))mc_borders[3]<=1;
				end
			end
			if(dut.cav_done && dut.cav_ok) begin
				maximum=max_abs_coeff;
				for(c=0;c<16;c=c+1) begin
					magnitude=dut.cav_coeff[c]<0 ? -17'(dut.cav_coeff[c]) : 17'(dut.cav_coeff[c]);
					if(magnitude>maximum)maximum=magnitude;
				end
				max_abs_coeff<=maximum[15:0];
				if(dut.rseq_chr && !dut.rseq_cdc && dut.cav_tc!=0)
					chroma_ac_blocks<=chroma_ac_blocks+1'b1;
			end
			if(dut.phase==20 && dut.cmt_i==0 && dut.filt_plane==0 && dut.is_intra_mb) begin
				if(!dut.lat_slice_i)intra_in_p<=intra_in_p+1'b1;
				if(dut.is_i16)i16_modes[dut.i16_mode]<=1;
				else for(c=0;c<16;c=c+1)i4_modes[dut.i4_mode[c]]<=1;
				chroma_modes[dut.chroma_mode]<=1;
			end
		end
	end
endmodule
