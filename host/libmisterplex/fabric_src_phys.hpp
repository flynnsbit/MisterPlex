#pragma once
// fabric_src_phys.hpp — Rank2 reserved-window fabric SRC staging PA layout.
//
// SoT: DESIGN_CARD_FABRIC_STAGING_BRINGUP §1 (WHERE STAGING PA LIVES)
//      DESIGN_CARD_FABRIC_SRC_PHYS_INGEST Rank2
//
// THIS LAND (constants + pure helpers only):
//   - Preferred LAB bring-up phys = OPT-A 0x30601000 (reuse PL330 staging fence)
//   - frame_bytes for product canvas COPY = 720 I420 1_382_400 (8B aligned)
//   - stagingPhysBase() / stagingFrameBytes720() / align checks
//
// NOT THIS LAND:
//   - ensureFabricSrcStagingMap / mmap /dev/mem
//   - resolvePublishSrcPhys runtime
//   - sendDdrFrame fork / skip T_copy
//   - kDdrPublishFabricPathEnabledInProduct (stays false)
//   - product flag ON / device / FIT_GO
//
// Adjacent research land (fill helper, still no product wire):
//   fabric_src_staging.hpp — fillStagingFromPayload + kick handoff sequence
//
// Bring-up PA ranking (card §1.2):
//   OPT-A LAB DEFAULT: kPl330StagingPhys = 0x30601000 (named fabric_src_staging role)
//     cap = kPl330StagingBytes = 0x180000 ≥ 1382400
//     HARD COLLISION with concurrent ddr_pl330_ingest_bench — lab mutex only
//   OPT-B FREE REGION (parent SSOT follow-up; not preferred lab default):
//     kPl330AbiRegionEndPhys = 0x30781000  OR nicer 0x30800000
//   OPT-C REJECT: invent virt_to_phys / heap pagemap
//
// Product path unchanged: CpuSerial bank memcpy + PLXK.

#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/fabric_dma_host.hpp"

#include <cstddef>
#include <cstdint>

namespace misterplex {

// ---- Rank2 fabric_src_staging phys SSOT (LAB bring-up) ----------------------
// Preferred lab staging phys: OPT-A reuse of PL330 staging fence (card SoT).
// Role rename: this PA is fabric_src_staging under research; PL330 product DMA
// owner remains FORBID (H3). Mutual exclusion with PL330 lab benches required.

inline constexpr uint32_t kFabricSrcStagingPhysLab = kPl330StagingPhys; // 0x30601000
inline constexpr uint32_t kFabricSrcStagingBytesLab = kPl330StagingBytes; // 0x180000

// OPT-B free-region sketches (documented only; not selected as lab default).
// Parent may promote one of these as kFabricSrcStagingPhys later.
inline constexpr uint32_t kFabricSrcStagingPhysFreeAfterPl330 =
    kPl330AbiRegionEndPhys; // 0x30781000 (page-aligned)
inline constexpr uint32_t kFabricSrcStagingPhysFreeNice = 0x30800000u;

// Active research SSOT for Rank2 layout math (LAB OPT-A).
// When productizing the name, parent may retarget to OPT-B free carve.
inline constexpr uint32_t kFabricSrcStagingPhys = kFabricSrcStagingPhysLab;
inline constexpr uint32_t kFabricSrcStagingBytes = kFabricSrcStagingBytesLab;

// Fabric engine align rule: src/bank/frame_bytes 8B-aligned and non-zero len.
// 720 I420 payload needs no pad: 1382400 % 8 == 0.
inline constexpr uint32_t kFabricFrameBytesAlign = 8u;

static_assert(kFabricSrcStagingPhys == 0x30601000u,
              "lab Rank2 staging phys SoT = PL330 staging 0x30601000");
static_assert(kFabricSrcStagingBytes == 0x00180000u,
              "staging region = bank stride 0x180000");
static_assert(kFabricSrcStagingBytes >=
                  static_cast<uint32_t>(kPlex720pYuv420pBytes),
              "staging region must fit one 720 I420 frame");
static_assert((static_cast<uint32_t>(kPlex720pYuv420pBytes) % kFabricFrameBytesAlign) ==
                  0u,
              "720 I420 frame_bytes 8B-aligned (no pad)");
static_assert((kFabricSrcStagingPhys % kFabricFrameBytesAlign) == 0u,
              "staging base 8B-aligned for fabric align_ok");
static_assert(kFabricSrcStagingPhys >= kPlexDdrReservedWindowStart &&
                  kFabricSrcStagingPhys + kFabricSrcStagingBytes <=
                      kPlexDdrReservedWindowEnd,
              "staging inside reserved HPS window");
static_assert(kFabricSrcStagingPhysFreeAfterPl330 == 0x30781000u,
              "OPT-B free after PL330 ABI end");
static_assert((kFabricSrcStagingPhysFreeAfterPl330 % 0x1000u) == 0u,
              "OPT-B free base page-aligned");
static_assert((kFabricSrcStagingPhysFreeNice % 0x1000u) == 0u,
              "OPT-B nice base page-aligned");

// ---- Pure helpers (no mmap, no product path) --------------------------------

// Preferred lab Rank2 staging physical base (fabric SRC for COPY bring-up).
inline constexpr uint32_t stagingPhysBase() { return kFabricSrcStagingPhys; }

// Product-canvas frame_bytes for fabric COPY jobs (720 I420).
// Lab harnesses may pass smaller lens; product sketch = 720.
inline constexpr uint32_t stagingFrameBytes720() {
    return static_cast<uint32_t>(kPlex720pYuv420pBytes);
}

// Staging region capacity (map length / dual-buffer headroom).
inline constexpr uint32_t stagingRegionBytes() { return kFabricSrcStagingBytes; }

// 8B fabric align_ok for a job that sources from Rank2 staging PA.
// bank_phys still required (present bank destination).
inline constexpr bool stagingFabricAlignOk(uint32_t src_phys, uint32_t bank_phys,
                                           uint32_t frame_bytes) {
    return fabricKickAlignOk(src_phys, bank_phys, frame_bytes);
}

// True if (phys,len) lies entirely inside the Rank2 staging region.
inline constexpr bool stagingPhysInRegion(uint32_t phys, uint32_t len = 1u) {
    if (len == 0u)
        return false;
    if (phys < kFabricSrcStagingPhys)
        return false;
    // Avoid wrap: require phys + len stays within region end.
    const uint32_t end = kFabricSrcStagingPhys + kFabricSrcStagingBytes;
    if (phys > end)
        return false;
    return phys + len <= end;
}

// True if frame_bytes fits staging capacity and satisfies 8B non-zero align.
inline constexpr bool stagingFrameBytesOk(uint32_t frame_bytes) {
    return frame_bytes != 0u && (frame_bytes % kFabricFrameBytesAlign) == 0u &&
           frame_bytes <= kFabricSrcStagingBytes;
}

// Default 720 job: staging base + product bank0 + 720 I420 len align_ok.
inline constexpr bool stagingDefault720AlignOk(uint32_t bank_phys) {
    return stagingFabricAlignOk(stagingPhysBase(), bank_phys,
                                stagingFrameBytes720()) &&
           stagingFrameBytesOk(stagingFrameBytes720()) &&
           stagingPhysInRegion(stagingPhysBase(), stagingFrameBytes720());
}

} // namespace misterplex
