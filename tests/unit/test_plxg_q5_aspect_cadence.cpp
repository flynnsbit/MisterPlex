// Red-before-green: PLXG q5 aspect+cadence pack + selection (w-path ABI #2 ONLY).
//
// Negative cases a naive wrong implementation must fail:
//   1) non-zero reserved [63:34] → receiver reject (matches w-mem latch E4)
//   2) unknown DAR/fps → valid bits clear (must NOT invent 16:9 or 24)
//   3) storage-aspect fallback on 720×480 without SAR → must stay invalid
//   4) wire offset of q5 is 0x828 (sixth qword), not still 5-qword-only
//   5) unilateral bit34 fps_1001 is FORBIDDEN — film flag is host-only until
//      parent arbitrates mem+latch+clock (rd-duck BLOCKER 2026-08-03)

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
    expect(kPlxgRecordBytesAspectCadence != 40u, "red: not still 5-qword/40B");
    expect(kPlxgQ5ReservedShift == 34u, "ABI#2 reserved starts at bit 34");
    expect(!kPlxgQ5Fps1001OnWire, "fps_1001 not on wire until parent arbitration");
    expect(kPlxgQ5Fps1001Bit == 0ull, "retired #2.1 bit symbol is zero");
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
    expect(((q >> 34) & 1ull) == 0, "bit34 reserved clear for integer 24");
    expect((q >> 34) == 0, "reserved [63:34] zero");

    PlxgAspectCadence u{};
    expect(unpackPlxgQ5(q, &u), "unpack ok");
    expect(u.dar_x == 16 && u.dar_y == 9 && u.content_fps == 24, "round-trip fields");
    expect(u.dar_valid && u.fps_valid && !u.fps_1001, "round-trip valids");
}

static void test_reserved_reject_red_twin() {
    // w-mem: q5_reserved_nz = |sh5[63:34] — bit 34 alone is already fatal.
    const uint64_t dirty34 = (1ull << 34);
    expect(!plxgQ5ReservedOk(dirty34), "red: reserved bit 34 fails reservedOk");
    expect(!plxgQ5ReceiverAccepts(dirty34), "red: receiver rejects bit34 (w-mem E4)");
    PlxgAspectCadence u{};
    expect(!unpackPlxgQ5(dirty34, &u), "red: unpack rejects bit34");

    const uint64_t dirty35 = (1ull << 35);
    expect(!plxgQ5ReservedOk(dirty35), "red: reserved bit 35 fails reservedOk");
    expect(!plxgQ5ReceiverAccepts(dirty35), "red: receiver rejects bit35");

    // Host may know film 1001; pack MUST still leave bit34 clear (ABI #2).
    PlxgAspectCadence film_host{};
    film_host.fps_valid = true;
    film_host.content_fps = 24;
    film_host.fps_1001 = true;
    film_host.fps_num = 24000;
    film_host.fps_den = 1001;
    uint64_t qok = ~0ull;
    expect(packPlxgQ5(film_host, &qok), "pack film host fields ok");
    expect(((qok >> 34) & 1ull) == 0, "red: film must NOT set wire bit34");
    expect(plxgQ5ReceiverAccepts(qok), "receiver accepts film packed under ABI#2");
    expect(((qok >> 24) & 0xFFull) == 24, "film packs integer family 24");

    // Clean pack must never set reserved [63:34].
    PlxgAspectCadence c{};
    c.dar_valid = true;
    c.dar_x = 4;
    c.dar_y = 3;
    uint64_t q = ~0ull;
    expect(packPlxgQ5(c, &q), "pack 4:3");
    expect((q >> 34) == 0, "pack never sets reserved [63:34]");
}

static void test_unknown_no_invent_red_twin() {
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
    const auto c = selectPlxgAspectCadence(720, 480, "", "", 0, 0);
    expect(!c.dar_valid, "red: 720x480 storage AR must not set dar_valid");
    const auto d = selectPlxgAspectCadence(720, 480, "8:9", "", 0, 0);
    expect(d.dar_valid, "SAR 8:9 on 720x480 → dar_valid");
    const auto e = selectPlxgAspectCadence(720, 480, "32:27", "", 30000, 1001);
    expect(e.dar_valid && e.dar_x == 16 && e.dar_y == 9, "32:27 → 16:9");
    expect(e.fps_valid && e.content_fps == 30, "30000/1001 → fps=30");
}

