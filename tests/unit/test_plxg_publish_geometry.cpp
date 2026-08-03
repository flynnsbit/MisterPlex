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

    if (g_fails) {
        std::fprintf(stderr, "test_plxg_publish_geometry: %d FAIL(s)\n", g_fails);
        return 1;
    }
    std::printf("PASS test_plxg_publish_geometry tiers=320/416/624/720/540/720p "
                "PLXG_matches_payload NO_LEGACY480_SHEAR\n");
    return 0;
}
