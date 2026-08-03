// Dual-geometry present path self-check (Verilator).
// POS: Template keeps H_DE=529 / bank 512KiB; L4 gets 1280×720 / 1312×762 / 1.5MiB.
// NEG: fault twin with H_DE=529 under MODE=1 must be detected (is_529=1, native=0).
#include "Vpresent_geom_dual_tb_top.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>

static int g_fails = 0;

static void expect_eq(const char* name, uint32_t got, uint32_t want) {
	if (got != want) {
		std::fprintf(stderr, "FAIL %s: got=%u (0x%x) want=%u (0x%x)\n",
			name, got, got, want, want);
		g_fails++;
	} else {
		std::printf("OK   %s=%u (0x%x)\n", name, got, got);
	}
}

static void expect_true(const char* name, bool cond) {
	if (!cond) {
		std::fprintf(stderr, "FAIL %s\n", name);
		g_fails++;
	} else {
		std::printf("OK   %s\n", name);
	}
}

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	Vpresent_geom_dual_tb_top* top = new Vpresent_geom_dual_tb_top;

	// Combinational — one eval is enough.
	top->eval();

	// ---- Template 640×480 (product default) ----
	expect_eq("tpl_h_de", top->tpl_h_de, 529);
	expect_eq("tpl_v_store", top->tpl_v, 240);
	expect_eq("tpl_store_w", top->tpl_store_w, 640);
	expect_eq("tpl_store_h", top->tpl_store_h, 480);
	expect_eq("tpl_bank", top->tpl_bank, 0x00080000u);
	expect_true("tpl_is_529", top->tpl_is_529 != 0);

	// ---- L4 1280×720 ----
	expect_eq("l4_h_de", top->l4_h_de, 1280);
	expect_eq("l4_v_act", top->l4_v, 720);
	expect_eq("l4_h_total", top->l4_h_total, 1312);
	expect_eq("l4_v_total", top->l4_v_total, 762);
	expect_eq("l4_store_w", top->l4_store_w, 1280);
	expect_eq("l4_store_h", top->l4_store_h, 720);
	expect_eq("l4_bank", top->l4_bank, 0x00180000u);
	// NEGATIVE (primary): L4 must NOT produce Template H_DE=529
	expect_true("l4_h_de_not_529", top->l4_h_de != 529);
	expect_true("l4_is_529_must_be_0", top->l4_is_529 == 0);
	expect_true("l4_native_de", top->l4_native_de != 0);

	// ---- Fault twin proves the NEGATIVE case is not tautological ----
	// A naive wrong L4 that keeps H_DE=529 trips is_529 and clears native_de.
	expect_eq("bad_h_de_is_529", top->bad_h_de, 529);
	expect_true("bad_is_529_detects_hardcode", top->bad_is_529 != 0);
	expect_true("bad_native_de_cleared", top->bad_native_de == 0);

	delete top;
	if (g_fails != 0) {
		std::fprintf(stderr, "present_geom_dual_tb: %d FAIL(s)\n", g_fails);
		return 1;
	}
	std::printf("present_geom_dual_tb: PASS\n");
	return 0;
}
