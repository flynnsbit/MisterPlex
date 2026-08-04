// PLXA self-describing map — positive accept + NEGATIVE version mismatch.
#include "libmisterplex/plxa_map.hpp"

#include <cstdio>

using namespace misterplex::plxa;

static int fails = 0;
#define CHECK(cond) do { \
  if (!(cond)) { \
    std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
    ++fails; \
  } \
} while (0)

int main() {
    MapWord m;

    // Bad magic
    CHECK(!decodePlxaWord(0xDEADBEEFull, m));
    CHECK(acceptPlxa(m) == AcceptStatus::BadMagic);

    // Positive: version match + has_plxd + relative offset 0x128
    const uint64_t good =
        packPlxaWord(kPlxaAbiVersion, kFlagDoorbellRelative | kFlagHasPlxd, 0x0128);
    CHECK(decodePlxaWord(good, m));
    CHECK(m.version == kPlxaAbiVersion);
    CHECK((m.flags & kFlagHasPlxd) != 0);
    CHECK(m.plxd_offset == 0x0128);
    CHECK(acceptPlxa(m) == AcceptStatus::Ok);

    // NEGATIVE (the point of this gate): core advertises a future/past version
    const uint64_t wrong_ver =
        packPlxaWord(static_cast<uint8_t>(kPlxaAbiVersion + 1), kFlagHasPlxd, 0x0128);
    CHECK(decodePlxaWord(wrong_ver, m));
    CHECK(m.ok_magic);
    CHECK(acceptPlxa(m) == AcceptStatus::VersionMismatch);
    CHECK(acceptPlxa(m, kPlxaAbiVersion) == AcceptStatus::VersionMismatch);

    // Also fail if magic ok but PLXD capability bit clear (pre-PLXD RBF class)
    const uint64_t no_plxd = packPlxaWord(kPlxaAbiVersion, 0, 0);
    CHECK(decodePlxaWord(no_plxd, m));
    CHECK(acceptPlxa(m) == AcceptStatus::MissingPlxdCapability);

    // Host expected-version pin: accepting only version 0 must reject v1
    CHECK(decodePlxaWord(good, m));
    CHECK(acceptPlxa(m, /*expected_version=*/0) == AcceptStatus::VersionMismatch);

    // resolvePlxdPhys: relative vs absolute
    CHECK(decodePlxaWord(good, m));
    CHECK(resolvePlxdPhys(m, /*doorbell=*/0x300FF000u, /*fallback=*/0x3007F128u) ==
          0x300FF128u);
    const uint64_t abs_map =
        packPlxaWord(kPlxaAbiVersion, kFlagHasPlxd, /*off ignored*/ 0);
    CHECK(decodePlxaWord(abs_map, m));
    CHECK(resolvePlxdPhys(m, 0x300FF000u, 0x3007F128u) == 0x3007F128u);

    // NEGATIVE: wrong version must not be used to resolve a live address
    CHECK(decodePlxaWord(wrong_ver, m));
    CHECK(acceptPlxa(m) == AcceptStatus::VersionMismatch);
    // Host path must refuse before resolve; document the invariant here.
    CHECK(acceptPlxa(m) != AcceptStatus::Ok);

    if (fails) {
        std::fprintf(stderr, "test_plxa_map: %d failure(s)\n", fails);
        return 1;
    }
    std::printf("test_plxa_map: OK (version_mismatch + resolve exercised)\n");
    return 0;
}
