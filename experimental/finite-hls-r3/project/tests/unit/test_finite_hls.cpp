#include "libmisterplex/av_inproc_decode.hpp"
#include "../../arm/misterplexd/finite_hls_io.hpp"

#include <chrono>
#include <cstdio>
#include <cstring>
#include <dlfcn.h>
#include <filesystem>
#include <map>
#include <memory>
#include <stdexcept>
#include <thread>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/error.h>
}

using namespace misterplex;

static unsigned videoDecoderOpens = 0;

// Interposition covers calls made inside the shared libavformat as well as
// calls from our source. Fixture encoding runs in a separate ffmpeg process.
extern "C" int avcodec_open2(AVCodecContext* context, const AVCodec* codec,
                            AVDictionary** options) {
    if (context->codec_type == AVMEDIA_TYPE_VIDEO ||
        (codec && codec->type == AVMEDIA_TYPE_VIDEO)) {
        ++videoDecoderOpens;
        return AVERROR(ENOSYS);
    }
    using Open = int (*)(AVCodecContext*, const AVCodec*, AVDictionary**);
    static auto original = reinterpret_cast<Open>(dlsym(RTLD_NEXT, "avcodec_open2"));
    return original ? original(context, codec, options) : AVERROR(ENOSYS);
}

static void require(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
}

static size_t descriptors() {
    size_t count = 0;
    for (const auto& entry : std::filesystem::directory_iterator("/proc/self/fd")) {
        (void)entry;
        ++count;
    }
    return count;
}

struct Result {
    std::vector<AvCompressedAccessUnit> units;
    std::vector<uint8_t> pcm;
    AvCompressedDiagnostics diagnostics;
    int64_t firstAudio = ddr_bitstream_ring::kNoTimestamp;
    bool failed = false;
    std::string error;
};

static Result collect(AvInprocDecoder& source) {
    Result result;
    std::string error;
    bool videoEof = false;
    for (unsigned turn = 0; turn < 8192; ++turn) {
        if (!videoEof) {
            AvCompressedAccessUnit unit;
            const int read = source.readAccessUnit(unit, error);
            if (read < 0) { result.failed = true; result.error = error; break; }
            if (!read) videoEof = true;
            else result.units.push_back(std::move(unit));
        } else if (!source.audioEof()) {
            const auto progress = source.advanceCompressedAudio(error);
            if (progress == AvAudioProgress::Error || progress == AvAudioProgress::Cancelled) {
                result.failed = true;
                result.error = error;
                break;
            }
        }
        uint8_t bytes[8192];
        for (;;) {
            const int count = source.drainPcm(bytes, sizeof(bytes), false);
            if (!count) break;
            result.pcm.insert(result.pcm.end(), bytes, bytes + count);
        }
        const auto state = source.compressedDiagnostics();
        require(state.queuedPackets <= kCompressedPacketCountLimit &&
                state.queuedBytes <= kCompressedPacketByteLimit &&
                state.pcmBytes <= kCompressedPcmByteLimit, "bounded queues exceeded");
        if (videoEof && source.audioEof()) break;
        require(turn != 8191, "finite fixture iteration bound exceeded");
    }
    result.firstAudio = source.firstAudioPtsUs();
    result.diagnostics = source.compressedDiagnostics();
    return result;
}

struct DirectFixture {
    struct Resource {
        std::string body;
        bool closed = false;
    };

    struct Handle {
        Resource* resource = nullptr;
        AVIOContext* io = nullptr;
        size_t position = 0;
    };

    static DirectFixture* active;
    std::map<std::string, Resource> resources;
    std::vector<std::unique_ptr<Handle>> handles;

    ~DirectFixture() {
        for (auto& handle : handles) {
            if (!handle->io) continue;
            av_freep(&handle->io->buffer);
            avio_context_free(&handle->io);
        }
    }

    static int read(void* opaque, uint8_t* data, int size) {
        auto& handle = *static_cast<Handle*>(opaque);
        if (handle.position >= handle.resource->body.size()) return AVERROR_EOF;
        const size_t remaining = handle.resource->body.size() - handle.position;
        const size_t count = std::min(remaining, static_cast<size_t>(size));
        std::memcpy(data, handle.resource->body.data() + handle.position, count);
        handle.position += count;
        return static_cast<int>(count);
    }

    static int64_t seek(void* opaque, int64_t offset, int whence) {
        auto& handle = *static_cast<Handle*>(opaque);
        const auto size = static_cast<int64_t>(handle.resource->body.size());
        if (whence == AVSEEK_SIZE) return size;
        int64_t next = 0;
        if (whence == SEEK_SET) next = offset;
        else if (whence == SEEK_CUR) next = static_cast<int64_t>(handle.position) + offset;
        else if (whence == SEEK_END) next = size + offset;
        else return AVERROR(EINVAL);
        if (next < 0 || next > size) return AVERROR(EINVAL);
        handle.position = static_cast<size_t>(next);
        return next;
    }

