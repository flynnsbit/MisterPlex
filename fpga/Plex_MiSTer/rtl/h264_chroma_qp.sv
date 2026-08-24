// Chroma QP: ITU Table 8-15 / host detail_r::chromaQp.
// qpc = kChromaQP[clip(qpy + chroma_qp_index_offset, 0, 51)].
// Phase 1a gold PPS: chroma_qp_index_offset = 0 (so qpc == table[qpy]).
// pps_parser ST_CHR already consumes that se into ue_val and drops it —
// export se_of(ue_val) when wiring. Do not instantiate from Plex.sv.

`default_nettype none

module h264_chroma_qp (
	input  wire        [5:0] qpy,
	input  wire signed [5:0] chroma_qp_index_offset,
	output reg         [5:0] qpc
);
	integer q;
	function automatic [5:0] tab815;
		input integer qi;
		begin
			if (qi <= 29)
				tab815 = qi[5:0];
			else begin
				case (qi)
				30: tab815 = 6'd29; 31: tab815 = 6'd30; 32: tab815 = 6'd31;
				33: tab815 = 6'd32; 34: tab815 = 6'd32; 35: tab815 = 6'd33;
				36: tab815 = 6'd34; 37: tab815 = 6'd34; 38: tab815 = 6'd35;
				39: tab815 = 6'd35; 40: tab815 = 6'd36; 41: tab815 = 6'd36;
				42: tab815 = 6'd37; 43: tab815 = 6'd37; 44: tab815 = 6'd37;
				45: tab815 = 6'd38; 46: tab815 = 6'd38; 47: tab815 = 6'd38;
				48: tab815 = 6'd39; 49: tab815 = 6'd39; 50: tab815 = 6'd39;
				default: tab815 = 6'd39; // 51
				endcase
			end
		end
	endfunction

	always @* begin
		q = $signed({1'b0, qpy}) + chroma_qp_index_offset;
		if (q < 0)
			q = 0;
		if (q > 51)
			q = 51;
		qpc = tab815(q);
	end
endmodule

`default_nettype wire
