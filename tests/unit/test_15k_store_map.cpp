// 15 kHz bob/weave store map. L8: compile -DP15K_STORE_MAP_WRONG for identity-x / y=vc.
#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/present_15k_store_map.hpp"

#include <cstdio>
#include <fstream>
#include <sstream>
#include <string>

static int fails = 0;
#define CHECK(cond)                                                                              \
    do {                                                                                         \
        if (!(cond)) {                                                                           \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                 \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

static std::string repoFile(const char* rel) {
    const std::string here = __FILE__;
    const auto pos = here.rfind("tests/unit/test_15k_store_map.cpp");
    if (pos == std::string::npos)
        return rel;
    return here.substr(0, pos) + rel;
}

static std::string slurp(const std::string& path) {
    std::ifstream in(path.c_str());
    CHECK(in.good());
    std::ostringstream ss;
    ss << in.rdbuf();
    return ss.str();
}

int main() {
    using namespace misterplex::p15k;
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    std::setvbuf(stderr, nullptr, _IONBF, 0);

    const auto bob00 = map15kStore(0, 0, false, false);
    const auto bobHi = map15kStore(319, 239, false, false);
    const auto we00 = map15kStore(0, 0, false, true);
    const auto weHi = map15kStore(639, 239, false, true);
    const auto wo00 = map15kStore(0, 0, true, true);
    const auto woHi = map15kStore(639, 239, true, true);

    std::printf("bob (0,0)->(%d,%d) (319,239)->(%d,%d)\n", bob00.x, bob00.y, bobHi.x, bobHi.y);
    std::printf("weave even (0,0)->(%d,%d) (639,239)->(%d,%d)\n", we00.x, we00.y, weHi.x, weHi.y);
    std::printf("weave odd (0,0)->(%d,%d) (639,239)->(%d,%d)\n", wo00.x, wo00.y, woHi.x, woHi.y);
    std::printf("phys=0x%08X doorbell=0x%08X store=%dx%d new_doorbell=%d\n", kPhysBase,
                kDoorbellPhys, kStoreW, kStoreH, kNewDoorbell ? 1 : 0);

    CHECK(bob00.x == 0 && bob00.y == 0);
    CHECK(bobHi.x == 638 && bobHi.y == 478);
    CHECK(we00.x == 0 && we00.y == 0);
    CHECK(weHi.x == 639 && weHi.y == 478);
    CHECK(wo00.x == 0 && wo00.y == 1);
    CHECK(woHi.x == 639 && woHi.y == 479);

    // field_odd must not move bob (DROP even rows/cols).
    CHECK(map15kStore(17, 9, true, false).x == 34);
    CHECK(map15kStore(17, 9, true, false).y == 18);

    // Mid-range weave: even y=2*vc, odd y=2*vc+1, x=hc.
    CHECK(map15kStore(11, 1, false, true).x == 11);
    CHECK(map15kStore(11, 1, false, true).y == 2);
    CHECK(map15kStore(11, 1, true, true).x == 11);
    CHECK(map15kStore(11, 1, true, true).y == 3);

    // Clamp past 640/480 (and past H_DE).
    CHECK(map15kStore(320, 240, false, false).x == 639);
    CHECK(map15kStore(320, 240, false, false).y == 479);
    CHECK(map15kStore(640, 240, false, true).x == 639);
    CHECK(map15kStore(640, 240, false, true).y == 479);
    CHECK(map15kStore(640, 240, true, true).x == 639);
    CHECK(map15kStore(640, 240, true, true).y == 479);
    CHECK(map15kStore(700, 300, false, true).x == 639);
    CHECK(map15kStore(700, 300, true, true).y == 479);
    CHECK(map15kStore(-1, -1, false, false).x == 0);
    CHECK(map15kStore(-1, -1, false, false).y == 0);

    int bobSweepFails = 0;
    int weaveSweepFails = 0;
    for (int vc = 0; vc < 240; ++vc) {
        for (int hc = 0; hc < 320; ++hc) {
            const auto p = map15kStore(hc, vc, false, false);
            if (p.x != (hc << 1) || p.y != (vc << 1) || (p.x & 1) || (p.y & 1)) {
                if (bobSweepFails < 4)
                    std::fprintf(stderr, "FAIL bob hc=%d vc=%d -> (%d,%d)\n", hc, vc, p.x, p.y);
                ++bobSweepFails;
            }
        }
    }
    for (int vc = 0; vc < 240; ++vc) {
        for (int hc = 0; hc < 640; ++hc) {
            const auto ev = map15kStore(hc, vc, false, true);
            const auto od = map15kStore(hc, vc, true, true);
            if (ev.x != hc || ev.y != (vc << 1) || od.x != hc || od.y != ((vc << 1) | 1)) {
                if (weaveSweepFails < 4)
                    std::fprintf(stderr, "FAIL weave hc=%d vc=%d even=(%d,%d) odd=(%d,%d)\n", hc,
                                 vc, ev.x, ev.y, od.x, od.y);
                ++weaveSweepFails;
            }
        }
    }
    fails += bobSweepFails + weaveSweepFails;
    if (bobSweepFails || weaveSweepFails)
        std::fprintf(stderr, "FAIL sweep bob=%d weave=%d\n", bobSweepFails, weaveSweepFails);

    // Same true480 bank. 320×240 doorbell 0x3007F000 must not appear.
    CHECK(kPhysBase == 0x30000000u);
    CHECK(kDoorbellPhys == 0x300FF000u);
    CHECK(kDoorbellPhys != 0x3007F000u);
    CHECK(kDoorbellPhys != kLegacy320x240DoorbellPhys);
    CHECK(kPhysBase == misterplex::kDdrFramePhysBase);
    CHECK(kDoorbellPhys == misterplex::kPlex480pYuv420pDoorbellPhys);
    CHECK(kBankStride == misterplex::kPlex480pYuv420pBankStride);
    CHECK(!kNewDoorbell);
    CHECK(kStoreW == 640 && kStoreH == 480);
    CHECK(kCodedW == 624 && kDisplayW == 618 && kPresentedW == 640);
    CHECK(kPillarL == 11 && kPillarR == 11);
    CHECK(kI420Bytes == 449280);
    CHECK(kI420Bytes != kLegacy320x240I420Bytes);

    const std::string svh = slurp(repoFile("fpga/Plex_MiSTer/rtl/plex_15k_bw_contract.svh"));
    CHECK(svh.find("32'h3000_0000") != std::string::npos);
    CHECK(svh.find("32'h300F_F000") != std::string::npos);
    CHECK(svh.find("P15K_NEW_DOORBELL    = 1'b0") != std::string::npos);
    CHECK(svh.find("P15K_STORE_W            = 640") != std::string::npos);
    CHECK(svh.find("P15K_STORE_H            = 480") != std::string::npos);
    CHECK(svh.find("32'h3007_F000") == std::string::npos);
    CHECK(svh.find("0x3007F000") == std::string::npos);
    CHECK(svh.find("No 320x240 doorbell") != std::string::npos);

    const std::string qip = slurp(repoFile("fpga/Plex_MiSTer/files.qip"));
    CHECK(qip.find("present_15k_store_map") == std::string::npos);
    CHECK(qip.find("plex_15k_bw_contract") == std::string::npos);

    if (fails) {
        std::fprintf(stderr, "test_15k_store_map: %d FAILURES\n", fails);
        return 1;
    }
    std::printf("test_15k_store_map: OK\n");
    return 0;
}
