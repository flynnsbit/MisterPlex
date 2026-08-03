// PLXD runtime discovery — positive (magic present at a candidate) + negative
// (magic absent everywhere must FAIL).
#include "libmisterplex/plxd_discover.hpp"

#include <cstdint>
#include <cstdio>

using namespace misterplex;

static int fails = 0;
#define CHECK(cond) do { \
  if (!(cond)) { \
    std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
    ++fails; \
  } \
} while (0)

static uint64_t pack_plxd(uint8_t fbm, uint8_t db, bool sp, uint16_t fd) {
  return static_cast<uint64_t>(mailbox_abi::kPlxdMagic) |
         (static_cast<uint64_t>(fbm & 3u) << 32) |
         (static_cast<uint64_t>(db & 1u) << 34) |
         (static_cast<uint64_t>(sp ? 1u : 0u) << 35) |
         (static_cast<uint64_t>(fd) << 48);
}

int main() {
  // --- NEGATIVE: empty map, no magic anywhere ---
  {
    const uint64_t words[] = {0};
    const uint32_t addrs[] = {0};
    auto r = discoverPlxdInImage(words, addrs, 0);
    CHECK(!r.found);
    CHECK(r.phys_addr == 0);
  }

  // --- NEGATIVE: wrong magic at every candidate ---
  {
    const uint32_t addrs[] = {
        kPlxdCandidatePhys[0], kPlxdCandidatePhys[1],
        kPlxdCandidatePhys[2], kPlxdCandidatePhys[3],
    };
    const uint64_t words[] = {
        0x504C584Bull, // PLXK, not PLXD
        0xDEADBEEFull,
        0ull,
        pack_plxd(2, 0, false, 1) ^ 1ull, // corrupted magic
    };
    auto r = discoverPlxdInImage(words, addrs, 4);
    CHECK(!r.found);
  }

  // --- POSITIVE: main absolute 0x3007F128 ---
  {
    const uint32_t addrs[] = {mailbox_abi::kPlxdAddr};
    const uint64_t words[] = {pack_plxd(0x2, 0, false, 7)};
    auto r = discoverPlxdInImage(words, addrs, 1);
    CHECK(r.found);
    CHECK(r.phys_addr == 0x3007F128u);
    CHECK(r.status.free_bank_mask == 0x2);
    CHECK(r.status.disp_bank == 0);
    CHECK(r.status.frames_done == 7);
    CHECK(r.candidate_index == 0);
  }

  // --- POSITIVE: product doorbell-relative 0x300FF128 only ---
  {
    const uint32_t addrs[] = {kPlxdDoorbellProduct + 0x128u};
    const uint64_t words[] = {pack_plxd(0x1, 1, false, 99)};
    auto r = discoverPlxdInImage(words, addrs, 1);
    CHECK(r.found);
    CHECK(r.phys_addr == 0x300FF128u);
    CHECK(r.status.free_bank_mask == 0x1);
    CHECK(r.status.disp_bank == 1);
    CHECK(r.candidate_index == 1);
  }

  // --- POSITIVE: Option-C 0x3047F128 only ---
  {
    const uint32_t addrs[] = {kPlxdDoorbellOptionC + 0x128u};
    const uint64_t words[] = {pack_plxd(0x3, 0, false, 1)};
    auto r = discoverPlxdInImage(words, addrs, 1);
    CHECK(r.found);
    CHECK(r.phys_addr == 0x3047F128u);
    CHECK(r.candidate_index == 2);
  }

  // --- Preference: absolute wins when both live ---
  {
    const uint32_t addrs[] = {
        mailbox_abi::kPlxdAddr,
        kPlxdDoorbellProduct + 0x128u,
    };
    const uint64_t words[] = {
        pack_plxd(0x2, 0, false, 1),
        pack_plxd(0x1, 1, false, 2),
    };
    auto r = discoverPlxdInImage(words, addrs, 2);
    CHECK(r.found);
    CHECK(r.phys_addr == 0x3007F128u);
    CHECK(r.candidate_index == 0);
  }

  // --- Torn read rejected (w0 != w1 via alternating fake mem) ---
  {
    int calls = 0;
    auto r = discoverPlxdMailbox([&](uint32_t phys, uint64_t& word) -> bool {
      if (phys != 0x3007F128u)
        return false;
      // Alternate two different valid-looking words → unstable
      word = (calls++ & 1) ? pack_plxd(0x1, 0, false, 1)
                           : pack_plxd(0x2, 0, false, 2);
      return true;
    });
    CHECK(!r.found);
  }

  if (fails) {
    std::fprintf(stderr, "test_plxd_discover: %d failure(s)\n", fails);
    return 1;
  }
  std::printf("test_plxd_discover: OK\n");
  return 0;
}
