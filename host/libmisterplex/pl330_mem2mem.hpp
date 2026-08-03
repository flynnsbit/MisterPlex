#pragma once

// Cyclone V HPS PL330 mem2mem helper (w-path Route A).
//
// Programs the non-secure DMAC via /dev/mem debug instruction interface.
// Default OFF — parent measures concurrency; Linux may already own channels.
//
// Program scratch + staging live in the memmap reserved window at fixed phys
// (kPl330ProgScratchPhys / kPl330StagingPhys in ddr_frame_layout.hpp) so the
// PL330 can fetch microcode by PA without CMA/hugepages/pagemap.
//
// Pre-register (device, after scratch wired):
//   P1: pl330_transfer started=1 (no longer needs_prog_scratch_phys)
//   P2: DMA wall for 1382400 B into bank ≤ serial CPU copy (~15.9 ms)
//   P3: copy_under_burn inflate_ms small ⇒ max(decode,dma) credible
//
// Do NOT ring the frame doorbell from this header — caller owns ordering
// (DdrIngestSession::mayRingDoorbell).

#include "libmisterplex/ddr_frame_layout.hpp"

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <string>
#include <sys/mman.h>
#include <unistd.h>

namespace misterplex {

// Cyclone V HPS non-secure PL330 (Intel CV HPS TRM).
constexpr uint32_t kPl330NsBasePhys = 0xFFE01000u;
constexpr size_t kPl330MapLen = 0x1000u;

// Register offsets (ARM DDI0424)
constexpr uint32_t kPl330_DSR = 0x000;
constexpr uint32_t kPl330_FSRD = 0x030;
constexpr uint32_t kPl330_FSRC = 0x034;
constexpr uint32_t kPl330_CSR0 = 0x100; // + n*0x08
constexpr uint32_t kPl330_CPC0 = 0x104;
constexpr uint32_t kPl330_DBGSTATUS = 0xD00;
constexpr uint32_t kPl330_DBGCMD = 0xD04;
constexpr uint32_t kPl330_DBGINST0 = 0xD08;
constexpr uint32_t kPl330_DBGINST1 = 0xD0C;
constexpr uint32_t kPl330_CR0 = 0xE00;
constexpr uint32_t kPl330_CRD = 0xE14;

struct Pl330Mem2MemRequest {
    uint32_t src_phys = 0;
    uint32_t dst_phys = 0;
    size_t len = 0;
    int channel = 0; // 0..7 prefer
};

struct Pl330Mem2MemResult {
    bool ok = false;
    bool hardware_present = false;
    bool channel_started = false;
    int channel_used = -1;
    std::string detail;
    uint32_t dsr = 0;
    uint32_t cr0 = 0;
};

// CCR: SA/DA inc, SS32/DS32, symmetric burst_len in 1..16 (encoded as len-1).
// Returns 0 on bad args. See ARM DDI0424 CCR.
inline uint32_t pl330BuildCcrBurst(unsigned burst_len) {
    if (burst_len < 1 || burst_len > 16)
        return 0;
    const uint32_t SRC_INC = 1u << 0;
    const uint32_t DST_INC = 1u << 14;
    const uint32_t SRC_BURST_SIZE_32 = 2u << 1; // 2^2 = 4 bytes
    const uint32_t DST_BURST_SIZE_32 = 2u << 15;
    const uint32_t bl = burst_len - 1u;
    const uint32_t SRC_BURST_LEN = bl << 4;
    const uint32_t DST_BURST_LEN = bl << 18;
    return SRC_INC | DST_INC | SRC_BURST_SIZE_32 | DST_BURST_SIZE_32 | SRC_BURST_LEN |
           DST_BURST_LEN;
}

// Back-compat: burst-1 CCR when len is 4-byte aligned (len only validates).
inline uint32_t pl330BuildCcr(size_t len) {
    if (len == 0 || (len % 4) != 0)
        return 0;
    return pl330BuildCcrBurst(1);
}

// Factor n_iters into inner*outer with both in 1..256. Prefer larger outer.
inline bool pl330FactorLoops(uint32_t n_iters, uint32_t* inner, uint32_t* outer) {
    if (!inner || !outer || n_iters == 0)
        return false;
    if (n_iters <= 256u) {
        *inner = n_iters;
        *outer = 1;
        return true;
    }
    if (n_iters > 256u * 256u)
        return false;
    for (uint32_t o = 256u; o >= 1u; --o) {
        if (n_iters % o)
            continue;
        const uint32_t i = n_iters / o;
        if (i >= 1u && i <= 256u) {
            *inner = i;
            *outer = o;
            return true;
        }
    }
    return false;
}

// Pick largest burst in {16,8,4,2,1} that divides len and factors loop count.
inline bool pl330PickBurstAndLoops(size_t len, unsigned* burst_len, uint32_t* inner,
                                   uint32_t* outer) {
    if (!burst_len || !inner || !outer || len == 0 || (len % 4) != 0)
        return false;
    const unsigned cands[] = {16, 8, 4, 2, 1};
    for (unsigned b : cands) {
        const uint32_t bpb = 4u * b;
        if ((len % bpb) != 0)
            continue;
        const uint32_t n_iters = static_cast<uint32_t>(len / bpb);
        if (pl330FactorLoops(n_iters, inner, outer)) {
            *burst_len = b;
            return true;
        }
    }
    return false;
}

// Encode channel program. Loop body is one DMALD+DMAST per burst beat set.
// Nested LC1 (outer) then LC0 (inner). Returns byte length or 0.
inline size_t pl330BuildMem2MemProgramLoops(uint8_t* out, size_t out_cap, uint32_t src,
                                            uint32_t dst, uint32_t ccr, uint32_t inner,
                                            uint32_t outer) {
    if (!out || out_cap < 40 || inner == 0 || inner > 256 || outer == 0 || outer > 256)
        return 0;
    size_t o = 0;
    auto emit = [&](uint8_t b) {
        if (o < out_cap)
            out[o++] = b;
    };
    auto emit32 = [&](uint32_t v) {
        emit(static_cast<uint8_t>(v));
        emit(static_cast<uint8_t>(v >> 8));
        emit(static_cast<uint8_t>(v >> 16));
        emit(static_cast<uint8_t>(v >> 24));
    };
    // DMAMOV SAR / CCR / DAR
    emit(0xBC);
    emit(0x00);
    emit32(src);
    emit(0xBC);
    emit(0x01);
    emit32(ccr);
    emit(0xBC);
    emit(0x02);
    emit32(dst);

    // Outer first when nested (LC1), then LC0.
    if (outer > 1) {
        emit(0x22); // DMALP LC1
        emit(static_cast<uint8_t>(outer - 1));
    }
    emit(0x20); // DMALP LC0
    emit(static_cast<uint8_t>(inner - 1));
    emit(0x04); // DMALD
    emit(0x08); // DMAST
    // LPEND LC0: bjump over DMALD+DMAST = 2
    emit(0x38);
    emit(0x02);
    if (outer > 1) {
        // LPEND LC1: body = DMALP_LC0(2)+DMALD(1)+DMAST(1)+LPEND_LC0(2) = 6
        emit(0x3C);
        emit(0x06);
    }
    emit(0x34); // DMASEV 0
    emit(0x00);
    emit(0x00); // DMAEND
    return o;
}

// Back-compat: n_words of burst-1 (4 B) transfers.
inline size_t pl330BuildMem2MemProgram(uint8_t* out, size_t out_cap, uint32_t src, uint32_t dst,
                                       uint32_t ccr, uint32_t n_words) {
    uint32_t inner = 0, outer = 0;
    if (!pl330FactorLoops(n_words, &inner, &outer))
        return 0;
    return pl330BuildMem2MemProgramLoops(out, out_cap, src, dst, ccr, inner, outer);
}

// Full-frame encode: auto burst + nested loops. out_burst receives chosen burst.
inline size_t pl330BuildMem2MemProgramAuto(uint8_t* out, size_t out_cap, uint32_t src, uint32_t dst,
                                           size_t len, unsigned* out_burst = nullptr) {
    unsigned burst = 1;
    uint32_t inner = 0, outer = 0;
    if (!pl330PickBurstAndLoops(len, &burst, &inner, &outer))
        return 0;
    const uint32_t ccr = pl330BuildCcrBurst(burst);
    if (!ccr)
        return 0;
    if (out_burst)
        *out_burst = burst;
    return pl330BuildMem2MemProgramLoops(out, out_cap, src, dst, ccr, inner, outer);
}

class Pl330Mem2Mem {
public:
    ~Pl330Mem2Mem() { close(); }

