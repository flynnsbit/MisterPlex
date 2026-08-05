#pragma once
// fabric_src_staging.hpp — RESEARCH-ONLY host fill of Rank2 fabric_src_staging.
//
// SoT: DESIGN_CARD_FABRIC_STAGING_BRINGUP (fill → kick → wait → PLXK)
//      fabric_src_phys.hpp Rank2 PA layout SSOT
//      fabric_dma_host.hpp programFabricKick / waitFabricKickDone
//
// THIS LAND:
//   - fillStagingFromPayload(staging_map, payload, frame_bytes)
//     memcpy virt payload into a mapped (or mock) staging buffer with bounds
//   - Research sequence doc (below) for handoff to programFabricKick
//
// NOT THIS LAND:
//   - ensureFabricSrcStagingMap / mmap /dev/mem
//   - sendDdrFrame fork / skip T_copy
//   - kDdrPublishFabricPathEnabledInProduct (stays false)
//   - product flag ON / device / FIT_GO / PLXK ring inside this helper
//
// Research sequence (caller-owned, no product wire):
//   1) Obtain staging VA (lab mmap of stagingPhysBase(), or unit mock buffer)
//   2) fillStagingFromPayload(staging_map, payload, frame_bytes)
//      → bounds-checked memcpy into staging; barrier for visibility
//   3) programFabricKick(io, st, job) with job.src_phys = stagingPhysBase()
//      (and bank_phys / frame_bytes / cmd_seq); NEVER rings PLXK
//   4) waitFabricKickDone(io, st, ...) until PLXH done/err
//   5) Caller owns kickDdrDoorbell / PLXK AFTER done + payload barrier
//
// Product path unchanged: CpuSerial bank memcpy + PLXK.

#include "libmisterplex/fabric_src_phys.hpp"

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace misterplex {

// ---- Fill result (research diagnostics) -------------------------------------

enum class StagingFillResult {
    Ok = 0,
    NullMap,       // staging_map == nullptr
    NullPayload,   // payload == nullptr while frame_bytes > 0
    ZeroLen,       // frame_bytes == 0
    Oversize,      // frame_bytes > staging_cap
    Misaligned,    // frame_bytes not 8B-aligned (fabric kick contract)
};

inline const char* stagingFillResultName(StagingFillResult r) {
    switch (r) {
    case StagingFillResult::Ok:
        return "Ok";
    case StagingFillResult::NullMap:
        return "NullMap";
    case StagingFillResult::NullPayload:
        return "NullPayload";
    case StagingFillResult::ZeroLen:
        return "ZeroLen";
    case StagingFillResult::Oversize:
        return "Oversize";
    case StagingFillResult::Misaligned:
        return "Misaligned";
    }
    return "Unknown";
}

// Validate frame_bytes against a staging map capacity (default = Rank2 SSOT).
// require_align: when true, enforce 8B fabric kick contract on length.
inline StagingFillResult stagingFillArgsOk(const void* staging_map,
                                           const void* payload,
                                           uint32_t frame_bytes,
                                           uint32_t staging_cap = kFabricSrcStagingBytes,
                                           bool require_align = true) {
    if (staging_map == nullptr)
        return StagingFillResult::NullMap;
    if (frame_bytes == 0u)
        return StagingFillResult::ZeroLen;
    if (payload == nullptr)
        return StagingFillResult::NullPayload;
    if (frame_bytes > staging_cap)
        return StagingFillResult::Oversize;
    if (require_align && (frame_bytes % kFabricFrameBytesAlign) != 0u)
        return StagingFillResult::Misaligned;
    return StagingFillResult::Ok;
}

// Copy virt payload into mapped (or mock) Rank2 staging buffer.
//
// staging_map: host VA of fabric_src_staging (mmap of stagingPhysBase() in lab;
//              any writable buffer of size >= frame_bytes in unit tests).
// payload:     source frame bytes (host virt).
// frame_bytes: copy length; must fit staging_cap and (by default) be 8B-aligned.
// staging_cap: capacity of staging_map (default kFabricSrcStagingBytes).
// require_align: reject non-8B lengths when true (fabric programFabricKick gate).
//
// On success: memcpy + __sync_synchronize() so subsequent programFabricKick
// with src_phys=stagingPhysBase() observes filled bytes (lab O_SYNC/map path).
// Does NOT program fabric kick, wait PLXH, or ring PLXK.
inline StagingFillResult fillStagingFromPayloadEx(
    void* staging_map, const void* payload, uint32_t frame_bytes,
    uint32_t staging_cap = kFabricSrcStagingBytes, bool require_align = true) {
    const StagingFillResult check =
        stagingFillArgsOk(staging_map, payload, frame_bytes, staging_cap,
                          require_align);
    if (check != StagingFillResult::Ok)
        return check;

    std::memcpy(staging_map, payload, static_cast<size_t>(frame_bytes));
    __sync_synchronize();
    return StagingFillResult::Ok;
}

// Bool wrapper for call sites that only need ok/fail.
inline bool fillStagingFromPayload(void* staging_map, const void* payload,
                                   uint32_t frame_bytes,
                                   uint32_t staging_cap = kFabricSrcStagingBytes,
                                   bool require_align = true) {
    return fillStagingFromPayloadEx(staging_map, payload, frame_bytes,
                                    staging_cap, require_align) ==
           StagingFillResult::Ok;
}

// Convenience: fill then describe a FabricDmaJob sourcing Rank2 staging PA.
// Does not kick; caller still runs programFabricKick / wait / PLXK.
inline bool makeStagingFabricJob(FabricDmaJob& out, uint32_t bank_phys,
                                 uint32_t frame_bytes, uint16_t cmd_seq,
                                 bool bank_sel = false,
                                 bool use_bank_sel = true) {
    if (!stagingFrameBytesOk(frame_bytes))
        return false;
    if (!stagingFabricAlignOk(stagingPhysBase(), bank_phys, frame_bytes))
        return false;
    out.src_phys = stagingPhysBase();
    out.bank_phys = bank_phys;
    out.frame_bytes = frame_bytes;
    out.bank_sel = bank_sel;
    out.use_bank_sel = use_bank_sel;
    out.cmd_seq = cmd_seq;
    return true;
}

} // namespace misterplex
