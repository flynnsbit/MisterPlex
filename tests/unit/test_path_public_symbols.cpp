// Red twin: merge that drops w-path public symbols must fail compile or this test.
#include "libmisterplex/path_public_symbols.hpp"
#include "libmisterplex/pms_delivery_geom.hpp"

#include <cstdio>
#include <cstring>
#include <string>

using namespace misterplex;

static int g_fails = 0;
static void expect(bool c, const char* m) {
    if (!c) {
        std::fprintf(stderr, "FAIL: %s\n", m);
        ++g_fails;
    } else {
        std::fprintf(stderr, "ok: %s\n", m);
    }
}

int main() {
    const char* rc = path_symbols::pathPublicSymbolRollCall();
    expect(rc && std::strcmp(rc, "path_public_symbols_ok") == 0, "roll-call ok");

    // Concrete behaviour — not just linkage.
    const auto s360 = ddrStorageGeometryForContent(640, 360);
    expect(s360.coded_width.get() == 640 && s360.coded_height.get() == 360, "360 storage identity");
    const auto f360 = ddrFfmpegGeometryForPresent(640, 360);
    expect(f360.coded_width.get() == 640 && f360.coded_height.get() == 360, "ffmpeg alias 360");
    const auto s540 = ddrFfmpegGeometryForPresent(960, 540);
    expect(s540.coded_width.get() == 960 && s540.coded_height.get() == 540, "540 storage identity");

    // rd-duck: native classes must NOT fall back to 624x480 canvas.
    const auto n320 = ddrStorageGeometryForContent(320, 240);
    expect(n320.coded_width.get() == 320 && n320.coded_height.get() == 240, "native 320x240");
    const auto n720 = ddrStorageGeometryForContent(720, 480);
    expect(n720.coded_width.get() == 720 && n720.coded_height.get() == 480, "native 720x480");
    const auto n416 = ddrStorageGeometryForContent(416, 234);
    expect(n416.coded_width.get() == 416 && n416.coded_height.get() == 234, "native 416x234");
    const auto n352 = ddrStorageGeometryForContent(624, 352);
    expect(n352.coded_width.get() == 624 && n352.coded_height.get() == 352, "native 624x352");
    // Unaligned 426 → pad store (align-up), not silent 624 canvas.
    const auto n426 = ddrStorageGeometryForContent(426, 240);
    expect(n426.coded_width.get() == 432 && n426.coded_height.get() == 240,
           "unaligned 426 pads to 432x240");
    expect(n320.coded_width.get() != 624, "red: 320 must not become 624 canvas");

    // 360p constants greppable and consistent.
    expect(kPlex360pCodedWidth.get() == 640, "kPlex360pCodedWidth");
    expect(kPlex360pCodedHeight.get() == 360, "kPlex360pCodedHeight");

    // PLXG q5 still present.
    expect(kPlxgQ5ByteOffset == 0x828u, "q5 @0x828");
    PlxgAspectCadence c{};
    c.dar_valid = true;
    c.dar_x = 16;
    c.dar_y = 9;
    uint64_t q = 0;
    expect(packPlxgQ5(c, &q) && (q & 0xFFF) == 16, "packPlxgQ5");

    // Source-aware selector still linked.
    const auto sa = selectSourceAwarePmsRequest(624, 480, 960, 540);
    expect(sa.request_w == 624 && sa.request_h == 480 && sa.store_w == 624,
           "source-aware 624x480");

    if (g_fails) {
        std::fprintf(stderr, "test_path_public_symbols: %d FAIL\n", g_fails);
        return 1;
    }
    std::fprintf(stderr, "test_path_public_symbols: PASS\n");
    return 0;
}
