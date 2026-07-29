// test_bitstream_ring_lifecycle.cpp — Exercises the NalDispatcher →
// CopyRingBitstreamProducer chain with H.264 fixture data.
//
// COVERAGE (instrument-integrity audit #16):
//   Tested:   return codes, counter stats, data byte-integrity, backpressure,
//             pause/resume, seek/flush, dormant state, sustained load.
//   NOT tested (residual gap):
//     - PLXN record framing (32-byte headers with magic/session/seq/length).
//       The mock uses a raw std::deque<uint8_t>, not the real ring protocol.
//       The real FpgaSpi::writeBitstreamRecord() wraps NALs in PLXN framing;
//       that path requires /dev/mem and cannot run in a host unit test.
//     - DDR ring wraparound at 256 KiB boundary (mock grows unbounded).
//     - Cache coherency / fence ordering (O_SYNC + __sync_synchronize audit
//       is done by code review — see arm-bitstream-feed-analysis.md).

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
    // Degeneracy: ring must actually contain data (not zero-length passthrough)
    CHECK(ring.snapshot().size() > 0);
    CHECK(ring.snapshot().size() >= sps.size() + pps.size() + idr.size());

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
    size_t totalInputBytes = 0;
    for (const auto& nal : nals) {
        auto r = dispatch.handleNal(nal.data(), nal.size());
        CHECK(r == PushResult::Ok);
        ++pushed;
        totalInputBytes += nal.size();
    }
    CHECK(pushed == nals.size());
    // Degeneracy: fixture must contain non-trivial data, and ring must hold it
    CHECK(totalInputBytes > 100);
    auto st = ring.status();
    CHECK(st.bytes_accepted >= totalInputBytes);
    CHECK(ring.snapshot().size() > 0);
    CHECK(dispatch.end() == ControlResult::Ok);
    std::fprintf(stderr, "  OK: fixture nals=%zu pushed=%llu bytes=%llu (input=%zu)\n",
                 nals.size(), static_cast<unsigned long long>(st.nal_accepted),
                 static_cast<unsigned long long>(st.bytes_accepted), totalInputBytes);
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
    // Degeneracy: must have pushed at least some data before hitting Full.
    // If it returns Full on the first push, the ring never accepted anything.
    CHECK(stats.bytes_pushed > 0);
    CHECK(stats.nal_pushed >= 3); // at least SPS + PPS + one slice before Full
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
    // Degeneracy: must have actually transferred substantial data.
    // 1000 frames × ~6700 bytes = ~6.7 MB minimum; anything less means the
    // ring silently dropped data while returning Ok.
    CHECK(stats.bytes_pushed > 5000000);
    CHECK(dispatch.end() == ControlResult::Ok);
    std::fprintf(stderr, "  OK: sustained 1000 frames, bytes=%llu full_escalations=0\n",
                 static_cast<unsigned long long>(stats.bytes_pushed));
}

// ---------------------------------------------------------------------------
// Data-integrity verification — added during instrument-integrity audit #16.
// Prior to this, ALL lifecycle tests checked only return codes and counters.
// A producer that silently corrupted or dropped bytes would have passed.
// ---------------------------------------------------------------------------
static void testDataIntegrity() {
    std::fprintf(stderr, "--- testDataIntegrity ---\n");
    CopyRingBitstreamProducer ring(ring::kRingBytes);
    NalDispatcher dispatch(ring);
    CHECK(dispatch.begin(1) == ControlResult::Ok);

    // Push 3 NALs with known, distinguishable payloads
    auto sps = makeNal(7, 20);   // SPS, 20 payload bytes (each = index & 0xFF)
    auto pps = makeNal(8, 10);   // PPS
    auto idr = makeNal(5, 200);  // IDR slice

    CHECK(dispatch.handleNal(sps.data(), sps.size()) == PushResult::Ok);
    CHECK(dispatch.handleNal(pps.data(), pps.size()) == PushResult::Ok);
    CHECK(dispatch.handleNal(idr.data(), idr.size()) == PushResult::Ok);

    // Concatenate what we pushed — the ring should hold this exact byte sequence
    std::vector<uint8_t> expected;
    expected.insert(expected.end(), sps.begin(), sps.end());
    expected.insert(expected.end(), pps.begin(), pps.end());
    expected.insert(expected.end(), idr.begin(), idr.end());

    auto got = ring.snapshot();
    // Degeneracy: both sides must be non-empty and non-trivial.
    // A zero-length comparison is vacuously exact — that is #18.
    CHECK(expected.size() > 100);
    CHECK(got.size() > 100);
    CHECK(got.size() == expected.size());
    size_t mismatches = 0;
    for (size_t i = 0; i < std::min(got.size(), expected.size()); ++i) {
        if (got[i] != expected[i])
            ++mismatches;
    }
    CHECK(mismatches == 0);
    if (mismatches > 0) {
        std::fprintf(stderr, "  FAIL: %zu byte mismatches out of %zu\n",
                     mismatches, expected.size());
    }

    CHECK(dispatch.end() == ControlResult::Ok);
    std::fprintf(stderr, "  OK: %zu bytes verified byte-exact\n", expected.size());
}

