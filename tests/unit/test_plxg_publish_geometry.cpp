// rd-duck shear gate: makeDdrPublishPlan PLXG must match payload geometry.
// NEG: Legacy480 PLXG + 320×240 payload is forbidden.
#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/ddr_present_bank.hpp"
#include "libmisterplex/plxg_record.hpp"

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

static int g_fails = 0;
static void expect(bool c, const char* m) {
    if (!c) {
        std::fprintf(stderr, "FAIL: %s\n", m);
        ++g_fails;
    }
}

static void checkTier(int w, int h, const char* tag) {
    using namespace misterplex;
    const auto g = ddrFrameGeometryForFpgaPresent(w, h);
    expect(g.coded_width.get() == w && g.coded_height.get() == h,
           (std::string(tag) + " storage identity").c_str());
    const size_t bytes = yuv420pFrameBytes(w, h);
    expect(bytes == static_cast<size_t>(w) * static_cast<size_t>(h) * 3u / 2u,
           (std::string(tag) + " I420 bytes").c_str());
    std::vector<uint8_t> yuv(bytes, 0x10);
    DdrPublishFrame f{yuv.data(), yuv.size(), g, DdrFrameFormat::Yuv420p};
    DdrPublishPlan plan{};
    std::string err;
    expect(makeDdrPublishPlan(f, 0, plan, &err), (std::string(tag) + " plan ok: " + err).c_str());
    expect(plan.program_plxg, (std::string(tag) + " program_plxg").c_str());
    expect(plan.copy_bytes == bytes, (std::string(tag) + " copy_bytes").c_str());
    expect(plan.layout.frame_bytes == bytes, (std::string(tag) + " layout.frame_bytes").c_str());
    expect(plan.layout.line_bytes == w, (std::string(tag) + " y_stride==w").c_str());
    expect(plan.layout.chroma_line_bytes == w / 2, (std::string(tag) + " c_stride").c_str());
    // Bank map: LEG if payload ≤520192 else Option-C — never geometry-derived.
    expect(!ddrLayoutBankMapIsGeometryDerived(plan.layout),
           (std::string(tag) + " fixed LEG/Option-C bank map").c_str());
    if (bytes <= static_cast<size_t>(kPlex480pYuv420pBankUsableBytes)) {
        expect(plan.bank_map == DdrBankMap::Legacy480p, (std::string(tag) + " LEG map").c_str());
        expect(plan.layout.bank_stride == kPlex480pYuv420pBankStride,
               (std::string(tag) + " LEG stride 0x80000").c_str());
        expect(plan.layout.doorbell_phys == kPlex480pYuv420pDoorbellPhys,
               (std::string(tag) + " LEG doorbell 0x300FF000").c_str());
        expect(plan.layout.phys_base == kDdrFramePhysBase, (std::string(tag) + " LEG base").c_str());
    } else {
        expect(plan.bank_map == DdrBankMap::OptionC720p, (std::string(tag) + " Option-C map").c_str());
        expect(plan.layout.bank_stride == kPlex720pYuv420pBankStride,
               (std::string(tag) + " Option-C stride").c_str());
        expect(plan.layout.doorbell_phys == kPlex720pYuv420pDoorbellPhys,
               (std::string(tag) + " Option-C doorbell").c_str());
    }
    // NEG: raw makeDdrFrameLayout for small frames is geometry-derived (0x40000 trap).
    if (w == 320 && h == 240) {
        const auto raw = makeDdrFrameLayout(g);
        expect(ddrLayoutBankMapIsGeometryDerived(raw), "NEG raw 320 is geometry-derived map");
        expect(raw.bank_stride == 0x40000u && raw.doorbell_phys == 0x3007F000u,
               "NEG raw 320 is 0x40000/0x3007F000 trap");
        expect(plan.layout.bank_stride != raw.bank_stride,
               "publish must not keep raw geometry bank stride");
    }

    int cw = 0, ch = 0, ys = 0, cs = 0, deW = 0, deH = 0;
    unpackPlxgQ2(plan.plxg_q[2], &deW, &deH, &cw, &ch);
    unpackPlxgQ3(plan.plxg_q[3], &ys, &cs, nullptr, nullptr);
    expect(cw == w && ch == h, (std::string(tag) + " PLXG coded matches payload").c_str());
    expect(ys == w && cs == w / 2, (std::string(tag) + " PLXG stride matches layout").c_str());
    expect(plxgQ5ReservedOk(plan.plxg_q[5]), (std::string(tag) + " q5 reserved ok").c_str());

    // NEG: must not look like Legacy480 when tier is not 624×480.
    if (w != 624 || h != 480) {
        expect(plxgLegacy480MismatchesPayload(cw, ch),
               (std::string(tag) + " NEG not legacy480 coded").c_str());
        expect(!(cw == 624 && ch == 480 && ys == 624),
               (std::string(tag) + " NEG no shear Legacy480 PLXG").c_str());
    }
}