static void test_lab_624x350_dar_provenance() {
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

    const auto dp = selectPlxgAspectCadence(624, 480, "160:117", "", 24000, 1001,
                                            PlxgDarProvenance::DirectPlay);
    expect(dp.dar_valid && dp.dar_x == 16 && dp.dar_y == 9, "DP 624x480×160:117 → 16:9");
}

static void test_media_aspect_decimal() {
    const auto c = selectPlxgAspectCadence(0, 0, "", "1.78", 24, 1);
    expect(c.dar_valid, "media 1.78 dar_valid");
    expect(c.dar_x == 89 && c.dar_y == 50, "1.78 → 89/50");
    expect(c.fps_valid && c.content_fps == 24, "integer 24");
}

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
        refresh();
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
    constexpr int kW = 624, kH = 350;

    {
        PlxgQ5PublishSim s;
        s.w = kW;
        s.h = kH;
        s.setFps(24000, 1001);
        s.setAspect("160:117", "1.78");
        s.transcode = true; // assign only, NO refresh
        expect(s.last.dar_valid && s.last.dar_x == 256 && s.last.dar_y == 105,
               "RED old-order stale pack is 256:105 (double SAR)");
    }

    {
        PlxgQ5PublishSim s;
        s.w = kW;
        s.h = kH;
        s.setProvenanceTranscode(true);
        s.setFps(24000, 1001);
        s.setAspect("160:117", "1.78");
        expect(s.last.dar_valid && s.last.dar_x == 89 && s.last.dar_y == 50,
               "main order: initial q5 DAR 89:50 (Media 1.78) not 256:105");
        expect(!(s.last.dar_x == 256 && s.last.dar_y == 105),
               "main order must not publish 256:105");
        expect(s.last.fps_valid && s.last.content_fps == 24, "main order fps 24");
        expect((s.q5 >> 34) == 0, "main order wire reserved [63:34] clear");
    }

    {
        PlxgQ5PublishSim s;
        s.w = kW;
        s.h = kH;
        s.setFps(24000, 1001);
        s.setAspect("160:117", "1.78");
        expect(s.last.dar_x == 256 && s.last.dar_y == 105, "precondition DP 256:105");
        s.setProvenanceTranscode(true);
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
    expect(contentFpsForPlxg(24000, 1001, &f, &n) && f == 24 && n, "24000/1001 → 24+1001 host");
    expect(contentFpsForPlxg(30000, 1001, &f, &n) && f == 30 && n, "30000/1001 → 30+1001 host");
    expect(contentFpsIntegerForPlxg(24000, 1001, &f) && f == 24, "compat integer still 24");
    expect(!contentFpsForPlxg(0, 1, &f, &n), "0 fps unknown");
    expect(!contentFpsForPlxg(12, 5, &f, &n), "2.4 fps not a family → unknown");
}

