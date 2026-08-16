#pragma once
// Fabric-direct / stick helpers. Default OFF (env/compile). Stubs keep
// the 720p inproc path compiling; product play uses heap + sendYuv420p.

#include <cstdint>
#include <cstring>
#include <string>

namespace misterplex {

struct FabricDirectSlot {
    uint32_t phys = 0;
    uint8_t* virt = nullptr;
};

struct FabricDirectAlloc {
    FabricDirectSlot slot[2]{};
    const char* how = "off";
    bool real() const { return slot[0].phys != 0 && slot[1].phys != 0; }
};

inline bool allocateFabricDirectSlots(FabricDirectAlloc&, size_t, bool = false, int = 2) {
    return false;
}
inline void releaseFabricDirectAlloc(FabricDirectAlloc& a) { a = FabricDirectAlloc{}; }
inline uint32_t refreshFabricSlotPhys(FabricDirectSlot&, size_t) { return 0; }
inline const char* fabricDirectHow(const FabricDirectAlloc& a) { return a.how; }
inline bool failClosedFabricDirectPhysPair(uint32_t, uint32_t) { return false; }
inline bool fabricDirectPhysPairReal(uint32_t a, uint32_t b) { return a != 0 && b != 0; }
inline int probePagemapPfnVisibility() { return 0; }
inline const char* pagemapPfnVisName(int) { return "unknown"; }

inline int avResyncDropMsForPresent(int confMs, bool l4PresentEvery) {
    return l4PresentEvery ? 0 : confMs;
}

constexpr int kPlex960Yuv420pBytes = 960 * 540 * 3 / 2;

} // namespace misterplex
