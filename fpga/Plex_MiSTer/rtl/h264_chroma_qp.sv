// H.264 8.5.5 / Table 8-15 chroma QP map (8-bit). Caller applies pps offset
// before clip to [0,51]. Combinational, tiny LUT — not an area concern.

`default_nettype none

module h264_chroma_qp (
	input  wire [5:0]        qpy,                 // 0..51
	input  wire signed [4:0] chroma_qp_index_offset, // se(), typically 0
	output wire [5:0]        qpc
);
	function automatic [5:0] map_tab;
		input [5:0] q;
		begin
			case (q)
			6'd0: map_tab = 6'd0;   6'd1: map_tab = 6'd1;   6'd2: map_tab = 6'd2;
			6'd3: map_tab = 6'd3;   6'd4: map_tab = 6'd4;   6'd5: map_tab = 6'd5;
			6'd6: map_tab = 6'd6;   6'd7: map_tab = 6'd7;   6'd8: map_tab = 6'd8;
			6'd9: map_tab = 6'd9;   6'd10: map_tab = 6'd10; 6'd11: map_tab = 6'd11;
			6'd12: map_tab = 6'd12; 6'd13: map_tab = 6'd13; 6'd14: map_tab = 6'd14;
			6'd15: map_tab = 6'd15; 6'd16: map_tab = 6'd16; 6'd17: map_tab = 6'd17;
			6'd18: map_tab = 6'd18; 6'd19: map_tab = 6'd19; 6'd20: map_tab = 6'd20;
			6'd21: map_tab = 6'd21; 6'd22: map_tab = 6'd22; 6'd23: map_tab = 6'd23;
			6'd24: map_tab = 6'd24; 6'd25: map_tab = 6'd25; 6'd26: map_tab = 6'd26;
			6'd27: map_tab = 6'd27; 6'd28: map_tab = 6'd28; 6'd29: map_tab = 6'd29;
			6'd30: map_tab = 6'd29; 6'd31: map_tab = 6'd30; 6'd32: map_tab = 6'd31;
			6'd33: map_tab = 6'd32; 6'd34: map_tab = 6'd32; 6'd35: map_tab = 6'd33;
			6'd36: map_tab = 6'd34; 6'd37: map_tab = 6'd34; 6'd38: map_tab = 6'd35;
			6'd39: map_tab = 6'd35; 6'd40: map_tab = 6'd36; 6'd41: map_tab = 6'd36;
			6'd42: map_tab = 6'd37; 6'd43: map_tab = 6'd37; 6'd44: map_tab = 6'd37;
			6'd45: map_tab = 6'd38; 6'd46: map_tab = 6'd38; 6'd47: map_tab = 6'd38;
			6'd48: map_tab = 6'd39; 6'd49: map_tab = 6'd39; 6'd50: map_tab = 6'd39;
			default: map_tab = 6'd39;
			endcase
		end
	endfunction

	wire signed [7:0] q_sum = $signed({2'b0, qpy}) + 8'(chroma_qp_index_offset);
	wire [5:0] q_clip =
		(q_sum < 0) ? 6'd0 :
		(q_sum > 51) ? 6'd51 :
		q_sum[5:0];

	assign qpc = map_tab(q_clip);
endmodule

`default_nettype wire
