#include <bits/stdc++.h>
#define private public
#include "media_player.hpp"
#undef private
#include "libmisterplex/av_inproc_decode.hpp"

#include <cstdarg>
#include <fcntl.h>
#include <unistd.h>
extern "C" {
#include <libavformat/avformat.h>
#include <libavutil/error.h>
}

using namespace misterplex;

static void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}

static AVFormatContext* input = nullptr;
static int (*originalRead)(void*, uint8_t*, int) = nullptr;
enum class InputFault { None, Error, WaitForCancellation };
static InputFault fault = InputFault::None;
static std::atomic<bool> faultReached{false};
static unsigned audioOpens = 0, otherDeviceOpens = 0;

extern "C" int __real_avformat_open_input(
    AVFormatContext**, const char*, const AVInputFormat*, AVDictionary**);
extern "C" int __wrap_avformat_open_input(
    AVFormatContext** context, const char* url, const AVInputFormat* format,
    AVDictionary** options) {
    const int result = __real_avformat_open_input(context, url, format, options);
    if (result >= 0) input = *context;
    return result;
}

// Keep every fixture byte. Only the underlying EOF read is replaced, so the
// real av_read_frame/parser path must surface the injected negative I/O result.
static int failingRead(void* opaque, uint8_t* bytes, int count) {
    const int result = originalRead(opaque, bytes, count);
    if (result > 0 || fault == InputFault::None) return result;
    faultReached.store(true);
    if (fault == InputFault::Error) return AVERROR(EIO);
    for (unsigned i = 0; i < 3000; ++i) {
        if (input->interrupt_callback.callback(input->interrupt_callback.opaque))
            return AVERROR_EXIT;
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    return AVERROR(ETIMEDOUT);
}

static void installFault(InputFault requested) {
    require(input && input->pb && input->pb->read_packet, "missing standard AVIO seam");
    originalRead = input->pb->read_packet;
    fault = requested;
    faultReached.store(false);
    input->pb->read_packet = failingRead;
}

extern "C" int __real_open(const char*, int, ...);
extern "C" int __wrap_open(const char* path, int flags, ...) {
    if (std::strncmp(path, "/dev/", 5) == 0) {
        if (std::strcmp(path, "/dev/MrAudio") == 0 &&
            flags == (O_WRONLY | O_NONBLOCK))
            ++audioOpens;
        else
            ++otherDeviceOpens;
        errno = EACCES;
        return -1;
    }
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list args;
        va_start(args, flags);
        mode = va_arg(args, mode_t);
        va_end(args);
    }
    return __real_open(path, flags, mode);
}

static AvInprocOpenOpts options(std::atomic<bool>& stop) {
    AvInprocOpenOpts value;
    value.compressedVideo = true;
    value.expectW = 320; value.expectH = 240;
    value.requireAllIdr = true;
    value.maxAccessUnitBytes = value.maxVclRbspBytes = 8192;
    value.expectedFpsNum = 24; value.expectedFpsDen = 1;
    value.cancelled = &stop;
    return value;
}

static int readToTerminal(AvInprocDecoder& source, std::string& error) {
    for (unsigned i = 0; i < 200; ++i) {
        AvCompressedAccessUnit au;
        const int read = source.readAccessUnit(au, error);
        uint8_t pcm[8192];
        while (source.drainPcm(pcm, sizeof(pcm), false)) {}
        if (read <= 0) return read;
    }
    throw std::runtime_error("input reader exceeded bounded fixture");
}

static void inputError(const char* path) {
    AvInprocDecoder source;
    std::atomic<bool> stop{false};
    std::string error;
    require(source.open(path, options(stop), error), error.c_str());
    installFault(InputFault::Error);
    const int result = readToTerminal(source, error);
    const auto before = source.compressedDiagnostics();
    require(result < 0 && faultReached.load() &&
            before.inputReadResult == AVERROR(EIO) && before.ioError == AVERROR(EIO),
            "case did not exercise a real negative av_read_frame/AVIO return");
    std::printf("real libav negative input: read=%d AVIO=%d\n",
                *before.inputReadResult, *before.ioError);
    stop.store(true); // Same flag failFpgaSession sets before terminal snapshots.
    unsigned records = 0;
    finishFpgaPlayback({true, false, false, true},
        [&] {
            const auto state = source.compressedDiagnostics();
            const auto text = formatCompressedDiagnostics(state);
            require(state.inputReadResult == AVERROR(EIO) && state.ioError == AVERROR(EIO) &&
                    state.cancelled && text.find("input_read_kind=error") != std::string::npos,
                    "failure-stop/retirement relabeled observed I/O error as cancellation");
            return text;
        }, [&] { source.requestStop(); }, [&] { source.close(); return true; },
        [] { return true; }, [&] { return stop.load(); },
        [&](const FpgaTerminalReceipt& receipt) {
            ++records;
            require(receipt.beforeQuiesce && receipt.beforeReset,
                    "I/O cause check failed in one of the retained snapshots");
        });
    require(records == 1, "negative I/O terminal receipt missing");
    fault = InputFault::None;
    stop.store(false);
    require(source.open(path, options(stop), error), error.c_str());
    const auto reopened = source.compressedDiagnostics();
    require(!reopened.inputReadResult && !reopened.cancelled,
            "reopen retained previous input observation");
    AvCompressedAccessUnit au;
    require(source.readAccessUnit(au, error) == 1, "reopened input did not return an AU");
    const auto fresh = formatCompressedDiagnostics(source.compressedDiagnostics());
    require(fresh.find("input_read_kind=packet") != std::string::npos &&
            fresh.find("input_read_cancelled=0") != std::string::npos,
            "reopened input did not record a fresh successful read");
}

