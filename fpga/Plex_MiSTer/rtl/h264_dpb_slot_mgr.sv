// DDR-resident multi-slot DPB manager (fabric decode).
//
// Frames live at product physical bases:
//   slot_base = DPB_PHYS_BASE + slot_id * DPB_SLOT_STRIDE
// Plane layout inside a slot matches present I420 (Y then U then V).
//
// Lifecycle:
//   idr_start  -> invalidate all refs; claim slot 0 as current
//   frame_done -> promote current -> short-term ref; allocate new current
// Eviction (when full): drop oldest short-term ref (min age). Sliding-window
// baseline - not full H.264 MMCO.
//
// FAULT H264_DPB_DDR_FAULT_WRONG_EVICT: drop NEWEST ref instead - List0[0]
// becomes wrong; negative TB must fail.
//
// Metadata only - no DDR data ports. w-mem owns arbiter attach (future m3).
`default_nettype none

module h264_dpb_slot_mgr #(
	parameter int NUM_SLOTS = 5,
	parameter int DPB_PHYS_BASE = 32'h3080_0000,
	parameter int DPB_SLOT_STRIDE = 32'h0018_0000
)(
	input  wire        clk,
	input  wire        reset,

	input  wire        idr_start,
	input  wire        frame_done,
	input  wire [15:0] frame_num,

	output reg         ref_ready,
	output reg  [2:0]  ref_count,
	output reg  [2:0]  current_slot,
	output reg  [31:0] current_base,
	output reg  [31:0] ref_base0,
	output reg  [31:0] ref_base1,
	output reg  [31:0] ref_base2,
	output reg  [31:0] ref_base3,
	output reg         alloc_error,
	output reg         evict_pulse
);
	function automatic [31:0] slot_phys(input integer s);
		slot_phys = DPB_PHYS_BASE[31:0] + (s[31:0] * DPB_SLOT_STRIDE[31:0]);
	endfunction

	reg        valid_r  [0:NUM_SLOTS-1];
	reg        is_ref_r [0:NUM_SLOTS-1];
	reg        is_cur_r [0:NUM_SLOTS-1];
	reg [15:0] fnum_r   [0:NUM_SLOTS-1];
	reg [15:0] age_r    [0:NUM_SLOTS-1];
	reg [15:0] age_tick_r;
	reg [2:0]  cur_r;

	reg        found_free;
	reg [2:0]  free_s;
	reg        found_vict;
	reg [2:0]  vict_s;
	reg [15:0] vict_age;

	integer si;
	integer j;
	integer p;
	integer q;
	reg [2:0]  rc_b;
	reg [15:0] bag_age [0:3];
	reg [2:0]  bag_idx [0:3];
	reg [15:0] aa;
	reg        inserted;

	always @(posedge clk) begin
		evict_pulse <= 1'b0;
		if (reset) begin
			for (si = 0; si < NUM_SLOTS; si = si + 1) begin
				valid_r[si]  = 1'b0;
				is_ref_r[si] = 1'b0;
				is_cur_r[si] = 1'b0;
				fnum_r[si]   = 16'd0;
				age_r[si]    = 16'd0;
			end
			age_tick_r   = 16'd0;
			cur_r        = 3'd0;
			current_slot <= 3'd0;
			current_base <= slot_phys(0);
			ref_ready    <= 1'b0;
			ref_count    <= 3'd0;
			ref_base0    <= 32'd0;
			ref_base1    <= 32'd0;
			ref_base2    <= 32'd0;
			ref_base3    <= 32'd0;
			alloc_error  <= 1'b0;
		end else if (idr_start) begin
			for (si = 0; si < NUM_SLOTS; si = si + 1) begin
				valid_r[si]  = (si == 0);
				is_ref_r[si] = 1'b0;
				is_cur_r[si] = (si == 0);
				fnum_r[si]   = frame_num;
				age_r[si]    = 16'd0;
			end
			age_tick_r   = 16'd0;
			cur_r        = 3'd0;
			current_slot <= 3'd0;
			current_base <= slot_phys(0);
			alloc_error  <= 1'b0;
			// List0 empty after IDR
			ref_count <= 3'd0;
			ref_base0 <= 32'd0;
			ref_base1 <= 32'd0;
			ref_base2 <= 32'd0;
			ref_base3 <= 32'd0;
			ref_ready <= 1'b0;
		end else if (frame_done) begin
			// Promote current -> short-term ref.
			is_ref_r[cur_r] = 1'b1;
			is_cur_r[cur_r] = 1'b0;
			age_r[cur_r]    = age_tick_r;
			age_tick_r      = age_tick_r + 16'd1;

			found_free = 1'b0;
			free_s = 3'd0;
			for (si = 0; si < NUM_SLOTS; si = si + 1) begin
				if (!found_free && !valid_r[si]) begin
					found_free = 1'b1;
					free_s = 3'(si);
				end
			end

			found_vict = 1'b0;
			vict_s = 3'd0;
			vict_age = 16'hFFFF;
			if (!found_free) begin
				for (si = 0; si < NUM_SLOTS; si = si + 1) begin
					if (valid_r[si] && is_ref_r[si] && !is_cur_r[si]) begin
`ifdef H264_DPB_DDR_FAULT_WRONG_EVICT
						if (!found_vict || age_r[si] >= vict_age) begin
							found_vict = 1'b1;
							vict_s = 3'(si);
							vict_age = age_r[si];
						end
