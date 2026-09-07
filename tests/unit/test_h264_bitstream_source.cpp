#include "libmisterplex/h264_nal_dispatch.hpp"
#include "libmisterplex/ddr_bitstream_ring.hpp"

#include <cstdio>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

using namespace misterplex::h264stream;

namespace {
int fails = 0;
#define CHECK(x)                                                                                  \
    do {                                                                                           \
        if (!(x)) {                                                                                \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #x);                     \
            ++fails;                                                                               \
        }                                                                                          \
    } while (0)

std::vector<uint8_t> nal(uint8_t type, std::initializer_list<uint8_t> payload) {
    std::vector<uint8_t> v{0, 0, 0, 1, static_cast<uint8_t>(0x60 | (type & 0x1f))};
    v.insert(v.end(), payload.begin(), payload.end());
    return v;
}

std::vector<uint8_t> readFile(const char* path) {
    std::ifstream in(path, std::ios::binary);
    CHECK(in.good());
    return {std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>()};
}

struct FlakyProducer final : public IBitstreamProducer {
    CopyRingBitstreamProducer inner{1024};
    int full_before_ok = 0;
    ControlResult begin(uint64_t s) override { return inner.begin(s); }
    PushResult pushNal(const NalView& n) override {
        if (full_before_ok > 0) {
            --full_before_ok;
            return PushResult::Full;
        }
        return inner.pushNal(n);
    }
    ControlResult flush(uint64_t s) override { return inner.flush(s); }
    ControlResult end(uint64_t s) override { return inner.end(s); }
    ControlResult pause(uint64_t s) override { return inner.pause(s); }
    ControlResult resume(uint64_t s) override { return inner.resume(s); }
    Telemetry status() const override { return inner.status(); }
};
} // namespace

