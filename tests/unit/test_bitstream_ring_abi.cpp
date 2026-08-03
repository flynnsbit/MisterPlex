// test_bitstream_ring_abi.cpp — fabric-decode bitstream ring map + PLXN model.
// NEG: skipped seq and wrap/partial-publish must fail honestly (not silent).

#include "libmisterplex/ddr_bitstream_ring.hpp"
#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/fabric_ddr_bandwidth.hpp"

#include <cstdio>
#include <cstring>
#include <vector>

using namespace misterplex;
namespace ring = misterplex::ddr_bitstream_ring;

static int fails = 0;
#define CHECK(cond)                                                                                \
    do {                                                                                           \
        if (!(cond)) {                                                                             \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                   \
            ++fails;                                                                               \
        }                                                                                          \
    } while (0)

static void testMapCollisionFence() {
    std::fprintf(stderr, "--- testMapCollisionFence ---\n");
    CHECK(ring::bitstreamRingClearsOptionC());
    CHECK(ring::bitstreamRingClearsPl330());
    CHECK(ring::bitstreamRingInsideReserved());
    CHECK(ring::kDataPhys == kDdrBitstreamRingDataPhys);
    CHECK(ring::kCtrlPhys == kDdrBitstreamRingCtrlPhys);
    CHECK(ring::kRingBytes == kDdrBitstreamRingBytes);
    CHECK(ring::kDataPhys == 0x30100000u);
    CHECK(ring::kCtrlPhys == 0x30140000u);
    CHECK(ring::kOptionCBasePhys == kPlex720pDdrFramePhysBase);
    CHECK(ring::kOptionCDoorbellPhys == kPlex720pYuv420pDoorbellPhys);
    CHECK(ring::kPl330ScratchPhys == kDdrPl330ScratchPhys);
    // Gap between PLXB page and Option-C
    CHECK(ring::kCtrlPhys + 0x50u <= ring::kOptionCBasePhys);
    // Doorbell page ends before PL330
    CHECK(ring::kOptionCDoorbellPhys + 0x1000u <= ring::kPl330ScratchPhys);
    std::fprintf(stderr, "  OK map: ring[0x%08x,0x%08x) PLXB@0x%08x OptionC@0x%08x PL330@0x%08x\n",
                 ring::kDataPhys, ring::kRingDataEndPhys, ring::kCtrlPhys, ring::kOptionCBasePhys,
                 ring::kPl330ScratchPhys);
}

static void testBitrateArithmetic() {
    std::fprintf(stderr, "--- testBitrateArithmetic ---\n");
    const double bpf = ring::bitstreamBytesPerFrame(2585.0, 24.0);
    // 2585e3/8/24 = 13463.5416...
    CHECK(bpf > 13400.0 && bpf < 13600.0);
    const double ms = ring::bitstreamCpuPushMsAtBankRateKbit(2585.0, 24.0, 88.045);
    CHECK(ms > 0.10 && ms < 0.25); // ~0.15 ms — uncached ceiling irrelevant
    const double i420 = static_cast<double>(kPlex720pYuv420pBytes);
    CHECK(bpf * 100.0 < i420); // ~100x reduction claim directionally true
    std::fprintf(stderr, "  OK bpf=%.1f ms@88MiBps=%.3f ratio=%.0fx\n", bpf, ms, i420 / bpf);
}

