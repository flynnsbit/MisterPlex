// test_bitstream_ring_lifecycle.cpp — Exercises the full NalDispatcher →
// CopyRingBitstreamProducer chain with real H.264 fixture data.
// Covers: session begin/push/end, seek (flush→re-begin), pause/resume,
// mid-stream teardown, dormant status, and ring Full backpressure.

#include "libmisterplex/h264_nal_dispatch.hpp"
#include "libmisterplex/ddr_bitstream_ring.hpp"

#include <cassert>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iterator>
#include <vector>

using namespace misterplex::h264stream;
namespace ring = misterplex::ddr_bitstream_ring;

static int fails = 0;
#define CHECK(cond)                                                                               \
    do {                                                                                           \
        if (!(cond)) {                                                                             \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                  \
            ++fails;                                                                               \
        }                                                                                          \
    } while (0)

static std::vector<uint8_t> readFile(const char* path) {
    std::ifstream in(path, std::ios::binary);
    if (!in.good()) {
        std::fprintf(stderr, "FAIL: cannot open %s\n", path);
        ++fails;
        return {};
    }
    return {std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>()};
}

static std::vector<uint8_t> makeNal(uint8_t type, size_t payloadBytes) {
    std::vector<uint8_t> v{0, 0, 0, 1, static_cast<uint8_t>(0x60 | (type & 0x1f))};
    for (size_t i = 0; i < payloadBytes; ++i)
        v.push_back(static_cast<uint8_t>(i & 0xff));
    return v;
}

// Parse Annex-B stream into individual NALs.
static std::vector<std::vector<uint8_t>> splitNals(const uint8_t* data, size_t len) {
    std::vector<std::vector<uint8_t>> nals;
    std::vector<size_t> starts;
    for (size_t i = 0; i + 3 < len;) {
        if (i + 3 < len && data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1) {
            starts.push_back(i);
            i += 3;
        } else if (i + 4 <= len && data[i] == 0 && data[i + 1] == 0 &&
                   data[i + 2] == 0 && data[i + 3] == 1) {
            starts.push_back(i);
            i += 4;
        } else {
            ++i;
        }
    }
    for (size_t k = 0; k < starts.size(); ++k) {
        size_t end = (k + 1 < starts.size()) ? starts[k + 1] : len;
        nals.emplace_back(data + starts[k], data + end);
    }
    return nals;
}

static void testBasicSessionLifecycle() {
    std::fprintf(stderr, "--- testBasicSessionLifecycle ---\n");
    CopyRingBitstreamProducer ring(ring::kRingBytes);
    NalDispatcher dispatch(ring);

    CHECK(dispatch.begin(42) == ControlResult::Ok);

    auto sps = makeNal(7, 10);
    auto pps = makeNal(8, 5);
    auto idr = makeNal(5, 100);

    CHECK(dispatch.handleNal(sps.data(), sps.size()) == PushResult::Ok);
    CHECK(dispatch.handleNal(pps.data(), pps.size()) == PushResult::Ok);
    CHECK(dispatch.handleNal(idr.data(), idr.size()) == PushResult::Ok);

    auto st = ring.status();
    CHECK(st.active);
    CHECK(st.nal_accepted == 3);
    CHECK(st.bytes_accepted > 0);

    CHECK(dispatch.end() == ControlResult::Ok);
    st = ring.status();
    CHECK(!st.active);
    std::fprintf(stderr, "  OK: begin→push→end, nal_accepted=%llu bytes=%llu\n",
                 static_cast<unsigned long long>(st.nal_accepted),
                 static_cast<unsigned long long>(st.bytes_accepted));
}