static void test_film_cadence_host_only_not_wire_bit34() {
    // Host retains exact rational + fps_1001; wire stays ABI #2 (no bit34).
    const auto film = selectPlxgAspectCadence(624, 480, "160:117", "1.78", 24000, 1001);
    expect(film.fps_valid && film.content_fps == 24 && film.fps_1001,
           "film select sets host fps_1001");
    expect(film.fps_num == 24000 && film.fps_den == 1001, "host keeps exact rational");
    int hn = 0, hd = 0;
    expect(plxgContentFpsRational(film, &hn, &hd) && hn == 24000 && hd == 1001,
           "host rational API keeps 24000/1001");

    uint64_t q = 0;
    expect(packPlxgQ5(film, &q), "pack film q5 under ABI#2");
    expect(((q >> 34) & 1ull) == 0, "red: #2.1 bit34 must NOT be set (w-mem collision)");
    expect(plxgQ5ReceiverAccepts(q), "w-mem-compatible receiver accepts film pack");

    PlxgAspectCadence u{};
    expect(unpackPlxgQ5(q, &u), "unpack film");
    expect(u.content_fps == 24 && u.fps_valid && !u.fps_1001,
           "wire unpack has family 24, no 1001 flag");

    const auto int24 = selectPlxgAspectCadence(624, 480, "", "1.78", 24, 1);
    expect(int24.fps_valid && int24.content_fps == 24 && !int24.fps_1001,
           "integer 24 has host fps_1001=0");
    // Host can still distinguish film vs int; wire cannot until arbitration.
    expect(film.fps_1001 != int24.fps_1001, "red: host film ≠ integer 24 flag");
    uint64_t qi = 0;
    expect(packPlxgQ5(int24, &qi), "pack int24");
    // Cadence nibble of wire is identical (family 24, fps_valid, bit34=0); DAR may differ.
    expect(((q >> 24) & 0x3FFull) == ((qi >> 24) & 0x3FFull),
           "ABI#2 wire cadence bits identical for film family and integer 24");
    expect(((q >> 34) | (qi >> 34)) == 0, "both packs leave reserved [63:34] clear");

    // Residual slip under integer wire (documented; not fixed without parent ABI).
    const double content = 24000.0 / 1001.0;
    const double fabric_int = 24.000672;
    const double slip = cadenceUnitSlipPeriodSec(fabric_int, content);
    expect(slip > 40.0 && slip < 41.5, "film vs int-fabric slip ~40.57s (ABI#2 residual)");
    expect(cadenceUnitSlipPeriodSec(content, content) == 0.0, "matched rates → zero slip");

    const auto n30 = selectPlxgAspectCadence(0, 0, "", "", 30000, 1001);
    expect(n30.fps_1001 && n30.content_fps == 30, "29.97 → host 30+1001");
    uint64_t q30 = 0;
    expect(packPlxgQ5(n30, &q30) && ((q30 >> 34) & 1ull) == 0, "29.97 pack bit34 clear");
    const double slip30 = cadenceUnitSlipPeriodSec(30.000840, 30000.0 / 1001.0);
    expect(slip30 > 31.0 && slip30 < 34.0, "29.97 vs int-fabric slip ~32.4s");
}

static void test_mailbox_words_abi2() {
    // Clean ABI #2 pack → LE words for doorbell+0x828 (host half of wire).
    PlxgAspectCadence c{};
    c.dar_x = 16;
    c.dar_y = 9;
    c.content_fps = 24;
    c.dar_valid = true;
    c.fps_valid = true;
    c.fps_1001 = true; // host-only; must not poison words
    uint64_t q = 0;
    expect(packPlxgQ5(c, &q), "mailbox: pack clean 16:9@24");
    uint32_t lo = 0xdeadbeefu, hi = 0xdeadbeefu;
    expect(plxgQ5ToMailboxWords(q, &lo, &hi), "mailbox: clean q5 → words");
    expect(lo == static_cast<uint32_t>(q & 0xffffffffu), "mailbox: lo matches");
    expect(hi == static_cast<uint32_t>((q >> 32) & 0xffffffffu), "mailbox: hi matches");
    expect((hi >> 2) == 0, "mailbox: hi[31:2] zero (reserved beyond valid bits)");
    expect((hi & 3u) == 3u, "mailbox: dar_valid|fps_valid in hi[1:0]");

    // Negative: bit34 dirty must refuse words (fail-closed; no poison latch).
    const uint64_t dirty = q | (1ull << 34);
    uint32_t dlo = 1, dhi = 1;
    expect(!plxgQ5ToMailboxWords(dirty, &dlo, &dhi),
           "red: mailbox words reject bit34 (arb#4 vacated)");
    expect(dlo == 1 && dhi == 1, "red: rejected words leave outs unchanged");
    expect(!plxgQ5ToMailboxWords(q, nullptr, &hi), "null lo fails");
    expect(!plxgQ5ToMailboxWords(q, &lo, nullptr), "null hi fails");
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
    test_film_cadence_host_only_not_wire_bit34();
    test_mailbox_words_abi2();
    if (g_fails) {
        std::fprintf(stderr, "test_plxg_q5_aspect_cadence: %d FAIL(s)\n", g_fails);
        return 1;
    }
    std::fprintf(stderr, "test_plxg_q5_aspect_cadence: PASS\n");
    return 0;
}
