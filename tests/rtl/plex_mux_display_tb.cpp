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
	return 0;
}
