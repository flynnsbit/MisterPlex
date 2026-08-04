#pragma once
// ARM → fabric DMA kick descriptor (w-plxd on integ/720p-compose).
//
// Matches fpga/Plex_MiSTer/rtl/ddr_frame_dma.sv ports:
//   start, src_phys, bank_phys, frame_bytes (8-byte aligned).
// Fabric owns the DDR→DDR copy; ARM stops host memcpy (see fabric_copy_handover.hpp).
//
// M10K: 0 (host contract only). Bounce BRAM lives in ddr_frame_dma (w-mem EST
// 2 × M10K at 64-bit bounce — layout 2×(256×32); unfitted).
//
// Refresh: this path does not set scanout rate. With PRESENT_CLK_PIX_PLL @29.7 MHz
// + CEA 1650×750 the compose targets 24.000 Hz; @20 MHz same-clock would be
// ~16.16 Hz (w-clock owns the falsifiable refresh claim — do not report 720p
// "working" on geometry alone).

#include "libmisterplex/ddr_frame_layout.hpp"

#include <cstdint>
#include <string>

namespace misterplex {

struct FabricDmaKick {
    uint32_t src_phys = 0;
    uint32_t bank_phys = 0;
    uint32_t frame_bytes = 0;
    int bank = 0;
    bool valid = false;
};

// 8-byte align required by ddr_frame_dma align_ok.
inline bool fabricDmaPhysAligned(uint32_t phys) { return (phys & 7u) == 0u; }

inline bool fabricDmaBytesAligned(uint32_t n) { return (n & 7u) == 0u && n != 0u; }

// Option-C bank0/1 phys for 720p I420 (compose QSF FRAME 1280×720).
inline uint32_t fabricDma720pBankPhys(int bank) {
    const uint32_t b = static_cast<uint32_t>(bank & 1);
    return kPlex720pPhysBase + b * kPlex720pYuv420pBankStride;
}

// Default host staging for fabric/PL330 source (after triple banks).
inline uint32_t fabricDma720pDefaultSrcPhys() { return kPl330StagingPhys; }

// Build a kick for true-720p I420 publication. Rejects misalignment, wrong size,
// bank outside Option-C window, and src overlapping bank payload.
inline FabricDmaKick buildFabricDmaKick720p(uint32_t src_phys, int bank,
                                            uint32_t frame_bytes = kPlex720pYuv420pBytes,
                                            std::string* err = nullptr) {
    FabricDmaKick k{};
    k.bank = bank & 1;
    k.src_phys = src_phys;
    k.bank_phys = fabricDma720pBankPhys(k.bank);
    k.frame_bytes = frame_bytes;

    auto fail = [&](const char* msg) -> FabricDmaKick {
        if (err)
            *err = msg;
        k.valid = false;
        return k;
    };

    if (bank != 0 && bank != 1)
        return fail("fabric_dma_kick: bank must be 0 or 1");
    if (!fabricDmaPhysAligned(src_phys))
        return fail("fabric_dma_kick: src_phys must be 8-byte aligned");
    if (!fabricDmaPhysAligned(k.bank_phys))
        return fail("fabric_dma_kick: bank_phys must be 8-byte aligned");
    if (!fabricDmaBytesAligned(frame_bytes))
        return fail("fabric_dma_kick: frame_bytes must be non-zero 8-byte multiple");
    if (frame_bytes != static_cast<uint32_t>(kPlex720pYuv420pBytes))
        return fail("fabric_dma_kick: frame_bytes must equal 720p I420 (1382400)");
    // Bank payload must sit inside Option-C triple window.
    const uint32_t bank_end = k.bank_phys + frame_bytes;
    if (k.bank_phys < kPlex720pPhysBase || bank_end > kPlex720pOptionCTripleEndPhys)
        return fail("fabric_dma_kick: bank window outside Option-C 720p map");
    // Source must not overlap the destination bank payload (R+W same region is illegal).
    const uint32_t src_end = src_phys + frame_bytes;
    if (src_phys < bank_end && k.bank_phys < src_end)
        return fail("fabric_dma_kick: src overlaps destination bank");
    // Prefer staging region (product intent); allow any non-overlapping aligned src
    // inside the reserved HPS window for lab DMA sources.
    if (src_phys < kPlexDdrReservedWindowStart || src_end > kPlexDdrReservedWindowEnd)
        return fail("fabric_dma_kick: src outside reserved HPS DDR window");

    k.valid = true;
    if (err)
        err->clear();
    return k;
}

// True when host memcpy publish is product-forbidden for this payload size
// (true-720p I420). Sub-720p glass source may still use CpuSerial.
inline bool fabricDmaRequiredForPayload(size_t payload_bytes) {
    return payload_bytes >= static_cast<size_t>(kPlex720pYuv420pBytes);
}

} // namespace misterplex
