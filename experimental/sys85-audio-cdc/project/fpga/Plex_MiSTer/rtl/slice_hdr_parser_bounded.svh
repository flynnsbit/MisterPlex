// Header only. Macroblock syntax and all residuals belong to h264_mb_ctrl.
// The bounded capture is sufficient for the supported single-reference header;
// an overlong or truncated header fails instead of borrowing zero padding.
`default_nettype none
module slice_hdr_parser_bounded #(
    parameter int BIT_W = 17
) (
    input wire clk, reset, cap_clear, cap_en,
    input wire [7:0] cap_data,
    input wire cap_end, is_idr_nal,
    input wire [1:0] nal_ref_idc,
    input wire [4:0] log2_max_frame_num,
    input wire [4:0] log2_max_pic_order_cnt_lsb,
    input wire [2:0] poc_type,
    input wire sps_ready, pps_ready, deblock_ctrl,
    input wire signed [7:0] pic_init_qp,
    input wire [7:0] active_pps_id, num_ref_l0,
    output reg valid, error,
    output reg [15:0] first_mb,
    output reg [7:0] slice_type, pps_id,
    output reg [15:0] frame_num, idr_pic_id,
    output reg is_i_slice,
    output reg signed [7:0] slice_qp_delta,
    output reg [5:0] slice_qp,
    output reg [1:0] disable_deblocking_idc,
    output reg signed [7:0] slice_alpha_c0_offset_div2, slice_beta_offset_div2,
    output wire [7:0] first_mb_type,
    output wire has_mb_type,
    output wire [4:0] residual_tc,
    output wire [1:0] residual_t1,
    output wire residual_ok,
    output wire signed [7:0] residual_dc,
    output wire [7:0] residual_csum,
    output wire signed [8:0] residual_coeff [0:15],
    output wire residual_place_pulse, residual_place_ok,
    output wire [4:0] residual_place_tc,
    output wire [1:0] residual_place_t1,
    output wire signed [7:0] residual_place_dc,
    output wire [5:0] residual_place_qp,
    output wire signed [8:0] residual_place_coeff [0:15],
    output reg [BIT_W-1:0] bit_pos_hdr, bit_pos_resid,
    output reg bit_pos_valid, busy
);
    localparam int MAXB = 48;
    reg [7:0] mem [0:MAXB-1];
    reg [5:0] len;
    reg [8:0] pos;
    wire oob = (pos >> 3) >= len;
    wire bitv = oob ? 1'b0 : mem[pos[8:3]][7-pos[2:0]];
    localparam [4:0] IDLE=0, UE_ZERO=1, BITS=2, UE_VALUE=3, FIRST=4,
        TYPE=5, PPS=6, FRAME=7, IDR=8, POC=9, AFTER_POC=10, OVERRIDE=11,
        NREF=12, RPLM=13, MARKING=14, QP=15, DEBLOCK=16, ALPHA=17,
        BETA=18, DONE=19, FAILED=20;
    reg [4:0] st, cont, ue_cont, left, zeros;
    reg [15:0] acc, ue;
    reg idr;
    reg [1:0] ref_idc;

    assign first_mb_type = 0;
    assign has_mb_type = 0;
    assign residual_tc = 0;
    assign residual_t1 = 0;
    assign residual_ok = 0;
    assign residual_dc = 0;
    assign residual_csum = 0;
    assign residual_place_pulse = 0;
    assign residual_place_ok = 0;
    assign residual_place_tc = 0;
    assign residual_place_t1 = 0;
    assign residual_place_dc = 0;
    assign residual_place_qp = 0;
    genvar g;
    generate for (g=0; g<16; g=g+1) begin : unused_residual
        assign residual_coeff[g] = 0;
        assign residual_place_coeff[g] = 0;
    end endgenerate

    task automatic get_ue(input [4:0] target);
        begin zeros <= 0; ue_cont <= target; st <= UE_ZERO; end
    endtask
    task automatic get_bits(input [4:0] n, input [4:0] target);
        begin left <= n; acc <= 0; cont <= target; st <= BITS; end
    endtask
    task automatic get_marking;
        begin
            if (ref_idc != 0) get_bits(idr ? 5'd2 : 5'd1, MARKING);
            else get_ue(QP);
        end
    endtask
    function automatic signed [16:0] signed_code(input [15:0] code);
        signed_code = code[0] ? $signed(({1'b0, code} + 17'd1) >> 1) :
                                      -$signed({2'b0, code[15:1]});
    endfunction

    always @(posedge clk) begin
        if (reset || cap_clear) len <= 0;
        else if (cap_en && len < MAXB) begin
            mem[len] <= cap_data;
            len <= len + 1'b1;
        end
    end
    always @(posedge clk) begin : parser
        reg [16:0] code;
        reg signed [17:0] qp_value;
        if (reset || cap_clear) begin
            st <= IDLE;
            valid <= 0; error <= 0; busy <= 0; bit_pos_valid <= 0;
            first_mb <= 0; slice_type <= 0; pps_id <= 0;
            frame_num <= 0; idr_pic_id <= 0; is_i_slice <= 0;
            slice_qp_delta <= 0; slice_qp <= 0;
            disable_deblocking_idc <= 0;
            slice_alpha_c0_offset_div2 <= 0; slice_beta_offset_div2 <= 0;
            bit_pos_hdr <= 0; bit_pos_resid <= 0;
            pos <= 0; left <= 0; zeros <= 0; acc <= 0; ue <= 0;
            idr <= 0; ref_idc <= 0; cont <= IDLE; ue_cont <= IDLE;
        end else case (st)
        IDLE: if (cap_end) begin
            busy <= 1;
            if ((len == 0 && !cap_en) || !sps_ready || !pps_ready ||
                !(poc_type == 0 || poc_type == 2) ||
                log2_max_frame_num < 4 || log2_max_frame_num > 16 ||
                (poc_type == 0 && (log2_max_pic_order_cnt_lsb < 4 ||
                                   log2_max_pic_order_cnt_lsb > 16)) ||
                pic_init_qp < 0 || pic_init_qp > 51 || num_ref_l0 != 0)
                st <= FAILED;
            else begin
                pos <= 0; idr <= is_idr_nal; ref_idc <= nal_ref_idc;
                get_ue(FIRST);
            end
        end
        UE_ZERO: begin
            if (oob) st <= FAILED;
            else begin
                pos <= pos + 1'b1;
                if (!bitv) begin
                    if (zeros == 16) st <= FAILED;
                    else zeros <= zeros + 1'b1;
                end else if (zeros == 0) begin ue <= 0; st <= ue_cont; end
                else get_bits(zeros, UE_VALUE);
            end
        end
        BITS: begin
            if (oob || left == 0) st <= FAILED;
            else begin
                acc <= {acc[14:0], bitv}; pos <= pos + 1'b1;
                left <= left - 1'b1;
                if (left == 1) st <= cont;
            end
        end
        UE_VALUE: begin
            code = (17'd1 << zeros) - 1'b1 + {1'b0, acc};
            if (code > 65535) st <= FAILED;
            else begin ue <= code[15:0]; st <= ue_cont; end
        end
        FIRST: begin first_mb <= ue; get_ue(TYPE); end
        TYPE: begin
            slice_type <= ue[7:0];
            is_i_slice <= ue == 2 || ue == 7;
            if (!(ue == 0 || ue == 2 || ue == 5 || ue == 7) ||
                (idr && !(ue == 2 || ue == 7))) st <= FAILED;
            else get_ue(PPS);
        end
        PPS: begin
            pps_id <= ue[7:0];
            if (ue > 255 || ue != {8'd0, active_pps_id}) st <= FAILED;
            else get_bits(log2_max_frame_num, FRAME);
        end
        FRAME: begin
            frame_num <= acc;
            if (idr) get_ue(IDR);
            else st <= POC;
        end
        IDR: begin
            idr_pic_id <= ue;
            if (ref_idc == 0) st <= FAILED;
            else st <= POC;
        end
        POC: begin
            if (poc_type == 0) get_bits(log2_max_pic_order_cnt_lsb, AFTER_POC);
            else st <= AFTER_POC;
        end
        AFTER_POC: begin
            if (!is_i_slice) get_bits(1, OVERRIDE);
            else get_marking();
        end
        OVERRIDE: begin
            if (acc[0]) get_ue(NREF);
            else get_bits(1, RPLM);
        end
        NREF: begin
            if (ue != 0) st <= FAILED;
            else get_bits(1, RPLM);
        end
        RPLM: begin
            if (acc[0]) st <= FAILED;
            else get_marking();
        end
        MARKING: begin
            // Long-term references / adaptive MMCO need a different DPB contract.
            if (acc[0]) st <= FAILED;
            else get_ue(QP);
        end
        QP: begin
            qp_value = $signed(pic_init_qp) + signed_code(ue);
            if (qp_value < 0 || qp_value > 51) st <= FAILED;
            else begin
                slice_qp_delta <= signed_code(ue);
                slice_qp <= qp_value[5:0];
                if (deblock_ctrl) get_ue(DEBLOCK);
                else st <= DONE;
            end
        end
        DEBLOCK: begin
            disable_deblocking_idc <= ue[1:0];
            if (ue > 2) st <= FAILED;
            else if (ue == 1) st <= DONE;
            else get_ue(ALPHA);
        end
        ALPHA: begin
            if (signed_code(ue) < -6 || signed_code(ue) > 6) st <= FAILED;
            else begin slice_alpha_c0_offset_div2 <= signed_code(ue); get_ue(BETA); end
        end
        BETA: begin
            if (signed_code(ue) < -6 || signed_code(ue) > 6) st <= FAILED;
            else begin slice_beta_offset_div2 <= signed_code(ue); st <= DONE; end
        end
        DONE: begin
            valid <= 1; busy <= 0; bit_pos_valid <= 1;
            bit_pos_hdr <= BIT_W'(pos); bit_pos_resid <= BIT_W'(pos);
        end
        default: begin
            valid <= 0; bit_pos_valid <= 0; busy <= 0; error <= 1;
            st <= FAILED;
        end
        endcase
    end
endmodule
`default_nettype wire
