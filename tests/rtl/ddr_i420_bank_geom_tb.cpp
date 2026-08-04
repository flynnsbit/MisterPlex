// Pins ddr_i420_bank_geom 480p product + 720p ABI; negative 720p-on-480p-stride.
#include "Vddr_i420_bank_geom_tb_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>

static int fails = 0;
#define CHECK(c, m) do { if (!(c)) { std::fprintf(stderr, "FAIL %s\n", m); ++fails; } } while (0)

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	Vddr_i420_bank_geom_tb_top top;
	top.eval();

	// 480p product
	CHECK(top.p480_frame_bytes == 449280u, "480p I420 bytes");
	CHECK(top.p480_u_off == 299520u, "480p U offset");
	CHECK(top.p480_v_off == 374400u, "480p V offset");
	CHECK(top.p480_doorbell == 0x300FF000u, "480p doorbell");
	CHECK(top.p480_fits, "480p fits 0x80000 stride");
	CHECK(top.p480_doorbell_ok, "480p doorbell derived");
	CHECK(top.p480_banks_ok, "480p banks below doorbell");
	CHECK(top.p480_pillar_ok, "480p pillar 11+618+11=640");
	CHECK(top.p480_chroma_ok, "480p even dims");
	CHECK(top.p480_y_qw == 78, "480p Y line qwords 624/8");
	CHECK(top.p480_c_qw == 39, "480p C line qwords 624/16");

	// 720p w-mem ABI
	CHECK(top.p720_frame_bytes == 1382400u, "720p I420 bytes");
	CHECK(top.p720_u_off == 921600u, "720p U offset 1280*720");
	CHECK(top.p720_v_off == 1152000u, "720p V offset");
	CHECK(top.p720_doorbell == 0x3047F000u, "720p doorbell");
	CHECK(top.p720_fits, "720p fits 0x180000 stride");
	CHECK(top.p720_doorbell_ok, "720p doorbell derived");
	CHECK(top.p720_banks_ok, "720p banks below doorbell");
	CHECK(top.p720_pillar_ok, "720p no pillar");
	CHECK(top.p720_y_qw == 160, "720p Y qwords 1280/8");
	CHECK(top.p720_c_qw == 80, "720p C qwords 1280/16");

	// NEGATIVE: naive wrong impl would set fits=1 when only WxH change
	CHECK(top.neg_720_on_480_frame == 1382400u, "neg still 720p bytes");
	CHECK(!top.neg_720_on_480_fits, "NEGATIVE 720p must NOT fit 480p stride");

	if (fails) {
		std::printf("ddr_i420_bank_geom: %d FAIL(s)\n", fails);
		return 1;
	}
	std::printf("ddr_i420_bank_geom: OK 480p+720p ABI; neg 720-on-480 stride rejected\n");
	return 0;
}