static void testFixtureFullStream() {
    std::fprintf(stderr, "--- testFixtureFullStream ---\n");
    auto data = readFile("tests/fixtures/p3_multinal/wcap_residual14_idr_plus_p.264");
    if (data.empty()) return;

    auto nals = splitNals(data.data(), data.size());
    CHECK(nals.size() >= 3); // SPS + PPS + at least one slice

    CopyRingBitstreamProducer ring(ring::kRingBytes);
    NalDispatcher dispatch(ring);
    CHECK(dispatch.begin(1) == ControlResult::Ok);

    size_t pushed = 0;
    for (const auto& nal : nals) {
        auto r = dispatch.handleNal(nal.data(), nal.size());
        CHECK(r == PushResult::Ok);
        ++pushed;
    }
    CHECK(pushed == nals.size());
    CHECK(dispatch.end() == ControlResult::Ok);
    auto st = ring.status();
    std::fprintf(stderr, "  OK: fixture nals=%zu pushed=%llu bytes=%llu\n",
                 nals.size(), static_cast<unsigned long long>(st.nal_accepted),
                 static_cast<unsigned long long>(st.bytes_accepted));
}

static void testSeekFlushReset() {
    std::fprintf(stderr, "--- testSeekFlushReset ---\n");
    CopyRingBitstreamProducer ring(ring::kRingBytes);
    NalDispatcher dispatch(ring);

    CHECK(dispatch.begin(1) == ControlResult::Ok);
    auto sps = makeNal(7, 10);
    auto pps = makeNal(8, 5);
    auto idr = makeNal(5, 100);
    CHECK(dispatch.handleNal(sps.data(), sps.size()) == PushResult::Ok);
    CHECK(dispatch.handleNal(pps.data(), pps.size()) == PushResult::Ok);
    CHECK(dispatch.handleNal(idr.data(), idr.size()) == PushResult::Ok);

    auto st1 = ring.status();
    CHECK(st1.nal_accepted == 3);

    // Seek: flush old session, begin new one
    CHECK(dispatch.flushForSeek(2) == ControlResult::Ok);
    auto st2 = ring.status();
    CHECK(st2.active);

    // After seek, SPS/PPS from old session are cleared.
    // Must push new parameter sets before VCL. This is correct behavior —
    // the transport requires fresh params after a discontinuity.
    CHECK(dispatch.handleNal(sps.data(), sps.size()) == PushResult::Ok);
    CHECK(dispatch.handleNal(pps.data(), pps.size()) == PushResult::Ok);

    // Now push post-seek IDR
    auto idr2 = makeNal(5, 200);
    auto r = dispatch.handleNal(idr2.data(), idr2.size());
    CHECK(r == PushResult::Ok);

    // SPS/PPS were pushed explicitly, not replayed
    auto stats = dispatch.stats();
    CHECK(stats.sps_replayed == 0);
    CHECK(stats.pps_replayed == 0);

    CHECK(dispatch.end() == ControlResult::Ok);
    std::fprintf(stderr, "  OK: seek/flush→re-begin, sps_replayed=%llu pps_replayed=%llu\n",
                 static_cast<unsigned long long>(stats.sps_replayed),
                 static_cast<unsigned long long>(stats.pps_replayed));
}

static void testPauseResume() {
    std::fprintf(stderr, "--- testPauseResume ---\n");
    CopyRingBitstreamProducer ring(ring::kRingBytes);
    NalDispatcher dispatch(ring);

    CHECK(dispatch.begin(1) == ControlResult::Ok);
    auto sps = makeNal(7, 10);
    auto pps = makeNal(8, 5);
    auto idr = makeNal(5, 100);
    CHECK(dispatch.handleNal(sps.data(), sps.size()) == PushResult::Ok);
    CHECK(dispatch.handleNal(pps.data(), pps.size()) == PushResult::Ok);
    CHECK(dispatch.handleNal(idr.data(), idr.size()) == PushResult::Ok);

    CHECK(dispatch.pause() == ControlResult::Ok);
    auto st = ring.status();
    CHECK(st.paused);

    // NALs while paused should be silently dropped
    auto p1 = makeNal(1, 50);
    CHECK(dispatch.handleNal(p1.data(), p1.size()) == PushResult::Ok);
    auto stats = dispatch.stats();
    CHECK(stats.nal_dropped_paused >= 1);

    CHECK(dispatch.resume() == ControlResult::Ok);
    st = ring.status();
    CHECK(!st.paused);

    // After resume, SPS/PPS should replay before next VCL
    auto idr2 = makeNal(5, 80);
    CHECK(dispatch.handleNal(idr2.data(), idr2.size()) == PushResult::Ok);
    stats = dispatch.stats();
    CHECK(stats.sps_replayed >= 1);

    CHECK(dispatch.end() == ControlResult::Ok);
    std::fprintf(stderr, "  OK: pause dropped=%llu, resume replayed sps=%llu pps=%llu\n",
                 static_cast<unsigned long long>(stats.nal_dropped_paused),
                 static_cast<unsigned long long>(stats.sps_replayed),
                 static_cast<unsigned long long>(stats.pps_replayed));
}

