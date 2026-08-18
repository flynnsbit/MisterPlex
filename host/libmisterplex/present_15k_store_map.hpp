#pragma once
// C++ twin of fpga/Plex_MiSTer/rtl/present_15k_store_map.sv
// 15 kHz beam (hc,vc,field) → 640×480 I420 store @ PHYS 0x30000000 / doorbell 0x300FF000.
// Bob DROP: even columns+rows. Weave: identity-x, y=2*vc(+1 if odd). Clamp 639/479.
// Define P15K_STORE_MAP_WRONG for L8 identity-x / y=vc red twin.

#include <cstdint>

namespace misterplex {
namespace p15k {

inline constexpr int kStoreW = 640;
inline constexpr int kStoreH = 480;
inline constexpr int kStoreLastX = 639;
inline constexpr int kStoreLastY = 479;
inline constexpr int kCodedW = 624;
inline constexpr int kDisplayW = 618;
inline constexpr int kPresentedW = 640;
inline constexpr int kPillarL = 11;
inline constexpr int kPillarR = 11;
inline constexpr int kI420Bytes = 449280;
inline constexpr int kLegacy320x240I420Bytes = 115200;
inline constexpr uint32_t kPhysBase = 0x30000000u;
inline constexpr uint32_t kDoorbellPhys = 0x300FF000u;
inline constexpr uint32_t kBankStride = 0x00080000u;
inline constexpr uint32_t kLegacy320x240DoorbellPhys = 0x3007F000u;
inline constexpr bool kNewDoorbell = false;
inline constexpr int kBobXParity = 0;
inline constexpr int kBobYParity = 0;

struct StoreXY {
    int x;
    int y;
};

inline constexpr int clampStoreX(int x) {
    if (x < 0)
        return 0;
    if (x > kStoreLastX)
        return kStoreLastX;
    return x;
}

inline constexpr int clampStoreY(int y) {
    if (y < 0)
        return 0;
    if (y > kStoreLastY)
        return kStoreLastY;
    return y;
}

inline constexpr StoreXY map15kStore(int hc, int vc, bool field_odd, bool mode_weave) {
#ifdef P15K_STORE_MAP_WRONG
    // L8 red twin: identity-x on bob, y=vc (not 2*vc).
    (void)field_odd;
    (void)mode_weave;
    return {clampStoreX(hc), clampStoreY(vc)};
#else
    const int x = mode_weave ? hc : ((hc << 1) | kBobXParity);
    const int y = mode_weave ? ((vc << 1) | (field_odd ? 1 : 0)) : ((vc << 1) | kBobYParity);
    return {clampStoreX(x), clampStoreY(y)};
#endif
}

static_assert(kStoreW == 640 && kStoreH == 480, "store stays 640x480");
static_assert(kPhysBase == 0x30000000u, "true480 PHYS bank");
static_assert(kDoorbellPhys == 0x300FF000u, "true480 doorbell");
static_assert(kDoorbellPhys != kLegacy320x240DoorbellPhys, "no 320x240 doorbell");
static_assert(!kNewDoorbell, "no new doorbell");
static_assert(kI420Bytes != kLegacy320x240I420Bytes, "not 320x240 I420");
static_assert(kPillarL + kDisplayW + kPillarR == kPresentedW, "11+618+11");

#ifndef P15K_STORE_MAP_WRONG
static_assert(map15kStore(0, 0, false, false).x == 0 && map15kStore(0, 0, false, false).y == 0,
              "bob (0,0)");
static_assert(map15kStore(319, 239, false, false).x == 638 &&
                  map15kStore(319, 239, false, false).y == 478,
              "bob (319,239)");
static_assert(map15kStore(0, 0, false, true).x == 0 && map15kStore(0, 0, false, true).y == 0,
              "weave even (0,0)");
static_assert(map15kStore(639, 239, false, true).x == 639 &&
                  map15kStore(639, 239, false, true).y == 478,
              "weave even (639,239)");
static_assert(map15kStore(0, 0, true, true).x == 0 && map15kStore(0, 0, true, true).y == 1,
              "weave odd (0,0)");
static_assert(map15kStore(639, 239, true, true).x == 639 &&
                  map15kStore(639, 239, true, true).y == 479,
              "weave odd (639,239)");
#endif

} // namespace p15k
} // namespace misterplex
