// rd-duck: q5 must survive full 6-qword seqlock; standalone +0x828 must NOT promote.
// Covers LEG (320) and Option-C (540/720) content plans on bootstrap page model.
#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/ddr_present_bank.hpp"
#include "libmisterplex/plxg_q5_aspect_cadence.hpp"
#include "libmisterplex/plxg_record.hpp"

#include <cstdio>
#include <string>
#include <vector>

static int g_fails = 0;
static void expect(bool c, const char* m) {
    if (!c) {
        std::fprintf(stderr, "FAIL: %s\n", m);
        ++g_fails;
    }
}

static void checkQ5E2E(int w, int h, const char* tag) {
    using namespace misterplex;
    const auto g = ddrFrameGeometryForFpgaPresent(w, h);
    const size_t bytes = yuv420pFrameBytes(w, h);
    std::vector<uint8_t> yuv(bytes, 0x10);
    DdrPublishFrame f{yuv.data(), yuv.size(), g, DdrFrameFormat::Yuv420p};
    DdrPublishPlan plan{};
    std::string err;
    expect(makeDdrPublishPlan(f, 0, plan, &err), (std::string(tag) + " plan: " + err).c_str());
    expect(plan.plxg_q[5] == 0, (std::string(tag) + " default q5 zero").c_str());

    PlxgAspectCadence c{};
    c.dar_x = 16;
    c.dar_y = 9;
    c.content_fps = 24;
    c.dar_valid = true;
    c.fps_valid = true;
    uint64_t q5 = 0;
    expect(packPlxgQ5(c, &q5) && q5 != 0, (std::string(tag) + " pack q5").c_str());
    expect(plxgQ5ReservedOk(q5), (std::string(tag) + " reserved ok").c_str());
    expect(injectPlxgQ5IntoPublishPlan(plan, q5), (std::string(tag) + " inject").c_str());
    expect(plan.plxg_q[5] == q5, (std::string(tag) + " plan q5").c_str());
    expect(plan.program_plxg, (std::string(tag) + " program_plxg").c_str());

    uint16_t committed = 0;
    uint64_t latched = 0;
    expect(plxgQ5FullRecordE2E(plan.plxg_q, q5, /*softLast=*/0, &committed, &latched),
           (std::string(tag) + " full-record E2E").c_str());
    expect(latched == q5, (std::string(tag) + " latched q5").c_str());
    expect(committed != 0 && !plxgSeqDoorbellFieldIsReservedUngated(committed),
           (std::string(tag) + " committed seq").c_str());

    // Bank map class for this tier (LEG vs Option-C).
    if (bytes <= static_cast<size_t>(kPlex480pYuv420pBankUsableBytes)) {
        expect(plan.bank_map == DdrBankMap::Legacy480p, (std::string(tag) + " LEG").c_str());
        expect(plan.layout.doorbell_phys == kPlex480pYuv420pDoorbellPhys,
               (std::string(tag) + " LEG door").c_str());
    } else {
        expect(plan.bank_map == DdrBankMap::OptionC720p, (std::string(tag) + " OptC").c_str());
        expect(plan.layout.doorbell_phys == kPlex720pYuv420pDoorbellPhys,
               (std::string(tag) + " OptC door").c_str());
    }
}

int main() {
    using namespace misterplex;

    // POS: nonzero DAR/fps survives full record + poller commit (LEG + Option-C).
    checkQ5E2E(320, 240, "LEG320");
    checkQ5E2E(624, 480, "LEG624");
    checkQ5E2E(960, 540, "OptC540");
    checkQ5E2E(1280, 720, "OptC720");

    // NEG: reserved bit34 refuse inject.
    {
        DdrPublishPlan plan{};
        plan.program_plxg = true;
        const uint64_t bad = (1ull << 34); // vacated fps_1001
        expect(!injectPlxgQ5IntoPublishPlan(plan, bad), "NEG reserved q5 refused");
        expect(plan.plxg_q[5] == 0, "NEG plan q5 unchanged");
    }

    // NEG: q5-only poke never promotes (already inside FullRecordE2E; explicit).
    {
        uint8_t page[0x1000]{};
        uint64_t q[6]{};
        q[0] = packPlxgQ0(true, true, 1);
        q[1] = packPlxgQ1(320, 240, 0, 0);
        q[2] = packPlxgQ2(320, 240, 320, 240);
        q[3] = packPlxgQ3(320, 160, 320, 240);
        q[5] = packPlxgQ5(16, 9, 24, true, true);
        uint16_t seq = 0;
        expect(plxgSeqlockPublishToPage(page, sizeof(page), q, 0, &seq), "seed record");
        PlxgPollerSim pol{};
        expect(pol.tryCommit(page, sizeof(page)), "seed promote");
        const uint64_t good = pol.latched_q[5];
        plxgFaultWriteQ5Only(page, packPlxgQ5(4, 3, 25, true, true));
        expect(!pol.tryCommit(page, sizeof(page)), "NEG q5-only no promote");
        expect(pol.latched_q[5] == good, "NEG latched q5 sticky");
    }

    if (g_fails) {
        std::fprintf(stderr, "test_plxg_q5_publish_e2e: %d FAIL(s)\n", g_fails);
        return 1;
    }
    std::printf("PASS test_plxg_q5_publish_e2e LEG+OptC q5_full_record NEG_q5_only "
                "NEG_reserved\n");
    return 0;
}