    bool open(std::string* err = nullptr) {
        close();
        fd_ = ::open("/dev/mem", O_RDWR | O_SYNC | O_CLOEXEC);
        if (fd_ < 0) {
            if (err)
                *err = "pl330: open /dev/mem failed";
            return false;
        }
        map_ = ::mmap(nullptr, kPl330MapLen, PROT_READ | PROT_WRITE, MAP_SHARED, fd_,
                      static_cast<off_t>(kPl330NsBasePhys));
        if (map_ == MAP_FAILED) {
            map_ = nullptr;
            ::close(fd_);
            fd_ = -1;
            if (err)
                *err = "pl330: mmap DMAC failed";
            return false;
        }
        // Fixed ABI scratch in reserved window (PA known by construction).
        scratch_map_ = ::mmap(nullptr, kPl330AbiRegionBytes, PROT_READ | PROT_WRITE, MAP_SHARED,
                              fd_, static_cast<off_t>(kPl330AbiRegionPhys));
        if (scratch_map_ == MAP_FAILED) {
            scratch_map_ = nullptr;
            ::munmap(map_, kPl330MapLen);
            map_ = nullptr;
            ::close(fd_);
            fd_ = -1;
            if (err)
                *err = "pl330: mmap ABI scratch/staging failed";
            return false;
        }
        prog_scratch_phys_ = kPl330ProgScratchPhys;
        prog_scratch_virt_ = scratch_map_;
        staging_phys_ = kPl330StagingPhys;
        staging_virt_ = static_cast<uint8_t*>(scratch_map_) + kPl330ProgScratchBytes;
        return true;
    }

