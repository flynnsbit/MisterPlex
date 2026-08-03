// 624 coded / 618 display / crop_left=3 PLXG q3 must survive mux.
#include "Vplex_mux_display_tb.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <iostream>

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	Vplex_mux_display_tb top{};

	// Product silicon contract (ddr_frame_layout / plxg_record makeLegacy480p*).
	constexpr int kCodedW = 624;
	constexpr int kCodedH = 480;
	constexpr int kDispW = 618;
	constexpr int kDispH = 480;
	constexpr int kCropL = 3;
	constexpr int kCropT = 0;

	top.plxg_live = 1;
	top.plxg_geom = 1;
	top.plxg_cw = kCodedW; // content-bearing
	top.plxg_ch = kCodedH;
	top.plxg_coded_w = kCodedW;
	top.plxg_coded_h = kCodedH;
	top.plxg_y_stride = kCodedW;
	top.plxg_c_stride = kCodedW / 2;
	top.plxg_dw = kDispW;
	top.plxg_dh = kDispH;
	top.plxg_cl = kCropL;
	top.plxg_ct = kCropT;
	top.eval();

	std::cout << "MEASURED mux624/618 coded=" << (int)top.obs_coded_w
	          << " disp=" << (int)top.obs_display_w
	          << " crop_l=" << (int)top.obs_crop_l
	          << " window_ok=" << (int)top.obs_window_ok
	          << " geom_en=" << (int)top.obs_geom_en << "\n";

	if ((int)top.obs_coded_w != kCodedW) {
		std::cerr << "FAIL coded_w expected " << kCodedW << " got "
		          << (int)top.obs_coded_w << "\n";
		return 1;
	}
	if ((int)top.obs_crop_l != kCropL) {
		std::cerr << "FAIL crop_left expected " << kCropL << " got "
		          << (int)top.obs_crop_l << "\n";
		return 1;
	}
	if ((int)top.obs_display_w != kDispW) {
		std::cerr << "FAIL display_w expected " << kDispW
		          << " (q3 live) got " << (int)top.obs_display_w
		          << " — coded alias drops PLXG display\n";
		return 1;
	}
	if ((int)top.obs_display_h != kDispH) {
		std::cerr << "FAIL display_h expected " << kDispH << " got "
		          << (int)top.obs_display_h << "\n";
		return 1;
	}
	if (!top.obs_window_ok) {
		std::cerr << "FAIL crop+display must be <= coded (3+618<=624)\n";
		return 1;
	}
	// Boundary: +1 display must fail window_ok (oracle negative).
	top.plxg_dw = kDispW + 1; // 619 → 3+619=622 still OK; use 622 for fail
	top.plxg_dw = 622; // 3+622=625 > 624
	top.eval();
	if (top.obs_window_ok) {
		std::cerr << "FAIL negative: crop3+disp622 must exceed coded624\n";
		return 1;
	}
	std::cout << "MEASURED mux_oversize disp=622 window_ok=0\n";

	// Exact edge: crop3+disp621=624 pass
	top.plxg_dw = 621;
	top.eval();
	if (!top.obs_window_ok || (int)top.obs_display_w != 621) {
		std::cerr << "FAIL edge: crop3+disp621 must pass got disp="
		          << (int)top.obs_display_w
		          << " ok=" << (int)top.obs_window_ok << "\n";
		return 1;
	}
	std::cout << "OK plex_mux_display 624/618 + crop bounds oracle\n";

	// ---- B14 pad 432 coded / 426 display / crop_left=2 (rd-duck + w-mem) ----
	// Equal-geometry tests are blind to q3; this is the second coded!=display
	// class (Direct-Part library items). display must stay 426, not alias 432.
	constexpr int kPadCoded = 432;
	constexpr int kPadDisp = 426;
	constexpr int kPadCropL = 2;
	constexpr int kPadCropR = 4; // informational; mux sees left only
	(void)kPadCropR;
	top.plxg_live = 1;
	top.plxg_geom = 1;
	top.plxg_cw = kPadDisp; // content DE tracks delivered
	top.plxg_ch = 240;
	top.plxg_coded_w = kPadCoded;
	top.plxg_coded_h = 240;
	top.plxg_y_stride = kPadCoded;
	top.plxg_c_stride = kPadCoded / 2;
	top.plxg_dw = kPadDisp;
	top.plxg_dh = 240;
	top.plxg_cl = kPadCropL;
	top.plxg_ct = 0;
	top.eval();
	std::cout << "MEASURED mux432/426 coded=" << (int)top.obs_coded_w
	          << " disp=" << (int)top.obs_display_w
	          << " crop_l=" << (int)top.obs_crop_l
	          << " window_ok=" << (int)top.obs_window_ok << "\n";
	if ((int)top.obs_coded_w != kPadCoded) {
		std::cerr << "FAIL 426: coded_w expected " << kPadCoded << " got "
		          << (int)top.obs_coded_w << "\n";
		return 1;
	}
	if ((int)top.obs_display_w != kPadDisp) {
		std::cerr << "FAIL 426: display_w expected " << kPadDisp
		          << " (q3 B14) got " << (int)top.obs_display_w
		          << " — coded alias squeezes pad as content\n";
		return 1;
	}
	if ((int)top.obs_crop_l != kPadCropL) {
		std::cerr << "FAIL 426: crop_left expected " << kPadCropL << " got "
		          << (int)top.obs_crop_l << "\n";
		return 1;
	}
	if (!top.obs_window_ok) {
		std::cerr << "FAIL 426: crop2+display426 must be <= coded432\n";
		return 1;
	}
	// Negative: display=coded 432 with crop2 → 434 > 432 (would pass if
	// display were ignored; here we force dw=431 edge then oversize).
	top.plxg_dw = 431; // 2+431=433 > 432
	top.eval();
	if (top.obs_window_ok) {
		std::cerr << "FAIL 426 neg: crop2+disp431 must exceed coded432\n";
		return 1;
	}
	// Idle fallback: !live → display tracks idle coded (960 under PRESENT_BEAM
	// not set here → ladder/force leave coded from last? Without live, content
	// false → display := coded path. Drive live=0, coded stays 432 → disp 432.
	top.plxg_live = 0;
	top.plxg_dw = kPadDisp; // must be ignored when !plxg_content
	top.eval();
	if ((int)top.obs_display_w != (int)top.obs_coded_w) {
		std::cerr << "FAIL idle: display must fallback to coded when !content got "
		          << (int)top.obs_display_w << " coded=" << (int)top.obs_coded_w
		          << "\n";
		return 1;
	}
	std::cout << "MEASURED mux_idle display=coded=" << (int)top.obs_display_w << "\n";
	std::cout << "OK plex_mux_display 432/426 B14 pad + idle fallback\n";
	return 0;
}
