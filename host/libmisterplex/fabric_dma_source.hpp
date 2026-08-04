#pragma once

// Fabric DDR publication source contract (w-mem / rd-duck).
//
// BLOCKING FACT (rd-duck): media_player builds a normal std::vector<uint8_t>
// frame (~3467/3984). That pointer is NOT a contiguous physical buffer and is
// NOT a legal ddr_frame_dma src_phys.
//
// Retireable path (explicit allocation + cache/visibility):
//
//   CPU decode/scale → heap vector bytes
//        │
//        ▼  FabricDmaStagingMap::loadCpuBytes()   ← REQUIRED (this is still a
//   Contiguous PA kFabricDmaStagingPhys             CPU fill of reserved ring;
//   (0x3060_1000, size 0x18_0000)                   it does NOT retire the
//        │  visibilityBarrier()                     *publication* copy — fabric
//        ▼                                          DMA does staging→bank)
//   armKick() → src_phys for status[12]
//        │
//        ▼
//   ddr_frame_dma Avalon copy → bank; dma_done → frame_store kick
//
// Scatter-gather is NOT supported (single src_phys). CMA/dma-buf product
// drivers may own the same PA contract later.
//
// Cache: reserved window is outside System RAM (memmap). /dev/mem maps are
// pgprot_noncached — no D-cache clean required. Compiler fence + dummy load
// still required so status[12] cannot reorder above fill stores.
//
// NOT_INTEGRATION_READY until misterplexd product path calls load+kick
// instead of sendDdrFrame bank memcpy (OPEN).

#include "libmisterplex/ddr_frame_layout.hpp"

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>

#if defined(__linux__)
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#endif

namespace misterplex {

// Same reserved ring as PL330 staging (shared ABI with w-path).
constexpr uint32_t kFabricDmaStagingPhys = kPl330StagingPhys;       // 0x30601000
constexpr uint32_t kFabricDmaStagingBytes = kPl330StagingBytes;     // 0x180000
constexpr uint32_t kFabricDmaScratchPhys = kPl330ProgScratchPhys;   // 0x30600000
constexpr uint32_t kFabricDmaScratchBytes = kPl330ProgScratchBytes; // 0x1000

static_assert(kFabricDmaStagingPhys == 0x30601000u, "fabric staging phys");
static_assert(kFabricDmaStagingBytes == kPlex720pYuv420pBankStride,
              "staging holds one 720p bank stride");
static_assert(kFabricDmaStagingPhys == kPl330StagingPhys, "fabric==PL330 staging PA");
static_assert(kFabricDmaStagingBytes == kPl330StagingBytes, "fabric==PL330 staging size");

// Legal fabric DMA source: contiguous PA inside staging, 8-byte aligned,
// length > 0, length ≤ staging capacity, length multiple of 8 (Avalon 64-bit).
inline bool fabricDmaSrcPhysLegal(uint32_t src_phys, size_t len) {
    if (len == 0 || (len % 8u) != 0)
        return false;
    if ((src_phys & 7u) != 0)
        return false;
    if (len > static_cast<size_t>(kFabricDmaStagingBytes))
        return false;
    return pl330PhysInStaging(src_phys, static_cast<uint32_t>(len));
}

// Unresolved phys sentinel used by DdrIngestJob when only virt is known.
inline bool fabricDmaRejectsUnresolvedPhys(uint32_t src_phys) { return src_phys == 0; }

// Truncating a userspace VA to uint32_t and feeding it as src_phys is the
// classic false path — any address outside the staging window is rejected.
inline bool fabricDmaRejectsOutsideStagingWindow(uint32_t maybe_phys, size_t len) {
    return !fabricDmaSrcPhysLegal(maybe_phys, len);
}

// True when a host pointer must NOT be used directly as Avalon src_phys.
// Heap/vector pointers always return true (must go through loadCpuBytes).
inline bool fabricDmaMustStageHostPointer(const void* host_ptr, size_t len) {
    if (!host_ptr || len == 0)
        return true;
    const uintptr_t v = reinterpret_cast<uintptr_t>(host_ptr);
    // Truncated 32-bit view of a heap VA is never a legal staging PA on LP64.
    const uint32_t truncated = static_cast<uint32_t>(v);
    if (fabricDmaRejectsUnresolvedPhys(truncated))
        return true;
    if (fabricDmaRejectsOutsideStagingWindow(truncated, len))
        return true;
    // Even if truncated accidentally equals staging base, a bare host pointer
    // is still not a substitute for an explicit mapped staging fill.
    return true;
}

enum class FabricDmaSourcePhase : uint8_t {
    Closed = 0,
    MappedEmpty = 1,
    Filling = 2,
    PayloadVisible = 3, // safe to assert status[12] / start pulse
    KickArmed = 4,      // caller claimed start; engine owns the bytes
    Failed = 5,
};

// Maps the reserved staging page via /dev/mem (or a host test double).
// Default product path still uses sendDdrFrame until open()+load()+kick land.
class FabricDmaStagingMap {
public:
    FabricDmaStagingMap() = default;
    FabricDmaStagingMap(const FabricDmaStagingMap&) = delete;
    FabricDmaStagingMap& operator=(const FabricDmaStagingMap&) = delete;
    ~FabricDmaStagingMap() { close(); }

    uint32_t phys() const { return kFabricDmaStagingPhys; }
    size_t capacity() const { return kFabricDmaStagingBytes; }
    void* virt() const { return virt_; }
    FabricDmaSourcePhase phase() const { return phase_; }
    size_t filledBytes() const { return filled_; }

