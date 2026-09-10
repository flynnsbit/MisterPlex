// Shared serial inverse quantization/transform. Signed coefficients retain
// their complete syntax range; only prediction + residual is clipped.
module h264_recon (
	input wire clk, reset, start,
	input wire signed [15:0] cavlc_coeff [0:15],
	input wire [5:0] qp,
	input wire [4:0] max_coeff,
	input wire [7:0] pred [0:15],
	input wire use_dc,
	input wire signed [31:0] dc_value,
	output wire signed [15:0] sat_coeff [0:15],
	output reg [7:0] recon [0:15],
	output reg [7:0] recon_sig,
	output reg done, ok
);
	reg [2:0] state;
	reg [4:0] index;
	`include "h264_qp_math.svh"
	reg [3:0] q_div6;
	reg [2:0] q_mod6;
	reg [4:0] count;
	reg dc_enable;
	reg ac_nonzero;
	reg signed [35:0] dc_residual;
	reg signed [31:0] dc;
	reg signed [15:0] coeff [0:15];
	reg [7:0] prediction [0:15];
	reg signed [35:0] block_data [0:15];
	reg signed [35:0] a, b, c, d, z0, z1, z2, z3;
	reg signed [35:0] product, pixel;
	reg [3:0] pos;
	reg [4:0] scale;
	reg [1:0] category;
	integer i, base;

	function automatic [3:0] zigzag(input [3:0] n);
		case(n)
		0:zigzag=0; 1:zigzag=1; 2:zigzag=4; 3:zigzag=8;
		4:zigzag=5; 5:zigzag=2; 6:zigzag=3; 7:zigzag=6;
		8:zigzag=9; 9:zigzag=12; 10:zigzag=13; 11:zigzag=10;
		12:zigzag=7; 13:zigzag=11; 14:zigzag=14; default:zigzag=15;
		endcase
	endfunction

	genvar g;
	generate for(g=0;g<16;g=g+1) begin: full_coeff
		assign sat_coeff[g] = cavlc_coeff[g];
	end endgenerate

	always @* begin
		pos = zigzag(index[3:0]);
		category = {1'b0,pos[0]} + {1'b0,pos[2]};
		case(q_mod6)
		0: scale = category==0 ? 10 : category==1 ? 13 : 16;
		1: scale = category==0 ? 11 : category==1 ? 14 : 18;
		2: scale = category==0 ? 13 : category==1 ? 16 : 20;
		3: scale = category==0 ? 14 : category==1 ? 18 : 23;
		4: scale = category==0 ? 16 : category==1 ? 20 : 25;
		default: scale = category==0 ? 18 : category==1 ? 23 : 29;
		endcase
		product = $signed(coeff[index[3:0]]) * $signed({1'b0,scale});
		product = product <<< q_div6;
		base = state==2 ? index[1:0]*4 : index[1:0];
		a=block_data[base]; b=block_data[base+(state==2 ? 1 : 4)];
		c=block_data[base+(state==2 ? 2 : 8)];
		d=block_data[base+(state==2 ? 3 : 12)];
		z0=a+c; z1=a-c; z2=(b>>>1)-d; z3=b+(d>>>1);
		pixel = ((block_data[index[3:0]] + 36'sd32) >>> 6)
		        + $signed({1'b0,prediction[index[3:0]]});
	end

	always @(posedge clk) begin
		done <= 0;
		if(reset) begin
			state<=0; index<=0; ok<=0; recon_sig<=0;
		end else case(state)
		0: if(start) begin
			q_div6<=h264_qp_div6(qp); q_mod6<=h264_qp_mod6(qp);
			count<=max_coeff; dc_enable<=use_dc; dc<=dc_value;
			ok<=0; index<=0; recon_sig<=0;
			ac_nonzero<=0;
			for(i=0;i<16;i=i+1) begin
				if (i<max_coeff && cavlc_coeff[i]!=0 && (max_coeff==15 || i!=0))
					ac_nonzero<=1;
				// max_coeff=15 is the CAVLC AC-only list, not a full
				// scan with its last coefficient dropped.
				coeff[i] <= max_coeff==15 ? (i==0 ? 16'sd0 : cavlc_coeff[i-1])
				                                : (i<max_coeff ? cavlc_coeff[i] : 16'sd0);
				prediction[i]<=pred[i];
			end
			if(qp<=51 && (max_coeff==0 || max_coeff==15 || max_coeff==16))
				state<=1;
			else begin done<=1; ok<=0; end
		end
		1: begin
			block_data[pos] <= dc_enable && index==0 ? {{4{dc[31]}},dc} : product;
			if(index==0 && !ac_nonzero) begin
				dc_residual<=((dc_enable ? 36'(dc) : product)+36'sd32)>>>6;
				state<=5;
			end else if(index==15) begin index<=0; state<=2; end
			else index<=index+1'b1;
		end
		2: begin
			block_data[base]<=z0+z3; block_data[base+1]<=z1+z2;
			block_data[base+2]<=z1-z2; block_data[base+3]<=z0-z3;
			if(index==3) begin index<=0; state<=3; end
			else index<=index+1'b1;
		end
		3: begin
			block_data[base]<=z0+z3; block_data[base+4]<=z1+z2;
			block_data[base+8]<=z1-z2; block_data[base+12]<=z0-z3;
			if(index==3) begin index<=0; state<=4; end
			else index<=index+1'b1;
		end
		4: begin
			recon[index[3:0]] <= pixel<0 ? 8'd0 : pixel>255 ? 8'd255 : pixel[7:0];
			recon_sig <= recon_sig ^ (pixel<0 ? 8'd0 : pixel>255 ? 8'd255 : pixel[7:0]);
			if(index==15) begin done<=1; ok<=1; state<=0; end
			else index<=index+1'b1;
		end
		5: begin
			for(i=0;i<16;i=i+1) begin
				recon[i] <= $signed({1'b0,prediction[i]})+dc_residual<0 ? 8'd0 :
				            $signed({1'b0,prediction[i]})+dc_residual>255 ? 8'd255 :
				            8'($signed({1'b0,prediction[i]})+dc_residual);
			end
			state<=6;
		end
		6: begin
			recon_sig<=recon[0]^recon[1]^recon[2]^recon[3]^recon[4]^recon[5]^recon[6]^recon[7]^
			           recon[8]^recon[9]^recon[10]^recon[11]^recon[12]^recon[13]^recon[14]^recon[15];
			done<=1;ok<=1;state<=0;
		end
		default:state<=0;
		endcase
	end
endmodule
