// Testbench wrapper: nalu_scanner's full-slice RBSP port feeding
// h264_rbsp_window, i.e. the supply chain from Annex-B bytes to the random
// access view the decoder reads. Byte-serial input stands in for
// bitstream_fifo; that FIFO is covered by the stream_path sims.
module nalu_slice_rbsp_tb (
    input  wire        clk,
    input  wire        reset,
    input  wire [7:0]  in_data,
    input  wire        in_valid,
    output wire        rd_en_o,
    input  wire        request_valid,
    input  wire [15:0] request_offset,
    output wire [7:0]  byte_out [0:63],
    output wire [15:0] window_base,
    output wire [15:0] bytes_captured,
    output wire        slice_complete,
    output wire        overflow,
    output wire        underflow,
    output wire [15:0] nalu_count,
    output wire [7:0]  slice_count,
    output wire        has_idr
);

    // nalu_scanner pulls from a FIFO interface: rd_empty low means a byte is
    // available this cycle, and it registers the byte one cycle later.
    // The FIFO handshake is part of the contract under test: a byte is consumed
    // in the cycle rd_en is high, and must be held stable until then. A tb that
    // advanced a byte per cycle regardless would feed the scanner a skewed
    // stream and mis-attribute the damage to the RTL.
    wire rd_en;
    assign rd_en_o = rd_en;
    wire rd_empty = ~in_valid;

    wire sps_cap_clear, sps_cap_en, sps_cap_end;
    wire [7:0] sps_cap_data;
    wire pps_cap_clear, pps_cap_en, pps_cap_end;
    wire [7:0] pps_cap_data;
    wire sl_cap_clear, sl_cap_en, sl_cap_end;
    wire [7:0] sl_cap_data;
    wire sl_is_idr, sl_nal_ref_idc_nonzero;
    wire sl_rbsp_clear, sl_rbsp_en, sl_rbsp_end;
    wire [7:0] sl_rbsp_data;
    wire [7:0] last_nal_type;
    wire has_stream;
    wire [31:0] bytes_seen;
    wire [7:0] idr_count, sps_count, pps_count;
    wire vcl_pulse;

    nalu_scanner scan (
        .clk(clk),
        .reset(reset),
        .rd_data(in_data),
        .rd_empty(rd_empty),
        .rd_en(rd_en),
        .nalu_count(nalu_count),
        .last_nal_type(last_nal_type),
        .has_stream(has_stream),
        .bytes_seen(bytes_seen),
        .idr_count(idr_count),
        .sps_count(sps_count),
        .pps_count(pps_count),
        .slice_count(slice_count),
        .has_idr(has_idr),
        .vcl_pulse(vcl_pulse),
        .sps_cap_clear(sps_cap_clear), .sps_cap_en(sps_cap_en),
        .sps_cap_data(sps_cap_data), .sps_cap_end(sps_cap_end),
        .pps_cap_clear(pps_cap_clear), .pps_cap_en(pps_cap_en),
        .pps_cap_data(pps_cap_data), .pps_cap_end(pps_cap_end),
        .sl_cap_clear(sl_cap_clear), .sl_cap_en(sl_cap_en),
        .sl_cap_data(sl_cap_data), .sl_cap_end(sl_cap_end),
        .sl_rbsp_clear(sl_rbsp_clear), .sl_rbsp_en(sl_rbsp_en),
        .sl_rbsp_data(sl_rbsp_data), .sl_rbsp_end(sl_rbsp_end),
        .sl_is_idr(sl_is_idr),
        .sl_nal_ref_idc_nonzero(sl_nal_ref_idc_nonzero)
    );

    h264_rbsp_window #(.BUF_BYTES(8192)) u_win (
        .clk(clk),
        .reset(reset),
        .cap_clear(sl_rbsp_clear),
        .cap_en(sl_rbsp_en),
        .cap_data(sl_rbsp_data),
        .cap_end(sl_rbsp_end),
        .request_valid(request_valid),
        .request_offset(request_offset),
        .byte_out(byte_out),
        .window_base(window_base),
        .window_valid(),
        .bytes_captured(bytes_captured),
        .slice_complete(slice_complete),
        .overflow(overflow),
        .underflow(underflow)
    );

endmodule
