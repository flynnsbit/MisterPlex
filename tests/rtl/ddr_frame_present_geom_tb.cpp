// Boundary coverage for ddr_frame_present_geom (480p product + 720p L4 + 240p).
// Negative cases: naive hardcode leaving 618x480 window on a 720p FRAME fails.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>
#include "Vddr_frame_present_geom_tb_top.h"
#include "verilated.h"

static int g_fails = 0;

static void expect(const char *name, bool ok) {
	if (!ok) {
		std::printf("FAIL %s\n", name);
		g_fails++;
	}
}

static void set_xy(Vddr_frame_present_geom_tb_top *top, unsigned x, unsigned y) {
	top->rd_x = x;
	top->rd_y = y;
	top->eval();
}

static uint8_t parse_fault(int argc, char **argv, std::string& fault_name) {
	fault_name = "none";
	for (int i = 1; i < argc; ++i) {
		const std::string arg = argv[i];
		if (arg.rfind("--fault=", 0) != 0)
			continue;
		fault_name = arg.substr(8);
		if (fault_name == "coded640") return 1;
		if (fault_name == "pillar10") return 2;
		if (fault_name == "pillar12") return 3;
		if (fault_name == "lost-row479") return 4;
		if (fault_name == "even-rows") return 5;
		if (fault_name == "ddr-drift") return 6;
		std::fprintf(stderr, "unknown fault mode: %s\n", fault_name.c_str());
		std::exit(2);
	}
	return 0;
}

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	auto *top = new Vddr_frame_present_geom_tb_top;
	std::string fault_name;
	top->fault_mode = parse_fault(argc, argv, fault_name);
	std::printf("GEOM_FAULT_MODE=%s\n", fault_name.c_str());

	// ---- Static ends / strides (no xy) ----
	set_xy(top, 0, 0);
	expect("480_present_end_x_629", top->pe480_x == 629); // 11+618
	expect("480_present_end_y_480", top->pe480_y == 480);
	expect("480_y_line_qwords_78", top->yq480 == 78);     // 624/8
	expect("480_c_line_qwords_39", top->cq480 == 39);     // 624/16
	expect("480_y_plane_offset_0", top->yoff480 == 0);
	expect("480_u_plane_offset_299520", top->uoff480 == 299520u);
	expect("480_v_plane_offset_374400", top->voff480 == 374400u);
	expect("480_y_stride_624", top->ys480 == 624);
	expect("480_chroma_stride_312", top->cs480 == 312);
	expect("480_frame_bytes", top->f480 == 449280);
	expect("480_bank0", top->b480_0 == 0x30000000u);
	expect("480_bank1", top->b480_1 == 0x30080000u);      // +0x80000
	expect("480_bank0_end", top->b480_end == 0x30000000u + 449280u);
	expect("480_doorbell", top->d480 == 0x300FF000u);
	expect("480_u_follows_y", top->uoff480 == top->ys480 * 480u);
	expect("480_v_follows_u",
	       top->voff480 == top->uoff480 + top->cs480 * 240u);
	expect("480_frame_ends_after_v",
	       top->f480 == top->voff480 + top->cs480 * 240u);
	expect("480_map_ends_after_doorbell_page",
	       top->d480 + 0x1000u == top->b480_0 + 2u * 0x80000u);
	// bank boundary ±1 relative to frame payload end
	const uint32_t b0_last = top->b480_end - 1;
	const uint32_t b0_overflow = top->b480_end;
	expect("480_bank_last_lt_bank1", b0_last < top->b480_1);
	expect("480_bank_end_le_bank1", b0_overflow <= top->b480_1);

	expect("720_present_end_x_1280", top->pe720_x == 1280);
	expect("720_present_end_y_720", top->pe720_y == 720);
	expect("720_y_line_qwords_160", top->yq720 == 160);   // 1280/8
	expect("720_c_line_qwords_80", top->cq720 == 80);     // 1280/16
	expect("720_frame_bytes_1382400", top->f720 == 1382400u);
	expect("720_bank0", top->b720_0 == 0x30180000u);
	expect("720_bank1", top->b720_1 == 0x30180000u + 0x00180000u);
	expect("720_bank0_end", top->b720_end == 0x30180000u + 1382400u);
	expect("720_doorbell", top->d720 == 0x3047F000u);
	expect("720_bank_last_lt_bank1", (top->b720_end - 1) < top->b720_1);
	expect("720_bank_end_le_bank1", top->b720_end <= top->b720_1);
	// exact bank boundary ±1 on stride (not just frame_bytes)
	const uint32_t stride_end = top->b720_0 + 0x00180000u;
	expect("720_stride_end_eq_bank1", stride_end == top->b720_1);
	expect("720_frame_lt_stride", top->f720 < 0x00180000u);
	expect("720_frame_plus1_still_in_bank",
	       (top->b720_0 + top->f720) < top->b720_1); // end == base+frame; last byte in bank
	expect("720_byte_frame_minus1_in",
	       (0x30180000u + 1382400u - 1u) < top->b720_1);
	expect("720_byte_at_frame_end_is_bank_boundary_ok",
	       (0x30180000u + 1382400u) <= top->b720_1);
	// first byte of bank1 is bank boundary
	expect("720_bank1_is_boundary", top->b720_1 == 0x30300000u);

	expect("240_present_end_320x240", top->pe240_x == 320 && top->pe240_y == 240);
	expect("240_frame_bytes", top->f240 == 320u * 240u * 3u / 2u);

	// ---- Every 640x480 presented coordinate ----
	uint64_t coord_mismatches = 0;
	uint64_t row_mismatches = 0;
	uint64_t visible_count = 0;
	uint64_t border_count = 0;
	bool first_mismatch_printed = false;
	std::vector<unsigned> source_row_hits(480, 0);
	for (unsigned y = 0; y < 480; ++y) {
		for (unsigned x = 0; x < 640; ++x) {
			set_xy(top, x, y);
			const bool want_visible = x >= 11 && x < 629;
			const unsigned want_x = want_visible ? x - 11 : 0;
			const unsigned want_y = want_visible ? y : 0;
			const bool got_visible = top->v480 != 0;
			const bool mismatch =
				got_visible != want_visible ||
				(want_visible && (top->s480_x != want_x || top->s480_y != want_y)) ||
				(!want_visible && (top->s480_x != 0 || top->s480_y != 0));
			if (mismatch) {
				++coord_mismatches;
				if (!first_mismatch_printed) {
					std::fprintf(stderr,
						"FAIL 480 first coordinate mismatch x=%u y=%u "
						"got visible=%u src=%u,%u want visible=%u src=%u,%u\n",
						x, y, unsigned(top->v480), unsigned(top->s480_x),
						unsigned(top->s480_y), unsigned(want_visible), want_x, want_y);
					first_mismatch_printed = true;
				}
			}
			if (got_visible) {
				++visible_count;
				if (top->s480_y < source_row_hits.size())
					++source_row_hits[top->s480_y];
				if (top->s480_y != y)
					++row_mismatches;
			} else {
				++border_count;
			}
		}
	}
	expect("480_all_640x480_coordinates", coord_mismatches == 0);
	expect("480_visible_count_618x480", visible_count == 618u * 480u);
	expect("480_border_count_22x480", border_count == 22u * 480u);
	expect("480_rows_0_through_479_identity", row_mismatches == 0);
	bool every_row_exact = true;
	for (unsigned y = 0; y < source_row_hits.size(); ++y) {
		if (source_row_hits[y] != 618u) {
			every_row_exact = false;
			if (!first_mismatch_printed) {
				std::fprintf(stderr, "FAIL source row %u hit %u times, want 618\n",
					y, source_row_hits[y]);
				first_mismatch_printed = true;
			}
		}
	}
	expect("480_each_source_row_used_exactly_618_times", every_row_exact);

	// ---- 480p visibility boundaries (pillar 11, display 618 → x in [11,629)) ----
	set_xy(top, 10, 0);
	expect("480_x10_outside_left", top->v480 == 0);
	set_xy(top, 11, 0);
	expect("480_x11_inside", top->v480 == 1);
	expect("480_x11_src0", top->s480_x == 0);
	set_xy(top, 628, 0);
	expect("480_x628_inside_last", top->v480 == 1);
	expect("480_x628_src617", top->s480_x == 617);
	set_xy(top, 629, 0);
	expect("480_x629_outside_right", top->v480 == 0);
	set_xy(top, 11, 479);
	expect("480_y479_inside", top->v480 == 1);
	expect("480_y479_identity", top->s480_y == 479);
	set_xy(top, 628, 479);
	expect("480_last_presented_content_pixel", top->v480 == 1 &&
	       top->s480_x == 617 && top->s480_y == 479);
	set_xy(top, 11, 480);
	expect("480_y480_outside", top->v480 == 0);

	// ---- 720p full-frame visibility ----
	set_xy(top, 0, 0);
	expect("720_0_0_inside", top->v720 == 1);
	expect("720_0_0_src", top->s720_x == 0 && top->s720_y == 0);
	set_xy(top, 1279, 719);
	expect("720_1279_719_inside", top->v720 == 1);
	expect("720_1279_719_src", top->s720_x == 1279 && top->s720_y == 719);
	set_xy(top, 1280, 719);
	// rd_x is 11 bits; 1280 fits. Visibility must be outside.
	expect("720_1280_outside", top->v720 == 0);
	set_xy(top, 1279, 720);
	expect("720_y720_outside", top->v720 == 0);

	// NEGATIVE: if L4 still used 480p window, x=1279 would be outside (629 end).
	// We require 720p INSIDE at 1279 — a leftover 618-wide window fails here.
	set_xy(top, 1279, 100);
	expect("720_NEG_not_618_window", top->v720 == 1);
	set_xy(top, 700, 500);
	expect("720_NEG_y500_not_480_clip", top->v720 == 1);

	// 480p must NOT suddenly open to 1280 (regression guard)
	set_xy(top, 700, 100);
	expect("480_x700_still_outside", top->v480 == 0);
	set_xy(top, 100, 500);
	expect("480_y500_still_outside", top->v480 == 0);

	// 240p corners
	set_xy(top, 319, 239);
	expect("240_last_inside", top->v240 == 1);
	set_xy(top, 320, 239);
	expect("240_x320_outside", top->v240 == 0);
	set_xy(top, 319, 240);
	expect("240_y240_outside", top->v240 == 0);

	if (g_fails) {
		std::printf("ddr_frame_present_geom_tb FAIL count=%d\n", g_fails);
		delete top;
		return 1;
	}
	std::printf("PASS ddr_frame_present_geom_tb "
	            "480_coords=307200 rows=0..479 identity 480p_end=629x480 "
	            "Y/U/V=0/299520/374400 strides=624/312 "
	            "720p_end=1280x720 720p_1279_719_inside bank720_stride=0x180000\n");
	delete top;
	return 0;
}
