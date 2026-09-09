module scaler_config (
	input wire clk, reset,
	input wire io_uio, io_strobe,
	input wire [15:0] io_din,
	input wire [11:0] width, height, hfp, hs, hbp, vfp, vs, vbp,
	input wire pixel_repeat, vrr, freescale,
	input wire [11:0] hset, vset,
	input wire [12:0] source_arx, source_ary, arc1x, arc1y, arc2x, arc2y,
	input wire lowlat, freeze, bob_deint, swblack, pal_n,
	input wire [2:0] filter,
	input wire core_fb_en,
	input wire [5:0] core_fb_format,
	input wire [11:0] core_fb_width, core_fb_height,
	input wire [31:0] core_fb_base,
	input wire [13:0] core_fb_stride,
	output wire [125:0] lfb_config,
	output reg [11:0] hdmi_width = 0, hdmi_height = 0,
	output reg [11:0] arx = 0, ary = 0,
	output reg arxy = 0,
	(* preserve = "true" *) output reg [269:0] cfg_data = 0,
	output reg cfg_req = 0,
	input wire cfg_ack
);
	reg [125:0] lfb_active = 0, lfb_shadow = 0;
	reg [7:0] host_command = 0, host_count = 0;
	reg host_active = 0, host_data = 0, host_discard = 0;
	assign lfb_config = lfb_active;

	// A deselection commits exactly the words received, including short
	// enable/disable commands. Untouched fields retain the previous command.
	always @(posedge clk or posedge reset) begin
		if (reset) begin
			host_active <= 0;
			host_data <= 0;
			host_discard <= 1;
		end else if (!io_uio) begin
			if (host_active && host_command == 8'h2f && host_data)
				lfb_active <= lfb_shadow;
			host_active <= 0;
			host_data <= 0;
			host_discard <= 0;
		end else if (io_strobe && !host_discard) begin
			if (!host_active) begin
				host_active <= 1;
				host_command <= io_din[7:0];
				host_count <= 0;
				lfb_shadow <= lfb_active;
			end else begin
				host_count <= host_count + 1'b1;
				host_data <= 1;
				if (host_command == 8'h2f) begin
					case (host_count[3:0])
						0: lfb_shadow[125:118] <= {io_din[15:14], io_din[5:0]};
						1: lfb_shadow[29:14] <= io_din;
						2: lfb_shadow[45:30] <= io_din;
						3: lfb_shadow[117:106] <= io_din[11:0];
						4: lfb_shadow[105:94] <= io_din[11:0];
						5: lfb_shadow[93:82] <= io_din[11:0];
						6: lfb_shadow[81:70] <= io_din[11:0];
						7: lfb_shadow[69:58] <= io_din[11:0];
						8: lfb_shadow[57:46] <= io_din[11:0];
						9: lfb_shadow[13:0] <= io_din[13:0];
					endcase
				end
			end
		end
	end

	wire [12:0] selected_arx = source_ary != 0 ? source_arx :
		source_arx == 1 ? arc1x : source_arx == 2 ? arc2x : 13'd0;
	wire [12:0] selected_ary = source_ary != 0 ? source_ary :
		source_arx == 1 ? arc1y : source_arx == 2 ? arc2y : 13'd0;
	always @(posedge clk) begin
		hdmi_height <= (vset != 0 && vset < height) ? vset : height;
		hdmi_width <= ((hset != 0 && hset < width) ? hset : width) << pixel_repeat;
		arx <= selected_arx[11:0]; ary <= selected_ary[11:0];
		arxy <= selected_arx[12] | selected_ary[12];
	end

	(* async_reg = "true", preserve = "true" *) reg ack_meta = 0, ack_sync = 0;
	always @(posedge clk or posedge reset) begin
		if (reset) begin
			ack_meta <= 0;
			ack_sync <= 0;
		end else begin
			ack_meta <= cfg_ack;
			ack_sync <= ack_meta;
		end
	end

	localparam [3:0] IDLE=0, SELECT=1, MUL_W=2, WAIT_W=3,
		MUL_H=4, WAIT_H=5, CLAMP=6, CENTER=7, PUBLISH=8;
	reg [3:0] state = IDLE;
	reg sent = 0;
	reg [269:0] assembled = 0;
	reg [11:0] saved_width, saved_height, saved_hdmi_width, saved_hdmi_height;
	reg [11:0] saved_arx, saved_ary, wcalc, hcalc, videow, videoh;
	reg saved_repeat, saved_free, saved_arxy, saved_lfb;
	reg md_start = 0;
	wire md_busy;
	reg [11:0] md_mul1, md_mul2, md_div;
	wire [23:0] md_result;
	sys_umuldiv #(12,12,12) ar_muldiv (
		.clk(clk), .start(md_start), .busy(md_busy),
		.mul1(md_mul1), .mul2(md_mul2), .div(md_div), .result(md_result), .remainder()
	);

	// Request/data remain held until actual scaler application is acknowledged.
	// Updates not yet submitted are state: as with the old VS base latch, the
	// latest complete configuration wins while the output clock is stopped.
	always @(posedge clk or posedge reset) begin
		if (reset) begin
			state <= IDLE;
			cfg_req <= 0;
			sent <= 0;
			md_start <= 0;
		end else begin
			md_start <= 0;
			case (state)
				IDLE: if (!io_uio && !host_active && cfg_req == ack_sync) begin
					saved_width <= width; saved_height <= height;
					saved_hdmi_width <= ((hset != 0 && hset < width) ? hset : width) << pixel_repeat;
					saved_hdmi_height <= (vset != 0 && vset < height) ? vset : height;
					saved_repeat <= pixel_repeat; saved_free <= freescale;
					saved_arx <= selected_arx[11:0]; saved_ary <= selected_ary[11:0];
					saved_arxy <= selected_arx[12] | selected_ary[12];
					saved_lfb <= lfb_active[125];
					assembled <= {
						12'(width+hfp+hbp+hs), 12'(width+hfp), 12'(width+hfp+hs), width,
						lfb_active[93:82], lfb_active[81:70],
						12'(height+vfp+vbp+vs), 12'(height+vfp), 12'(height+vfp+vs), height,
						lfb_active[69:58], lfb_active[57:46],
						1'b0, ~lowlat, (lfb_active[125] ? lfb_active[124] : |filter), 2'b00,
						2'b01, 1'b1, vrr, 12'(height+vbp+vs+12'd1),
						(lfb_active[125] | core_fb_en),
						(lfb_active[125] ? lfb_active[117:106] : core_fb_width),
						(lfb_active[125] ? lfb_active[105:94] : core_fb_height),
						(lfb_active[125] ? lfb_active[123:118] : core_fb_format),
						(lfb_active[125] ? lfb_active[45:14] : core_fb_base),
						(lfb_active[125] ? lfb_active[13:0] : core_fb_stride),
						freeze, bob_deint, swblack, pal_n, 24'b0
					};
					state <= SELECT;
				end
				SELECT: begin
					if (saved_lfb) state <= PUBLISH;
					else if (saved_free || saved_arx == 0 || saved_ary == 0) begin
						wcalc <= saved_hdmi_width; hcalc <= saved_hdmi_height;
						state <= CLAMP;
					end else if (saved_arxy) begin
						wcalc <= saved_arx; hcalc <= saved_ary;
						state <= CLAMP;
					end else state <= MUL_W;
				end
				MUL_W: begin
					md_mul1 <= saved_hdmi_height; md_mul2 <= saved_arx; md_div <= saved_ary;
					md_start <= 1; state <= WAIT_W;
				end
				WAIT_W: if (!md_start && !md_busy) begin
					wcalc <= md_result[11:0]; state <= MUL_H;
				end
				MUL_H: begin
					md_mul1 <= saved_hdmi_width; md_mul2 <= saved_ary; md_div <= saved_arx;
					md_start <= 1; state <= WAIT_H;
				end
				WAIT_H: if (!md_start && !md_busy) begin
					hcalc <= md_result[11:0]; state <= CLAMP;
				end
				CLAMP: begin
					videow <= ((wcalc > saved_hdmi_width) ? saved_hdmi_width : wcalc) >> saved_repeat;
					videoh <= (hcalc > saved_hdmi_height) ? saved_hdmi_height : hcalc;
					state <= CENTER;
				end
				CENTER: begin
					assembled[221:210] <= (saved_width-videow) >> 1;
					assembled[209:198] <= ((saved_width-videow) >> 1) + videow - 1'b1;
					assembled[149:138] <= (saved_height-videoh) >> 1;
					assembled[137:126] <= ((saved_height-videoh) >> 1) + videoh - 1'b1;
					state <= PUBLISH;
				end
				PUBLISH: begin
					if (!sent || assembled != cfg_data ||
						(assembled[104] && !assembled[24] && assembled[76:74]==3'b011)) begin
						cfg_data <= assembled;
						cfg_req <= ~cfg_req;
						sent <= 1;
					end
					state <= IDLE;
				end
				default: state <= IDLE;
			endcase
		end
	end
endmodule
