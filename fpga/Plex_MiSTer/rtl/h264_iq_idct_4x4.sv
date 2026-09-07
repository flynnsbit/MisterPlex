// Combinational leaf interfaces for diagnostics and transform verification.
// The macroblock controller shares the serial implementation in h264_recon.
module h264_dequant4x4 (
	input wire signed [15:0] coeff [0:15],
	input wire [5:0] qp,
	input wire [4:0] max_coeff,
	output reg signed [31:0] dequant [0:15]
);
	function automatic integer zigzag(input integer n);
		case(n)
		0:zigzag=0; 1:zigzag=1; 2:zigzag=4; 3:zigzag=8;
		4:zigzag=5; 5:zigzag=2; 6:zigzag=3; 7:zigzag=6;
		8:zigzag=9; 9:zigzag=12; 10:zigzag=13; 11:zigzag=10;
		12:zigzag=7; 13:zigzag=11; 14:zigzag=14; default:zigzag=15;
		endcase
	endfunction
	integer i, pos, category, scale;
	reg signed [35:0] value;
	always @* begin
		for(i=0;i<16;i=i+1) dequant[i]=0;
		pos=0; category=0; scale=0; value=0;
		for(i=0;i<16;i=i+1) begin
			if(i<max_coeff && (max_coeff!=15 || i<15)) begin
				pos=zigzag(i+(max_coeff==15 ? 1 : 0));
				category=(pos&1)+((pos>>2)&1);
				case(qp%6)
				0:scale=category==0 ? 10 : category==1 ? 13 : 16;
				1:scale=category==0 ? 11 : category==1 ? 14 : 18;
				2:scale=category==0 ? 13 : category==1 ? 16 : 20;
				3:scale=category==0 ? 14 : category==1 ? 18 : 23;
				4:scale=category==0 ? 16 : category==1 ? 20 : 25;
				default:scale=category==0 ? 18 : category==1 ? 23 : 29;
				endcase
				value=$signed(coeff[i])*scale;
				dequant[pos]=value<<<(qp/6);
			end
		end
	end
endmodule

module h264_idct4x4 (
	input wire signed [31:0] dequant [0:15],
	output reg signed [31:0] residual [0:15]
);
	reg signed [35:0] rows [0:15];
	reg signed [35:0] a,b,c,d,z0,z1,z2,z3;
	integer i;
	always @* begin
		a=0;b=0;c=0;d=0;z0=0;z1=0;z2=0;z3=0;
		for(i=0;i<4;i=i+1) begin
			a=dequant[4*i];b=dequant[4*i+1];
			c=dequant[4*i+2];d=dequant[4*i+3];
			z0=a+c;z1=a-c;z2=(b>>>1)-d;z3=b+(d>>>1);
			rows[4*i]=z0+z3;rows[4*i+1]=z1+z2;
			rows[4*i+2]=z1-z2;rows[4*i+3]=z0-z3;
		end
		for(i=0;i<4;i=i+1) begin
			a=rows[i];b=rows[i+4];c=rows[i+8];d=rows[i+12];
			z0=a+c;z1=a-c;z2=(b>>>1)-d;z3=b+(d>>>1);
			residual[i]=(z0+z3+36'sd32)>>>6;
			residual[i+4]=(z1+z2+36'sd32)>>>6;
			residual[i+8]=(z1-z2+36'sd32)>>>6;
			residual[i+12]=(z0-z3+36'sd32)>>>6;
		end
	end
endmodule

module h264_recon4x4 (
	input wire [7:0] pred [0:15],
	input wire signed [31:0] residual [0:15],
	output wire [7:0] recon [0:15]
);
	genvar i;
	generate for(i=0;i<16;i=i+1) begin: pixel
		wire signed [32:0] value=$signed({1'b0,pred[i]})+residual[i];
		assign recon[i]=value<0 ? 8'd0 : value>255 ? 8'd255 : value[7:0];
	end endgenerate
endmodule