static void testMeasuredWorstAuHeadroom() {
    std::fprintf(stderr, "--- testMeasuredWorstAuHeadroom ---\n");
    // Parent real720p_2600k.mp4: MAX AU = 60915 B (prereg 4/4 HIT).
    CHECK(ring::kMeasuredWorstAuBytes == 60915u);
    CHECK(ring::kMeasuredMeanAuBytes == 13507u);
    CHECK(ring::kMeasuredMinAuBytes == 413u);
    CHECK(kDdrBitstreamMeasuredWorstAuBytes == 60915u);
    CHECK(ring::kWorstAuRecordBytes == 32u + 60915u);
    CHECK(ring::kMinWorstAuSlots == 3u);
    CHECK(ring::kRingBytes >= ring::kMinWorstAuSlots * ring::kWorstAuRecordBytes);
    CHECK(ring::kRingWorstAuCapacity >= ring::kMinWorstAuSlots);
    CHECK(ring::kRingWorstAuCapacity == 4u); // floor(262144/60947)

    const double worst_ms = ring::bitstreamWorstAuPushMs(88.045);
    const double mean_ms = ring::bitstreamMeanAuPushMs(88.045);
    // Parent scored 0.660 ms worst / 0.146 ms mean — allow tight band.
    CHECK(worst_ms > 0.64 && worst_ms < 0.68);
    CHECK(mean_ms > 0.14 && mean_ms < 0.16);
    CHECK(worst_ms < 41.667); // trivial vs deadline
    // vs one decoded I420 frame at same ceiling
    const double i420_ms =
        ring::bitstreamCpuPushMsAtBankRate(static_cast<double>(kPlex720pYuv420pBytes), 88.045);
    CHECK(i420_ms / worst_ms > 20.0); // parent: 22.7x

    // Empty ring has worst-AU headroom; nearly full does not.
    CHECK(ring::ringHasWorstAuHeadroom(0));
    CHECK(ring::ringHasWorstAuHeadroom(ring::kRingBytes - ring::kWorstAuRecordBytes));
    CHECK(!ring::ringHasWorstAuHeadroom(ring::kRingBytes - ring::kWorstAuRecordBytes + 1));

    // Model: push one worst-case payload, then fill until Full refuses another.
    ring::BitstreamRingModel m(ring::kRingBytes);
    CHECK(m.pushRecord(ring::Event::Begin, 0, 1, 0, nullptr, 0) == ring::PushResult::Ok);
    std::vector<uint8_t> worst(ring::kMeasuredWorstAuBytes, 0x5A);
    uint32_t accepted = 0;
    for (uint32_t s = 0; s < 8; ++s) {
        auto pr = m.pushRecord(ring::Event::Nal, 5, 1, s, worst.data(),
                               ring::kMeasuredWorstAuBytes);
        if (pr == ring::PushResult::Full)
            break;
        CHECK(pr == ring::PushResult::Ok);
        ++accepted;
    }
    CHECK(accepted >= ring::kMinWorstAuSlots);
    CHECK(accepted == ring::kRingWorstAuCapacity ||
          accepted == ring::kRingWorstAuCapacity - 0); // Begin took 32 B
    // After Begin(32), capacity may be 3 full worst AUs only if remainder tight:
    // (262144-32)/60947 = 4.29 → still 4 Nals. Require >= 3.
    CHECK(accepted >= 3);
    std::fprintf(stderr,
                 "  OK worst_au=%u record=%zu slots_min=%u capacity=%u accepted=%u "
                 "worst_ms=%.3f mean_ms=%.3f vs_i420=%.1fx\n",
                 ring::kMeasuredWorstAuBytes, ring::kWorstAuRecordBytes,
                 ring::kMinWorstAuSlots, ring::kRingWorstAuCapacity, accepted, worst_ms,
                 mean_ms, i420_ms / worst_ms);
}

static void testPlxnRoundTrip() {
    std::fprintf(stderr, "--- testPlxnRoundTrip ---\n");
    uint8_t hdr[32];
    ring::packPlxnHeader(hdr, ring::Event::Nal, 5, 0x1122334455667788ull, 7, 100);
    ring::Event ev{};
    uint8_t nt = 0;
    uint64_t sess = 0;
    uint32_t seq = 0, len = 0;
    CHECK(ring::unpackPlxnHeader(hdr, ev, nt, sess, seq, len));
    CHECK(ev == ring::Event::Nal);
    CHECK(nt == 5);
    CHECK(sess == 0x1122334455667788ull);
    CHECK(seq == 7);
    CHECK(len == 100);
    hdr[0] ^= 0xff;
    CHECK(!ring::unpackPlxnHeader(hdr, ev, nt, sess, seq, len));
}

static void testHappyPathWrap() {
    std::fprintf(stderr, "--- testHappyPathWrap ---\n");
    // Small ring to force wrap
    ring::BitstreamRingModel m(256);
    CHECK(m.pushRecord(ring::Event::Begin, 0, 1, 0, nullptr, 0) == ring::PushResult::Ok);
    ring::Event ev{};
    uint8_t nt;
    uint64_t sess;
    uint32_t seq;
    std::vector<uint8_t> pay;
    CHECK(m.pullRecord(ev, nt, sess, seq, pay));
    CHECK(ev == ring::Event::Begin);

    std::vector<uint8_t> body(40, 0xA5);
    for (uint32_t s = 0; s < 8; ++s) {
        auto pr = m.pushRecord(ring::Event::Nal, 1, 1, s, body.data(),
                               static_cast<uint32_t>(body.size()));
        CHECK(pr == ring::PushResult::Ok);
        CHECK(m.pullRecord(ev, nt, sess, seq, pay));
        CHECK(ev == ring::Event::Nal);
        CHECK(seq == s);
        CHECK(pay.size() == body.size());
        CHECK(std::memcmp(pay.data(), body.data(), body.size()) == 0);
    }
    CHECK(!m.desyncSticky());
    CHECK(!m.underrunSticky());
    std::fprintf(stderr, "  OK wrap path write=%u read=%u\n", m.writeCount(), m.readCount());
}