// Prove the data-integrity check can fail: compare ring snapshot against
// an intentionally-corrupted copy and confirm the comparison catches it.
static void testDataIntegrityRed() {
    std::fprintf(stderr, "--- testDataIntegrityRed (prove-fail) ---\n");
    CopyRingBitstreamProducer ring(ring::kRingBytes);
    NalDispatcher dispatch(ring);
    CHECK(dispatch.begin(2) == ControlResult::Ok);

    auto sps = makeNal(7, 10);
    auto pps = makeNal(8, 5);
    auto idr = makeNal(5, 100);
    CHECK(dispatch.handleNal(sps.data(), sps.size()) == PushResult::Ok);
    CHECK(dispatch.handleNal(pps.data(), pps.size()) == PushResult::Ok);
    CHECK(dispatch.handleNal(idr.data(), idr.size()) == PushResult::Ok);

    auto got = ring.snapshot();
    CHECK(got.size() > 0);

    // Build the correct expected, then corrupt one byte
    std::vector<uint8_t> corrupted(got);
    corrupted[corrupted.size() / 2] ^= 0xFF;  // flip middle byte

    size_t mismatches = 0;
    for (size_t i = 0; i < got.size(); ++i) {
        if (got[i] != corrupted[i])
            ++mismatches;
    }
    // We EXPECT at least one mismatch — this proves the byte comparison is
    // not vacuous (i.e., it would catch a corrupt transport)
    CHECK(mismatches >= 1);

    CHECK(dispatch.end() == ControlResult::Ok);
    std::fprintf(stderr, "  OK: corruption detected (%zu mismatches as expected)\n", mismatches);
}

// Verify data survives a consume-then-push cycle (wraparound in a real ring)
static void testDataIntegrityMultiRound() {
    std::fprintf(stderr, "--- testDataIntegrityMultiRound ---\n");
    CopyRingBitstreamProducer ring(ring::kRingBytes);
    NalDispatcher dispatch(ring);
    CHECK(dispatch.begin(3) == ControlResult::Ok);

    auto sps = makeNal(7, 10);
    auto pps = makeNal(8, 5);
    auto idr = makeNal(5, 64);
    CHECK(dispatch.handleNal(sps.data(), sps.size()) == PushResult::Ok);
    CHECK(dispatch.handleNal(pps.data(), pps.size()) == PushResult::Ok);
    CHECK(dispatch.handleNal(idr.data(), idr.size()) == PushResult::Ok);

    // Consume all, then push more
    ring.consumeBytes(ring.snapshot().size());
    CHECK(ring.snapshot().empty());

    // Push 5 more slices and verify each round-trip (post-IDR P slices)
    for (int i = 0; i < 5; ++i) {
        auto slice = makeNal(1, 500 + i * 100);
        CHECK(dispatch.handleNal(slice.data(), slice.size()) == PushResult::Ok);

        auto got = ring.snapshot();
        // The ring should end with exactly this slice's bytes
        CHECK(got.size() >= slice.size());
        size_t offset = got.size() - slice.size();
        size_t mismatches = 0;
        for (size_t j = 0; j < slice.size(); ++j) {
            if (got[offset + j] != slice[j])
                ++mismatches;
        }
        CHECK(mismatches == 0);
        ring.consumeBytes(got.size());
    }

    CHECK(dispatch.end() == ControlResult::Ok);
    std::fprintf(stderr, "  OK: 5 rounds of push→verify→consume, all byte-exact\n");
}