    void close() {
        if (scratch_map_ && scratch_map_ != MAP_FAILED) {
            ::munmap(scratch_map_, kPl330AbiRegionBytes);
            scratch_map_ = nullptr;
        }
        prog_scratch_virt_ = nullptr;
        staging_virt_ = nullptr;
        prog_scratch_phys_ = 0;
        staging_phys_ = 0;
        if (map_ && map_ != MAP_FAILED) {
            ::munmap(map_, kPl330MapLen);
            map_ = nullptr;
        }
        if (fd_ >= 0) {
            ::close(fd_);
            fd_ = -1;
        }
    }

    bool isOpen() const { return map_ != nullptr && scratch_map_ != nullptr; }

    uint32_t progScratchPhys() const { return prog_scratch_phys_; }
    void* progScratchVirt() const { return prog_scratch_virt_; }
    uint32_t stagingPhys() const { return staging_phys_; }
    void* stagingVirt() const { return staging_virt_; }

    // Copy host bytes into contiguous staging (PA = kPl330StagingPhys).
    bool loadStaging(const void* src, size_t len, std::string* err = nullptr) {
        if (!staging_virt_ || !src || len == 0 || len > kPl330StagingBytes) {
            if (err)
                *err = "pl330: staging load rejected";
            return false;
        }
        std::memcpy(staging_virt_, src, len);
        __sync_synchronize();
        return true;
    }

    uint32_t read32(uint32_t off) const {
        if (!map_)
            return 0;
        return *reinterpret_cast<volatile uint32_t*>(static_cast<uint8_t*>(map_) + off);
    }

    void write32(uint32_t off, uint32_t v) {
        if (!map_)
            return;
        *reinterpret_cast<volatile uint32_t*>(static_cast<uint8_t*>(map_) + off) = v;
    }

    // Probe only — does not start a channel.
    Pl330Mem2MemResult probe() {
        Pl330Mem2MemResult r;
        if (!map_) {
            r.detail = "not open";
            return r;
        }
        r.dsr = read32(kPl330_DSR);
        r.cr0 = read32(kPl330_CR0);
        // CR0 should report channel count; zero often means wrong map / powered down.
        r.hardware_present = (r.cr0 != 0 && r.cr0 != 0xFFFFFFFFu);
        r.detail = r.hardware_present ? "pl330 cr0 ok" : "pl330 cr0 empty";
        r.ok = r.hardware_present;
        return r;
    }