static void inputCancellation(const char* path, bool bufferedPacket, bool externalStop = false) {
    AvInprocDecoder source;
    std::atomic<bool> stop{false};
    std::string error;
    require(source.open(path, options(stop), error), error.c_str());
    installFault(InputFault::WaitForCancellation);
    int result = 1;
    std::thread reader([&] {
        try { result = readToTerminal(source, error); }
        catch (const std::exception& failure) { error = failure.what(); result = -2; }
    });
    for (unsigned i = 0; i < 2000 && !faultReached.load(); ++i)
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    if (externalStop) stop.store(true);
    else source.requestStop();
    reader.join();
    const auto state = source.compressedDiagnostics();
    std::printf("interrupted input observation: result=%d %s\n",
                result, formatCompressedDiagnostics(state).c_str());
    const auto text = formatCompressedDiagnostics(state);
    require(result < 0 && faultReached.load() &&
            state.inputReadResult == (bufferedPacket ? 0 : AVERROR_EXIT) &&
            state.ioError == AVERROR_EXIT && stop.load() == externalStop &&
            text.find(bufferedPacket ? "input_read_kind=packet" : "input_read_kind=cancelled") !=
                std::string::npos && text.find("input_read_cancelled=1") != std::string::npos,
            "actual interrupted input read was not retained as cancellation");
    std::printf("real libav cancellation: read=%d AVIO=%d\n",
                *state.inputReadResult, *state.ioError);
    source.close();
    fault = InputFault::None;
    stop.store(false);
    require(source.open(path, options(stop), error) &&
            !source.compressedDiagnostics().inputReadResult,
            "cancelled input observation survived reopen");
    AvCompressedAccessUnit au;
    require(source.readAccessUnit(au, error) == 1 &&
            formatCompressedDiagnostics(source.compressedDiagnostics()).find(
                "input_read_cancelled=0") != std::string::npos,
            "reopened input retained the previous observed cancellation");
}

static void audioOpenFailure(const char* path) {
    AvInprocDecoder source;
    std::atomic<bool> stop{false};
    std::string error;
    require(source.open(path, options(stop), error), error.c_str());
    int64_t firstVideoPts = ddr_bitstream_ring::kNoTimestamp;
    for (unsigned i = 0; i < 72 && source.compressedDiagnostics().pcmBytes < 8192; ++i) {
        AvCompressedAccessUnit au;
        require(source.readAccessUnit(au, error) == 1, "fixture did not supply original PCM");
        if (firstVideoPts == ddr_bitstream_ring::kNoTimestamp)
            firstVideoPts = int64_t(static_cast<long double>(au.pts) *
                                   au.timebaseNum * 1000000 / au.timebaseDen);
    }
    require(source.compressedDiagnostics().pcmBytes >= 8192, "insufficient PCM for open branch");
    // Process-lifetime, never initialized player: shutdown performs global child
    // cleanup outside this seam. No player thread or device descriptor is created.
    auto* player = new MediaPlayer;
    unsigned errors = 0;
    player->setLog([&](const std::string& line) {
        if (line.find("MrAudio open failed (no silent audio fallback)") != std::string::npos)
            ++errors;
    });
    player->inprocPcm_ = &source;
    player->fpgaVideoStarted_.store(true);
    player->fpgaFirstVideoPtsUs_.store(firstVideoPts);
    player->stop_.store(false);
    player->fpgaAudioPump(); // Actual production worker, stopped at its wrapped open failure.
    require(audioOpens == 1 && otherDeviceOpens == 0 && errors == 1,
            "open-failure seam accessed another device or hid the original error");
    require(player->fpgaAudioExit_.load() == FpgaAudioExit::Error && player->stop_.load() &&
            player->fpgaAudioDone_.load() && !player->audioActive_.load() &&
            !player->fpgaAudioStarted_.load() && player->fpgaAudioOutput_ == -1 &&
            player->audioBytes_.load() == 0,
            "audio open failure became cancelled/running or success-shaped");
    player->inprocPcm_ = nullptr;
    std::puts("production fpgaAudioPump open failure: error retained; no device access/PCM submission");
}

int main(int argc, char** argv) {
    try {
        require(argc == 3, "need failure selector and real interleaved fixture");
        const std::string mode = argv[1];
        if (mode == "--io-error") inputError(argv[2]);
        else if (mode == "--io-cancel") inputCancellation(argv[2], false);
        else if (mode == "--io-external-cancel") inputCancellation(argv[2], false, true);
        else if (mode == "--io-buffered-cancel") inputCancellation(argv[2], true);
        else if (mode == "--audio-open") audioOpenFailure(argv[2]);
        else throw std::runtime_error("unknown failure selector");
        require(otherDeviceOpens == 0, "unexpected device access");
        return 0;
    } catch (const std::exception& error) {
        std::fprintf(stderr, "FAIL input/audio cause: %s\n", error.what());
        return 1;
    }
}