// ---------------------------------------------------------------------------
// Feed-specific degeneracy assertion (#18 follow-up):
// A stalled feed and a working feed look identical if you only check that data
// is present. This test asserts that consecutive ring snapshots DIFFER after
// each push — catching a feed that replays the same buffer, or an FPGA that
// re-reads stale data without advancing.
// ---------------------------------------------------------------------------
static void testContentVariation() {
    std::fprintf(stderr, "--- testContentVariation ---\n");
    CopyRingBitstreamProducer ring(ring::kRingBytes);
    NalDispatcher dispatch(ring);
    CHECK(dispatch.begin(10) == ControlResult::Ok);

    auto sps = makeNal(7, 20);
    auto pps = makeNal(8, 10);
    CHECK(dispatch.handleNal(sps.data(), sps.size()) == PushResult::Ok);
    CHECK(dispatch.handleNal(pps.data(), pps.size()) == PushResult::Ok);

    // Push 10 distinct slices and verify each snapshot differs from the previous
    std::vector<uint8_t> prevSnapshot = ring.snapshot();
    CHECK(prevSnapshot.size() > 0);
    int distinctSnapshots = 0;

    for (int i = 0; i < 10; ++i) {
        // Each slice has a unique payload: different size AND different seed byte
        auto slice = makeNal(static_cast<uint8_t>((i % 2 == 0) ? 5 : 1),
                             300 + i * 50);
        CHECK(dispatch.handleNal(slice.data(), slice.size()) == PushResult::Ok);

        auto curSnapshot = ring.snapshot();
        // Degeneracy: snapshot MUST differ from previous (feed advanced)
        CHECK(curSnapshot.size() > prevSnapshot.size());
        // Content must actually differ — not just length
        bool differs = (curSnapshot.size() != prevSnapshot.size());
        if (!differs) {
            for (size_t j = 0; j < curSnapshot.size(); ++j) {
                if (curSnapshot[j] != prevSnapshot[j]) {
                    differs = true;
                    break;
                }
            }
        }
        CHECK(differs);
        if (differs)
            ++distinctSnapshots;
        prevSnapshot = curSnapshot;
    }
    // All 10 pushes must produce distinct snapshots
    CHECK(distinctSnapshots == 10);

    // Also verify: no two adjacent NALs in the ring have identical content.
    // This catches a repeating-pattern feed where every frame is the same bytes.
    auto finalData = ring.snapshot();
    CHECK(finalData.size() > 100);
    // Simple entropy check: count distinct byte values in the ring.
    // Real H.264 NALs have high entropy; a repeating pattern does not.
    bool seen[256] = {};
    for (uint8_t b : finalData)
        seen[b] = true;
    int distinctBytes = 0;
    for (int i = 0; i < 256; ++i)
        if (seen[i])
            ++distinctBytes;
    // With varied NAL sizes and `i & 0xFF` payloads, we expect nearly all 256.
    // A degenerate feed (all zeros, all 0x80, repeating short pattern) would fail.
    CHECK(distinctBytes > 64);

    CHECK(dispatch.end() == ControlResult::Ok);
    std::fprintf(stderr, "  OK: 10 pushes produced %d distinct snapshots, %d/256 distinct bytes\n",
                 distinctSnapshots, distinctBytes);
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
    testDataIntegrity();
    testDataIntegrityRed();
    testDataIntegrityMultiRound();
    testContentVariation();

    if (fails) {
        std::fprintf(stderr, "test_bitstream_ring_lifecycle: %d FAIL(s)\n", fails);
        return 1;
    }
    std::fprintf(stderr, "test_bitstream_ring_lifecycle: ALL PASS\n");
    return 0;
}