    static int open(AVFormatContext*, AVIOContext** output, const char* url, int flags,
                    AVDictionary**) {
        if (!active || flags != AVIO_FLAG_READ || !url) return AVERROR(EINVAL);
        const auto found = active->resources.find(url);
        if (found == active->resources.end()) return AVERROR(ENOENT);
        auto handle = std::make_unique<Handle>();
        handle->resource = &found->second;
        uint8_t* buffer = static_cast<uint8_t*>(av_malloc(4096));
        if (!buffer) return AVERROR(ENOMEM);
        handle->io = avio_alloc_context(buffer, 4096, 0, handle.get(), read, nullptr, seek);
        if (!handle->io) {
            av_free(buffer);
            return AVERROR(ENOMEM);
        }
        handle->io->seekable = AVIO_SEEKABLE_NORMAL;
        *output = handle->io;
        active->handles.push_back(std::move(handle));
        return 0;
    }

    static int close(AVFormatContext*, AVIOContext* io) {
        if (!active || !io) return AVERROR(EINVAL);
        const auto found = std::find_if(active->handles.begin(), active->handles.end(),
            [&](const std::unique_ptr<Handle>& handle) { return handle->io == io; });
        if (found == active->handles.end()) return AVERROR(EINVAL);
        (*found)->resource->closed = true;
        av_freep(&io->buffer);
        avio_context_free(&io);
        active->handles.erase(found);
        return 0;
    }
};

DirectFixture* DirectFixture::active = nullptr;

struct DirectFixtureScope {
    explicit DirectFixtureScope(DirectFixture& fixture) : previous(DirectFixture::active) {
        DirectFixture::active = &fixture;
    }
    ~DirectFixtureScope() { DirectFixture::active = previous; }

    DirectFixture* previous = nullptr;
};

struct DirectOutcome {
    std::string scenario;
    int finiteHlsError = 0;
    int transportError = 0;
    bool verified = false;
    bool transportEof = false;
    int64_t mediaBytes = 0;
    std::string reason = "none";
};

static AVIOContext* openWrapped(AVFormatContext& format, const std::string& url) {
    AVIOContext* io = nullptr;
    require(format.io_open(&format, &io, url.c_str(), AVIO_FLAG_READ, nullptr) == 0,
            "direct finite-HLS open failed");
    return io;
}

static void closeWrapped(AVFormatContext& format, AVIOContext* io) {
    require(format.io_close2(&format, io) == 0, "direct finite-HLS close failed");
}

static void readExact(AVIOContext* io, size_t bytes) {
    uint8_t block[64];
    size_t seen = 0;
    while (seen < bytes) {
        const size_t want = std::min(bytes - seen, sizeof(block));
        const int read = avio_read_partial(io, block, static_cast<int>(want));
        require(read > 0, "direct finite-HLS read truncated");
        seen += static_cast<size_t>(read);
    }
}

static DirectOutcome runDirectFiniteHlsScenario(const std::string& scenario) {
    DirectFixture fixture;
    DirectFixtureScope scope(fixture);
    AVFormatContext format{};
    format.io_open = DirectFixture::open;
    format.io_close2 = DirectFixture::close;
    FiniteHlsIo hls;
    require(hls.attach(&format, "http://example.com/root.m3u8") == 0,
            "direct finite-HLS attach failed");
    const std::string playlistUrl = "http://example.com/media/index.m3u8";
    const std::string segmentUrl = "http://example.com/media/seg000.ts";
    const std::string segment(188, 'A');
    const std::string largeSegment(65536, 'B');
    if (scenario == "close-complete") {
        fixture.resources.emplace(segmentUrl, DirectFixture::Resource{segment});
        fixture.resources.emplace(playlistUrl, DirectFixture::Resource{
            "#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1.0,\nseg000.ts\n#EXT-X-ENDLIST\n"});
        auto* segmentIo = openWrapped(format, segmentUrl);
        readExact(segmentIo, segment.size());
        closeWrapped(format, segmentIo);
        auto* playlistIo = openWrapped(format, playlistUrl);
        readExact(playlistIo, fixture.resources.at(playlistUrl).body.size());
        closeWrapped(format, playlistIo);
        require(hls.verifyEof(1000000, 1000000, 0) == 0,
                "close-without-EOF did not verify finite completion");
        require(!hls.transportEof(), "close-without-EOF faked transport EOF");
    } else if (scenario == "close-partial") {
        fixture.resources.emplace(segmentUrl, DirectFixture::Resource{largeSegment});
        auto* segmentIo = openWrapped(format, segmentUrl);
        readExact(segmentIo, 64);
        closeWrapped(format, segmentIo);
        require(hls.error() == AVERROR(EIO), "partial close missed resource-length failure");
        require(std::string(hls.reason()) == "resource-length",
                "partial close lost resource-length reason");
        require(!hls.verified(), "partial close became verified");
    } else if (scenario == "close-abandon") {
        fixture.resources.emplace(segmentUrl, DirectFixture::Resource{largeSegment});
        auto* segmentIo = openWrapped(format, segmentUrl);
        readExact(segmentIo, 64);
        hls.noteAbandon();
        closeWrapped(format, segmentIo);
        require(hls.error() == 0, "intentional abandon became a terminal finite-HLS error");
        require(hls.transportError() == 0, "intentional abandon became a transport error");
        require(!hls.verified(), "intentional abandon became verified");
    } else {
        throw std::runtime_error("unknown direct finite-HLS scenario");
    }
    return {scenario, hls.error(), hls.transportError(), hls.verified(), hls.transportEof(),
            hls.mediaBytes(), hls.reason()};
}