    // Host unit tests: bind an already-allocated buffer as if it were the map
    // (no /dev/mem). phys is still reported as kFabricDmaStagingPhys.
    bool openTestDouble(void* backing, size_t bytes, std::string* err = nullptr) {
        close();
        if (!backing || bytes < kFabricDmaStagingBytes) {
            if (err)
                *err = "fabric_dma: test double too small";
            phase_ = FabricDmaSourcePhase::Failed;
            return false;
        }
        virt_ = backing;
        test_double_ = true;
        filled_ = 0;
        phase_ = FabricDmaSourcePhase::MappedEmpty;
        return true;
    }

#if defined(__linux__)
    bool openDevMem(std::string* err = nullptr) {
        close();
        fd_ = ::open("/dev/mem", O_RDWR | O_SYNC);
        if (fd_ < 0) {
            if (err)
                *err = "fabric_dma: open /dev/mem failed";
            phase_ = FabricDmaSourcePhase::Failed;
            return false;
        }
        void* p = ::mmap(nullptr, kFabricDmaStagingBytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd_,
                         static_cast<off_t>(kFabricDmaStagingPhys));
        if (p == MAP_FAILED) {
            ::close(fd_);
            fd_ = -1;
            if (err)
                *err = "fabric_dma: mmap staging failed";
            phase_ = FabricDmaSourcePhase::Failed;
            return false;
        }
        virt_ = p;
        test_double_ = false;
        filled_ = 0;
        phase_ = FabricDmaSourcePhase::MappedEmpty;
        return true;
    }
#endif

    void close() {
#if defined(__linux__)
        if (!test_double_ && virt_) {
            ::munmap(virt_, kFabricDmaStagingBytes);
        }
        if (fd_ >= 0) {
            ::close(fd_);
            fd_ = -1;
        }
#endif
        virt_ = nullptr;
        test_double_ = false;
        filled_ = 0;
        phase_ = FabricDmaSourcePhase::Closed;
    }

    // Copy CPU bytes (e.g. vector.data()) into contiguous staging.
    // REQUIRED before fabric DMA start — vector is never src_phys.
    bool loadCpuBytes(const void* src, size_t len, std::string* err = nullptr) {
        if (phase_ != FabricDmaSourcePhase::MappedEmpty &&
            phase_ != FabricDmaSourcePhase::PayloadVisible &&
            phase_ != FabricDmaSourcePhase::KickArmed) {
            if (err)
                *err = "fabric_dma: not mapped";
            phase_ = FabricDmaSourcePhase::Failed;
            return false;
        }
        if (!src || !virt_) {
            if (err)
                *err = "fabric_dma: null src/virt";
            phase_ = FabricDmaSourcePhase::Failed;
            return false;
        }
        if (!fabricDmaSrcPhysLegal(kFabricDmaStagingPhys, len)) {
            if (err)
                *err = "fabric_dma: len/align rejected for staging PA";
            phase_ = FabricDmaSourcePhase::Failed;
            return false;
        }
        phase_ = FabricDmaSourcePhase::Filling;
        std::memcpy(virt_, src, len);
        filled_ = len;
        if (!visibilityBarrier(err)) {
            phase_ = FabricDmaSourcePhase::Failed;
            return false;
        }
        phase_ = FabricDmaSourcePhase::PayloadVisible;
        return true;
    }

    // Compiler fence + dummy load of last committed byte so status[12] cannot
    // be reordered above the fill by the compiler. Noncached map needs no
    // D-cache clean; this is still the explicit visibility step.
    bool visibilityBarrier(std::string* err = nullptr) {
        if (!virt_ || filled_ == 0) {
            if (err)
                *err = "fabric_dma: barrier without payload";
            return false;
        }
        std::atomic_thread_fence(std::memory_order_seq_cst);
        volatile uint8_t* p = static_cast<volatile uint8_t*>(virt_);
        (void)p[filled_ - 1];
        std::atomic_thread_fence(std::memory_order_seq_cst);
        return true;
    }

    // Call only after PayloadVisible. Returns the PA fabric RTL must use.
    // Does not itself poke status[12] — HPS SPI/status owner does that.
    bool armKick(uint32_t* out_src_phys, size_t* out_len, std::string* err = nullptr) {
        if (phase_ != FabricDmaSourcePhase::PayloadVisible) {
            if (err)
                *err = "fabric_dma: kick before payload visible";
            return false;
        }
        if (!fabricDmaSrcPhysLegal(kFabricDmaStagingPhys, filled_)) {
            if (err)
                *err = "fabric_dma: filled len illegal";
            phase_ = FabricDmaSourcePhase::Failed;
            return false;
        }
        if (out_src_phys)
            *out_src_phys = kFabricDmaStagingPhys;
        if (out_len)
            *out_len = filled_;
        phase_ = FabricDmaSourcePhase::KickArmed;
        return true;
    }

private:
    void* virt_ = nullptr;
    size_t filled_ = 0;
    FabricDmaSourcePhase phase_ = FabricDmaSourcePhase::Closed;
    bool test_double_ = false;
#if defined(__linux__)
    int fd_ = -1;
#endif
};

// One-shot: heap/vector → staging fill + barrier + armKick.
// Does NOT retire bank publication copy — only prepares src_phys for fabric.
inline bool fabricDmaPrepareFromCpuBuffer(FabricDmaStagingMap& map, const void* cpu_src,
                                          size_t len, uint32_t* out_src_phys, size_t* out_len,
                                          std::string* err = nullptr) {
    if (!map.loadCpuBytes(cpu_src, len, err))
        return false;
    return map.armKick(out_src_phys, out_len, err);
}

} // namespace misterplex