static void testRingFullBackpressure() {
    std::fprintf(stderr, "--- testRingFullBackpressure ---\n");
    // Tiny ring: only 512 bytes. Push until Full.
    CopyRingBitstreamProducer ring(512);
    NalDispatcher dispatch(ring, DispatchConfig{0, 0}); // no retries

    CHECK(dispatch.begin(1) == ControlResult::Ok);
    auto sps = makeNal(7, 10);
    auto pps = makeNal(8, 5);
    CHECK(dispatch.handleNal(sps.data(), sps.size()) == PushResult::Ok);
    CHECK(dispatch.handleNal(pps.data(), pps.size()) == PushResult::Ok);

    // Push increasingly large NALs until the ring fills
    bool sawFull = false;
    for (int i = 0; i < 100; ++i) {
        auto big = makeNal(5, 200);
        auto r = dispatch.handleNal(big.data(), big.size());
        if (r == PushResult::Full) {
            sawFull = true;
            break;
        }
    }
    CHECK(sawFull);
    auto stats = dispatch.stats();
    CHECK(stats.full_escalations >= 1);
    // Ring overrun count should be recorded
    auto st = ring.status();
    CHECK(st.overrun_count >= 1);
    std::fprintf(stderr, "  OK: Full after %llu nals, overrun_count=%llu\n",
                 static_cast<unsigned long long>(stats.nal_pushed),
                 static_cast<unsigned long long>(st.overrun_count));
}

static void testDormantStatus() {
    std::fprintf(stderr, "--- testDormantStatus ---\n");
    ring::Status st{};
    // Default: not dormant
    CHECK(!st.dormant);
    // Set dormant flag
    st.dormant = true;
    CHECK(st.dormant);
    std::fprintf(stderr, "  OK: dormant flag set/clear\n");
}

static void testCtrlDormantMagic() {
    std::fprintf(stderr, "--- testCtrlDormantMagic ---\n");
    // Verify PLXD magic is distinct from all other magics
    CHECK(ring::kCtrlDormantMagic != ring::kCtrlMagic);
    CHECK(ring::kCtrlDormantMagic != ring::kReadMagic);
    CHECK(ring::kCtrlDormantMagic != ring::kErrMagic);
    CHECK(ring::kCtrlDormantMagic != ring::kRecordMagic);
    CHECK(ring::kCtrlDormantMagic != ring::kStat0Magic);
    CHECK(ring::kCtrlDormantMagic != ring::kStat1Magic);
    CHECK(ring::kCtrlDormantMagic != ring::kStat2Magic);
    CHECK(ring::kCtrlDormantMagic != ring::kStat3Magic);
    CHECK(ring::kCtrlDormantMagic != ring::kStat4Magic);
    CHECK(ring::kCtrlDormantMagic != ring::kStat5Magic);
    CHECK(ring::kCtrlDormantMagic != ring::kStat6Magic);
    // PLXD = 0x504C5844
    CHECK(ring::kCtrlDormantMagic == mailbox_abi::kPlxbDormantMagic);
    // Verify it follows the PLX? naming scheme
    CHECK((ring::kCtrlDormantMagic & 0xFFFFFF00u) == 0x504C5800u);
    std::fprintf(stderr, "  OK: PLXD=0x%08X unique, PLX? family\n", ring::kCtrlDormantMagic);
}

