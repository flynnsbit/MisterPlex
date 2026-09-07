`default_nettype none
module h264_syntax_lane_tb_top #(
    parameter int ADDR_W = 14
) (
    input wire clk, reset,
    input wire [1:0] kind,
    input wire cap_clear, cap_en, cap_end,
    input wire [7:0] cap_data,
    input wire idr,
    input wire [1:0] nal_ref,
    output wire sps_valid, sps_error, pps_valid, pps_error, hdr_valid, hdr_error,
    output wire [15:0] width, height,
    output wire [15:0] coded_width, coded_height,
    output wire [15:0] crop_left, crop_top, crop_right, crop_bottom,
    output wire [15:0] sar_width, sar_height,
    output wire sar_known,
    output wire [7:0] mb_width, mb_height,
    output wire video_full_range_flag,
    output wire [7:0] matrix_coefficients,
    output wire [ADDR_W+3:0] hdr_pos,
    output wire [5:0] qp,
    output wire [1:0] deblock,
    output wire signed [7:0] alpha, beta, chroma_offset,
    output reg legacy_place_seen,
    output reg [7:0] legacy_csum, legacy_dc,
    output reg [5:0] legacy_qp,
    input wire wr_clear, wr_en, wr_end,
    input wire [ADDR_W-1:0] wr_addr,
    input wire [7:0] wr_data,
    output wire [13:0] physical_ram_len,
    output wire physical_ram_done, physical_ram_overflow,
    input wire br_load, br_get, br_ue, br_se, br_u,
    input wire [ADDR_W+3:0] br_start_pos,
    input wire [ADDR_W:0] br_len,
    input wire br_final,
    input wire [4:0] br_n,
    output wire [ADDR_W+3:0] br_pos,
    output wire br_ready, br_eof, br_error, br_busy, br_done, br_ok, br_bit_valid, br_bit,
    output wire [15:0] br_value,
    output wire signed [15:0] br_signed,
    output wire [31:0] capacity,
    input wire seq_start, seq_advance, seq_i16,
    input wire [3:0] cbp_l,
    input wire [1:0] cbp_c,
    output wire seq_valid, seq_done, seq_chr, seq_cb,
    output wire [4:0] seq_id, seq_max,
    output wire [2:0] seq_table,
    output wire [1:0] seq_x, seq_y
);
    wire [4:0] logfn, logpoc;
    wire [2:0] poc;
    wire [7:0] sps_id, pps_sps, pps_id, nref;
    wire signed [7:0] init_qp;
    wire db;
    sps_parser sps (
        .clk(clk), .reset(reset), .cap_clear(cap_clear && kind==0),
        .cap_en(cap_en && kind==0), .cap_data(cap_data), .cap_end(cap_end && kind==0),
        .valid(sps_valid), .error(sps_error), .width(width), .height(height),
        .coded_width(coded_width), .coded_height(coded_height),
        .crop_left(crop_left), .crop_top(crop_top), .crop_right(crop_right), .crop_bottom(crop_bottom),
        .sar_width(sar_width), .sar_height(sar_height), .sar_known(sar_known),
        .mb_width(mb_width), .mb_height(mb_height),
        .sps_id(sps_id), .log2_max_frame_num(logfn),
        .log2_max_pic_order_cnt_lsb(logpoc), .poc_type(poc),
        .video_full_range_flag(video_full_range_flag),
        .matrix_coefficients(matrix_coefficients)
    );
    pps_parser pps (
        .clk(clk), .reset(reset), .cap_clear(cap_clear && kind==1),
        .cap_en(cap_en && kind==1), .cap_data(cap_data), .cap_end(cap_end && kind==1),
        .valid(pps_valid), .error(pps_error), .pps_id(pps_id), .sps_id(pps_sps),
        .num_ref_l0(nref), .pic_init_qp(init_qp), .deblock_ctrl(db),
        .chroma_qp_index_offset(chroma_offset)
    );
    slice_hdr_parser #(.BIT_W(ADDR_W+4)) hdr (
        .clk(clk), .reset(reset), .cap_clear(cap_clear && kind==2),
        .cap_en(cap_en && kind==2), .cap_data(cap_data), .cap_end(cap_end && kind==2),
        .is_idr_nal(idr), .nal_ref_idc(nal_ref),
        .log2_max_frame_num(logfn), .log2_max_pic_order_cnt_lsb(logpoc), .poc_type(poc),
        .sps_ready(sps_valid), .pps_ready(pps_valid && pps_sps==sps_id),
        .active_pps_id(pps_id), .num_ref_l0(nref),
        .deblock_ctrl(db), .pic_init_qp(init_qp), .valid(hdr_valid), .error(hdr_error),
        .slice_qp(qp), .disable_deblocking_idc(deblock),
        .slice_alpha_c0_offset_div2(alpha), .slice_beta_offset_div2(beta),
        .bit_pos_hdr(hdr_pos)
    );
    wire legacy_pulse;
    wire [7:0] legacy_csum_live, legacy_dc_live;
    wire [5:0] legacy_qp_live;
    slice_hdr_parser #(.LEGACY_DIAGNOSTIC(1'b1)) legacy_hdr (
        .clk(clk), .reset(reset), .cap_clear(cap_clear && kind==2),
        .cap_en(cap_en && kind==2), .cap_data(cap_data), .cap_end(cap_end && kind==2),
        .is_idr_nal(idr), .nal_ref_idc(nal_ref),
        .log2_max_frame_num(logfn), .log2_max_pic_order_cnt_lsb(logpoc), .poc_type(poc),
        .sps_ready(sps_valid), .pps_ready(pps_valid && pps_sps==sps_id),
        .active_pps_id(pps_id), .num_ref_l0(nref),
        .deblock_ctrl(db), .pic_init_qp(init_qp),
        .residual_place_pulse(legacy_pulse), .residual_csum(legacy_csum_live),
        .residual_place_dc(legacy_dc_live), .residual_place_qp(legacy_qp_live)
    );
    always @(posedge clk) begin
        if (reset || (cap_clear && kind==2)) begin
            legacy_place_seen <= 0;
            legacy_csum <= 0; legacy_dc <= 0; legacy_qp <= 0;
        end else if (legacy_pulse) begin
            legacy_place_seen <= 1;
            legacy_csum <= legacy_csum_live;
            legacy_dc <= legacy_dc_live;
            legacy_qp <= legacy_qp_live;
        end
    end
    wire [7:0] rd;
    wire [ADDR_W-1:0] addr;
    assign capacity = 1 << ADDR_W;
    generate
        if (ADDR_W == 13) begin : actual_ram
            h264_slice_rbsp_ram #(.DEPTH(8192)) ram (
                .clk(clk), .reset(reset), .wr_clear(wr_clear),
                .wr_en(wr_en), .wr_data(wr_data), .wr_end(wr_end),
                .rd_addr(addr), .rd_data(rd), .len(physical_ram_len),
                .done(physical_ram_done), .overflow(physical_ram_overflow)
            );
        end else begin : parameter_model
            reg [7:0] mem [0:(1<<ADDR_W)-1];
            reg [7:0] data;
            always @(posedge clk) begin
                if (wr_en) mem[wr_addr] <= wr_data;
                data <= mem[addr];
            end
            assign rd = data;
            assign physical_ram_len = 0;
            assign physical_ram_done = 0;
            assign physical_ram_overflow = 0;
        end
    endgenerate
    h264_bit_reader #(.ADDR_W(ADDR_W)) reader (
        .clk(clk), .reset(reset), .load(br_load), .bit_pos_i(br_start_pos),
        .rbsp_len(br_len), .rbsp_done(br_final), .ram_rd(rd), .ram_addr(addr),
        .bit_pos(br_pos), .eof(br_eof), .ready(br_ready), .error(br_error),
        .get_bit(br_get), .bit_valid(br_bit_valid), .bit_out(br_bit),
        .start_ue(br_ue), .start_se(br_se), .start_u(br_u), .u_n(br_n),
        .syn_busy(br_busy), .syn_done(br_done), .syn_ok(br_ok),
        .ue_val(br_value), .se_val(br_signed)
    );
    h264_residual_seq seq (
        .clk(clk), .reset(reset), .start_mb(seq_start), .advance(seq_advance),
        .is_i16(seq_i16), .cbp_luma(cbp_l), .cbp_chroma(cbp_c),
        .blk_valid(seq_valid), .mb_res_done(seq_done), .blk_id(seq_id),
        .max_coeff(seq_max), .coeff_token_table(seq_table), .blk_x(seq_x),
        .blk_y(seq_y), .is_chroma(seq_chr), .chr_cb(seq_cb)
    );
endmodule
`default_nettype wire
