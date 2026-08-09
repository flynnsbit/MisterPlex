// Does the bitstream feed give the FPGA decoder a stream it can actually
// start decoding?
//
// The feed's job in the staging plan is narrow: hand the decoder a supply of
// NALs such that it can begin at a keyframe and keep going. Two properties
// decide whether that is true, and neither is about throughput:
//
//   1. EVERY IDR must be a valid entry point. If SPS/PPS are sent once per
//      session, a decoder that comes up late, restarts, or loses the head of
//      the ring to a wrap has no parameter sets and can never decode a single
//      macroblock. It would look like a decoder bug and is not.
//
//   2. A FULL RING MUST NOT KILL THE FEED. During decoder bring-up the
//      consumer is absent by definition, so the ring fills in well under a
//      second. If that is fatal, the feed is dead before the decoder is ever
//      switched on, and every subsequent RTL experiment reads a stale ring.
//
// Both are tested here against a fake producer, so they run with no device.

#include "libmisterplex/h264_nal_dispatch.hpp"

#include <cstdio>
#include <string>
#include <vector>

using namespace misterplex::h264stream;

static int fails = 0;
#define CHECK(cond)                                                            \
    do {                                                                       \
        if (!(cond)) {                                                         \
            std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);        \
            ++fails;                                                           \
        }                                                                      \
    } while (0)

namespace {

struct Pushed {
    uint8_t type;
    uint32_t seq;
};

// Fake ring. `capacity` NALs are accepted, then it reports Full until drained,
// which is exactly how the real 256 KB ring behaves against a stalled consumer.
class FakeProducer : public IBitstreamProducer {
public:
    int capacity = 1000000;
    std::vector<Pushed> pushed;
    bool begun = false;

    ControlResult begin(uint64_t) override {
        begun = true;
        return ControlResult::Ok;
    }
    PushResult pushNal(const NalView& nal) override {
        if (static_cast<int>(pushed.size()) >= capacity)
            return PushResult::Full;
        pushed.push_back({nal.nal_type, nal.seq});
        return PushResult::Ok;
    }
    ControlResult flush(uint64_t) override { return ControlResult::Ok; }
    ControlResult end(uint64_t) override { return ControlResult::Ok; }
    ControlResult pause(uint64_t) override { return ControlResult::Ok; }
    ControlResult resume(uint64_t) override { return ControlResult::Ok; }
    Telemetry status() const override { return Telemetry{}; }
};

std::vector<uint8_t> nal(uint8_t type, size_t payload = 8) {
    std::vector<uint8_t> v{0x00, 0x00, 0x00, 0x01};
    v.push_back(static_cast<uint8_t>(type & 0x1F)); // nal_ref_idc 0 is fine here
    v.resize(v.size() + payload, 0x42);
    return v;
}

void feed(NalDispatcher& d, uint8_t type, PushResult* out = nullptr) {
    const auto n = nal(type);
    const auto r = d.handleNal(n.data(), n.size());
    if (out)
        *out = r;
}

// Walk the pushed sequence and confirm that from every IDR onward a decoder
// has seen an SPS and a PPS *at or before* that IDR.
bool everyIdrIsSelfContained(const std::vector<Pushed>& pushed) {
    bool sps = false, pps = false;
    for (const auto& p : pushed) {
        if (p.type == 7)
            sps = true;
        else if (p.type == 8)
            pps = true;
        else if (p.type == 5) {
            // A decoder joining at THIS IDR must find the parameter sets
            // immediately preceding it, so reset and require them each time.
            if (!sps || !pps)
                return false;
            sps = false;
            pps = false;
        }
    }
    return true;
}

} // namespace

