#pragma once
// ARM side of the fabric DDR publication-copy handover (w-plxd).
//
// Single-core reality (parent /proc/stat): MiSTer owns one A9 at idle; mpx-main
// ~0.8%. Dual-core decode||copy WITHDRAWN. Host memcpy must retire into fabric
// (ddr_frame_dma + fabric_dma_arm_kick). This header names DELETE vs KEEP.
//
// M10K: 0 (contract only). Engine bounce M10K is w-mem's EST (2 @ 64-bit layout).

#include <cstddef>

namespace misterplex {
namespace fabric_copy_handover {

inline constexpr const char* kDeleteSites[] = {
    "arm/misterplexd/fpga_spi.cpp:std::memcpy(ddrMap_ + bankOff, payload, len)",
    "arm/misterplexd/fpga_spi.cpp:cleanDcacheRange(ddrMap_ + bankOff, len)",
    "arm/misterplexd/fpga_spi.hpp:DdrTiming::copy_us",
    "arm/misterplexd/fpga_spi.hpp:DdrTiming::flush_us",
    "arm/misterplexd/media_player.cpp:prof.ddrCopyUs += dt.copy_us",
    "arm/misterplexd/media_player.cpp:prof.ddrFlushUs += dt.flush_us",
};

inline constexpr const char* kKeepSites[] = {
    "host/libmisterplex/ddr_bank_release_select.hpp:selectDdrWriteBank",
    "host/libmisterplex/plxd_liveness.hpp:plxdLivenessTick",
    "arm/misterplexd/fpga_spi.cpp:kickDdrDoorbell",
    "host/libmisterplex/ddr_frame_layout.hpp",
    "host/libmisterplex/fabric_dma_kick.hpp:buildFabricDmaKick720p",
    "fpga/Plex_MiSTer/rtl/fabric_dma_arm_kick.sv",
    "fpga/Plex_MiSTer/rtl/ddr_frame_dma.sv",
};

inline constexpr std::size_t kDeleteCount =
    sizeof(kDeleteSites) / sizeof(kDeleteSites[0]);
inline constexpr std::size_t kKeepCount = sizeof(kKeepSites) / sizeof(kKeepSites[0]);

static_assert(kDeleteCount >= 4, "DELETE inventory too small");
static_assert(kKeepCount >= 5, "KEEP inventory too small");

// M10K cost of this header: 0
inline constexpr int kM10kCost = 0;

} // namespace fabric_copy_handover
} // namespace misterplex