    // Execute blocking mem2mem. len must be multiple of 4.
    // Prefers one microcode program (burst 8/16 + nested LC1/LC0). Falls back to
    // burst-1 1 KiB chunks only if auto encode fails.
    Pl330Mem2MemResult transferBlocking(const Pl330Mem2MemRequest& req, int timeout_ms = 50) {
        Pl330Mem2MemResult r = probe();
        if (!r.hardware_present)
            return r;
        if (req.src_phys == 0 || req.dst_phys == 0 || req.len == 0 || (req.len % 4) != 0) {
            r.ok = false;
            r.detail = "bad src/dst/len";
            return r;
        }
        // Full-frame / large: single program when burst+loops factor.
        {
            auto one = transferOneBlockAuto(req, timeout_ms);
            if (one.ok || one.channel_started) {
                if (one.ok)
                    one.detail = std::string("auto ") + one.detail;
                return one;
            }
            // Fall through to chunked if encode/start failed before DMA.
            if (one.detail.find("program") == std::string::npos &&
                one.detail != "needs_prog_scratch_phys") {
                // Fault/timeout on auto — do not silently chunk (could double-write).
                return one;
            }
            if (one.detail == "needs_prog_scratch_phys")
                return one;
        }
        // Chunked burst-1 fallback (256 words = 1024 B).
        size_t done = 0;
        int ch = req.channel;
        while (done < req.len) {
            size_t chunk = req.len - done;
            if (chunk > 256u * 4u)
                chunk = 256u * 4u;
            Pl330Mem2MemRequest sub = req;
            sub.src_phys = req.src_phys + static_cast<uint32_t>(done);
            sub.dst_phys = req.dst_phys + static_cast<uint32_t>(done);
            sub.len = chunk;
            sub.channel = ch;
            auto one = transferOneBlock(sub, timeout_ms);
            if (!one.ok) {
                r = one;
                return r;
            }
            done += chunk;
            r = one;
        }
        r.ok = true;
        r.detail = "chunked ok";
        return r;
    }

private:
    // Debug-instruction go: DMAGO for channel with PC in DBGINST1.
    // We place program in a small bounce buffer in *destination bank prefix* —
    // NOT used. Instead: use DMAMOV via debug for SAR/DAR/CCR then loop DMALD/DMAST
    // via repeated DBGINST — too slow.
    //
    // Practical v1: use first 64 bytes of a dedicated program buffer at
    // dst_phys is frame data — cannot overwrite. Require caller to supply
    // program buffer via transferOneBlock embedding in DMAC insn FIFO using
    // DMAGO with instructions fed through DBGINST0 as non-secure manager.
    //
    // Simpler reliable path used here: **CPU does not claim full microcode load**.
    // We expose descriptor build + probe; transferOneBlock attempts DMAGO with
    // inline DMAMOV sequence via debug for very small transfers only, else
    // returns not-implemented for full frame so bench reports honestly.
    Pl330Mem2MemResult goProgram(const uint8_t* prog, size_t plen, int channel, int timeout_ms,
                                 const char* tag) {
        Pl330Mem2MemResult r;
        r.hardware_present = true;
        r.cr0 = read32(kPl330_CR0);
        r.dsr = read32(kPl330_DSR);
        if (!prog || plen == 0) {
            r.detail = "program encode failed";
            return r;
        }
        if (prog_scratch_phys_ == 0 || !prog_scratch_virt_) {
            r.ok = false;
            r.detail = "needs_prog_scratch_phys";
            r.channel_started = false;
            return r;
        }
        if (plen > kPl330ProgScratchBytes) {
            r.detail = "program exceeds scratch";
            return r;
        }
        std::memcpy(prog_scratch_virt_, prog, plen);
        if (plen < 64)
            std::memset(static_cast<uint8_t*>(prog_scratch_virt_) + plen, 0, 64 - plen);
        __sync_synchronize();

        const int ch = (channel >= 0 && channel < 8) ? channel : 0;
        for (int i = 0; i < 10000; ++i) {
            if ((read32(kPl330_DBGSTATUS) & 1u) == 0)
                break;
            if (i == 9999) {
                r.detail = "dbgstatus sticky busy";
                return r;
            }
        }
        const uint32_t ns = 0;
        const uint32_t inst0 = (0u << 16) | (static_cast<uint32_t>(ch) << 8) | (0xA0u | (ns << 1));
        write32(kPl330_DBGINST0, inst0);
        write32(kPl330_DBGINST1, prog_scratch_phys_);
        write32(kPl330_DBGCMD, 0);
        r.channel_started = true;
        r.channel_used = ch;

        const uint32_t csr_off = kPl330_CSR0 + static_cast<uint32_t>(ch) * 8u;
        // Busy-spin first ~2 ms, then usleep — full-frame must not pay 10us/chunk tax.
        const int spins = timeout_ms * 200;
        for (int i = 0; i < spins; ++i) {
            const uint32_t csr = read32(csr_off);
            if ((csr & 0xFu) == 0) {
                r.ok = true;
                r.detail = tag ? tag : "dma stopped ok";
                return r;
            }
            if (read32(kPl330_FSRC) & (1u << ch)) {
                r.detail = "channel fault";
                r.ok = false;
                return r;
            }
            if (i > 400)
                usleep(10);
        }
        r.detail = "timeout";
        r.ok = false;
        return r;
    }

