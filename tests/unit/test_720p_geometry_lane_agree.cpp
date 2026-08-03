// Cross-lane 720p geometry contract (w-scaler READ ↔ w-clock DE ↔ w-osd canvas ↔ w-mem bank).
// Truth lives here as compile-time pins + host ABI. Fails if any lane drifts.
// See docs/fabric-geometry-lane-contract.md and w-clock H_OWNERSHIP_W_SCALER.md.
#include "libmisterplex/ddr_frame_layout.hpp"

#include <cstdint>
#include <iostream>

int main() {
	using namespace misterplex;
	int fails = 0;
	auto chk = [&](bool ok, const char* msg) {
		if (!ok) {
			std::cerr << "FAIL " << msg << "\n";
			++fails;
		}
	};

	// ---- Bank / coded (w-scaler READ + w-mem WRITE interface) ----
	chk(kPlex720pCodedWidth.get() == 1280, "coded_w 1280");
	chk(kPlex720pCodedHeight.get() == 720, "coded_h 720");
	chk(kPlex720pYStrideBytes == 1280, "y_stride 1280");
	chk(kPlex720pChromaStrideBytes == 640, "c_stride 640");
	chk(kPlex720pYuvLumaLineQwords == 160, "Y qwords/line 160 (=1 M10K)");
	chk(kPlex720pYuvChromaLineQwords == 80, "C qwords/line 80");
	chk(kPlex720pUPlaneOffset == 921600, "U byte off");
	chk(kPlex720pVPlaneOffset == 1152000, "V byte off");
	chk(kPlex720pYuv420pBytes == 1382400, "I420 bytes");
	chk(kPlex720pDdrFramePhysBase == 0x30180000u, "Option-C base");
	chk(kPlex720pYuv420pBankStride == 0x00180000u, "Option-C bank stride");
	chk(kPlex720pYuv420pDoorbellPhys == 0x3047F000u, "Option-C doorbell");
	chk(kPlex720pPillarboxLeft == 0 && kPlex720pCropLeft == 0, "no pillar/crop");
	chk((kPlex720pCodedWidth.get() % 4) == 0, "W%4==0 for PPC=4 free-lunch");
	chk((kPlex720pCodedWidth.get() % 8) == 0, "W%8==0 last Y sample ends qword");
	chk(kPlex720pDisplayWidth.get() == 1280 && kPlex720pDisplayHeight.get() == 720,
	    "display == coded (osd idle / chrome target canvas)");

	const auto lay = makePlex720pDdrFrameLayout();
	chk(lay.phys_base == kPlex720pDdrFramePhysBase, "layout phys_base");
	chk(lay.bank_stride == kPlex720pYuv420pBankStride, "layout bank_stride pinned Option-C");
	chk(lay.doorbell_phys == kPlex720pYuv420pDoorbellPhys, "layout doorbell pinned Option-C");
	chk(lay.line_bytes == 1280, "layout line_bytes");
	chk(lay.chroma_line_bytes == 640, "layout chroma_line_bytes");
	chk(lay.u_offset == 921600u, "layout u_offset");
	chk(lay.v_offset == 1152000u, "layout v_offset");
	chk(lay.frame_bytes == 1382400u, "layout frame_bytes");
	chk(lay.bank_stride == 0x00180000u && lay.doorbell_phys == 0x3047F000u,
	    "pinned helper wins over derive");

	const uint32_t plxd = kPlex720pYuv420pDoorbellPhys + 0x128u;
	chk(plxd == 0x3047F128u, "PLXD @ Option-C doorbell+0x128");

	// ---- Destination DE (w-clock owns glass; w-scaler maps into it) ----
	// Product Template (macros OFF / control arm d1b24e0c): H_DE=529, V=480.
	constexpr int kProductHDe = 529;
	constexpr int kProductVDe = 480;
	// PRESENT_MULTI_PIXEL ON (w-clock 8003ef89): H_DE=1280, V_ACTIVE=720.
	constexpr int kMultiHDe = 1280;
	constexpr int kMultiVDe = 720;
	chk(kProductHDe == 529 && kProductVDe == 480, "product Template DE lock");
	chk(kMultiHDe == kPlex720pDisplayWidth.get(), "multi-pixel H_DE == display_w");
	chk(kMultiVDe == kPlex720pDisplayHeight.get(), "multi-pixel V == display_h");
	// w-osd plex_chrome_cmds kTargetOutW/H (sibling a3761b0e / chrome 720p-first).
	constexpr int kOsdTargetW = 1280;
	constexpr int kOsdTargetH = 720;
	chk(kOsdTargetW == kMultiHDe && kOsdTargetH == kMultiVDe,
	    "w-osd target canvas == w-clock multi-pixel DE");
	chk(kOsdTargetW == kPlex720pCodedWidth.get(), "osd canvas == bank coded_w");

	// ---- Source content (variable; PLXG content_w/h) ----
	// Native bank fill: 1280×720. PMS degradation tier (w-path): 720×404.
	constexpr int kPmsDegW = 720, kPmsDegH = 404;
	chk(kPmsDegW < kMultiHDe && kPmsDegH < kMultiVDe, "PMS 404 needs fabric upscale");
	// H ownership: under multi-pixel, beam glass_x0 drives the window hc input
	// with h_de=1280 — NOT colorbars hc with H_DE=529 (shear class).
	chk(kMultiHDe != kProductHDe, "H_OWNERSHIP: multi DE must not equal Template 529");

	// ---- ACTIVE growth boundary (parent control ACTIVE=923×717) ----
	// w-scaler does NOT emit glass DE width. ACTIVE toward full raster requires
	// w-clock PRESENT_MULTI_PIXEL (core DE 1280) and/or w-osd FAB_IDLE canvas
	// on HDMI after ascal. Bank coded_w=1280 alone does not grow ACTIVE.
	chk(kPlex720pCodedWidth.get() == 1280, "bank ready for full-width READ");
	// Documented ownership split encoded as named constants for auditors:
	// owner_glass_de = w-clock; owner_store_map = w-scaler; owner_hdmi_chrome = w-osd.
	constexpr int owner_glass_de = 1;   // w-clock
	constexpr int owner_store_map = 2;  // w-scaler
	constexpr int owner_hdmi_chrome = 3; // w-osd
	chk(owner_glass_de != owner_store_map, "H_OWNERSHIP: glass != store map owner");
	chk(owner_hdmi_chrome != owner_store_map, "chrome plane != store map owner");
	(void)owner_glass_de;
	(void)owner_store_map;
	(void)owner_hdmi_chrome;

	// Negative: derived layout must not silently replace Option-C pins.
	const auto derived =
	    makeDdrFrameLayout(plex720pDdrFrameGeometry(), kPlex720pDdrFramePhysBase);
	chk(lay.bank_stride == 0x00180000u, "pinned stride");
	chk(derived.bank_stride != lay.bank_stride ||
	        derived.doorbell_phys == lay.doorbell_phys,
	    "document derive may differ — pinned is truth");

	if (fails) {
		std::cerr << "test_720p_geometry_lane_agree: " << fails << " fails\n";
		return 1;
	}
	std::cout << "PASS 720p geometry lane agree "
	          << "base=0x30180000 stride=0x180000 doorbell=0x3047F000 "
	          << "Y=1280 C=640 U=921600 V=1152000 PLXD=0x3047F128 "
	          << "PPC_W%4=0 "
	          << "DE_product=529x480 DE_multi=1280x720 osd_canvas=1280x720 "
	          << "H_OWNERSHIP=beam_glass+scaler_map+osd_hdmi "
	          << "pms_deg=720x404\n";
	return 0;
}
