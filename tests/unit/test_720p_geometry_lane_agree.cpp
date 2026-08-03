// Cross-lane 720p geometry pin (w-scaler READ ↔ w-mem Option-C ↔ w-clock PPC).
// Fails if host/RTL ABI drifts from the bank contract the integration fit uses.
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
	chk(kPlex720pDisplayWidth.get() == 1280 && kPlex720pDisplayHeight.get() == 720,
	    "display == coded (osd idle canvas)");

	const auto lay = makePlex720pDdrFrameLayout();
	chk(lay.phys_base == kPlex720pDdrFramePhysBase, "layout phys_base");
	chk(lay.bank_stride == kPlex720pYuv420pBankStride, "layout bank_stride pinned Option-C");
	chk(lay.doorbell_phys == kPlex720pYuv420pDoorbellPhys, "layout doorbell pinned Option-C");
	chk(lay.line_bytes == 1280, "layout line_bytes");
	chk(lay.chroma_line_bytes == 640, "layout chroma_line_bytes");
	chk(lay.u_offset == 921600u, "layout u_offset");
	chk(lay.v_offset == 1152000u, "layout v_offset");
	chk(lay.frame_bytes == 1382400u, "layout frame_bytes");
	// Derived doorbell must NOT silently replace Option-C (regression class).
	chk(lay.doorbell_phys != lay.phys_base + lay.bank_stride * 2u - 0x1000u ||
	        lay.bank_stride == kPlex720pYuv420pBankStride,
	    "Option-C stride/doorbell pair");

	const uint32_t plxd = kPlex720pYuv420pDoorbellPhys + 0x128u;
	chk(plxd == 0x3047F128u, "PLXD @ Option-C doorbell+0x128");

	// Negative: if someone reverts makePlex720p to pure derive, bank_stride shrinks.
	const auto derived =
	    makeDdrFrameLayout(plex720pDdrFrameGeometry(), kPlex720pDdrFramePhysBase);
	chk(derived.bank_stride != kPlex720pYuv420pBankStride ||
	        derived.doorbell_phys == kPlex720pYuv420pDoorbellPhys,
	    "document: derived layout may differ — pinned helper is source of truth");
	chk(lay.bank_stride == 0x00180000u && lay.doorbell_phys == 0x3047F000u,
	    "pinned helper wins over derive");

	if (fails) {
		std::cerr << "test_720p_geometry_lane_agree: " << fails << " fails\n";
		return 1;
	}
	std::cout << "PASS 720p geometry lane agree "
	          << "base=0x30180000 stride=0x180000 doorbell=0x3047F000 "
	          << "Y=1280 C=640 U=921600 V=1152000 PLXD=0x3047F128 "
	          << "PPC_W%4=0\n";
	return 0;
}
