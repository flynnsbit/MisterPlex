// Red-before-green: PLXG q5 aspect+cadence pack + selection (w-path ABI #2).
//
// Negative cases a naive wrong implementation must fail:
//   1) non-zero reserved [63:34] → receiver reject
//   2) unknown DAR/fps → valid bits clear (must NOT invent 16:9 or 24)
//   3) storage-aspect fallback on 720×480 without SAR → must stay invalid
//   4) wire offset of q5 is 0x828 (sixth qword), not still 5-qword-only

#include "libmisterplex/plxg_q5_aspect_cadence.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

using namespace misterplex;

static int g_fails = 0;

static void expect(bool cond, const char* msg) {
    if (!cond) {
        std::fprintf(stderr, "FAIL: %s\n", msg);
        ++g_fails;
    } else {
        std::fprintf(stderr, "ok: %s\n", msg);
    }
}

static void test_offsets() {
    expect(kPlxgQ5ByteOffset == 0x828u, "q5 wire offset is 0x828");
    expect(kPlxgQ5Index == 5u, "q5 is index 5");
    expect(kPlxgRecordQwordsAspectCadence == 6u, "record grows to 6 qwords");
    expect(kPlxgRecordBytesAspectCadence == 48u, "record is 48 bytes");
    // Red twin vs old 5-qword (40 B) ABI.
    expect(kPlxgRecordBytesAspectCadence != 40u, "red: not still 5-qword/40B");
}

static void test_pack_16x9_24() {
    PlxgAspectCadence c{};
    c.dar_x = 16;
    c.dar_y = 9;
    c.content_fps = 24;
    c.dar_valid = true;
    c.fps_valid = true;
    uint64_t q = 0;
    expect(packPlxgQ5(c, &q), "pack 16:9@24 ok");
    expect(plxgQ5ReceiverAccepts(q), "receiver accepts clean q5");
    expect((q & 0xFFFull) == 16, "dar_x=16");
    expect(((q >> 12) & 0xFFFull) == 9, "dar_y=9");
    expect(((q >> 24) & 0xFFull) == 24, "fps=24");
    expect(((q >> 32) & 1ull) == 1, "dar_valid set");
    expect(((q >> 33) & 1ull) == 1, "fps_valid set");
    expect((q >> 34) == 0, "reserved zero");

    PlxgAspectCadence u{};
    expect(unpackPlxgQ5(q, &u), "unpack ok");
    expect(u.dar_x == 16 && u.dar_y == 9 && u.content_fps == 24, "round-trip fields");
    expect(u.dar_valid && u.fps_valid, "round-trip valids");
}

static void test_reserved_reject_red_twin() {
    // Inject a non-zero reserved bit (bit 34).
    const uint64_t dirty = (1ull << 34);
    expect(!plxgQ5ReservedOk(dirty), "red: reserved bit 34 fails reservedOk");
    expect(!plxgQ5ReceiverAccepts(dirty), "red: receiver rejects reserved nonzero");
    PlxgAspectCadence u{};
    expect(!unpackPlxgQ5(dirty, &u), "red: unpack rejects reserved nonzero");

    // Clean pack must never set reserved.
    PlxgAspectCadence c{};
    c.dar_valid = true;
    c.dar_x = 4;
    c.dar_y = 3;
    uint64_t q = ~0ull;
    expect(packPlxgQ5(c, &q), "pack 4:3");
    expect((q >> 34) == 0, "pack never sets reserved");
}

static void test_unknown_no_invent_red_twin() {
    // Empty aspect + unknown fps → both valid clear. Naive default 16:9/24 fails.
    const auto c = selectPlxgAspectCadence(624, 480, "", "", 0, 0);
    expect(!c.dar_valid, "unknown DAR → dar_valid=0");
    expect(!c.fps_valid, "unknown fps → fps_valid=0");
    expect(c.dar_x == 0 && c.dar_y == 0, "no invented dar nums");
    expect(c.content_fps == 0, "no invented fps=24");

    uint64_t q = 0xdeadbeefull;
    expect(packPlxgQ5(c, &q), "pack unknown");
    expect(((q >> 32) & 1ull) == 0, "packed dar_valid=0");
    expect(((q >> 33) & 1ull) == 0, "packed fps_valid=0");
    expect((q & 0xFFFFFFFFull) == 0, "low32 zero when unknown");
}