    Pl330Mem2MemResult transferOneBlock(const Pl330Mem2MemRequest& req, int timeout_ms) {
        uint8_t prog[64];
        const uint32_t ccr = pl330BuildCcr(req.len);
        const uint32_t n_words = static_cast<uint32_t>(req.len / 4);
        const size_t plen =
            pl330BuildMem2MemProgram(prog, sizeof(prog), req.src_phys, req.dst_phys, ccr, n_words);
        return goProgram(prog, plen, req.channel, timeout_ms, "burst1 stopped ok");
    }

    Pl330Mem2MemResult transferOneBlockAuto(const Pl330Mem2MemRequest& req, int timeout_ms) {
        uint8_t prog[64];
        unsigned burst = 0;
        const size_t plen = pl330BuildMem2MemProgramAuto(prog, sizeof(prog), req.src_phys,
                                                         req.dst_phys, req.len, &burst);
        if (plen == 0) {
            Pl330Mem2MemResult r;
            r.hardware_present = true;
            r.detail = "program encode failed";
            return r;
        }
        char tag[40];
        std::snprintf(tag, sizeof(tag), "burst%u stopped ok", burst);
        return goProgram(prog, plen, req.channel, timeout_ms, tag);
    }

public:
    void setProgramScratch(uint32_t phys, void* virt) {
        prog_scratch_phys_ = phys;
        prog_scratch_virt_ = virt;
    }

    // Descriptor-only path for unit tests (no /dev/mem).
    static bool encodeProgramForTest(uint8_t* out, size_t cap, size_t* out_len, uint32_t src,
                                     uint32_t dst, size_t len) {
        unsigned burst = 0;
        const size_t n = pl330BuildMem2MemProgramAuto(out, cap, src, dst, len, &burst);
        if (!n) {
            // Tiny lens may only fit burst-1 single LC0.
            const uint32_t ccr = pl330BuildCcr(len);
            if (!ccr)
                return false;
            const size_t n2 = pl330BuildMem2MemProgram(out, cap, src, dst, ccr,
                                                       static_cast<uint32_t>(len / 4));
            if (!n2)
                return false;
            if (out_len)
                *out_len = n2;
            return true;
        }
        if (out_len)
            *out_len = n;
        (void)burst;
        return true;
    }

    // ABI constants visible to tests without /dev/mem.
    static uint32_t abiProgScratchPhys() { return kPl330ProgScratchPhys; }
    static uint32_t abiStagingPhys() { return kPl330StagingPhys; }

private:
    int fd_ = -1;
    void* map_ = nullptr;
    void* scratch_map_ = nullptr;
    uint32_t prog_scratch_phys_ = 0;
    void* prog_scratch_virt_ = nullptr;
    uint32_t staging_phys_ = 0;
    void* staging_virt_ = nullptr;
};

// Resolve first page phys for a user pointer via /proc/self/pagemap.
// Returns 0 on failure. Requires CAP_SYS_ADMIN on many kernels.
inline uint32_t pl330ResolveUserPhys(const void* virt) {
    if (!virt)
        return 0;
    const uintptr_t v = reinterpret_cast<uintptr_t>(virt);
    const uintptr_t page = v & ~static_cast<uintptr_t>(4095);
    const uintptr_t off = v - page;
    const long idx = static_cast<long>(page / 4096u);
    const int fd = ::open("/proc/self/pagemap", O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return 0;
    uint64_t entry = 0;
    if (::lseek(fd, idx * static_cast<off_t>(sizeof(entry)), SEEK_SET) < 0) {
        ::close(fd);
        return 0;
    }
    if (::read(fd, &entry, sizeof(entry)) != static_cast<ssize_t>(sizeof(entry))) {
        ::close(fd);
        return 0;
    }
    ::close(fd);
    if ((entry & (1ull << 63)) == 0)
        return 0; // not present
    const uint64_t pfn = entry & ((1ull << 55) - 1);
    if (pfn == 0)
        return 0;
    return static_cast<uint32_t>((pfn << 12) | off);
}

// True if len spans a single page-aligned physically contiguous region
// (simple check: all pages present and sequential PFNs) — v1: single page only.
inline bool pl330UserRangeSinglePage(const void* virt, size_t len) {
    if (!virt || len == 0)
        return false;
    const uintptr_t v = reinterpret_cast<uintptr_t>(virt);
    return ((v & 4095u) + len) <= 4096u;
}

} // namespace misterplex
