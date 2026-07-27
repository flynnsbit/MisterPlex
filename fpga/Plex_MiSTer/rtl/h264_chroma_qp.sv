// H.264 chroma QP mapping: qPI → QPc (ITU-T H.264 Table 8-15).
//
// Pure combinational lookup. QPc = qPI for qPI ≤ 29; non-linear above 29,
// saturating at QPc = 39 for qPI ≥ 48.
//
// Usage:
//   qpi = Clip3(0, 51, QPy + chroma_qp_index_offset)
//   QPc = h264_chroma_qp.qpc
//
// Width: qpi [5:0] = 0..51, qpc [5:0] = 0..39
//
// Measurement basis: the non-linear region (qPI 30–51) was NEVER exercised
// by the project test corpus (QP 5–27). The table was verified against the
// spec by test_dequant_qp_sweep.py (52 entries, 22 non-linear).
//
// At QPy=51, using luma QP for chroma gives 2^(51/6) = 256 instead of
// 2^(39/6) = 64 — a 4× error in the dequant scale factor. This produces
// visible chroma artefacts on constrained-bitrate content.

`default_nettype none

module h264_chroma_qp (
	input  wire [5:0] qpi,   // Clip3(0,51, QPy + chroma_qp_index_offset)
	output reg  [5:0] qpc    // QPc per Table 8-15
);

	// ITU-T H.264 Table 8-15: qPI → QPc
	// qPI 0–29: identity; qPI 30–51: non-linear, saturates at 39
	always_comb begin
		case (qpi)
			6'd0:  qpc = 6'd0;
			6'd1:  qpc = 6'd1;
			6'd2:  qpc = 6'd2;
			6'd3:  qpc = 6'd3;
			6'd4:  qpc = 6'd4;
			6'd5:  qpc = 6'd5;
			6'd6:  qpc = 6'd6;
			6'd7:  qpc = 6'd7;
			6'd8:  qpc = 6'd8;
			6'd9:  qpc = 6'd9;
			6'd10: qpc = 6'd10;
			6'd11: qpc = 6'd11;
			6'd12: qpc = 6'd12;
			6'd13: qpc = 6'd13;
			6'd14: qpc = 6'd14;
			6'd15: qpc = 6'd15;
			6'd16: qpc = 6'd16;
			6'd17: qpc = 6'd17;
			6'd18: qpc = 6'd18;
			6'd19: qpc = 6'd19;
			6'd20: qpc = 6'd20;
			6'd21: qpc = 6'd21;
			6'd22: qpc = 6'd22;
			6'd23: qpc = 6'd23;
			6'd24: qpc = 6'd24;
			6'd25: qpc = 6'd25;
			6'd26: qpc = 6'd26;
			6'd27: qpc = 6'd27;
			6'd28: qpc = 6'd28;
			6'd29: qpc = 6'd29;
			// Non-linear region:
			6'd30: qpc = 6'd29;
			6'd31: qpc = 6'd30;
			6'd32: qpc = 6'd31;
			6'd33: qpc = 6'd32;
			6'd34: qpc = 6'd32;
			6'd35: qpc = 6'd33;
			6'd36: qpc = 6'd34;
			6'd37: qpc = 6'd34;
			6'd38: qpc = 6'd35;
			6'd39: qpc = 6'd35;
			6'd40: qpc = 6'd36;
			6'd41: qpc = 6'd36;
			6'd42: qpc = 6'd37;
			6'd43: qpc = 6'd37;
			6'd44: qpc = 6'd37;
			6'd45: qpc = 6'd38;
			6'd46: qpc = 6'd38;
			6'd47: qpc = 6'd38;
			6'd48: qpc = 6'd39;
			6'd49: qpc = 6'd39;
			6'd50: qpc = 6'd39;
			6'd51: qpc = 6'd39;
			// Out of range (6-bit can hold 0–63; spec says clip to 0–51)
			default: qpc = 6'd39;
		endcase
	end

endmodule

`default_nettype wire
