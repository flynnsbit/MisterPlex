// Opt-in post-reconstruction filter. Not connected to the product/QIP yet.
// Stage one metadata record per coded MB after frame_begin, then pulse start
// only after ALL unfiltered reconstruction is finished. No intra prediction
// may read this bank after start. A failed/aborted bank must never be promoted.
// Progressive 8-bit 4:2:0 only. Storage strides/plane offsets never follow crop
// dimensions. mem_rd and mem_we are VALID, accepted only with their READY;
// reads may respond at any latency, including acceptance. mem_wdrained fences
// both reconstruction and filter writes. done is a successful final drain,
// never merely an issued last write. A new frame_begin is required per job.
`default_nettype none
module h264_deblock_frame #(
	parameter int STORAGE_W = 320,
	parameter int STORAGE_H = 240,
	parameter int BANK0_BASE = 0,
	parameter int BANK1_BASE = STORAGE_W * STORAGE_H * 3/2
)(
	input wire clk, reset,
	input wire frame_begin,
	input wire [31:0] frame_base,
	input wire [15:0] frame_width, frame_height,
	input wire start, frame_abort,
	output wire busy,
	output reg done, error,

	input wire meta_valid,
	output wire meta_ready,
	input wire [15:0] meta_mb,
	// 0=P16, 1=Pskip, 2=I4, 3=I16. Other modes are unsupported.
	input wire [2:0] meta_mode,
	input wire [5:0] meta_qp,
	// Raster 4x4 luma block order. Chroma bS inherits associated luma bS.
	input wire [15:0] meta_luma_nonzero,
	input wire signed [15:0] meta_mvx, meta_mvy,
	input wire [15:0] meta_reference, meta_slice,
	input wire signed [4:0] meta_chroma_offset,
	// Actual offsets, not syntax div2: even values in [-12,+12].
	input wire signed [4:0] meta_alpha_offset, meta_beta_offset,
	input wire [1:0] meta_disable_idc,

	output wire mem_rd,
	input wire mem_rready,
	output wire [31:0] mem_raddr,
	input wire mem_rvalid,
	input wire [7:0] mem_rdata,
	output wire mem_we,
	input wire mem_wready,
	output wire [31:0] mem_waddr,
	output wire [7:0] mem_wdata,
	// Includes preceding reconstruction writes and all accepted filter writes.
	input wire mem_wdrained
);
	localparam int MAX_MB = (STORAGE_W/16) * (STORAGE_H/16);
	localparam int META_AW = $clog2(MAX_MB) > 0 ? $clog2(MAX_MB) : 1;
	typedef struct packed {
		logic [2:0] mode;
		logic [5:0] qp;
		logic [15:0] nonzero;
		logic signed [15:0] mvx, mvy;
		logic [15:0] reference_id, slice_id;
		logic signed [4:0] chroma_offset, alpha_offset, beta_offset;
		logic [1:0] disable_idc;
	} metadata_t;
	metadata_t metadata [0:MAX_MB-1];
	metadata_t p_meta, q_meta;
	reg [MAX_MB-1:0] metadata_valid;
	reg [15:0] metadata_count, mb_count, mb_columns;
	reg [31:0] base;
	reg context_valid;
	localparam [3:0] IDLE=0, PRE_DRAIN=1, LOAD_MB=2, CHECK_MB=3,
		SELECT_EDGE=4, CHECK_EDGE=5, READ=6, WAIT_READ=7, FILTER=8,
		WRITE=9, NEXT_EDGE=10, NEXT_MB=11, FINAL_DRAIN=12, ABORT_DRAIN=13;
	reg [3:0] state;
	reg [15:0] mb_index, mb_x, mb_y;
	reg horizontal;
	reg [1:0] plane, edge_index, segment;
	reg [5:0] read_index, write_index;
	reg read_outstanding;
	reg [7:0] samples [0:31];
	reg [7:0] filtered [0:23];
	assign busy = state != IDLE;
	wire geometry_ok = frame_width != 0 && frame_height != 0 &&
		frame_width[3:0] == 0 && frame_height[3:0] == 0 &&
		int'(frame_width) <= STORAGE_W && int'(frame_height) <= STORAGE_H &&
		(frame_base == BANK0_BASE || frame_base == BANK1_BASE);
	wire metadata_ok = meta_mb < mb_count && meta_mode <= 3 && meta_qp <= 51 &&
		meta_chroma_offset >= -5'sd12 && meta_chroma_offset <= 5'sd12 &&
		meta_alpha_offset >= -5'sd12 && meta_alpha_offset <= 5'sd12 && !meta_alpha_offset[0] &&
		meta_beta_offset >= -5'sd12 && meta_beta_offset <= 5'sd12 && !meta_beta_offset[0] &&
		meta_disable_idc <= 2 && (meta_mode != 1 || meta_luma_nonzero == 0);
	assign meta_ready = !busy && context_valid && !error && !frame_begin && !start && !frame_abort;
	wire cancel = frame_abort || (frame_begin && busy);
	wire external_edge = edge_index == 0;
	wire picture_edge = external_edge && (horizontal ? mb_y == 0 : mb_x == 0);
	wire [15:0] neighbor_mb = horizontal ? mb_index - mb_columns : mb_index - 1'b1;
	wire [1:0] luma_edge = plane == 0 ? edge_index : {edge_index[0],1'b0};
	wire [3:0] q_block = horizontal ? {luma_edge,segment} : {segment,luma_edge};
	wire [1:0] p_edge = external_edge ? 2'd3 : luma_edge - 1'b1;
	wire [3:0] p_block = horizontal ? {p_edge,segment} : {segment,p_edge};
	wire p_intra = p_meta.mode >= 2;
	wire q_intra = q_meta.mode >= 2;
	wire signed [16:0] dx = $signed({p_meta.mvx[15],p_meta.mvx}) - $signed({q_meta.mvx[15],q_meta.mvx});
	wire signed [16:0] dy = $signed({p_meta.mvy[15],p_meta.mvy}) - $signed({q_meta.mvy[15],q_meta.mvy});
	wire mv_different = dx >= 17'sd4 || dx <= -17'sd4 || dy >= 17'sd4 || dy <= -17'sd4;
	reg [2:0] bs;
	always @* begin
		if (q_meta.disable_idc == 1 ||
		    (external_edge && q_meta.disable_idc == 2 && p_meta.slice_id != q_meta.slice_id))
			bs = 0;
		else if (p_intra || q_intra) bs = external_edge ? 3'd4 : 3'd3;
		else if (p_meta.nonzero[p_block] || q_meta.nonzero[q_block]) bs = 2;
		else if (p_meta.reference_id != q_meta.reference_id || mv_different) bs = 1;
		else bs = 0;
	end
	wire [5:0] p_qp, q_qp;
	h264_deblock_qp u_p_qp (
		.is_chroma(plane != 0), .qp_p(p_meta.qp), .qp_q(p_meta.qp),
		.chroma_qp_index_offset(p_meta.chroma_offset), .qp_avg(p_qp)
	);
	h264_deblock_qp u_q_qp (
		.is_chroma(plane != 0), .qp_p(q_meta.qp), .qp_q(q_meta.qp),
		.chroma_qp_index_offset(q_meta.chroma_offset), .qp_avg(q_qp)
	);
	wire [6:0] qp_sum = {1'b0,p_qp}+{1'b0,q_qp}+7'd1;
	wire [7:0] p3 [0:3], p2 [0:3], p1 [0:3], p0 [0:3];
	wire [7:0] q0 [0:3], q1 [0:3], q2 [0:3], q3 [0:3];
	wire [7:0] fp2 [0:3], fp1 [0:3], fp0 [0:3], fq0 [0:3], fq1 [0:3], fq2 [0:3];
	genvar lane;
	generate for (lane=0; lane<4; lane=lane+1) begin : g_samples
		assign p3[lane]=samples[lane];
		assign p2[lane]=samples[4+lane];
		assign p1[lane]=samples[8+lane];
		assign p0[lane]=samples[12+lane];
		assign q0[lane]=samples[16+lane];
		assign q1[lane]=samples[20+lane];
		assign q2[lane]=samples[24+lane];
		assign q3[lane]=samples[28+lane];
	end endgenerate
	h264_deblock_edge u_filter (
		.is_chroma(plane != 0), .bs(bs), .qp_avg(qp_sum[6:1]),
		.slice_alpha_c0_offset(q_meta.alpha_offset), .slice_beta_offset(q_meta.beta_offset),
		.p3_in(p3), .p2_in(p2), .p1_in(p1), .p0_in(p0),
		.q0_in(q0), .q1_in(q1), .q2_in(q2), .q3_in(q3),
		.p2_out(fp2), .p1_out(fp1), .p0_out(fp0),
		.q0_out(fq0), .q1_out(fq1), .q2_out(fq2),
		.alpha_dbg(), .beta_dbg(), .tc0_dbg()
	);
	wire [2:0] read_tap = plane == 0 ? read_index[4:2] : read_index[3:1];
	wire [1:0] read_lane = plane == 0 ? read_index[1:0] : {1'b0,read_index[0]};
	wire [2:0] write_tap = plane == 0 ? write_index[4:2] : write_index[3:1];
	wire [1:0] write_lane = plane == 0 ? write_index[1:0] : {1'b0,write_index[0]};
	wire [4:0] read_slot = {read_tap,read_lane};
	wire [4:0] write_slot = {write_tap,write_lane};
	function automatic [31:0] address(input integer tap_offset, input integer along);
		integer px,py,side,step,plane_offset,stride;
		begin
			side = plane == 0 ? 16 : 8;
			step = plane == 0 ? 4 : 2;
			px = int'(mb_x)*side + (horizontal ? int'(segment)*step+along : int'(edge_index)*4+tap_offset);
			py = int'(mb_y)*side + (horizontal ? int'(edge_index)*4+tap_offset : int'(segment)*step+along);
			stride = plane == 0 ? STORAGE_W : STORAGE_W/2;
			plane_offset = plane == 0 ? 0 : plane == 1 ? STORAGE_W*STORAGE_H : STORAGE_W*STORAGE_H*5/4;
			address = base + 32'(plane_offset+py*stride+px);
		end
	endfunction
	assign mem_rd = state == READ && !cancel;
	assign mem_raddr = address(int'(read_tap)-4,int'(read_lane));
	wire read_accept = mem_rd && mem_rready;
	wire response = mem_rvalid && (read_outstanding || read_accept);
	wire write_changed = filtered[write_slot] != samples[write_slot+5'd4];
	assign mem_we = state == WRITE && write_changed && !cancel;
	assign mem_waddr = address(int'(write_tap)-3,int'(write_lane));
	assign mem_wdata = filtered[write_slot];

	integer i;
	always @(posedge clk) begin
		done <= 0;
		if (reset) begin
			state<=IDLE; error<=0; context_valid<=0; metadata_valid<='0;
			metadata_count<=0; mb_count<=0; mb_columns<=0; base<=0;
			mb_index<=0; mb_x<=0; mb_y<=0; horizontal<=0; plane<=0; edge_index<=0; segment<=0;
			read_index<=0; write_index<=0; read_outstanding<=0; p_meta<='0; q_meta<='0;
			for (i=0;i<32;i=i+1) samples[i]<=0;
			for (i=0;i<24;i=i+1) filtered[i]<=0;
		end else begin
			if (read_accept) read_outstanding<=1;
			if (response) read_outstanding<=0;
			if (meta_valid && meta_ready) begin
				if (!metadata_ok) begin error<=1; context_valid<=0; end
				else begin
					metadata[meta_mb[META_AW-1:0]] <= {meta_mode,meta_qp,meta_luma_nonzero,
						meta_mvx,meta_mvy,meta_reference,meta_slice,meta_chroma_offset,
						meta_alpha_offset,meta_beta_offset,meta_disable_idc};
					if (!metadata_valid[meta_mb[META_AW-1:0]]) metadata_count<=metadata_count+1'b1;
					metadata_valid[meta_mb[META_AW-1:0]]<=1;
				end
			end
			case (state)
			IDLE: if (start && !frame_begin) begin
				if (!context_valid || error || metadata_count != mb_count) begin error<=1; context_valid<=0; end
				else begin
					context_valid<=0; state<=PRE_DRAIN;
					mb_index<=0; mb_x<=0; mb_y<=0;
				end
			end
			PRE_DRAIN: if (mem_wdrained) state<=LOAD_MB;
			LOAD_MB: begin
				q_meta<=metadata[mb_index[META_AW-1:0]];
				horizontal<=0; plane<=0; edge_index<=0; segment<=0;
				state<=CHECK_MB;
			end
			CHECK_MB: state<=q_meta.disable_idc == 1 ? NEXT_MB : SELECT_EDGE;
			SELECT_EDGE: begin
				if (picture_edge) state<=NEXT_EDGE;
				else begin
					p_meta<=external_edge ? metadata[neighbor_mb[META_AW-1:0]] : q_meta;
					state<=CHECK_EDGE;
				end
			end
			CHECK_EDGE: begin
				if (bs == 0) state<=NEXT_EDGE;
				// Later edges must see preceding accepted p/q writes, even on
				// a backend with independent, delayed read and write channels.
				else if (mem_wdrained) begin read_index<=0; state<=READ; end
			end
			READ: if (read_accept) state<=WAIT_READ;
			WAIT_READ: begin end
			FILTER: begin
				for (i=0;i<4;i=i+1) begin
					filtered[i]<=fp2[i]; filtered[4+i]<=fp1[i]; filtered[8+i]<=fp0[i];
					filtered[12+i]<=fq0[i]; filtered[16+i]<=fq1[i]; filtered[20+i]<=fq2[i];
				end
				write_index<=0; state<=WRITE;
			end
			WRITE: if (!write_changed || mem_wready) begin
				if (write_index == (plane == 0 ? 6'd23 : 6'd11)) state<=NEXT_EDGE;
				else write_index<=write_index+1'b1;
			end
			NEXT_EDGE: begin
				if (segment != 3) begin segment<=segment+1'b1; state<=SELECT_EDGE; end
				else begin
					segment<=0;
					if (edge_index != (plane == 0 ? 2'd3 : 2'd1)) begin edge_index<=edge_index+1'b1; state<=SELECT_EDGE; end
					else begin
						edge_index<=0;
						if (plane != 2) begin plane<=plane+1'b1; state<=SELECT_EDGE; end
						else if (!horizontal) begin horizontal<=1; plane<=0; state<=SELECT_EDGE; end
						else state<=NEXT_MB;
					end
				end
			end
			NEXT_MB: begin
				if (mb_index+1'b1 == mb_count) state<=FINAL_DRAIN;
				else begin
					mb_index<=mb_index+1'b1;
					if (mb_x+1'b1 == mb_columns) begin mb_x<=0; mb_y<=mb_y+1'b1; end
					else mb_x<=mb_x+1'b1;
					state<=LOAD_MB;
				end
			end
			FINAL_DRAIN: if (mem_wdrained) begin done<=1; state<=IDLE; end
			ABORT_DRAIN: if ((!read_outstanding || mem_rvalid) && mem_wdrained) state<=IDLE;
			default: begin error<=1; state<=ABORT_DRAIN; end
			endcase
			if (response && state != ABORT_DRAIN) begin
				samples[read_slot]<=mem_rdata;
				if (read_index == (plane == 0 ? 6'd31 : 6'd15)) state<=FILTER;
				else begin read_index<=read_index+1'b1; state<=READ; end
			end
			if (frame_begin && !busy && !frame_abort) begin
				context_valid<=geometry_ok; error<=!geometry_ok;
				metadata_count<=0; metadata_valid<='0;
				mb_columns<={4'd0,frame_width[15:4]};
				mb_count<=16'(frame_width[15:4]*frame_height[15:4]); base<=frame_base;
			end
			if (cancel) begin
				error<=1; done<=0; context_valid<=0;
				state<=ABORT_DRAIN;
			end
		end
	end
endmodule
`default_nettype wire