static Result openAndCollect(AvInprocDecoder& source, const std::string& path,
                             const AvInprocOpenOpts& options) {
    std::string error;
    if (!source.open(path, options, error)) {
        Result result;
        result.failed = true;
        result.error = error;
        result.diagnostics = source.compressedDiagnostics();
        require(!error.empty(), "failed input open lost its error");
        return result;
    }
    return collect(source);
}

static void same(const Result& actual, const Result& reference, bool seeking = false) {
    require(!actual.failed, ("complete finite source failed: " + actual.error).c_str());
    require(!reference.failed, ("reference source failed: " + reference.error).c_str());
    require(actual.diagnostics.inputEof && actual.diagnostics.audioEof &&
            actual.diagnostics.ioEof == true && actual.diagnostics.ioError == 0 &&
            actual.diagnostics.finiteHlsVerified == true &&
            actual.diagnostics.finiteHlsError == 0 &&
            actual.diagnostics.inputReadResult == AVERROR_EOF,
            "finite EOF was not verified as clean");
    const size_t offset = seeking ? reference.units.size() - actual.units.size() : 0;
    require(!actual.units.empty() &&
            (seeking ? actual.units.size() < reference.units.size()
                     : actual.units.size() == reference.units.size()),
            "finite transport changed AU count");
    for (size_t i = 0; i < actual.units.size(); ++i) {
        const auto& a = actual.units[i];
        const auto& b = reference.units[i + offset];
        require(a.pts == b.pts && a.duration == b.duration &&
                a.timebaseNum == b.timebaseNum && a.timebaseDen == b.timebaseDen &&
                a.annexb == b.annexb && a.keyframe == b.keyframe,
                "transport changed original PTS, duration, timebase or AU bytes");
        require(a.geometry.codedWidth == 320 && a.geometry.codedHeight == 240 &&
                a.geometry.sourceAspect.valid &&
                a.geometry.sourceAspect.x * 9 == a.geometry.sourceAspect.y * 16 &&
                a.geometry.limitedBt601Signaled(),
                "transport changed coded geometry, source DAR or color");
    }
    if (!seeking)
        require(!actual.pcm.empty() && actual.pcm == reference.pcm &&
                actual.firstAudio == reference.firstAudio,
                "transport changed original audio PTS or decoded stereo PCM");
    if (!seeking)
        require(actual.diagnostics.inputVideoPackets == actual.units.size() &&
                actual.diagnostics.returnedAccessUnits == actual.units.size(),
                "finite input/returned packet accounting drifted");
}