static void testNegSkippedSeq() {
    std::fprintf(stderr, "--- testNegSkippedSeq ---\n");
    ring::BitstreamRingModel m(4096);
    CHECK(m.pushRecord(ring::Event::Begin, 0, 9, 0, nullptr, 0) == ring::PushResult::Ok);
    ring::Event ev{};
    uint8_t nt;
    uint64_t sess;
    uint32_t seq;
    std::vector<uint8_t> pay;
    CHECK(m.pullRecord(ev, nt, sess, seq, pay));

    uint8_t b[4] = {1, 2, 3, 4};
    CHECK(m.pushRecord(ring::Event::Nal, 5, 9, 0, b, 4) == ring::PushResult::Ok);
    CHECK(m.pullRecord(ev, nt, sess, seq, pay));
    CHECK(seq == 0);

    // Skip seq 1 — publish seq 2
    CHECK(m.pushRecord(ring::Event::Nal, 5, 9, 2, b, 4) == ring::PushResult::Ok);
    CHECK(!m.pullRecord(ev, nt, sess, seq, pay)); // must fail
    CHECK(m.desyncSticky());
    CHECK(m.lastBadSeq() == 2);
    std::fprintf(stderr, "  OK NEG skip-seq desync last_bad=%u\n", m.lastBadSeq());
}

static void testNegPartialPublishUnderrun() {
    std::fprintf(stderr, "--- testNegPartialPublishUnderrun ---\n");
    ring::BitstreamRingModel m(4096);
    CHECK(m.pushRecord(ring::Event::Begin, 0, 1, 0, nullptr, 0) == ring::PushResult::Ok);
    ring::Event ev{};
    uint8_t nt;
    uint64_t sess;
    uint32_t seq;
    std::vector<uint8_t> pay;
    CHECK(m.pullRecord(ev, nt, sess, seq, pay));

    // Header claims 100-byte payload but only advance write by header (corrupt)
    uint8_t hdr[32];
    ring::packPlxnHeader(hdr, ring::Event::Nal, 1, 1, 0, 100);
    m.pokeAtWriteOffset(m.writeCount(), hdr, 32);
    m.corruptAdvanceWrite(32); // published header only — payload missing
    CHECK(!m.pullRecord(ev, nt, sess, seq, pay));
    CHECK(m.underrunSticky());
    std::fprintf(stderr, "  OK NEG partial publish → underrun sticky\n");
}

static void testNegOverrunFull() {
    std::fprintf(stderr, "--- testNegOverrunFull ---\n");
    ring::BitstreamRingModel m(64); // only two empty headers fit
    CHECK(m.pushRecord(ring::Event::Begin, 0, 1, 0, nullptr, 0) == ring::PushResult::Ok);
    CHECK(m.pushRecord(ring::Event::End, 0, 1, 0, nullptr, 0) == ring::PushResult::Ok);
    auto r = m.pushRecord(ring::Event::Nal, 1, 1, 0, nullptr, 0);
    CHECK(r == ring::PushResult::Full);
    CHECK(m.overrunSticky());
    std::fprintf(stderr, "  OK NEG full ring → Full+overrun\n");
}

static void testFabricDecodeBwBudget() {
    std::fprintf(stderr, "--- testFabricDecodeBwBudget ---\n");
    using namespace misterplex;
    const double peak = fabricDdrPeakMBps();
    CHECK(peak == 720.0);
    // 720p60 fabric decode+present mid ref_factor=1.5
    const double c60 = fabricDecodePresentCombinedMBps(60.0, 1.5);
    const double c24 = fabricDecodePresentCombinedMBps(24.0, 1.5);
    // scan 82.94 + write 82.94 + ref 124.42 + bs ~0.32 ≈ 290.6
    CHECK(c60 > 250.0 && c60 < 350.0);
    CHECK(c24 > 100.0 && c24 < 150.0);
    CHECK(c60 < peak * 0.5); // under half of theoretical peak
    CHECK(fabricBitstreamRingReadMBps(2585.0) < 0.5);
    std::fprintf(stderr, "  OK decode+present MBps@24=%.1f @60=%.1f peak=%.0f (%.1f%%@60)\n", c24,
                 c60, peak, 100.0 * c60 / peak);
}

int main() {
    testMapCollisionFence();
    testBitrateArithmetic();
    testMeasuredWorstAuHeadroom();
    testPlxnRoundTrip();
    testHappyPathWrap();
    testNegSkippedSeq();
    testNegPartialPublishUnderrun();
    testNegOverrunFull();
    testFabricDecodeBwBudget();
    if (fails) {
        std::fprintf(stderr, "FAILED %d checks\n", fails);
        return 1;
    }
    std::fprintf(stderr, "ALL OK test_bitstream_ring_abi\n");
    return 0;
}
