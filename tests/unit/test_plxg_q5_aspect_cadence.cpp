// Red-before-green: PLXG q5 aspect+cadence pack + selection (w-path ABI #2/#2.1).
//
// Negative cases a naive wrong implementation must fail:
//   1) non-zero reserved [63:35] → receiver reject
//   2) unknown DAR/fps → valid bits clear (must NOT invent 16:9 or 24)
//   3) storage-aspect fallback on 720×480 without SAR → must stay invalid
//   4) wire offset of q5 is 0x828 (sixth qword), not still 5-qword-only
//   5) 24000/1001 must set fps_1001 (integer-only bucket cannot certify film)

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
    expect(((q >> 34) & 1ull) == 0, "fps_1001 clear for integer 24");
    expect((q >> 35) == 0, "reserved [63:35] zero");

    PlxgAspectCadence u{};
    expect(unpackPlxgQ5(q, &u), "unpack ok");
    expect(u.dar_x == 16 && u.dar_y == 9 && u.content_fps == 24, "round-trip fields");
    expect(u.dar_valid && u.fps_valid && !u.fps_1001, "round-trip valids");
}

static void test_reserved_reject_red_twin() {
    // Inject a non-zero reserved bit (bit 35+). Bit 34 is fps_1001 (defined).
    const uint64_t dirty = (1ull << 35);
    expect(!plxgQ5ReservedOk(dirty), "red: reserved bit 35 fails reservedOk");
    expect(!plxgQ5ReceiverAccepts(dirty), "red: receiver rejects reserved nonzero");
    PlxgAspectCadence u{};
    expect(!unpackPlxgQ5(dirty, &u), "red: unpack rejects reserved nonzero");

    // fps_1001 alone is legal when fps_valid.
    PlxgAspectCadence ok{};
    ok.fps_valid = true;
    ok.content_fps = 24;
    ok.fps_1001 = true;
    uint64_t qok = 0;
    expect(packPlxgQ5(ok, &qok), "pack 24+1001 ok");
    expect((qok & kPlxgQ5Fps1001Bit) != 0, "bit 34 set for fps_1001");
    expect(plxgQ5ReceiverAccepts(qok), "receiver accepts fps_1001");

    // fps_1001 without fps_valid rejected.
    PlxgAspectCadence bad{};
    bad.fps_1001 = true;
    uint64_t qb = 0;
    expect(!packPlxgQ5(bad, &qb), "red: fps_1001 without fps_valid rejected");

    // Clean pack must never set reserved [63:35].
    PlxgAspectCadence c{};
    c.dar_valid = true;
    c.dar_x = 4;
    c.dar_y = 3;
    uint64_t q = ~0ull;
    expect(packPlxgQ5(c, &q), "pack 4:3");
    expect((q >> 35) == 0, "pack never sets reserved [63:35]");
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

static void test_lab_624x350_dar_provenance() {
    // rd-duck: xcode 624x350 is square-pixel fit; source SAR×350 double-counts.
    const auto bad = selectPlxgAspectCadence(624, 350, "160:117", "1.78", 24000, 1001,
                                             PlxgDarProvenance::DirectPlay);
    expect(bad.dar_valid && bad.dar_x == 256 && bad.dar_y == 105,
           "DP coded×SAR on 350 rows → 256:105 (math only)");

    const auto xc = selectPlxgAspectCadence(624, 350, "160:117", "1.78", 24000, 1001,
                                            PlxgDarProvenance::Transcode);
    expect(xc.dar_valid && xc.dar_x == 89 && xc.dar_y == 50,
           "transcode Media 1.78 → 89/50 NOT 256:105");
    expect(xc.fps_valid && xc.content_fps == 24, "24000/1001 → 24");

    const auto sp = selectPlxgAspectCadence(624, 350, "", "", 24, 1, PlxgDarProvenance::Transcode);
    expect(sp.dar_valid && sp.dar_x == 312 && sp.dar_y == 175,
           "transcode square-pixel 624:350 → 312:175");

    // True DP anamorphic full frame: 624x480 × 160:117 → 16:9.
    const auto dp = selectPlxgAspectCadence(624, 480, "160:117", "", 24000, 1001,
                                            PlxgDarProvenance::DirectPlay);
    expect(dp.dar_valid && dp.dar_x == 16 && dp.dar_y == 9, "DP 624x480×160:117 → 16:9");
}

static void test_media_aspect_decimal() {
    const auto c = selectPlxgAspectCadence(0, 0, "", "1.78", 24, 1);
    expect(c.dar_valid, "media 1.78 dar_valid");
    // 178/100 → 89/50
    expect(c.dar_x == 89 && c.dar_y == 50, "1.78 → 89/50");
    expect(c.fps_valid && c.content_fps == 24, "integer 24");
}

// Mirrors MediaPlayer field refresh order used by main.cpp (rd-duck ordering bug).
// Old main: fps refresh → aspect refresh → provenance assign (NO refresh)
// left q5 packed as DirectPlay 256:105. Require initial pack 89:50 (Media 1.78).
struct PlxgQ5PublishSim {
    bool transcode = false;
    std::string sar;
    std::string mar;
    int w = 0, h = 0, fn = 0, fd = 0;
    PlxgAspectCadence last{};
    uint64_t q5 = 0;

    void refresh() {
        const auto prov =
            transcode ? PlxgDarProvenance::Transcode : PlxgDarProvenance::DirectPlay;
        last = selectPlxgAspectCadence(w, h, transcode ? std::string{} : sar, mar, fn, fd,
                                      prov);
        q5 = 0;
        (void)packPlxgQ5(last, &q5);
    }
    void setProvenanceTranscode(bool t) {
        transcode = t;
        refresh(); // product setter must refresh
    }
    void setFps(int n, int d) {
        fn = n;
        fd = d;
        refresh();
    }
    void setAspect(std::string s, std::string m) {
        sar = std::move(s);
        mar = std::move(m);
        refresh();
    }
};

static void test_main_call_order_624x350_transcode() {
    // Coded delivery claim before banner (scale-source / measured later).
    constexpr int kW = 624, kH = 350;

    // --- RED twin: old main order without provenance refresh ---
    {
        PlxgQ5PublishSim s;
        s.w = kW;
        s.h = kH;
        s.setFps(24000, 1001);                         // refresh as DP
        s.setAspect("160:117", "1.78");                // still DP → 256:105
        s.transcode = true;                            // assign only, NO refresh
        // Stale pack must be the double-applied wrong DAR:
        expect(s.last.dar_valid && s.last.dar_x == 256 && s.last.dar_y == 105,
               "RED old-order stale pack is 256:105 (double SAR)");
        // If someone forgets refresh, last stays wrong — product forbids this.
    }

    // --- GREEN: main order provenance → fps → aspect (each refresh) ---
    {
        PlxgQ5PublishSim s;
        s.w = kW;
        s.h = kH;
        s.setProvenanceTranscode(true); // FIRST
        s.setFps(24000, 1001);
        s.setAspect("160:117", "1.78");
        expect(s.last.dar_valid && s.last.dar_x == 89 && s.last.dar_y == 50,
               "main order: initial q5 DAR 89:50 (Media 1.78) not 256:105");
        expect(!(s.last.dar_x == 256 && s.last.dar_y == 105),
               "main order must not publish 256:105");
        expect(s.last.fps_valid && s.last.content_fps == 24, "main order fps 24");
    }

    // --- GREEN: late provenance still heals if setter refreshes ---
    {
        PlxgQ5PublishSim s;
        s.w = kW;
        s.h = kH;
        s.setFps(24000, 1001);
        s.setAspect("160:117", "1.78"); // wrong DP pack
        expect(s.last.dar_x == 256 && s.last.dar_y == 105, "precondition DP 256:105");
        s.setProvenanceTranscode(true); // must refresh
        expect(s.last.dar_valid && s.last.dar_x == 89 && s.last.dar_y == 50,
               "late provenance refresh heals to 89:50");
    }
}

static void test_fps_families() {
    uint8_t f = 0;
    bool n = false;
    expect(contentFpsForPlxg(24, 1, &f, &n) && f == 24 && !n, "24/1 exact int");
    expect(contentFpsForPlxg(25, 1, &f, &n) && f == 25 && !n, "25/1");
    expect(contentFpsForPlxg(30, 1, &f, &n) && f == 30 && !n, "30/1");
    expect(contentFpsForPlxg(24000, 1001, &f, &n) && f == 24 && n, "24000/1001 → 24+1001");
    expect(contentFpsForPlxg(30000, 1001, &f, &n) && f == 30 && n, "30000/1001 → 30+1001");
    expect(contentFpsIntegerForPlxg(24000, 1001, &f) && f == 24, "compat integer still 24");
    expect(!contentFpsForPlxg(0, 1, &f, &n), "0 fps unknown");
    expect(!contentFpsForPlxg(12, 5, &f, &n), "2.4 fps not a family → unknown");
}

static void test_film_cadence_1001_not_integer_bucket() {
    // rd-duck: integer-only q5 cannot certify film cadence.
    const auto film = selectPlxgAspectCadence(624, 480, "160:117", "1.78", 24000, 1001);
    expect(film.fps_valid && film.content_fps == 24 && film.fps_1001,
           "film select sets fps_1001");
    expect(film.fps_num == 24000 && film.fps_den == 1001, "host keeps exact rational");
    uint64_t q = 0;
    expect(packPlxgQ5(film, &q), "pack film q5");
    expect((q & kPlxgQ5Fps1001Bit) != 0, "wire bit 34 set for film");
    PlxgAspectCadence u{};
    expect(unpackPlxgQ5(q, &u), "unpack film");
    expect(u.fps_1001 && u.content_fps == 24, "unpack fps_1001");
    int rn = 0, rd = 0;
    expect(plxgContentFpsRational(u, &rn, &rd) && rn == 24000 && rd == 1001,
           "wire reconstructs 24000/1001");

    const auto int24 = selectPlxgAspectCadence(624, 480, "", "1.78", 24, 1);
    expect(int24.fps_valid && int24.content_fps == 24 && !int24.fps_1001,
           "integer 24 has fps_1001=0");
    // RED: treating film as integer 24 loses the 1001 distinction.
    expect(film.fps_1001 != int24.fps_1001, "red: film ≠ integer 24 on wire flag");

    // Cadence slip: fabric ~24.000672 (w-clock integer path) vs content 23.976024.
    const double content = 24000.0 / 1001.0; // 23.97602397…
    const double fabric_int = 24.000672;    // rd-duck measured w-clock consume
    const double slip = cadenceUnitSlipPeriodSec(fabric_int, content);
    // Expect ~40.57s — band 40..41.5
    expect(slip > 40.0 && slip < 41.5, "film vs int-fabric slip ~40.57s");
    // With 1001-aware fabric rate matching content, slip → 0.
    const double fabric_ok = content;
    expect(cadenceUnitSlipPeriodSec(fabric_ok, content) == 0.0,
           "matched 1001 rates → zero slip");

    // 29.97 class
    const auto n30 = selectPlxgAspectCadence(0, 0, "", "", 30000, 1001);
    expect(n30.fps_1001 && n30.content_fps == 30, "29.97 → 30+1001");
    const double c2997 = 30000.0 / 1001.0;
    const double slip30 = cadenceUnitSlipPeriodSec(30.000840, c2997);
    expect(slip30 > 31.0 && slip30 < 34.0, "29.97 vs int-fabric slip ~32.4s");
}

int main() {
    test_offsets();
    test_pack_16x9_24();
    test_reserved_reject_red_twin();
    test_unknown_no_invent_red_twin();
    test_no_storage_aspect_fallback_720x480();
    test_lab_624x350_dar_provenance();
    test_main_call_order_624x350_transcode();
    test_media_aspect_decimal();
    test_fps_families();
    test_film_cadence_1001_not_integer_bucket();
    if (g_fails) {
        std::fprintf(stderr, "test_plxg_q5_aspect_cadence: %d FAIL(s)\n", g_fails);
        return 1;
    }
    std::fprintf(stderr, "test_plxg_q5_aspect_cadence: PASS\n");
    return 0;
}
