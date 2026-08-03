// rd-duck: true FpgaSpi::publishDdrFrame(320×240) integration — not plan-only.
// Lab maps replace /dev/mem so sendDdrFrame runs writePlxgRecord + doorbell kick.
#include "fpga_spi.hpp"
#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/ddr_present_bank.hpp"
#include "libmisterplex/plxg_q5_aspect_cadence.hpp"
#include "libmisterplex/plxg_record.hpp"

#include <cstdint>
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

int main() {
    using namespace misterplex;

    // --- setDdrFrameLayout(320) pins LEG, never geom 0x40000 -----------------
    {
        FpgaSpi spi;
        expect(spi.setDdrFrameLayout(320, 240), "setDdrFrameLayout 320");
        const auto L = spi.ddrFrameLayout();
        expect(L.coded_width.get() == 320 && L.coded_height.get() == 240, "layout coded 320");
        expect(L.bank_stride == kPlex480pYuv420pBankStride, "LEG bank_stride 0x80000");
        expect(L.doorbell_phys == kPlex480pYuv420pDoorbellPhys, "LEG doorbell 0x300FF000");
        expect(L.phys_base == kDdrFramePhysBase, "LEG phys 0x30000000");
        expect(!ddrLayoutBankMapIsGeometryDerived(L), "not geometry-derived");
        expect(L.bank_stride != 0x40000u, "NEG: not 0x40000 geom stride");
        expect(L.doorbell_phys != 0x3007F000u, "NEG: not 0x3007F000 geom door");
    }

    // --- Full publishDdrFrame hot path on lab maps ---------------------------
    std::vector<uint8_t> ddr(static_cast<size_t>(kPlex480pMapBytes2Bank), 0);
    std::vector<uint8_t> plxgPage(0x1000u, 0);
    FpgaSpi spi;
    expect(spi.attachLabPublishMaps(ddr.data(), ddr.size(), plxgPage.data(), plxgPage.size()),
           "attachLabPublishMaps");

    const auto g = ddrFrameGeometryForFpgaPresent(320, 240);
    expect(g.coded_width.get() == 320 && g.coded_height.get() == 240, "geom 320 identity");
    const size_t frameBytes = yuv420pFrameBytes(320, 240);
    expect(frameBytes == 115200u, "320 I420 bytes");
    std::vector<uint8_t> yuv(frameBytes);
    for (size_t i = 0; i < frameBytes; ++i)
        yuv[i] = static_cast<uint8_t>(0xA0 ^ (i & 0xFF));

    // Pending q5 must ride the same writePlxgRecord generation.
    PlxgAspectCadence cad{};
    cad.dar_x = 16;
    cad.dar_y = 9;
    cad.content_fps = 24;
    cad.dar_valid = true;
    cad.fps_valid = true;
    uint64_t q5 = 0;
    expect(packPlxgQ5(cad, &q5) && q5 != 0 && plxgQ5ReservedOk(q5), "pack q5");
    expect(spi.writePlxgQ5(q5), "writePlxgQ5 pending");
    expect(spi.lastWrittenPlxgQ5() == 0, "pending not yet on wire");

    DdrPublishFrame frame{yuv.data(), yuv.size(), g, DdrFrameFormat::Yuv420p};
    expect(spi.publishDdrFrame(frame, /*bank=*/0),
           (std::string("publishDdrFrame 320: ") + spi.lastError()).c_str());
    expect(spi.lastPublishedBank() == 0, "published bank 0");

    // Payload landed in bank 0 at LEG stride (not 0x40000).
    expect(std::memcmp(ddr.data(), yuv.data(), frameBytes) == 0, "bank0 payload match");
    // Trailing pad in bank stays zero beyond frame.
    expect(ddr[frameBytes] == 0, "pad after frame zero");

    // Doorbell at LEG offset kicked with magic + B20 PLXG couple in hi[12:0].
    const size_t doorOff =
        static_cast<size_t>(kPlex480pYuv420pDoorbellPhys - kDdrFramePhysBase);
    const uint32_t* door = reinterpret_cast<const uint32_t*>(ddr.data() + doorOff);
    expect(door[0] == FpgaSpi::kDdrDoorbellMagic, "doorbell magic PLXK");
    expect(door[0] != 0, "doorbell non-zero");

    // Full PLXG seqlock body at bootstrap page +0x800 (not active-only +0x828).
    const size_t recOff = static_cast<size_t>(kPlxgRecordByteOffset);
    const uint32_t* qwords = reinterpret_cast<const uint32_t*>(plxgPage.data() + recOff);
    // q0 lo = magic last (seqlock)
    expect(qwords[0] == kPlxgMagic, "q0 magic last");
    const uint16_t seq = static_cast<uint16_t>(qwords[1] >> 16);
    expect(seq != 0 && !plxgSeqDoorbellFieldIsReservedUngated(seq), "monotonic seq");

    // B20 host couple: doorbell expected_plxg_seq == committed PLXG generation.
    {
        uint32_t fgen = 0;
        uint16_t exp_plxg = 0;
        int dbank = -1;
        expect(decodeDdrDoorbellCoupled(door[0], door[1], DdrFrameFormat::Yuv420p, fgen,
                                        exp_plxg, dbank),
               "decode coupled doorbell");
        expect(exp_plxg == seq, "B20 doorbell[12:0] == PLXG seq");
        expect(dbank == 0, "doorbell bank 0");
        const auto couple = spi.lastPublishCouple();
        expect(couple.valid, "lastPublishCouple valid");
        expect(couple.plxg_seq == seq, "couple.plxg_seq");
        expect(couple.plxg_q[5] == q5, "couple visual tuple includes q5");
        expect(ddrDoorbellUnpackPlxgSeq(couple.doorbell_hi & kDdrFrameDoorbellSeqMask) == seq,
               "couple.doorbell_hi packs plxg seq");
    }

    auto loadQ = [&](int qi) -> uint64_t {
        const uint32_t lo = qwords[qi * 2 + 0];
        const uint32_t hi = qwords[qi * 2 + 1];
        return (static_cast<uint64_t>(hi) << 32) | lo;
    };
    const uint64_t q1 = loadQ(1);
    const uint64_t q2 = loadQ(2);
    const uint64_t q3 = loadQ(3);
    const uint64_t q5w = loadQ(5);
    int cw = 0, ch = 0, deW = 0, deH = 0, ys = 0, dw = 0;
    unpackPlxgQ1(q1, &cw, &ch, nullptr, nullptr);
    unpackPlxgQ2(q2, &deW, &deH, &cw, &ch);
    unpackPlxgQ3(q3, &ys, nullptr, &dw, nullptr);
    expect(cw == 320 && ch == 240, "PLXG coded 320x240");
    expect(deW == 320 && deH == 240, "PLXG DE 320x240");
    expect(ys == 320 && dw == 320, "PLXG stride/display 320");
    expect(q5w == q5, "q5 survived full record");
    expect(spi.lastWrittenPlxgQ5() == q5, "lastWrittenPlxgQ5 after commit");

    // Poller: first valid after reset is BASELINE (not promote); body still latched.
    PlxgPollerSim pol{};
    expect(pol.tryCommit(plxgPage.data(), plxgPage.size()), "poller baseline");
    expect(pol.last_event == PlxgPollerEvent::Baseline, "first event=Baseline");
    expect(pol.baselined && pol.latched_q[5] == q5, "poller baselined q5");
    expect(!pol.tryCommit(plxgPage.data(), plxgPage.size()), "same seq no re-commit");

    // Second publish: seq advances; q5 sticky in new generation; poller PROMOTES.
    expect(spi.publishDdrFrame(frame, /*bank=*/1), "second publish bank1");
    expect(spi.lastPublishedBank() == 1, "bank1");
    const uint16_t seq2 = static_cast<uint16_t>(qwords[1] >> 16);
    expect(seq2 != seq && seq2 != 0, "seq advanced");
    expect(loadQ(5) == q5, "q5 still in gen2");
    {
        uint16_t exp2 = 0;
        uint32_t fg2 = 0;
        int b2 = -1;
        expect(decodeDdrDoorbellCoupled(door[0], door[1], DdrFrameFormat::Yuv420p, fg2, exp2, b2),
               "decode couple gen2");
        expect(exp2 == seq2 && b2 == 1, "B20 gen2 doorbell packs new plxg+bank1");
        expect(spi.lastPublishCouple().plxg_seq == seq2, "couple tracks gen2");
    }
    expect(pol.tryCommit(plxgPage.data(), plxgPage.size()), "poller promote gen2");
    expect(pol.last_event == PlxgPollerEvent::Promote, "second event=Promote");
    expect(pol.latched_q[5] == q5, "promote keeps q5");
    // Bank1 payload at LEG stride.
    expect(std::memcmp(ddr.data() + kPlex480pYuv420pBankStride, yuv.data(), frameBytes) == 0,
           "bank1 payload at LEG stride");

    // NEG: geom-derived layout must fail setDdrFrameLayout path already covered;
    // plan mismatch: if someone forced 0x40000, publish would refuse.
    {
        DdrPublishPlan plan{};
        std::string err;
        expect(makeDdrPublishPlan(frame, 0, plan, &err), "plan ok");
        expect(plan.program_plxg, "plan.program_plxg");
        expect(plan.layout.bank_stride == 0x80000u, "plan LEG stride");
        expect(plan.plxg_q[1] != 0 || plan.plxg_q[2] != 0, "plan body non-empty");
    }

    // rd-duck B20: N doorbell → promote N+1 before N swap.
    // Correct store freezes full visual tuple + pend_geom_seq at doorbell match;
    // faulty RTL (applied_geom_seq <= live at swap) mis-labels bank N as N+1.
    {
        const auto gN = ddrFrameGeometryForFpgaPresent(320, 240);
        const auto gN1 = ddrStorageGeometryForContent(426, 240); // distinct tuple
        expect(gN1.display_width.get() == 426 && gN1.present_x == 2, "N+1 pad tuple");
        const auto layN = makeDdrFrameLayout(gN);
        const auto layN1 = makeDdrFrameLayout(gN1);
        auto recN = makePlxgRecordFromGeometry(gN, layN, /*seq*/ 3);
        auto recN1 = makePlxgRecordFromGeometry(gN1, layN1, /*seq*/ 7);
        expect(recN.valid && recN1.valid, "N/N+1 records");
        // Distinct content so mis-label is observable (not seq-only).
        expect(recN.q[1] != recN1.q[1] && recN.q[3] != recN1.q[3], "tuples differ");
        expect(b20PromoteBeforeSwapOracle(recN.q, /*seq_n*/ 3, recN1.q, /*seq_n1*/ 7,
                                          /*bank_n*/ 0),
               "B20 N→N+1 promote-before-swap: correct keeps N, fault takes N+1");

        // Integration: two host publishes + store sim with mid-flight promote.
        DdrStoreB20CoupleSim store{};
        PlxgPollerSim pol2{};
        pol2.reset();
        // Replay current page is gen2 from earlier; rebuild clean couple from couples.
        const auto c1 = spi.lastPublishCouple(); // gen2 after bank1 publish
        expect(c1.valid && c1.plxg_seq != 0, "host couple available");

        // Synthetic: commit N from couple body, doorbell bank0, then commit N+1 pad.
        store.onPlxgCommit(recN.q, 3);
        expect(store.acceptDoorbell(/*bank*/ 0, /*exp*/ 3), "store accept N");
        store.onPlxgCommit(recN1.q, 7); // promote while pend waits
        expect(store.live.geom_seq == 7 && store.pend.geom_seq == 3, "pend frozen at N");
        expect(store.swapApply(), "swap N");
        expect(store.applied.geom_seq == 3 && store.applied.bank == 0, "applied seq/bank N");
        expect(store.applied.display_w() == 320 && store.applied.content_w() == 320,
               "applied tuple N (320), not 426");
        // Next frame N+1
        expect(store.acceptDoorbell(/*bank*/ 1, /*exp*/ 7), "store accept N+1");
        expect(store.swapApply(), "swap N+1");
        expect(store.applied.geom_seq == 7 && store.applied.bank == 1, "applied N+1");
        expect(store.applied.display_w() == 426 && store.applied.present_x() == 2 &&
                   store.applied.crop_left() == 2,
               "applied full visual tuple N+1 (win/x0/crop, not cw/ch only)");

        // NEG: mismatched doorbell seq refused (no bare kick accept).
        store.onPlxgCommit(recN.q, 3);
        expect(!store.acceptDoorbell(0, /*wrong*/ 9), "NEG mismatch doorbell refused");
        expect(store.match_fail, "NEG match_fail set");
    }

    if (g_fails) {
        std::fprintf(stderr, "test_fpga_publish_ddr_frame: %d FAIL(s)\n", g_fails);
        return 1;
    }
    std::printf("PASS test_fpga_publish_ddr_frame 320 LEG+PLXG_seqlock+q5 "
                "B20_couple+baseline_poller+bank1+N_to_N1_oracle\n");
    return 0;
}