int main() {
    using namespace misterplex;

    // End-to-end tiers (rd-duck): 320/416/624/720 (+540 Option-C).
    checkTier(320, 240, "320x240");
    checkTier(416, 240, "416x240");
    checkTier(624, 480, "624x480");
    checkTier(720, 480, "720x480");
    checkTier(960, 540, "960x540");
    checkTier(1280, 720, "1280x720");

    // Explicit shear oracle: force Legacy480 body against 320 payload → guard.
    {
        const auto g320 = makeDdrFrameGeometry(320, 240);
        const auto lay = makeDdrFrameLayout(g320);
        const PlxgRecord bad = makePlxgRecordLegacy480(1);
        expect(!plxgRecordMatchesStorage(bad, 320, 240, 320, 160),
               "NEG Legacy480 does not match 320 storage");
        expect(plxgLegacy480MismatchesPayload(320, 240), "NEG 320 is legacy mismatch");
        const PlxgRecord good = makePlxgRecordFromGeometry(g320, lay, 1);
        expect(good.valid && plxgRecordMatchesStorage(good, 320, 240, 320, 160),
               "identity 320 PLXG matches");
    }

    // Product 480p path still emits pillarbox Legacy480 fields.
    {
        const auto g = plex480pDdrFrameGeometry();
        std::vector<uint8_t> yuv(yuv420pFrameBytes(g.coded_width, g.coded_height), 0x10);
        DdrPublishFrame f{yuv.data(), yuv.size(), g, DdrFrameFormat::Yuv420p};
        DdrPublishPlan plan{};
        std::string err;
        expect(makeDdrPublishPlan(f, 0, plan, &err), "product480 plan");
        int cw = 0, ch = 0, ys = 0, dw = 0;
        unpackPlxgQ2(plan.plxg_q[2], nullptr, nullptr, &cw, &ch);
        unpackPlxgQ3(plan.plxg_q[3], &ys, nullptr, &dw, nullptr);
        expect(cw == 624 && ch == 480 && ys == 624 && dw == 618, "product480 PLXG pillar");
        const PlxgRecord leg = makePlxgRecordLegacy480(1);
        expect(plan.plxg_q[1] == leg.q[1] && plan.plxg_q[2] == leg.q[2] &&
                   plan.plxg_q[3] == leg.q[3] && plan.plxg_q[4] == leg.q[4],
               "product480 uses Legacy480 body");
    }

    // 115200 payload + 624 geom still rejected (length guard).
    {
        std::vector<uint8_t> yuv(115200u, 0x40);
        DdrPublishFrame bad{yuv.data(), yuv.size(), plex480pDdrFrameGeometry(),
                            DdrFrameFormat::Yuv420p};
        DdrPublishPlan plan{};
        std::string err;
        expect(!makeDdrPublishPlan(bad, 0, plan, &err), "NEG 320 bytes vs 480 geom rejected");
    }

    // rd-duck: Direct-Part 426→432 coded≠display must survive makeDdrPublishPlan
    // and host→record→mux latch. Canvas H_DE=432, content DE=426 at x0=2, cropL=2.
    {
        const auto g = ddrStorageGeometryForContent(426, 240);
        expect(g.coded_width.get() == 432 && g.display_width.get() == 426 &&
                   g.presented_width.get() == 432 && g.crop_left == 2 && g.crop_right == 4 &&
                   g.present_x == 2 && g.present_y == 0,
               "426 pad geom coded432 display426 present_x=2");
        const auto layout = makeDdrFrameLayout(g);
        expect(ddrFrameLayoutValid(layout), "426 pad layout valid");
        expect(layout.line_bytes == 432 && layout.chroma_line_bytes == 216,
               "426 pad layout stride=coded 432");
        expect(layout.display_width.get() == 426 && layout.crop_left == 2 &&
                   layout.present_x == 2,
               "426 pad layout preserves display/crop/present_x");

        const size_t bytes = yuv420pFrameBytes(432, 240);
        std::vector<uint8_t> yuv(bytes, 0x10);
        DdrPublishFrame f{yuv.data(), yuv.size(), g, DdrFrameFormat::Yuv420p};
        DdrPublishPlan plan{};
        std::string err;
        expect(makeDdrPublishPlan(f, 0, plan, &err),
               (std::string("426 pad plan ok: ") + err).c_str());
        expect(plan.program_plxg, "426 pad program_plxg");
        expect(plan.copy_bytes == bytes, "426 pad copy_bytes=bank");
        expect(plan.layout.line_bytes == 432, "426 pad plan y_stride=432");
        expect(plan.bank_map == DdrBankMap::Legacy480p, "426 pad LEG bank map");

        int q1w = 0, q1h = 0, q1x = 0, q1y = 0;
        int deW = 0, deH = 0, cw = 0, ch = 0;
        int ys = 0, cs = 0, dw = 0, dh = 0;
        int px = 0, py = 0, cl = 0, ct = 0;
        unpackPlxgQ1(plan.plxg_q[1], &q1w, &q1h, &q1x, &q1y);
        unpackPlxgQ2(plan.plxg_q[2], &deW, &deH, &cw, &ch);
        unpackPlxgQ3(plan.plxg_q[3], &ys, &cs, &dw, &dh);
        unpackPlxgQ4(plan.plxg_q[4], &px, &py, &cl, &ct);
        expect(q1w == 426 && q1h == 240 && q1x == 2 && q1y == 0,
               "426 pad q1 content DE + present_x=2");
        expect(deW == 432 && deH == 240, "426 pad q2 H_DE=store canvas 432");
        expect(cw == 432 && ch == 240, "426 pad q2 coded=store");
        expect(ys == 432 && cs == 216, "426 pad q3 stride=coded");
        expect(dw == 426 && dh == 240, "426 pad q3 display preserved (coded≠display)");
        expect(px == 2 && py == 0 && cl == 2 && ct == 0,
               "426 pad q4 present_x=crop_left=2");
        // NEG: identity-on-432 PLXG would squeeze 426/432 under DAR.
        expect(!(q1w == 432 && cw == 432 && dw == 432 && cl == 0),
               "NEG 426 pad must not publish all-432 content");

        // host→record→mux→store oracle (catches 432/432 producer the 624/618
        // mux fixture cannot).
        PlxgRecord rec{};
        rec.valid = true;
        rec.seq = plan.plxg_seq;
        for (int i = 0; i < 6; ++i)
            rec.q[static_cast<size_t>(i)] = plan.plxg_q[static_cast<size_t>(i)];
        const auto mux = plxgMuxLatchVisual(rec);
        expect(plxgMuxIsPad426In432(mux), "host→record→mux 426@x2 in 432 canvas");

        // NEG oracle: store-only identity plan fails pad mux predicate.
        const auto gId = ddrStorageGeometryForContent(432, 240);
        DdrPublishFrame fId{yuv.data(), yuv.size(), gId, DdrFrameFormat::Yuv420p};
        DdrPublishPlan planId{};
        expect(makeDdrPublishPlan(fId, 0, planId, &err), "identity 432 plan builds");
        PlxgRecord recId{};
        recId.valid = true;
        for (int i = 0; i < 6; ++i)
            recId.q[static_cast<size_t>(i)] = planId.plxg_q[static_cast<size_t>(i)];
        expect(!plxgMuxIsPad426In432(plxgMuxLatchVisual(recId)),
               "NEG store-only 432 fails 426-pad mux predicate");
    }

    // NEG: store-only 432 identity must NOT invent display 426 / crop 2.
    {
        const auto g = ddrStorageGeometryForContent(432, 240);
        expect(g.coded_width.get() == 432 && g.display_width.get() == 432 && g.crop_left == 0,
               "NEG store-only 432 is identity");
        const size_t bytes = yuv420pFrameBytes(432, 240);
        std::vector<uint8_t> yuv(bytes, 0x20);
        DdrPublishFrame f{yuv.data(), yuv.size(), g, DdrFrameFormat::Yuv420p};
        DdrPublishPlan plan{};
        std::string err;
        expect(makeDdrPublishPlan(f, 0, plan, &err), "store-only 432 plan");
        int dw = 0, cl = 0, cw = 0;
        unpackPlxgQ2(plan.plxg_q[2], nullptr, nullptr, &cw, nullptr);
        unpackPlxgQ3(plan.plxg_q[3], nullptr, nullptr, &dw, nullptr);
        unpackPlxgQ4(plan.plxg_q[4], nullptr, nullptr, &cl, nullptr);
        expect(cw == 432 && dw == 432 && cl == 0,
               "NEG store-only 432 PLXG stays identity (no fake crop)");
    }

    if (g_fails) {
        std::fprintf(stderr, "test_plxg_publish_geometry: %d FAIL(s)\n", g_fails);
        return 1;
    }
    std::printf("PASS test_plxg_publish_geometry tiers=320/416/624/720/540/720p "
                "pad426_coded_ne_display NO_LEGACY480_SHEAR\n");
    return 0;
}