int main() {
    std::printf("Scope: 4 (IDR self-containment; full-ring resync; seq continuity; no-regress)\n");

    // 1. Every IDR carries its own SPS/PPS.
    {
        FakeProducer p;
        NalDispatcher d(p);
        CHECK(d.begin(1) == ControlResult::Ok);
        feed(d, 7);
        feed(d, 8);
        for (int gop = 0; gop < 3; ++gop) {
            feed(d, 5);
            for (int i = 0; i < 4; ++i)
                feed(d, 1);
        }
        CHECK(everyIdrIsSelfContained(p.pushed));
        // 3 IDRs, and the parameter sets precede each of them.
        int idrs = 0, spss = 0;
        for (const auto& x : p.pushed) {
            if (x.type == 5)
                ++idrs;
            if (x.type == 7)
                ++spss;
        }
        CHECK(idrs == 3);
        // 1 explicit SPS + 1 replayed ahead of each of the 3 IDRs. The replay
        // before the first IDR is redundant by a few bytes; the feed stays
        // dumb rather than tracking whether it happens to be redundant.
        CHECK(spss == 4);
        CHECK(d.stats().sps_replayed == 3);
        CHECK(d.stats().pps_replayed == 3);
    }

    // 2. RED for the old behaviour: with per-IDR replay disabled, a decoder
    // joining at the second IDR has no parameter sets. This is what shipped.
    {
        FakeProducer p;
        DispatchConfig cfg;
        cfg.replay_parameters_each_idr = false;
        NalDispatcher d(p, cfg);
        CHECK(d.begin(1) == ControlResult::Ok);
        feed(d, 7);
        feed(d, 8);
        feed(d, 5);
        feed(d, 1);
        feed(d, 5);
        CHECK(!everyIdrIsSelfContained(p.pushed));
    }

    // 3. A full ring must not be fatal, and the feed must rejoin at the next
    // IDR with parameter sets in front of it.
    {
        FakeProducer p;
        DispatchConfig cfg;
        cfg.max_full_retries = 0;
        cfg.full_retry_sleep_ms = 0;
        cfg.sleep_ms = [](int) {};
        NalDispatcher d(p, cfg);
        CHECK(d.begin(1) == ControlResult::Ok);
        feed(d, 7);
        feed(d, 8);
        feed(d, 5);

        p.capacity = static_cast<int>(p.pushed.size()); // consumer stalls now
        PushResult r{};
        for (int i = 0; i < 20; ++i) {
            feed(d, 1, &r);
            CHECK(r == PushResult::Ok); // never fatal to the producer
        }
        CHECK(d.stats().resyncs >= 1);

        const size_t stalled_at = p.pushed.size();
        p.capacity = 1000000; // consumer drains
        feed(d, 1, &r);       // still undecodable, must stay dropped
        CHECK(r == PushResult::Ok);
        CHECK(p.pushed.size() == stalled_at);

        feed(d, 5, &r); // IDR: rejoin here
        CHECK(r == PushResult::Ok);
        CHECK(p.pushed.size() > stalled_at);
        CHECK(everyIdrIsSelfContained(p.pushed));
        CHECK(d.stats().nal_dropped_resync >= 1);
    }

    // 4. The extra parameter sets must not break sequence numbering: every
    // pushed NAL carries a strictly increasing seq the consumer can trust.
    {
        FakeProducer p;
        NalDispatcher d(p);
        CHECK(d.begin(7) == ControlResult::Ok);
        feed(d, 7);
        feed(d, 8);
        for (int i = 0; i < 3; ++i) {
            feed(d, 5);
            feed(d, 1);
        }
        bool monotonic = true;
        for (size_t i = 1; i < p.pushed.size(); ++i)
            if (p.pushed[i].seq != p.pushed[i - 1].seq + 1)
                monotonic = false;
        CHECK(monotonic);
        CHECK(!p.pushed.empty() && p.pushed.front().seq == 0);
    }

    if (fails) {
        std::fprintf(stderr, "test_bitstream_feed_entry_points: %d failure(s)\n", fails);
        return 1;
    }
    std::printf("test_bitstream_feed_entry_points: OK\n");
    return 0;
}