static void test_no_storage_aspect_fallback_720x480() {
    // 720×480 without SAR/media — storage AR is 3:2, NOT DAR. Must stay invalid.
    const auto c = selectPlxgAspectCadence(720, 480, "", "", 0, 0);
    expect(!c.dar_valid, "red: 720x480 storage AR must not set dar_valid");
    // Contrast: with SAR 8:9 (NTSC anamorphic 16:9), DAR becomes 16:9.
    const auto d = selectPlxgAspectCadence(720, 480, "8:9", "", 0, 0);
    expect(d.dar_valid, "SAR 8:9 on 720x480 → dar_valid");
    // 720/480 * 8/9 = 5760/4320 = 4/3? Wait: 720*8 : 480*9 = 5760:4320 = 4:3
    // Classic NTSC DVD anamorphic 16:9 is often 32:27 SAR on 720x480:
    // 720*32 : 480*27 = 23040:12960 = 16:9
    const auto e = selectPlxgAspectCadence(720, 480, "32:27", "", 30000, 1001);
    expect(e.dar_valid && e.dar_x == 16 && e.dar_y == 9, "32:27 → 16:9");
    expect(e.fps_valid && e.content_fps == 30, "30000/1001 → fps=30");
}

static void test_lab_624x350_sar_160_117() {
    // Coded*SAR math: 624*160 : 350*117 = 99840:40950 = 256:105.
    // NOTE: ebec8ab3's "16:9 exactly" used (624/480)*(160/117) — display box
    // height 480, not coded 350. PLXG must use measured coded size, not invent 480.
    const auto c = selectPlxgAspectCadence(624, 350, "160:117", "", 24000, 1001);
    expect(c.dar_valid, "624x350+160:117 dar_valid");
    expect(c.dar_x == 256 && c.dar_y == 105, "624x350+160:117 → 256:105 (coded*SAR)");
    expect(c.fps_valid && c.content_fps == 24, "24000/1001 → 24");
    // When Media@aspectRatio carries display intent, use it if SAR absent.
    const auto m = selectPlxgAspectCadence(624, 350, "", "1.78", 24000, 1001);
    expect(m.dar_valid && m.dar_x == 89 && m.dar_y == 50, "media 1.78 → 89/50");
}

static void test_media_aspect_decimal() {
    const auto c = selectPlxgAspectCadence(0, 0, "", "1.78", 24, 1);
    expect(c.dar_valid, "media 1.78 dar_valid");
    // 178/100 → 89/50
    expect(c.dar_x == 89 && c.dar_y == 50, "1.78 → 89/50");
    expect(c.fps_valid && c.content_fps == 24, "integer 24");
}

static void test_fps_families() {
    uint8_t f = 0;
    expect(contentFpsIntegerForPlxg(24, 1, &f) && f == 24, "24/1");
    expect(contentFpsIntegerForPlxg(25, 1, &f) && f == 25, "25/1");
    expect(contentFpsIntegerForPlxg(30, 1, &f) && f == 30, "30/1");
    expect(contentFpsIntegerForPlxg(24000, 1001, &f) && f == 24, "23.976→24");
    expect(contentFpsIntegerForPlxg(30000, 1001, &f) && f == 30, "29.97→30");
    expect(!contentFpsIntegerForPlxg(0, 1, &f), "0 fps unknown");
    expect(!contentFpsIntegerForPlxg(12, 5, &f), "2.4 fps not a family → unknown");
}

int main() {
    test_offsets();
    test_pack_16x9_24();
    test_reserved_reject_red_twin();
    test_unknown_no_invent_red_twin();
    test_no_storage_aspect_fallback_720x480();
    test_lab_624x350_sar_160_117();
    test_media_aspect_decimal();
    test_fps_families();
    if (g_fails) {
        std::fprintf(stderr, "test_plxg_q5_aspect_cadence: %d FAIL(s)\n", g_fails);
        return 1;
    }
    std::fprintf(stderr, "test_plxg_q5_aspect_cadence: PASS\n");
    return 0;
}