int main() {
    const auto sps = nal(7, {0x42, 0x00, 0x1e});
    const auto pps = nal(8, {0xce, 0x06});
    auto idr = nal(5, {0xaa, 0xbb, 0xcc});
    const auto p = nal(1, {0x11, 0x22});

    // Copy-on-push: producer owns bytes before returning.
    CopyRingBitstreamProducer ring(256);
    CHECK(ring.begin(10) == ControlResult::Ok);
    NalView v{10, 0, 5, idr.data(), idr.size()};
    CHECK(ring.pushNal(v) == PushResult::Ok);
    idr[5] ^= 0xff;
    const auto snap = ring.snapshot();
    CHECK(snap.size() == v.len);
    CHECK(snap[5] == 0xaa);
    CHECK(ring.begin(11) == ControlResult::ActiveSession);
    CHECK(ring.end(10) == ControlResult::Ok);

    // Pause preserves compressed references: unconsumed P NALs are retried.
    CopyRingBitstreamProducer replayRing(4096);
    DispatchConfig cfg;
    cfg.max_full_retries = 0;
    cfg.sleep_ms = [](int) {};
    NalDispatcher dispatch(replayRing, cfg);
    CHECK(dispatch.begin(20) == ControlResult::Ok);
    CHECK(dispatch.handleNal(sps.data(), sps.size()) == PushResult::Ok);
    CHECK(dispatch.handleNal(pps.data(), pps.size()) == PushResult::Ok);
    CHECK(dispatch.handleNal(idr.data(), idr.size()) == PushResult::Ok);
    CHECK(dispatch.pause() == ControlResult::Ok);
    CHECK(dispatch.handleNal(p.data(), p.size()) == PushResult::Full);
    CHECK(dispatch.resume() == ControlResult::Ok);
    CHECK(dispatch.handleNal(p.data(), p.size()) == PushResult::Ok);
    CHECK(dispatch.stats().nal_dropped_paused == 0);
    CHECK(dispatch.stats().sps_replayed == 0);
    CHECK(dispatch.stats().pps_replayed == 0);
    CHECK(dispatch.end() == ControlResult::Ok);

    // Full is transient and retried; persistent Full escalates distinctly.
    FlakyProducer flaky;
    NalDispatcher retry(flaky, cfg);
    CHECK(retry.begin(30) == ControlResult::Ok);
    flaky.full_before_ok = 1;
    DispatchConfig retryCfg;
    retryCfg.max_full_retries = 2;
    retryCfg.sleep_ms = [](int) {};
    NalDispatcher retry2(flaky, retryCfg);
    CHECK(retry.end() == ControlResult::Ok);
    CHECK(retry2.begin(31) == ControlResult::Ok);
    CHECK(retry2.handleNal(sps.data(), sps.size()) == PushResult::Ok);
    CHECK(retry2.stats().full_retries == 1);
    CHECK(retry2.end() == ControlResult::Ok);

    CopyRingBitstreamProducer tiny(8);
    CHECK(tiny.begin(40) == ControlResult::Ok);
    NalView big{40, 0, 5, idr.data(), idr.size()};
    CHECK(tiny.pushNal(big) == PushResult::Ok);
    NalView tooMuch{40, 1, 1, p.data(), p.size()};
    CHECK(tiny.pushNal(tooMuch) == PushResult::Full);
    CHECK(tiny.status().overrun_count == 1);
    CHECK(tiny.consumeBytes(4096) != 0);
    CHECK(tiny.consumeBytes(1) == 0);
    CHECK(tiny.status().underrun_count == 1);
    const auto pressure = tiny.status();

    // Ring-space reuse / wrap contract: after the consumer advances, producer
    // can fill freed space without forcing a session reset.
    CHECK(tiny.pushNal(tooMuch) == PushResult::Ok);
    CHECK(tiny.status().ring_level_bytes == tooMuch.len);
    const bool wrapReuseOk = tiny.status().nal_accepted == 2;
    CHECK(wrapReuseOk);

    CopyRingBitstreamProducer seqRing(128);
    CHECK(seqRing.begin(50) == ControlResult::Ok);
    NalView badSeq{50, 7, 5, idr.data(), idr.size()};
    CHECK(seqRing.pushNal(badSeq) == PushResult::Desync);
    CHECK(seqRing.status().desync_count == 1);
    CHECK(seqRing.status().last_bad_seq == 7);
    const auto seqStatus = seqRing.status();

    // Seek/flush must not splice a partial NAL from the old session into the new one.
    CopyRingBitstreamProducer seekRing(4096);
    NalDispatcher seekDispatch(seekRing, cfg);
    AnnexBFramer seekFramer;
    CHECK(seekDispatch.begin(55) == ControlResult::Ok);
    const uint8_t partial[] = {0, 0, 0, 1, 0x65, 0xaa, 0xbb};
    CHECK(seekFramer.push(partial, sizeof(partial), [&](const uint8_t* p, size_t n) {
        CHECK(seekDispatch.handleNal(p, n) == PushResult::Ok);
    }));
    CHECK(seekRing.status().nal_accepted == 0);
    seekFramer.reset();
    CHECK(seekDispatch.flushForSeek(56) == ControlResult::Ok);
    CHECK(seekRing.status().session_id == 56);
    CHECK(seekRing.status().nal_accepted == 0);
    CHECK(seekDispatch.handleNal(sps.data(), sps.size()) == PushResult::Ok);
    CHECK(seekDispatch.handleNal(pps.data(), pps.size()) == PushResult::Ok);
    CHECK(seekDispatch.handleNal(idr.data(), idr.size()) == PushResult::Ok);
    CHECK(seekRing.status().nal_accepted == 3);
    CHECK(seekDispatch.end() == ControlResult::Ok);

    const auto fixture = readFile("tests/fixtures/p3_multinal/wcap_residual14_idr_plus_p.264");
    CHECK(fixture.size() == 9060);
    CopyRingBitstreamProducer fixtureRing(64 * 1024);
    NalDispatcher fixtureDispatch(fixtureRing, cfg);
    AnnexBFramer framer;
    CHECK(fixtureDispatch.begin(60) == ControlResult::Ok);
    size_t fixtureNals = 0;
    size_t fixtureVcl = 0;
    size_t fixtureIdr = 0;
    for (size_t off = 0; off < fixture.size();) {
        const size_t chunk = std::min<size_t>((off % 17) + 1, fixture.size() - off);
        CHECK(framer.push(fixture.data() + off, chunk, [&](const uint8_t* p, size_t n) {
            const uint8_t type = annexBNalType(p, n);
            ++fixtureNals;
            if (type == 1 || type == 5)
                ++fixtureVcl;
            if (type == 5)
                ++fixtureIdr;
            CHECK(fixtureDispatch.handleNal(p, n) == PushResult::Ok);
        }));
        off += chunk;
    }
    // The last NAL has no following start code; finish() must emit it cleanly.
    CHECK(fixtureNals == 4);
    CHECK(framer.finish([&](const uint8_t* p, size_t n) {
        const uint8_t type = annexBNalType(p, n);
        ++fixtureNals;
        if (type == 1 || type == 5)
            ++fixtureVcl;
        if (type == 5)
            ++fixtureIdr;
        CHECK(fixtureDispatch.handleNal(p, n) == PushResult::Ok);
    }));
    CHECK(fixtureNals == 5);
    CHECK(fixtureVcl == 2);
    CHECK(fixtureIdr == 1);
    CHECK(fixtureRing.status().bytes_accepted == fixture.size());
    CHECK(fixtureRing.status().nal_accepted == fixtureNals);
    CHECK(fixtureDispatch.end() == ControlResult::Ok);

    {
        AnnexBFramer bounded(8);
        size_t emitted = 0;
        auto accept = [&](const uint8_t*, size_t) { ++emitted; return true; };
        const auto shortNal = nal(1, {0x11});
        std::vector<uint8_t> many;
        for (int i = 0; i < 20; ++i)
            many.insert(many.end(), shortNal.begin(), shortNal.end());
        CHECK(bounded.push(many.data(), many.size(), accept));
        CHECK(bounded.finish(accept));
        CHECK(emitted == 20);
        bounded.reset();
        const auto oversized = nal(5, {1, 2, 3, 4, 5, 6, 7, 8, 9});
        CHECK(!bounded.push(oversized.data(), oversized.size(), accept));
        CHECK(bounded.error() == AnnexBFramer::Error::TooLarge);
        CHECK(!bounded.finish(accept));
        bounded.reset();
        const uint8_t shortFinal[] = {0, 0, 1, 0x0a};
        CHECK(bounded.push(shortFinal, sizeof(shortFinal), accept));
        CHECK(bounded.finish(accept));
        bounded.reset();
        CHECK(bounded.finish(accept));
        CHECK(bounded.push(shortFinal, sizeof(shortFinal) - 1, accept));
        CHECK(!bounded.finish(accept));
        CHECK(bounded.error() == AnnexBFramer::Error::Malformed);
        bounded.reset();
        CHECK(bounded.push(shortFinal, sizeof(shortFinal), accept));
        auto reject = [](const uint8_t*, size_t) { return false; };
        CHECK(!bounded.finish(reject));
        CHECK(bounded.error() == AnnexBFramer::Error::CallbackRejected);
        bounded.reset();
        CHECK(!bounded.push(nullptr, 1, accept));
        CHECK(bounded.error() == AnnexBFramer::Error::InvalidInput);
    }
    {
        namespace abi = misterplex::ddr_bitstream_ring;
        abi::AccessUnit au;
        au.session_id = 42;
        au.annexb = p.data();
        au.len = p.size();
        au.pts = 1001;
        au.duration = 1001;
        au.timebase_num = 1;
        au.timebase_den = 24000;
        au.flags = abi::kAccessUnitKeyframe;
        CHECK(abi::validAccessUnit(au));
        const auto metadata = abi::encodeAccessUnitMetadata(au);
        CHECK(metadata.size() == 32);
        CHECK(metadata[0] == 0xe9 && metadata[1] == 3);
        CHECK(metadata[8] == 1 && metadata[12] == 0xc0 && metadata[13] == 0x5d);
        CHECK(metadata[16] == 0xe9 && metadata[17] == 3 && metadata[24] == 1);
        CHECK(metadata[28] == 0 && metadata[31] == 0);
        au.timebase_den = 0;
        CHECK(!abi::validAccessUnit(au));
        au.timebase_den = 24;
        au.pts = abi::kNoTimestamp;
        CHECK(!abi::validAccessUnit(au));
        au.pts = -7;
        CHECK(abi::validAccessUnit(au));
        CHECK(!abi::validAccessUnit(au, au.len - 1));
        au.flags = 2;
        CHECK(!abi::validAccessUnit(au));
        CHECK(abi::countDistance(5, 0x7ffffffdu) == 8);
        CHECK(abi::countDistance(0x7fffffffu, 0) == 0x7fffffffu);

        constexpr uint64_t nonce = 0x0123456789abcdefull;
        const std::array<uint32_t, 8> values{{
            (mailbox_abi::kFpgaVideoLayoutId << 16) | mailbox_abi::kFpgaVideoAbiVersion,
            abi::kRequiredVideoFeatures, (240u << 16) | 320u, 16384u, 0x12345678u,
            static_cast<uint32_t>(nonce), static_cast<uint32_t>(nonce >> 32), 1u,
        }};
        const std::array<uint32_t, 8> magics{{
            mailbox_abi::kVideoCapsMagic, mailbox_abi::kVideoFeaturesMagic,
            mailbox_abi::kVideoDimensionsMagic, mailbox_abi::kVideoAuLimitMagic,
            mailbox_abi::kVideoBuildMagic, mailbox_abi::kVideoNonceLowMagic,
            mailbox_abi::kVideoNonceHighMagic, mailbox_abi::kVideoCapsCommitMagic,
        }};
        std::array<uint64_t, 8> words{};
        for (size_t i = 0; i < words.size(); ++i)
            words[i] = (static_cast<uint64_t>(values[i]) << 32) | magics[i];
        abi::VideoCapabilities caps;
        CHECK(abi::decodeVideoCapabilities(words, nonce, caps));
        CHECK(caps.supportsVideo());
        CHECK(caps.max_width == 320 && caps.max_height == 240 && caps.nonce == nonce);
        CHECK(!abi::decodeVideoCapabilities(words, nonce + 1, caps));
        CHECK(!abi::decodeVideoCapabilities(words, 0, caps));
        caps.features &= ~abi::Color420;
        CHECK(!caps.supportsVideo());
        words[7] = magics[7];
        CHECK(!abi::decodeVideoCapabilities(words, nonce, caps));
        words[7] |= 1ull << 32;
        words[4] = magics[4];
        CHECK(abi::decodeVideoCapabilities(words, nonce, caps));
        CHECK(!caps.supportsVideo());
        words[4] = (uint64_t{0x12345678} << 32) | magics[4];
        words[0] ^= 1;
        CHECK(!abi::decodeVideoCapabilities(words, nonce, caps));

        CHECK(abi::kMaxAccessUnitBytes + abi::kAccessUnitMetadataBytes +
                  abi::kRecordHeaderBytes + abi::kControlReserveBytes == abi::kRingBytes);
        std::array<uint64_t, 9> shown{{
            (uint64_t{abi::kVideoActive | abi::kVideoHasFrame | abi::kVideoAudioClock} << 32) |
                mailbox_abi::kVideoPresentationMagic,
            42, 1001, (uint64_t{24000} << 32) | 1,
            (uint64_t{2} << 32) | 1, 4004, nonce, 0,
            (uint64_t{3} << 32) | mailbox_abi::kVideoPresentationCommitMagic,
        }};
        abi::VideoPresentation presentation;
        CHECK(abi::decodeVideoPresentation(shown, 42, nonce, presentation));
        CHECK(presentation.active && presentation.has_frame && presentation.has_audio_clock);
        CHECK(presentation.session_id == 42 && presentation.seq == 1);
        CHECK(presentation.pts == 1001 && presentation.timebase_num == 1 &&
              presentation.timebase_den == 24000 && presentation.presentation_count == 2);
        CHECK(presentation.audio_samples_consumed == 4004 && presentation.publication == 3);
        CHECK(!abi::decodeVideoPresentation(shown, 41, nonce, presentation));
        CHECK(!abi::decodeVideoPresentation(shown, 42, nonce + 1, presentation));
        shown[8] = mailbox_abi::kVideoPresentationCommitMagic;
        CHECK(!abi::decodeVideoPresentation(shown, 42, nonce, presentation));
        shown[8] |= uint64_t{3} << 32;
        shown[3] = 1;
        CHECK(!abi::decodeVideoPresentation(shown, 42, nonce, presentation));
        shown[3] = (uint64_t{24000} << 32) | 1;
        shown[2] = static_cast<uint64_t>(abi::kNoTimestamp);
        CHECK(!abi::decodeVideoPresentation(shown, 42, nonce, presentation));
        shown[0] = (uint64_t{abi::kVideoActive | abi::kVideoBuffering} << 32) |
                   mailbox_abi::kVideoPresentationMagic;
        CHECK(abi::decodeVideoPresentation(shown, 42, nonce, presentation));
        CHECK(!presentation.has_frame && presentation.buffering && !presentation.has_audio_clock);
        shown[7] = 1;
        CHECK(!abi::decodeVideoPresentation(shown, 42, nonce, presentation));

        for (size_t i = 0; i < mailbox_abi::kAllMailboxes.size(); ++i) {
            const auto& a = mailbox_abi::kAllMailboxes[i];
            for (size_t j = i + 1; j < mailbox_abi::kAllMailboxes.size(); ++j) {
                const auto& b = mailbox_abi::kAllMailboxes[j];
                CHECK(uint64_t{a.phys_addr} + a.size_bytes <= b.phys_addr ||
                      uint64_t{b.phys_addr} + b.size_bytes <= a.phys_addr);
            }
        }
    }

    if (fails) {
        std::fprintf(stderr, "test_h264_bitstream_source: %d failures\n", fails);
        return 1;
    }
    std::printf("test_h264_bitstream_source: telemetry overrun=%llu underrun=%llu desync=%llu last_bad_seq=%u wrap_reuse=%d fixture_nals=%zu fixture_vcl=%zu fixture_bytes=%llu\n",
                static_cast<unsigned long long>(pressure.overrun_count),
                static_cast<unsigned long long>(pressure.underrun_count),
                static_cast<unsigned long long>(seqStatus.desync_count), seqStatus.last_bad_seq,
                wrapReuseOk ? 1 : 0, fixtureNals, fixtureVcl,
                static_cast<unsigned long long>(fixtureRing.status().bytes_accepted));
    std::printf("test_h264_bitstream_source: OK copy-on-push pause-replay full/underrun/overrun/desync\n");
    return 0;
}