`else
						if (!found_vict || age_r[si] < vict_age) begin
							found_vict = 1'b1;
							vict_s = 3'(si);
							vict_age = age_r[si];
						end
`endif
					end
				end
				if (found_vict) begin
					valid_r[vict_s]  = 1'b0;
					is_ref_r[vict_s] = 1'b0;
					is_cur_r[vict_s] = 1'b0;
					free_s = vict_s;
					found_free = 1'b1;
					evict_pulse <= 1'b1;
				end
			end

			if (found_free) begin
				valid_r[free_s]  = 1'b1;
				is_ref_r[free_s] = 1'b0;
				is_cur_r[free_s] = 1'b1;
				fnum_r[free_s]   = frame_num;
				age_r[free_s]    = 16'd0;
				cur_r            = free_s;
				current_slot    <= free_s;
				current_base    <= slot_phys(free_s);
				alloc_error     <= 1'b0;
			end else begin
				alloc_error <= 1'b1;
			end

			// Rebuild List0: refs sorted by age descending (newest first).
			rc_b = 3'd0;
			for (p = 0; p < 4; p = p + 1) begin
				bag_age[p] = 16'd0;
				bag_idx[p] = 3'd0;
			end
			for (j = 0; j < NUM_SLOTS; j = j + 1) begin
				if (valid_r[j] && is_ref_r[j] && !is_cur_r[j]) begin
					aa = age_r[j];
					inserted = 1'b0;
					for (p = 0; p < 4; p = p + 1) begin
						if (!inserted && ((rc_b <= 3'(p)) || (aa >= bag_age[p]))) begin
							for (q = 3; q > p; q = q - 1) begin
								bag_age[q] = bag_age[q - 1];
								bag_idx[q] = bag_idx[q - 1];
							end
							bag_age[p] = aa;
							bag_idx[p] = 3'(j);
							inserted = 1'b1;
							if (rc_b < 3'd4)
								rc_b = rc_b + 3'd1;
						end
					end
				end
			end
			ref_count <= rc_b;
			ref_base0 <= (rc_b > 3'd0) ? slot_phys(bag_idx[0]) : 32'd0;
			ref_base1 <= (rc_b > 3'd1) ? slot_phys(bag_idx[1]) : 32'd0;
			ref_base2 <= (rc_b > 3'd2) ? slot_phys(bag_idx[2]) : 32'd0;
			ref_base3 <= (rc_b > 3'd3) ? slot_phys(bag_idx[3]) : 32'd0;
			ref_ready <= (rc_b != 3'd0);
		end
	end
endmodule

`default_nettype wire
