// plex_chrome — post-ascal player chrome plane
//
// Owner: w-osd-hires · docs/plex-chrome-plane-rtl-proposal.md
// Status: FIT-READY source — NOT in files.qip / QSF until parent ONE-fit with
//   w-fit-1 PRODUCT_NO_STUB + w-geom. Do not request exclusive slot from this lane.
//
// Insertion (sys_top.v HDMI path — patch at fit time):
//   ascal → shadowmask → plex_chrome → osd hdmi_osd → pins
//
// Geometry: HDMI_WIDTH / HDMI_HEIGHT (applied). Integer NN body_scale from H/240.
// ARM: semantic PLXC list only (doorbell + 0x130). Never pixels.
//
// Budget prereg (BINDING baseline = t7b/8fdf class, NOT output_files alone):
//   Baseline ALM 23,585 / M10K 465 / DSP 44
//   PRODUCT_NO_STUB: −9,217 ALM / −268 M10K → free M10K ~356
//   Chrome V1: M10K +12±4 (cap 24) · ALM +2.5k±1k · DSP 0 · HDMI HOLD
// Telemetry: never shorten telem_flags; stub_busy stays 1'b0 under PRODUCT_NO_STUB.

`timescale 1ns / 1ps

module plex_chrome #(
    parameter int MAX_CMDS = 64,
    parameter int FONT_W   = 8,
    parameter int FONT_H   = 8,
    // BOOT_DEMO: preload one solid '#' glyph so 1080p glass can score body_scale
    // without ARM PLXC. Disabled when ARM drives cfg_seq/list_we.
    parameter bit BOOT_DEMO = 1'b0
) (
    input  wire        clk_hdmi,
    input  wire        reset,

    input  wire [11:0] HDMI_WIDTH,
    input  wire [11:0] HDMI_HEIGHT,

    input  wire [23:0] din,
    input  wire        hs_in,
    input  wire        vs_in,
    input  wire        de_in,
    output reg  [23:0] dout,
    output reg         hs_out,
    output reg         vs_out,
    output reg         de_out,

    input  wire        cfg_enable,
    input  wire [15:0] cfg_seq,
    input  wire [7:0]  cfg_cmd_count,
    input  wire        list_we,
    input  wire [7:0]  list_waddr,
    input  wire [63:0] list_wdata,

    output reg         chrome_hw,
    output reg  [11:0] mon_width,
    output reg  [11:0] mon_height,
    output reg  [3:0]  mon_body_scale
);

    function automatic [3:0] body_scale_f(input [11:0] h);
        reg [11:0] q, r;
        reg [4:0]  raw;
        begin
            q   = h / 12'd240;
            r   = h % 12'd240;
            raw = q[4:0];
            if (r > 12'd120)
                raw = q[4:0] + 5'd1;
            else if (r == 12'd120)
                raw = q[0] ? (q[4:0] + 5'd1) : q[4:0];
            if (raw < 5'd2) raw = 5'd2;
            if (raw > 5'd8) raw = 5'd8;
            body_scale_f = raw[3:0];
        end
    endfunction

    wire [3:0] body_scale = body_scale_f(HDMI_HEIGHT);

    always @(posedge clk_hdmi) begin
        chrome_hw      <= 1'b1;
        mon_width      <= HDMI_WIDTH;
        mon_height     <= HDMI_HEIGHT;
        mon_body_scale <= body_scale;
    end

    function automatic [7:0] font_row(input [7:0] code, input [2:0] row);
        reg [7:0] bits;
        begin
            bits = 8'h00;
            case (code)
                "P", "p": case (row)
                    0: bits = 8'hFC; 1: bits = 8'hC6; 2: bits = 8'hC6; 3: bits = 8'hFC;
                    4: bits = 8'hC0; 5: bits = 8'hC0; 6: bits = 8'hC0; default: bits = 8'h00;
                endcase
                "A", "a": case (row)
                    0: bits = 8'h38; 1: bits = 8'h6C; 2: bits = 8'hC6; 3: bits = 8'hC6;
                    4: bits = 8'hFE; 5: bits = 8'hC6; 6: bits = 8'hC6; default: bits = 8'h00;
                endcase
                "U", "u": case (row)
                    0: bits = 8'hC6; 1: bits = 8'hC6; 2: bits = 8'hC6; 3: bits = 8'hC6;
                    4: bits = 8'hC6; 5: bits = 8'hC6; 6: bits = 8'h7C; default: bits = 8'h00;
                endcase
                "S", "s": case (row)
                    0: bits = 8'h7C; 1: bits = 8'hC6; 2: bits = 8'hC0; 3: bits = 8'h7C;
                    4: bits = 8'h06; 5: bits = 8'hC6; 6: bits = 8'h7C; default: bits = 8'h00;
                endcase
                "E", "e": case (row)
                    0: bits = 8'hFE; 1: bits = 8'hC0; 2: bits = 8'hC0; 3: bits = 8'hFC;
                    4: bits = 8'hC0; 5: bits = 8'hC0; 6: bits = 8'hFE; default: bits = 8'h00;
                endcase
                "D", "d": case (row)
                    0: bits = 8'hF8; 1: bits = 8'hCC; 2: bits = 8'hC6; 3: bits = 8'hC6;
                    4: bits = 8'hC6; 5: bits = 8'hCC; 6: bits = 8'hF8; default: bits = 8'h00;
                endcase
                "#", 8'h23: bits = 8'hFF;
                default: bits = 8'h00;
            endcase
            font_row = bits;
        end
    endfunction

    (* ramstyle = "no_rw_check, M10K" *) (* noprune *) (* preserve *) reg [63:0] list_a [0:MAX_CMDS-1];
    (* ramstyle = "no_rw_check, M10K" *) (* noprune *) (* preserve *) reg [63:0] list_b [0:MAX_CMDS-1];
    reg        live_bank;
    reg [15:0] latched_seq;
    reg [7:0]  latched_count;
    reg        latched_en;

    // Cmd pack: [7:0]=op [23:8]=x [39:24]=y [47:40]=code; op=2 glyph
    // BOOT_DEMO: op=2, x=64, y=64, code='#' at list_a[0] (live_bank=0 reads list_a)
    localparam [63:0] BOOT_DEMO_CMD =
        {8'h00, 8'h00, 8'h23, 16'd64, 16'd64, 8'd2};

    integer li;
    initial begin
        for (li = 0; li < MAX_CMDS; li = li + 1) begin
            list_a[li] = 64'd0;
            list_b[li] = 64'd0;
        end
        // live_bank=0 reads list_a (see hit mux). Demo MUST land in list_a or
        // glass gets NO-DATA (c74c6863: list_b preload + live_bank=0 = elided/invisible).
        if (BOOT_DEMO) begin
            list_a[0]     = BOOT_DEMO_CMD;
            live_bank     = 1'b0;
            latched_seq   = 16'd1;
            latched_count = 8'd1;
            latched_en    = 1'b1;
        end else begin
            live_bank     = 1'b0;
            latched_seq   = 16'd0;
            latched_count = 8'd0;
            latched_en    = 1'b0;
        end
    end

    always @(posedge clk_hdmi) begin
        if (list_we && (list_waddr < MAX_CMDS[7:0])) begin
            if (live_bank)
                list_a[list_waddr] <= list_wdata;
            else
                list_b[list_waddr] <= list_wdata;
        end
    end

    reg vs_d;
    always @(posedge clk_hdmi) begin
        vs_d <= vs_in;
        if (reset) begin
            if (BOOT_DEMO) begin
                latched_en    <= 1'b1;
                latched_seq   <= 16'd1;
                latched_count <= 8'd1;
                live_bank     <= 1'b0;
            end else begin
                latched_en    <= 1'b0;
                latched_seq   <= 16'd0;
                latched_count <= 8'd0;
                live_bank     <= 1'b0;
            end
        end else if (vs_in && !vs_d) begin
            if (cfg_seq != latched_seq) begin
                latched_seq   <= cfg_seq;
                latched_count <= (cfg_cmd_count > MAX_CMDS[7:0]) ? MAX_CMDS[7:0]
                                                                : cfg_cmd_count;
                latched_en    <= cfg_enable;
                live_bank     <= ~live_bank;
            end
        end
    end

    reg        de_d;
    reg [11:0] hx, hy;

    always @(posedge clk_hdmi) begin
        if (reset) begin
            de_d <= 1'b0;
            hx   <= 12'd0;
            hy   <= 12'd0;
        end else begin
            de_d <= de_in;
            if (de_in && !de_d) begin
                hx <= 12'd0;
                hy <= hy + 12'd1;
            end else if (de_in) begin
                hx <= hx + 12'd1;
            end
            if (vs_in && !vs_d)
                hy <= 12'd0;
        end
    end

    // Cmd pack: [7:0]=op [23:8]=x [39:24]=y [47:40]=code
    // RECT: [55:48]=w [63:56]=h
    reg        hit;
    reg [23:0] hit_rgb;
    integer    ci;
    reg [63:0] cw;
    reg [7:0]  op, code;
    reg [15:0] cx, cy;
    reg [3:0]  sc;
    reg [11:0] gx, gy, bitx, bity;
    reg [7:0]  fbits;

    always @(*) begin
        hit     = 1'b0;
        hit_rgb = 24'h00_00_00;
        sc      = body_scale;
        for (ci = 0; ci < 8; ci = ci + 1) begin
            if (latched_en && (ci < latched_count)) begin
                cw   = live_bank ? list_b[ci] : list_a[ci];
                op   = cw[7:0];
                cx   = cw[23:8];
                cy   = cw[39:24];
                code = cw[47:40];
                if (op == 8'd2) begin
                    if (hx >= {4'd0, cx} && hy >= {4'd0, cy}) begin
                        gx = hx - {4'd0, cx};
                        gy = hy - {4'd0, cy};
                        if (gx < (FONT_W * sc) && gy < (FONT_H * sc)) begin
                            bitx  = gx / sc;
                            bity  = gy / sc;
                            fbits = font_row(code, bity[2:0]);
                            if (fbits[7 - bitx[2:0]]) begin
                                hit     = 1'b1;
                                hit_rgb = 24'hFF_FF_FF;
                            end
                        end
                    end
                end else if (op == 8'd1) begin
                    if (hx >= {4'd0, cx} && hy >= {4'd0, cy} &&
                        hx < {4'd0, cx} + {4'd0, cw[55:48]} &&
                        hy < {4'd0, cy} + {4'd0, cw[63:56]}) begin
                        hit     = 1'b1;
                        hit_rgb = 24'h14_14_28;
                    end
                end
            end
        end
    end

    reg [23:0] din_d;
    reg        hs_d, vs_d2, de_d2;
    reg        hit_d;
    reg [23:0] hit_rgb_d;

    always @(posedge clk_hdmi) begin
        din_d     <= din;
        hs_d      <= hs_in;
        vs_d2     <= vs_in;
        de_d2     <= de_in;
        hit_d     <= hit && de_in;
        hit_rgb_d <= hit_rgb;

        hs_out <= hs_d;
        vs_out <= vs_d2;
        de_out <= de_d2;
        if (hit_d)
            dout <= hit_rgb_d;
        else
            dout <= din_d;
    end

endmodule
