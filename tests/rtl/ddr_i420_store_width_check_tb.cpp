// Pins store-width elaborator: 720p 3× bank, chroma 640×360, neg undersize.
#include "Vddr_i420_store_width_check_tb_top.h"
#include "verilated.h"
#include <cstdio>

static int fails;
#define CHECK(c, m) do { if (!(c)) { std::fprintf(stderr, "FAIL %s\n", m); ++fails; } } while (0)

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	Vddr_i420_store_width_check_tb_top top;
	top.eval();

	// 480p: chroma half-plane 312×240
	CHECK(top.p480_frame == 449280u, "480p frame");
	CHECK(top.p480_chroma_w == 312, "480p chroma_w");
	CHECK(top.p480_chroma_h == 240, "480p chroma_h");
	CHECK(top.p480_y_qw == 78, "480p y qw");
	CHECK(top.p480_ok, "480p store_widths_ok");
	CHECK(top.p480_dual, "480p dual bank");

	// 720p: 3.0× bank vs 480p; chroma 640×360
	CHECK(top.p720_frame == 1382400u, "720p frame 1382400");
	CHECK(top.p720_u_off == 921600u, "720p U = 1280*720");
	CHECK(top.p720_v_off == 1152000u, "720p V");
	CHECK(top.p720_chroma_w == 640, "720p chroma_w 640 (was 312@480p)");
	CHECK(top.p720_chroma_h == 360, "720p chroma_h 360 (was 240@480p)");
	CHECK(top.p720_y_qw == 160, "720p y_line_qwords");
	CHECK(top.p720_c_qw == 80, "720p c_line_qwords");
	CHECK(top.p720_y_w_bits == 10, "clog2(720)=10");
	CHECK(top.p720_y_qw_aw == 8, "clog2(160)=8");
	CHECK(top.p720_ok, "720p store_widths_ok");
	CHECK(top.p720_dual, "720p dual bank still fits window");
	CHECK(top.p720_triple, "720p Option-C triple fits window");
	CHECK(top.p720_stride_ge_3x, "stride 0x180000 == 3*0x80000");
	CHECK(top.p720_frame_ge_3x, "frame >= 3*449280");
	CHECK(top.p720_doorbell == 0x3047F000u, "720p doorbell");
	// max y line qword off = 719*160 = 115040
	CHECK(top.p720_max_y_line_qw == 115040u, "max y line qword offset");
	// banks in [0x30180000, 0x40000000) / 0x180000 = 169
	CHECK(top.p720_banks_win == 169, "banks_in_reserved_window");

	// NEGATIVE: naive undersized containers must NOT claim OK at 720p
	CHECK(!top.neg_u16_frame_ok, "NEG: uint16 cannot hold 1382400");
	CHECK(!top.neg_u16_y_ok, "NEG: uint16 cannot hold Y plane 921600");
	CHECK(!top.neg_u7_yqw_ok, "NEG: 7-bit cannot hold y_line_qwords=160");
	CHECK(!top.neg_ref480_fits, "NEG: 720p frame must not fit 480p stride");

	// Document Plex.sv ladder vs ABI (0x200000 - 0x180000 = 0x80000)
	CHECK(top.neg_ladder_stride_vs_abi == 0x80000u, "ladder 0x200000 vs ABI 0x180000");

	if (fails) {
		std::printf("ddr_i420_store_width_check: %d FAIL\n", fails);
		return 1;
	}
	std::printf(
		"ddr_i420_store_width_check: OK 720p widths+chroma640x360; "
		"dual/triple banks; neg u16/u7/480p-stride; banks_win=169\n");
	return 0;
}
