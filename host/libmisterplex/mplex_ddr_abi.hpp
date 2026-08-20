#pragma once
#include <cstdint>
#include <sys/ioctl.h>

// Cached 2×2MiB contig slots from kmod/mplex_ddr (alloc_pages order 9).
// FPGA L4 DYN_BASE_EN=1 reads these PAs. Userspace PL330 poke stays banned.
namespace misterplex {

constexpr unsigned long kMplexCachedPgoff = 0x800UL; // pages; mmap offset 8MiB
constexpr uint32_t kMplexCachedSlotBytes = 2u * 1024u * 1024u;

struct MplexCachedPhys {
    uint32_t phys[2];
    uint32_t slot_bytes;
};

constexpr unsigned kMplexIocMagic = 'M';
#define MPLEX_IOC_CACHED_PHYS _IOR('M', 1, misterplex::MplexCachedPhys)

} // namespace misterplex
