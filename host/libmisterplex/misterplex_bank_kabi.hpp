#pragma once

// Userspace ABI for the misterplex_bank kernel owner (w-path).
// Product routes after parent incident 2026-08-03 (unbind dma-pl330 hard-hung SoC):
//   1) KernelDma        — dmaengine memcpy into reserved frame banks
//   2) CpuWriteCombine  — mmap banks with pgprot_writecombine; CPU fill
// Raw /dev/mem + userspace PL330 DMAGO is LAB ONLY and must not unbind dma-pl330.

#include "libmisterplex/ddr_frame_layout.hpp"

#include <cstdint>
#include <cstring>

namespace misterplex {

// Device node (module creates). No secrets; path is public product contract.
inline constexpr const char* kMisterplexBankDevPath = "/dev/misterplex_bank";
inline constexpr const char* kMisterplexBankModName = "misterplex_bank";

// Option-C 720p defaults — derived from ddr_frame_layout (w-mem freeze).
// NOT legacy 480p 0x30000000 — that stomps bitstream ring @0x30100000 and
// confuses bank1 with Option-C bank0. bank1 = base + stride = 0x30300000.
inline constexpr uint32_t kMisterplexBank0PhysDefault = kPlex720pDdrFramePhysBase;
inline constexpr uint32_t kMisterplexBankBytesDefault = kPlex720pYuv420pBankStride;
inline constexpr uint32_t kMisterplexBank1PhysDefault =
    kMisterplexBank0PhysDefault + kMisterplexBankBytesDefault;
static_assert(kMisterplexBank0PhysDefault == 0x30180000u, "kabi bank0 Option-C");
static_assert(kMisterplexBank1PhysDefault == 0x30300000u, "kabi bank1 Option-C");
static_assert(kMisterplexBankBytesDefault == 0x00180000u, "kabi stride Option-C");
static_assert(kMisterplexBank0PhysDefault != 0x30000000u, "kabi must not use legacy base");

// ioctl magic — avoid clash with FPGA manager.
inline constexpr unsigned kMisterplexBankIocMagic = 0xB7;

enum MisterplexBankIocNr : unsigned {
    kMpbIocInfo = 0x01,
    kMpbIocDmaMemcpy = 0x02,
    kMpbIocSetMapProt = 0x03,
};

enum MisterplexBankMapProt : uint32_t {
    kMpbMapProtNoncached = 0, // same class as /dev/mem reserved pfn (baseline)
    kMpbMapProtWriteCombine = 1, // PRODUCT serial-upgrade candidate
    kMpbMapProtCached = 2,       // lab only; requires explicit flush path
};

// Fixed-layout structs for ioctl (packed, LE). Keep stable across daemon builds.
#pragma pack(push, 1)
struct MisterplexBankInfo {
    uint32_t api_version; // bump on breaking change; start = 1
    uint32_t n_banks;
    uint32_t bank0_phys;
    uint32_t bank1_phys;
    uint32_t bank_bytes;
    uint32_t map_prot; // MisterplexBankMapProt currently applied to mmap
    uint32_t dma_capable; // 1 if dmaengine channel acquired
    uint32_t reserved0;
};

struct MisterplexBankDmaReq {
    uint32_t src_phys; // staging in System RAM (must be dma-mapable)
    uint32_t dst_bank; // 0 or 1
    uint32_t len;
    uint32_t flags; // bit0: sync wait completion before ioctl returns
};

struct MisterplexBankMapProtReq {
    uint32_t prot; // MisterplexBankMapProt
    uint32_t reserved0;
};
#pragma pack(pop)

inline constexpr uint32_t kMisterplexBankApiVersion = 1;
inline constexpr uint32_t kMisterplexBankDmaFlagSync = 1u << 0;

// Host-side encode helpers (no kernel headers required).
// _IOWR style: dir=2 (write|read), type=magic, nr, size — Linux ioctl encoding.
inline constexpr unsigned long mpbIoc(unsigned dir, unsigned nr, unsigned size) {
    return (static_cast<unsigned long>(dir) << 30) |
           (static_cast<unsigned long>(size) << 16) |
           (static_cast<unsigned long>(kMisterplexBankIocMagic) << 8) | nr;
}

inline constexpr unsigned long kMpbIocInfoCmd =
    mpbIoc(/*_IOWR*/ 3u, kMpbIocInfo, static_cast<unsigned>(sizeof(MisterplexBankInfo)));
inline constexpr unsigned long kMpbIocDmaMemcpyCmd =
    mpbIoc(/*_IOW*/ 1u, kMpbIocDmaMemcpy, static_cast<unsigned>(sizeof(MisterplexBankDmaReq)));
inline constexpr unsigned long kMpbIocSetMapProtCmd =
    mpbIoc(/*_IOW*/ 1u, kMpbIocSetMapProt, static_cast<unsigned>(sizeof(MisterplexBankMapProtReq)));

inline const char* misterplexBankMapProtName(uint32_t p) {
    switch (p) {
    case kMpbMapProtNoncached:
        return "noncached";
    case kMpbMapProtWriteCombine:
        return "write_combine";
    case kMpbMapProtCached:
        return "cached_lab";
    default:
        return "unknown";
    }
}

// Pass criteria for WC bench (parent): must beat /dev/mem and clear true-720 need.
inline bool misterplexBankWcRateIsProductCandidate(double miBps) {
    return miBps >= 230.2; // kParentTrue720pCopyMiBpsNeed
}

inline bool misterplexBankInfoSane(const MisterplexBankInfo& i) {
    if (i.api_version != kMisterplexBankApiVersion)
        return false;
    if (i.n_banks < 2)
        return false;
    if (i.bank_bytes < 1280u * 720u * 3u / 2u)
        return false;
    if (i.bank0_phys == 0 || i.bank1_phys == 0)
        return false;
    if (i.bank0_phys == i.bank1_phys)
        return false;
    // True-720 product window: bank1 must be bank0 + bank_bytes (no overlap).
    if (i.bank1_phys != i.bank0_phys + i.bank_bytes)
        return false;
    // Reject legacy 480p base disguised as 720p stride (ring stomp class).
    if (i.bank0_phys == 0x30000000u)
        return false;
    return true;
}

} // namespace misterplex