int main(int argc, char** argv) {
    try {
        require(argc == 7, "usage: test_finite_hls MODE INPUT REFERENCE FPS_NUM FPS_DEN GOOD_INPUT");
        const std::string mode = argv[1], input = argv[2], reference = argv[3];
        if (mode == "unit") {
            const auto result = runDirectFiniteHlsScenario(input);
            std::printf("{\"scenario\":\"%s\",\"finite_hls_error\":%d,"
                        "\"transport_error\":%d,\"transport_eof\":%s,"
                        "\"finite_hls_verified\":%s,\"media_bytes\":%lld,"
                        "\"finite_hls_error_kind\":\"%s\"}\n",
                        result.scenario.c_str(), result.finiteHlsError, result.transportError,
                        result.transportEof ? "true" : "false",
                        result.verified ? "true" : "false",
                        static_cast<long long>(result.mediaBytes), result.reason.c_str());
            return 0;
        }
        std::atomic<bool> cancelled{false}, paused{false};
        AvInprocOpenOpts opts;
        opts.compressedVideo = true;
        opts.finiteHls = mode == "explicit";
        opts.expectW = 320; opts.expectH = 240;
        opts.maxAccessUnitBytes = opts.maxVclRbspBytes = 8192;
        opts.expectedFpsNum = std::stoi(argv[4]);
        opts.expectedFpsDen = std::stoi(argv[5]);
        opts.requireAllIdr = opts.requireLimitedBt601 = true;
        opts.headers = "X-Plex-Token: generated-test-token\r\n"
                       "X-Plex-Session-Identifier: generated-test-session\r\n";
        opts.cancelled = &cancelled;
        opts.paused = &paused;
        AvInprocDecoder source;
        const size_t before = descriptors();
        const auto started = std::chrono::steady_clock::now();
        Result actual;
        if (mode == "cancel" || mode == "external-cancel") {
            std::string error;
            require(source.open(input, opts, error), "cancellation fixture did not open");
            std::thread cancel([&] {
                std::this_thread::sleep_for(std::chrono::milliseconds(200));
                if (mode == "cancel") source.requestStop();
                else cancelled.store(true);
            });
            try { actual = collect(source); }
            catch (...) { cancel.join(); throw; }
            cancel.join();
            require(actual.failed && actual.diagnostics.cancelled &&
                    actual.diagnostics.finiteHlsVerified != true,
                    "blocked HLS cancellation became successful EOF");
        } else if (mode == "backpressure") {
            std::string error;
            require(source.open(input, opts, error), "backpressure fixture did not open");
            paused.store(true);
            const auto initial = source.compressedDiagnostics();
            require(source.advanceCompressedAudio(error) == AvAudioProgress::Paused &&
                    source.compressedDiagnostics().inputVideoPackets == initial.inputVideoPackets,
                    "paused HLS advanced its input");
            paused.store(false);
            bool blocked = false;
            std::vector<uint8_t> earlierPcm;
            for (unsigned i = 0; i < 4096 && !blocked; ++i) {
                const auto result = source.advanceCompressedAudio(error);
                require(result != AvAudioProgress::Error && result != AvAudioProgress::Eof,
                        "HLS failed before bounded backpressure");
                blocked = result == AvAudioProgress::Backpressure;
                uint8_t bytes[8192];
                while (const int count = source.drainPcm(bytes, sizeof(bytes), false))
                    earlierPcm.insert(earlierPcm.end(), bytes, bytes + count);
            }
            require(blocked, "HLS did not preserve bounded video backpressure");
            actual = collect(source);
            actual.pcm.insert(actual.pcm.begin(), earlierPcm.begin(), earlierPcm.end());
        } else {
            if (mode == "seek") opts.startMs = 500;
            if (mode == "seek-reject") opts.startMs = 750;
            actual = openAndCollect(source, input, opts);
        }
        if (mode == "error" || mode == "reopen" || mode == "seek-reject") {
            require(actual.failed && actual.diagnostics.finiteHlsVerified != true,
                    "missing, failed or unfinished segment became successful natural EOF");
        }
        source.close();
        if (mode == "reopen" || mode == "cancel" || mode == "external-cancel") {
            cancelled.store(false);
            actual = openAndCollect(source, argv[6], opts);
            source.close();
        }
        if (mode != "error" && mode != "seek-reject") {
            opts.startMs = 0;
            opts.finiteHls = false;
            const auto expected = openAndCollect(source, reference, opts);
            source.close();
            require(expected.units.size() == 48, "generated reference did not contain 48 AUs");
            same(actual, expected, mode == "seek");
        }
        require(videoDecoderOpens == 0, "libav attempted a software video decoder");
        require(descriptors() == before, "HLS close/reopen leaked an input descriptor");
        const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - started).count();
        require(elapsed < 12000, "bounded HLS lifecycle exceeded twelve seconds");
        std::printf("{\"access_units\":%zu,\"pcm_bytes\":%zu,\"elapsed_ms\":%lld,"
                    "\"io_error\":%d,\"io_eof\":%s,\"finite_hls_error\":%d,"
                    "\"finite_hls_error_kind\":\"%s\",\"finite_hls_verified\":%s,"
                    "\"video_decoder_opens\":%u,\"failed\":%s}\n",
                    actual.units.size(), actual.pcm.size(), static_cast<long long>(elapsed),
                    actual.diagnostics.ioError.value_or(0),
                    actual.diagnostics.ioEof.value_or(false) ? "true" : "false",
                    actual.diagnostics.finiteHlsError.value_or(0),
                    actual.diagnostics.finiteHlsErrorKind.c_str(),
                    actual.diagnostics.finiteHlsVerified.value_or(false) ? "true" : "false",
                    videoDecoderOpens,
                    actual.failed ? "true" : "false");
        return 0;
    } catch (const std::exception& error) {
        std::fprintf(stderr, "finite HLS regression: %s\n", error.what());
        return 1;
    }
}
