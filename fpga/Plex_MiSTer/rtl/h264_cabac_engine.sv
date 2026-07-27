// H.264 CABAC binary arithmetic decoder engine feasibility core.
// Implements FFmpeg-compatible CABAC range/low update for regular, bypass,
// bypass-sign, and terminate bins. Context derivation is intentionally external.

module h264_cabac_engine (
    input  wire               clk,
    input  wire               reset,

    input  wire               load,
    input  wire signed [31:0] load_low,
    input  wire        [8:0]  load_range,

    output wire        [15:0] refill_addr,
    input  wire        [15:0] refill_data,

    input  wire               valid,
    output wire               ready,
    input  wire        [1:0]  mode,       // 0=regular, 1=bypass, 2=bypass-sign, 3=terminate
    input  wire        [6:0]  state_in,

    output reg                out_valid,
    output reg                bin,
    output reg         [6:0]  state_out,
    output reg signed  [31:0] low_dbg,
    output reg         [8:0]  range_dbg,
    output reg         [15:0] byte_pos_dbg
);

    localparam [1:0] MODE_REGULAR = 2'd0;
    localparam [1:0] MODE_BYPASS  = 2'd1;
    localparam [1:0] MODE_SIGN    = 2'd2;
    localparam [1:0] MODE_TERM    = 2'd3;

    reg signed [31:0] low;
    reg [8:0] range;
    reg [15:0] byte_pos;

    assign ready = 1'b1;
    assign refill_addr = byte_pos;

    function automatic [7:0] lps_range(input [1:0] range_idx, input [5:0] pstate);
        reg [7:0] idx;
        begin
            idx = {range_idx, pstate};
            case (idx)
            8'd0: lps_range = 8'd128;
            8'd1: lps_range = 8'd128;
            8'd2: lps_range = 8'd128;
            8'd3: lps_range = 8'd123;
            8'd4: lps_range = 8'd116;
            8'd5: lps_range = 8'd111;
            8'd6: lps_range = 8'd105;
            8'd7: lps_range = 8'd100;
            8'd8: lps_range = 8'd95;
            8'd9: lps_range = 8'd90;
            8'd10: lps_range = 8'd85;
            8'd11: lps_range = 8'd81;
            8'd12: lps_range = 8'd77;
            8'd13: lps_range = 8'd73;
            8'd14: lps_range = 8'd69;
            8'd15: lps_range = 8'd66;
            8'd16: lps_range = 8'd62;
            8'd17: lps_range = 8'd59;
            8'd18: lps_range = 8'd56;
            8'd19: lps_range = 8'd53;
            8'd20: lps_range = 8'd51;
            8'd21: lps_range = 8'd48;
            8'd22: lps_range = 8'd46;
            8'd23: lps_range = 8'd43;
            8'd24: lps_range = 8'd41;
            8'd25: lps_range = 8'd39;
            8'd26: lps_range = 8'd37;
            8'd27: lps_range = 8'd35;
            8'd28: lps_range = 8'd33;
            8'd29: lps_range = 8'd32;
            8'd30: lps_range = 8'd30;
            8'd31: lps_range = 8'd29;
            8'd32: lps_range = 8'd27;
            8'd33: lps_range = 8'd26;
            8'd34: lps_range = 8'd24;
            8'd35: lps_range = 8'd23;
            8'd36: lps_range = 8'd22;
            8'd37: lps_range = 8'd21;
            8'd38: lps_range = 8'd20;
            8'd39: lps_range = 8'd19;
            8'd40: lps_range = 8'd18;
            8'd41: lps_range = 8'd17;
            8'd42: lps_range = 8'd16;
            8'd43: lps_range = 8'd15;
            8'd44: lps_range = 8'd14;
            8'd45: lps_range = 8'd14;
            8'd46: lps_range = 8'd13;
            8'd47: lps_range = 8'd12;
            8'd48: lps_range = 8'd12;
            8'd49: lps_range = 8'd11;
            8'd50: lps_range = 8'd11;
            8'd51: lps_range = 8'd10;
            8'd52: lps_range = 8'd10;
            8'd53: lps_range = 8'd9;
            8'd54: lps_range = 8'd9;
            8'd55: lps_range = 8'd8;
            8'd56: lps_range = 8'd8;
            8'd57: lps_range = 8'd7;
            8'd58: lps_range = 8'd7;
            8'd59: lps_range = 8'd7;
            8'd60: lps_range = 8'd6;
            8'd61: lps_range = 8'd6;
            8'd62: lps_range = 8'd6;
            8'd63: lps_range = 8'd2;
            8'd64: lps_range = 8'd176;
            8'd65: lps_range = 8'd167;
            8'd66: lps_range = 8'd158;
            8'd67: lps_range = 8'd150;
            8'd68: lps_range = 8'd142;
            8'd69: lps_range = 8'd135;
            8'd70: lps_range = 8'd128;
            8'd71: lps_range = 8'd122;
            8'd72: lps_range = 8'd116;
            8'd73: lps_range = 8'd110;
            8'd74: lps_range = 8'd104;
            8'd75: lps_range = 8'd99;
            8'd76: lps_range = 8'd94;
            8'd77: lps_range = 8'd89;
            8'd78: lps_range = 8'd85;
            8'd79: lps_range = 8'd80;
            8'd80: lps_range = 8'd76;
            8'd81: lps_range = 8'd72;
            8'd82: lps_range = 8'd69;
            8'd83: lps_range = 8'd65;
            8'd84: lps_range = 8'd62;
            8'd85: lps_range = 8'd59;
            8'd86: lps_range = 8'd56;
            8'd87: lps_range = 8'd53;
            8'd88: lps_range = 8'd50;
            8'd89: lps_range = 8'd48;
            8'd90: lps_range = 8'd45;
            8'd91: lps_range = 8'd43;
            8'd92: lps_range = 8'd41;
            8'd93: lps_range = 8'd39;
            8'd94: lps_range = 8'd37;
            8'd95: lps_range = 8'd35;
            8'd96: lps_range = 8'd33;
            8'd97: lps_range = 8'd31;
            8'd98: lps_range = 8'd30;
            8'd99: lps_range = 8'd28;
            8'd100: lps_range = 8'd27;
            8'd101: lps_range = 8'd26;
            8'd102: lps_range = 8'd24;
            8'd103: lps_range = 8'd23;
            8'd104: lps_range = 8'd22;
            8'd105: lps_range = 8'd21;
            8'd106: lps_range = 8'd20;
            8'd107: lps_range = 8'd19;
            8'd108: lps_range = 8'd18;
            8'd109: lps_range = 8'd17;
            8'd110: lps_range = 8'd16;
            8'd111: lps_range = 8'd15;
            8'd112: lps_range = 8'd14;
            8'd113: lps_range = 8'd14;
            8'd114: lps_range = 8'd13;
            8'd115: lps_range = 8'd12;
            8'd116: lps_range = 8'd12;
            8'd117: lps_range = 8'd11;
            8'd118: lps_range = 8'd11;
            8'd119: lps_range = 8'd10;
            8'd120: lps_range = 8'd9;
            8'd121: lps_range = 8'd9;
            8'd122: lps_range = 8'd9;
            8'd123: lps_range = 8'd8;
            8'd124: lps_range = 8'd8;
            8'd125: lps_range = 8'd7;
            8'd126: lps_range = 8'd7;
            8'd127: lps_range = 8'd2;
            8'd128: lps_range = 8'd208;
            8'd129: lps_range = 8'd197;
            8'd130: lps_range = 8'd187;
            8'd131: lps_range = 8'd178;
            8'd132: lps_range = 8'd169;
            8'd133: lps_range = 8'd160;
            8'd134: lps_range = 8'd152;
            8'd135: lps_range = 8'd144;
            8'd136: lps_range = 8'd137;
            8'd137: lps_range = 8'd130;
            8'd138: lps_range = 8'd123;
            8'd139: lps_range = 8'd117;
            8'd140: lps_range = 8'd111;
            8'd141: lps_range = 8'd105;
            8'd142: lps_range = 8'd100;
            8'd143: lps_range = 8'd95;
            8'd144: lps_range = 8'd90;
            8'd145: lps_range = 8'd86;
            8'd146: lps_range = 8'd81;
            8'd147: lps_range = 8'd77;
            8'd148: lps_range = 8'd73;
            8'd149: lps_range = 8'd69;
            8'd150: lps_range = 8'd66;
            8'd151: lps_range = 8'd63;
            8'd152: lps_range = 8'd59;
            8'd153: lps_range = 8'd56;
            8'd154: lps_range = 8'd54;
            8'd155: lps_range = 8'd51;
            8'd156: lps_range = 8'd48;
            8'd157: lps_range = 8'd46;
            8'd158: lps_range = 8'd43;
            8'd159: lps_range = 8'd41;
            8'd160: lps_range = 8'd39;
            8'd161: lps_range = 8'd37;
            8'd162: lps_range = 8'd35;
            8'd163: lps_range = 8'd33;
            8'd164: lps_range = 8'd32;
            8'd165: lps_range = 8'd30;
            8'd166: lps_range = 8'd29;
            8'd167: lps_range = 8'd27;
            8'd168: lps_range = 8'd26;
            8'd169: lps_range = 8'd25;
            8'd170: lps_range = 8'd23;
            8'd171: lps_range = 8'd22;
            8'd172: lps_range = 8'd21;
            8'd173: lps_range = 8'd20;
            8'd174: lps_range = 8'd19;
            8'd175: lps_range = 8'd18;
            8'd176: lps_range = 8'd17;
            8'd177: lps_range = 8'd16;
            8'd178: lps_range = 8'd15;
            8'd179: lps_range = 8'd15;
            8'd180: lps_range = 8'd14;
            8'd181: lps_range = 8'd13;
            8'd182: lps_range = 8'd12;
            8'd183: lps_range = 8'd12;
            8'd184: lps_range = 8'd11;
            8'd185: lps_range = 8'd11;
            8'd186: lps_range = 8'd10;
            8'd187: lps_range = 8'd10;
            8'd188: lps_range = 8'd9;
            8'd189: lps_range = 8'd9;
            8'd190: lps_range = 8'd8;
            8'd191: lps_range = 8'd2;
            8'd192: lps_range = 8'd240;
            8'd193: lps_range = 8'd227;
            8'd194: lps_range = 8'd216;
            8'd195: lps_range = 8'd205;
            8'd196: lps_range = 8'd195;
            8'd197: lps_range = 8'd185;
            8'd198: lps_range = 8'd175;
            8'd199: lps_range = 8'd166;
            8'd200: lps_range = 8'd158;
            8'd201: lps_range = 8'd150;
            8'd202: lps_range = 8'd142;
            8'd203: lps_range = 8'd135;
            8'd204: lps_range = 8'd128;
            8'd205: lps_range = 8'd122;
            8'd206: lps_range = 8'd116;
            8'd207: lps_range = 8'd110;
            8'd208: lps_range = 8'd104;
            8'd209: lps_range = 8'd99;
            8'd210: lps_range = 8'd94;
            8'd211: lps_range = 8'd89;
            8'd212: lps_range = 8'd85;
            8'd213: lps_range = 8'd80;
            8'd214: lps_range = 8'd76;
            8'd215: lps_range = 8'd72;
            8'd216: lps_range = 8'd69;
            8'd217: lps_range = 8'd65;
            8'd218: lps_range = 8'd62;
            8'd219: lps_range = 8'd59;
            8'd220: lps_range = 8'd56;
            8'd221: lps_range = 8'd53;
            8'd222: lps_range = 8'd50;
            8'd223: lps_range = 8'd48;
            8'd224: lps_range = 8'd45;
            8'd225: lps_range = 8'd43;
            8'd226: lps_range = 8'd41;
            8'd227: lps_range = 8'd39;
            8'd228: lps_range = 8'd37;
            8'd229: lps_range = 8'd35;
            8'd230: lps_range = 8'd33;
            8'd231: lps_range = 8'd31;
            8'd232: lps_range = 8'd30;
            8'd233: lps_range = 8'd28;
            8'd234: lps_range = 8'd27;
            8'd235: lps_range = 8'd25;
            8'd236: lps_range = 8'd24;
            8'd237: lps_range = 8'd23;
            8'd238: lps_range = 8'd22;
            8'd239: lps_range = 8'd21;
            8'd240: lps_range = 8'd20;
            8'd241: lps_range = 8'd19;
            8'd242: lps_range = 8'd18;
            8'd243: lps_range = 8'd17;
            8'd244: lps_range = 8'd16;
            8'd245: lps_range = 8'd15;
            8'd246: lps_range = 8'd14;
            8'd247: lps_range = 8'd14;
            8'd248: lps_range = 8'd13;
            8'd249: lps_range = 8'd12;
            8'd250: lps_range = 8'd12;
            8'd251: lps_range = 8'd11;
            8'd252: lps_range = 8'd11;
            8'd253: lps_range = 8'd10;
            8'd254: lps_range = 8'd9;
            8'd255: lps_range = 8'd2;
            endcase
        end
    endfunction

    function automatic [7:0] mlps_state(input [7:0] idx);
        begin
            case (idx)
            8'd0: mlps_state = 8'd127;
            8'd1: mlps_state = 8'd126;
            8'd2: mlps_state = 8'd77;
            8'd3: mlps_state = 8'd76;
            8'd4: mlps_state = 8'd77;
            8'd5: mlps_state = 8'd76;
            8'd6: mlps_state = 8'd75;
            8'd7: mlps_state = 8'd74;
            8'd8: mlps_state = 8'd75;
            8'd9: mlps_state = 8'd74;
            8'd10: mlps_state = 8'd75;
            8'd11: mlps_state = 8'd74;
            8'd12: mlps_state = 8'd73;
            8'd13: mlps_state = 8'd72;
            8'd14: mlps_state = 8'd73;
            8'd15: mlps_state = 8'd72;
            8'd16: mlps_state = 8'd73;
            8'd17: mlps_state = 8'd72;
            8'd18: mlps_state = 8'd71;
            8'd19: mlps_state = 8'd70;
            8'd20: mlps_state = 8'd71;
            8'd21: mlps_state = 8'd70;
            8'd22: mlps_state = 8'd71;
            8'd23: mlps_state = 8'd70;
            8'd24: mlps_state = 8'd69;
            8'd25: mlps_state = 8'd68;
            8'd26: mlps_state = 8'd69;
            8'd27: mlps_state = 8'd68;
            8'd28: mlps_state = 8'd67;
            8'd29: mlps_state = 8'd66;
            8'd30: mlps_state = 8'd67;
            8'd31: mlps_state = 8'd66;
            8'd32: mlps_state = 8'd67;
            8'd33: mlps_state = 8'd66;
            8'd34: mlps_state = 8'd65;
            8'd35: mlps_state = 8'd64;
            8'd36: mlps_state = 8'd65;
            8'd37: mlps_state = 8'd64;
            8'd38: mlps_state = 8'd63;
            8'd39: mlps_state = 8'd62;
            8'd40: mlps_state = 8'd61;
            8'd41: mlps_state = 8'd60;
            8'd42: mlps_state = 8'd61;
            8'd43: mlps_state = 8'd60;
            8'd44: mlps_state = 8'd61;
            8'd45: mlps_state = 8'd60;
            8'd46: mlps_state = 8'd59;
            8'd47: mlps_state = 8'd58;
            8'd48: mlps_state = 8'd59;
            8'd49: mlps_state = 8'd58;
            8'd50: mlps_state = 8'd57;
            8'd51: mlps_state = 8'd56;
            8'd52: mlps_state = 8'd55;
            8'd53: mlps_state = 8'd54;
            8'd54: mlps_state = 8'd55;
            8'd55: mlps_state = 8'd54;
            8'd56: mlps_state = 8'd53;
            8'd57: mlps_state = 8'd52;
            8'd58: mlps_state = 8'd53;
            8'd59: mlps_state = 8'd52;
            8'd60: mlps_state = 8'd51;
            8'd61: mlps_state = 8'd50;
            8'd62: mlps_state = 8'd49;
            8'd63: mlps_state = 8'd48;
            8'd64: mlps_state = 8'd49;
            8'd65: mlps_state = 8'd48;
            8'd66: mlps_state = 8'd47;
            8'd67: mlps_state = 8'd46;
            8'd68: mlps_state = 8'd45;
            8'd69: mlps_state = 8'd44;
            8'd70: mlps_state = 8'd45;
            8'd71: mlps_state = 8'd44;
            8'd72: mlps_state = 8'd43;
            8'd73: mlps_state = 8'd42;
            8'd74: mlps_state = 8'd43;
            8'd75: mlps_state = 8'd42;
            8'd76: mlps_state = 8'd39;
            8'd77: mlps_state = 8'd38;
            8'd78: mlps_state = 8'd39;
            8'd79: mlps_state = 8'd38;
            8'd80: mlps_state = 8'd37;
            8'd81: mlps_state = 8'd36;
            8'd82: mlps_state = 8'd37;
            8'd83: mlps_state = 8'd36;
            8'd84: mlps_state = 8'd33;
            8'd85: mlps_state = 8'd32;
            8'd86: mlps_state = 8'd33;
            8'd87: mlps_state = 8'd32;
            8'd88: mlps_state = 8'd31;
            8'd89: mlps_state = 8'd30;
            8'd90: mlps_state = 8'd31;
            8'd91: mlps_state = 8'd30;
            8'd92: mlps_state = 8'd27;
            8'd93: mlps_state = 8'd26;
            8'd94: mlps_state = 8'd27;
            8'd95: mlps_state = 8'd26;
            8'd96: mlps_state = 8'd25;
            8'd97: mlps_state = 8'd24;
            8'd98: mlps_state = 8'd23;
            8'd99: mlps_state = 8'd22;
            8'd100: mlps_state = 8'd23;
            8'd101: mlps_state = 8'd22;
            8'd102: mlps_state = 8'd19;
            8'd103: mlps_state = 8'd18;
            8'd104: mlps_state = 8'd19;
            8'd105: mlps_state = 8'd18;
            8'd106: mlps_state = 8'd17;
            8'd107: mlps_state = 8'd16;
            8'd108: mlps_state = 8'd15;
            8'd109: mlps_state = 8'd14;
            8'd110: mlps_state = 8'd13;
            8'd111: mlps_state = 8'd12;
            8'd112: mlps_state = 8'd11;
            8'd113: mlps_state = 8'd10;
            8'd114: mlps_state = 8'd9;
            8'd115: mlps_state = 8'd8;
            8'd116: mlps_state = 8'd9;
            8'd117: mlps_state = 8'd8;
            8'd118: mlps_state = 8'd5;
            8'd119: mlps_state = 8'd4;
            8'd120: mlps_state = 8'd5;
            8'd121: mlps_state = 8'd4;
            8'd122: mlps_state = 8'd3;
            8'd123: mlps_state = 8'd2;
            8'd124: mlps_state = 8'd1;
            8'd125: mlps_state = 8'd0;
            8'd126: mlps_state = 8'd0;
            8'd127: mlps_state = 8'd1;
            8'd128: mlps_state = 8'd2;
            8'd129: mlps_state = 8'd3;
            8'd130: mlps_state = 8'd4;
            8'd131: mlps_state = 8'd5;
            8'd132: mlps_state = 8'd6;
            8'd133: mlps_state = 8'd7;
            8'd134: mlps_state = 8'd8;
            8'd135: mlps_state = 8'd9;
            8'd136: mlps_state = 8'd10;
            8'd137: mlps_state = 8'd11;
            8'd138: mlps_state = 8'd12;
            8'd139: mlps_state = 8'd13;
            8'd140: mlps_state = 8'd14;
            8'd141: mlps_state = 8'd15;
            8'd142: mlps_state = 8'd16;
            8'd143: mlps_state = 8'd17;
            8'd144: mlps_state = 8'd18;
            8'd145: mlps_state = 8'd19;
            8'd146: mlps_state = 8'd20;
            8'd147: mlps_state = 8'd21;
            8'd148: mlps_state = 8'd22;
            8'd149: mlps_state = 8'd23;
            8'd150: mlps_state = 8'd24;
            8'd151: mlps_state = 8'd25;
            8'd152: mlps_state = 8'd26;
            8'd153: mlps_state = 8'd27;
            8'd154: mlps_state = 8'd28;
            8'd155: mlps_state = 8'd29;
            8'd156: mlps_state = 8'd30;
            8'd157: mlps_state = 8'd31;
            8'd158: mlps_state = 8'd32;
            8'd159: mlps_state = 8'd33;
            8'd160: mlps_state = 8'd34;
            8'd161: mlps_state = 8'd35;
            8'd162: mlps_state = 8'd36;
            8'd163: mlps_state = 8'd37;
            8'd164: mlps_state = 8'd38;
            8'd165: mlps_state = 8'd39;
            8'd166: mlps_state = 8'd40;
            8'd167: mlps_state = 8'd41;
            8'd168: mlps_state = 8'd42;
            8'd169: mlps_state = 8'd43;
            8'd170: mlps_state = 8'd44;
            8'd171: mlps_state = 8'd45;
            8'd172: mlps_state = 8'd46;
            8'd173: mlps_state = 8'd47;
            8'd174: mlps_state = 8'd48;
            8'd175: mlps_state = 8'd49;
            8'd176: mlps_state = 8'd50;
            8'd177: mlps_state = 8'd51;
            8'd178: mlps_state = 8'd52;
            8'd179: mlps_state = 8'd53;
            8'd180: mlps_state = 8'd54;
            8'd181: mlps_state = 8'd55;
            8'd182: mlps_state = 8'd56;
            8'd183: mlps_state = 8'd57;
            8'd184: mlps_state = 8'd58;
            8'd185: mlps_state = 8'd59;
            8'd186: mlps_state = 8'd60;
            8'd187: mlps_state = 8'd61;
            8'd188: mlps_state = 8'd62;
            8'd189: mlps_state = 8'd63;
            8'd190: mlps_state = 8'd64;
            8'd191: mlps_state = 8'd65;
            8'd192: mlps_state = 8'd66;
            8'd193: mlps_state = 8'd67;
            8'd194: mlps_state = 8'd68;
            8'd195: mlps_state = 8'd69;
            8'd196: mlps_state = 8'd70;
            8'd197: mlps_state = 8'd71;
            8'd198: mlps_state = 8'd72;
            8'd199: mlps_state = 8'd73;
            8'd200: mlps_state = 8'd74;
            8'd201: mlps_state = 8'd75;
            8'd202: mlps_state = 8'd76;
            8'd203: mlps_state = 8'd77;
            8'd204: mlps_state = 8'd78;
            8'd205: mlps_state = 8'd79;
            8'd206: mlps_state = 8'd80;
            8'd207: mlps_state = 8'd81;
            8'd208: mlps_state = 8'd82;
            8'd209: mlps_state = 8'd83;
            8'd210: mlps_state = 8'd84;
            8'd211: mlps_state = 8'd85;
            8'd212: mlps_state = 8'd86;
            8'd213: mlps_state = 8'd87;
            8'd214: mlps_state = 8'd88;
            8'd215: mlps_state = 8'd89;
            8'd216: mlps_state = 8'd90;
            8'd217: mlps_state = 8'd91;
            8'd218: mlps_state = 8'd92;
            8'd219: mlps_state = 8'd93;
            8'd220: mlps_state = 8'd94;
            8'd221: mlps_state = 8'd95;
            8'd222: mlps_state = 8'd96;
            8'd223: mlps_state = 8'd97;
            8'd224: mlps_state = 8'd98;
            8'd225: mlps_state = 8'd99;
            8'd226: mlps_state = 8'd100;
            8'd227: mlps_state = 8'd101;
            8'd228: mlps_state = 8'd102;
            8'd229: mlps_state = 8'd103;
            8'd230: mlps_state = 8'd104;
            8'd231: mlps_state = 8'd105;
            8'd232: mlps_state = 8'd106;
            8'd233: mlps_state = 8'd107;
            8'd234: mlps_state = 8'd108;
            8'd235: mlps_state = 8'd109;
            8'd236: mlps_state = 8'd110;
            8'd237: mlps_state = 8'd111;
            8'd238: mlps_state = 8'd112;
            8'd239: mlps_state = 8'd113;
            8'd240: mlps_state = 8'd114;
            8'd241: mlps_state = 8'd115;
            8'd242: mlps_state = 8'd116;
            8'd243: mlps_state = 8'd117;
            8'd244: mlps_state = 8'd118;
            8'd245: mlps_state = 8'd119;
            8'd246: mlps_state = 8'd120;
            8'd247: mlps_state = 8'd121;
            8'd248: mlps_state = 8'd122;
            8'd249: mlps_state = 8'd123;
            8'd250: mlps_state = 8'd124;
            8'd251: mlps_state = 8'd125;
            8'd252: mlps_state = 8'd124;
            8'd253: mlps_state = 8'd125;
            8'd254: mlps_state = 8'd126;
            8'd255: mlps_state = 8'd127;
            endcase
        end
    endfunction

    function automatic [3:0] norm_shift(input [8:0] r);
        begin
            if (r[8]) norm_shift = 4'd0;
            else if (r[7]) norm_shift = 4'd1;
            else if (r[6]) norm_shift = 4'd2;
            else if (r[5]) norm_shift = 4'd3;
            else if (r[4]) norm_shift = 4'd4;
            else if (r[3]) norm_shift = 4'd5;
            else if (r[2]) norm_shift = 4'd6;
            else if (r[1]) norm_shift = 4'd7;
            else norm_shift = 4'd8;
        end
    endfunction

    function automatic [4:0] ctz32(input [31:0] v);
        integer i;
        begin
            ctz32 = 5'd31;
            for (i = 0; i < 32; i = i + 1) begin
                if (v[i]) begin
                    ctz32 = i[4:0];
                    i = 32;
                end
            end
        end
    endfunction

    task automatic refill_pair(
        input  signed [31:0] in_low,
        input         [15:0] in_pos,
        output signed [31:0] out_low,
        output        [15:0] out_pos
    );
        reg signed [31:0] addv;
        begin
            addv = {16'd0, refill_data[15:8], 9'd0} + {22'd0, refill_data[7:0], 1'd0} - 32'sd65535;
            out_low = in_low + addv;
            out_pos = in_pos + 16'd2;
        end
    endtask

    task automatic refill_pair_shifted(
        input  signed [31:0] in_low,
        input         [15:0] in_pos,
        output signed [31:0] out_low,
        output        [15:0] out_pos
    );
        reg signed [31:0] addv;
        reg [4:0] sh;
        begin
            sh = ctz32(in_low[31:0]) - 5'd16;
            addv = {16'd0, refill_data[15:8], 9'd0} + {22'd0, refill_data[7:0], 1'd0} - 32'sd65535;
            out_low = in_low + (addv <<< sh);
            out_pos = in_pos + 16'd2;
        end
    endtask

    always @(posedge clk) begin
        reg signed [31:0] nlow;
        reg signed [31:0] threshold;
        reg [8:0] nrange;
        reg [15:0] npos;
        reg [7:0] rlps;
        reg [8:0] rmps;
        reg [3:0] sh;
        reg lps;
        out_valid <= 1'b0;

        if (reset) begin
            low <= 32'sd0;
            range <= 9'd0;
            byte_pos <= 16'd0;
            low_dbg <= 32'sd0;
            range_dbg <= 9'd0;
            byte_pos_dbg <= 16'd0;
            bin <= 1'b0;
            state_out <= 7'd0;
        end else if (load) begin
            low <= load_low;
            range <= load_range;
            byte_pos <= 16'd0;
            low_dbg <= load_low;
            range_dbg <= load_range;
            byte_pos_dbg <= 16'd0;
            out_valid <= 1'b0;
        end else if (valid) begin
            nlow = low;
            nrange = range;
            npos = byte_pos;
            state_out <= state_in;
            bin <= 1'b0;

            if (mode == MODE_REGULAR) begin
                rlps = lps_range(range[7:6], state_in[6:1]);
                rmps = range - {1'b0, rlps};
                threshold = {14'd0, rmps, 17'd0};
                lps = ((threshold - low) < 0);
                if (lps) begin
                    nlow = low - threshold;
                    nrange = {1'b0, rlps};
                    state_out <= mlps_state(8'd127 - {1'b0, state_in})[6:0];
                    bin <= ~state_in[0];
                end else begin
                    nrange = rmps;
                    state_out <= mlps_state(8'd128 + {1'b0, state_in})[6:0];
                    bin <= state_in[0];
                end
                sh = norm_shift(nrange);
                nrange = nrange << sh;
                nlow = nlow <<< sh;
                if (nlow[15:0] == 16'd0)
                    refill_pair_shifted(nlow, npos, nlow, npos);
            end else if (mode == MODE_BYPASS || mode == MODE_SIGN) begin
                nlow = low <<< 1;
                if (nlow[15:0] == 16'd0)
                    refill_pair(nlow, npos, nlow, npos);
                threshold = {14'd0, range, 17'd0};
                if (nlow < threshold) begin
                    bin <= 1'b0;
                end else begin
                    nlow = nlow - threshold;
                    bin <= 1'b1;
                end
            end else begin
                nrange = range - 9'd2;
                threshold = {14'd0, nrange, 17'd0};
                if (low < threshold) begin
                    bin <= 1'b0;
                    if (nrange < 9'h100) begin
                        nrange = nrange << 1;
                        nlow = low <<< 1;
                        if (nlow[15:0] == 16'd0)
                            refill_pair(nlow, npos, nlow, npos);
                    end
                end else begin
                    bin <= 1'b1;
                end
            end

            low <= nlow;
            range <= nrange;
            byte_pos <= npos;
            low_dbg <= nlow;
            range_dbg <= nrange;
            byte_pos_dbg <= npos;
            out_valid <= 1'b1;
        end
    end
endmodule