static void testMidStreamTeardown() {
    std::fprintf(stderr, "--- testMidStreamTeardown ---\n");
    auto data = readFile("tests/fixtures/p3_inter_pred/plex_inter_p16_baseline_320x240_12f.264");
    if (data.empty()) return;

    auto nals = splitNals(data.data(), data.size());
    CHECK(nals.size() >= 5);

    CopyRingBitstreamProducer ring(ring::kRingBytes);
    NalDispatcher dispatch(ring);
    CHECK(dispatch.begin(99) == ControlResult::Ok);

    // Push only half the NALs (simulates mid-stream teardown)
    size_t half = nals.size() / 2;
    for (size_t i = 0; i < half; ++i) {
        auto r = dispatch.handleNal(nals[i].data(), nals[i].size());
        CHECK(r == PushResult::Ok);
    }

    // End mid-stream — should complete cleanly
    CHECK(dispatch.end() == ControlResult::Ok);
    auto st = ring.status();
    CHECK(!st.active);
    CHECK(st.nal_accepted == half);
    std::fprintf(stderr, "  OK: mid-stream end after %zu/%zu nals, ring clean\n", half, nals.size());
}

static void testRingCapacitySustain() {
    std::fprintf(stderr, "--- testRingCapacitySustain ---\n");
    // Simulate sustained 25 fps at ~1345 kbps: push 1000 frames, consuming between pushes.
    CopyRingBitstreamProducer ring(ring::kRingBytes);
    NalDispatcher dispatch(ring);
    CHECK(dispatch.begin(7) == ControlResult::Ok);

    auto sps = makeNal(7, 20);
    auto pps = makeNal(8, 8);
    CHECK(dispatch.handleNal(sps.data(), sps.size()) == PushResult::Ok);
    CHECK(dispatch.handleNal(pps.data(), pps.size()) == PushResult::Ok);

    // ~6725 bytes/frame at 1345kbps/25fps. Push 1000 frames, draining between each.
    const size_t framePayload = 6700;
    bool anyFail = false;
    for (int i = 0; i < 1000; ++i) {
        // Every 30th frame is an IDR (larger)
        uint8_t nalType = (i % 30 == 0) ? 5 : 1;
        size_t sz = (nalType == 5) ? framePayload * 4 : framePayload;
        auto frame = makeNal(nalType, sz);

        // If IDR, replay SPS+PPS needed — dispatch handles that
        auto r = dispatch.handleNal(frame.data(), frame.size());
        if (r != PushResult::Ok) {
            std::fprintf(stderr, "  FAIL at frame %d: %s\n", i, toString(r));
            anyFail = true;
            break;
        }

        // Simulate FPGA consuming — drain everything pushed so far
        ring.consumeBytes(ring.snapshot().size());
    }
    CHECK(!anyFail);
    auto stats = dispatch.stats();
    CHECK(stats.full_escalations == 0);
    CHECK(dispatch.end() == ControlResult::Ok);
    std::fprintf(stderr, "  OK: sustained 1000 frames, bytes=%llu full_escalations=0\n",
                 static_cast<unsigned long long>(stats.bytes_pushed));
}

int main() {
    testBasicSessionLifecycle();
    testFixtureFullStream();
    testSeekFlushReset();
    testPauseResume();
    testRingFullBackpressure();
    testDormantStatus();
    testCtrlDormantMagic();
    testMidStreamTeardown();
    testRingCapacitySustain();

    if (fails) {
        std::fprintf(stderr, "test_bitstream_ring_lifecycle: %d FAIL(s)\n", fails);
        return 1;
    }
    std::fprintf(stderr, "test_bitstream_ring_lifecycle: ALL PASS\n");
    return 0;
}
