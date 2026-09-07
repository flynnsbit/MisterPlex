#include "libmisterplex/av_inproc_decode.hpp"
#include "libmisterplex/av_clock.hpp"
#include "libmisterplex/fpga_terminal.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

using namespace misterplex;

static void require(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
}

static AvInprocOpenOpts options() {
    AvInprocOpenOpts opts;
    opts.compressedVideo = true;
    opts.expectW = 320; opts.expectH = 240;
    opts.maxAccessUnitBytes = 8192;
    opts.maxVclRbspBytes = 8192;
    opts.requireAllIdr = true;
    opts.expectedFpsNum = 24; opts.expectedFpsDen = 1;
    return opts;
}

static void checkBounds(const AvCompressedDiagnostics& state) {
    require(state.queuedPackets <= kCompressedPacketCountLimit, "packet count bound exceeded");
    require(state.queuedBytes <= kCompressedPacketByteLimit, "packet byte bound exceeded");
    require(state.pcmBytes <= kCompressedPcmByteLimit, "PCM bound exceeded");
}

static void checkPressure(const AvInprocDecoder& source) {
#if MPX_FPGA_AV_TRACE
    // This comparison is deliberately single-threaded. The live pressure view
    // itself must never call the locking detailed diagnostics method.
    const auto state = source.compressedDiagnostics();
    const auto pressure = source.compressedPressure();
    require(pressure.available == state.available &&
            pressure.queuedPackets == state.queuedPackets &&
            pressure.queuedBytes == state.queuedBytes &&
            pressure.pcmBytes == state.pcmBytes &&
            pressure.inputEof == state.inputEof &&
            pressure.audioEof == state.audioEof &&
            pressure.reservedVideo == state.reservedVideo &&
            pressure.blocked == state.blocked, "atomic pressure mirrors drifted");
#else
    (void)source;
#endif
}

struct PacedResult {
    std::vector<int64_t> pts;
    uint64_t emittedSamples = 0;
    bool stalled = false;
};

static PacedResult paced(const char* path, bool independentAudio) {
    AvInprocDecoder source;
    std::string error;
    require(source.open(path, options(), error), error.c_str());
    PacedResult result;
    int64_t firstPtsUs = 0, activeUs = 0, lastPresentation = 0;
    int64_t audioOrigin = 0, trim = 0;
    bool audioAligned = false;
    std::deque<uint8_t> output;
    auto audioTurn = [&] {
        uint8_t pcm[3840];
        if (output.size() < sizeof(pcm)) {
            const int count = source.drainPcm(pcm, sizeof(pcm), false);
            if (count) {
                if (!audioAligned) {
                    const int64_t timestamp = source.firstAudioPtsUs();
                    require(timestamp != ddr_bitstream_ring::kNoTimestamp,
                            "decoded PCM lost its original timestamp");
                    const int64_t delta = timestamp - firstPtsUs;
                    audioOrigin = std::max<int64_t>(0, delta);
                    trim = delta < 0 ? ((-delta * 48000) / 1000000) * 4 : 0;
                    audioAligned = true;
                }
                const size_t skipped = size_t(std::min<int64_t>(trim, count));
                trim -= int64_t(skipped);
                output.insert(output.end(), pcm + skipped, pcm + count);
            } else if (independentAudio && !source.audioEof()) {
                const auto progress = source.advanceCompressedAudio(error);
                require(progress != AvAudioProgress::Error, error.c_str());
                require(progress != AvAudioProgress::Cancelled, "unexpected cancellation");
            }
        }
        // A finite stereo sink actually removes valid pairs. Queued/submitted
        // PCM and virtual wall time are deliberately not its consumption clock.
        const size_t emitted = std::min<size_t>(960, output.size() / 4);
        for (size_t i = 0; i < emitted * 4; ++i) output.pop_front();
        result.emittedSamples += emitted;
        require(output.size() <= 2 * sizeof(pcm), "test sink became unbounded");
        checkBounds(source.compressedDiagnostics());
        checkPressure(source);
        return true;
    };
    for (;;) {
        AvCompressedAccessUnit au;
        const int read = source.readAccessUnit(au, error);
        require(read >= 0, error.c_str());
        if (!read) break;
        const int64_t ptsUs = int64_t(static_cast<long double>(au.pts) *
                                     au.timebaseNum * 1000000 / au.timebaseDen);
        if (result.pts.empty()) firstPtsUs = ptsUs;
        const auto wait = waitForCompressedAccessUnit(ptsUs - firstPtsUs,
            [] { return true; }, audioTurn,
            [&] {
                return CompressedPacingSnapshot{false, activeUs, lastPresentation,
                    audioAligned ? audioOrigin + int64_t(result.emittedSamples) * 1000000 / 48000
                                 : activeUs};
            }, [&] { activeUs += 20000; });
        if (wait == CompressedPacingResult::Stalled) {
            result.stalled = true;
            break;
        }
        require(wait == CompressedPacingResult::Due, "paced AU was cancelled");
        if (!result.pts.empty()) require(au.pts > result.pts.back(), "video PTS reordered");
        result.pts.push_back(au.pts);
        lastPresentation = activeUs;
    }
    if (!result.stalled) {
        for (unsigned turn = 0; turn < 2000 && (!source.audioEof() || !output.empty()); ++turn)
            audioTurn();
        require(source.audioEof() && output.empty(), "residual PCM lost or EOF drain hung");
    }
    source.requestStop();
    return result;
}

static void fullQueue(const char* path, int expectedFrames) {
    AvInprocDecoder source;
    std::string error;
    require(source.open(path, options(), error), error.c_str());
    AvAudioProgress progress = AvAudioProgress::Pending;
    for (unsigned turn = 0; turn < 500 && progress != AvAudioProgress::Backpressure; ++turn) {
        progress = source.advanceCompressedAudio(error);
        require(progress != AvAudioProgress::Error, error.c_str());
        checkBounds(source.compressedDiagnostics());
    }
    const auto full = source.compressedDiagnostics();
    checkPressure(source);
    require(progress == AvAudioProgress::Backpressure && full.pcmBytes == 0 &&
            full.queuedPackets == kCompressedPacketCountLimit,
            "fixture did not reach full video queue with empty PCM");
    require(full.detailsAvailable && full.reservedVideo &&
            full.queuedVideoPackets == kCompressedPacketCountLimit - 1,
            "terminal accounting lost the reserved video packet");
    int frames = 0;
    int64_t previous = ddr_bitstream_ring::kNoTimestamp;
    uint64_t pcmBytes = 0;
    for (;;) {
        AvCompressedAccessUnit au;
        const int read = source.readAccessUnit(au, error);
        require(read >= 0, error.c_str());
        if (read) {
            require(previous == ddr_bitstream_ring::kNoTimestamp || au.pts > previous,
                    "full queue reordered or duplicated a video packet");
            previous = au.pts;
            ++frames;
        }
        uint8_t pcm[8192];
        while (const int got = source.drainPcm(pcm, sizeof(pcm))) pcmBytes += got;
        checkBounds(source.compressedDiagnostics());
        checkPressure(source);
        if (!read) break;
        progress = source.advanceCompressedAudio(error);
        require(progress != AvAudioProgress::Error, error.c_str());
    }
    require(frames == expectedFrames && pcmBytes > 0 && source.audioEof(),
            "full queue failed to resume or discarded EOF data");
    source.close();
    checkPressure(source);
    require(source.open(path, options(), error), error.c_str());
    for (unsigned turn = 0; turn < 500; ++turn)
        if (source.advanceCompressedAudio(error) == AvAudioProgress::Backpressure) break;
    source.requestStop();
    require(source.advanceCompressedAudio(error) == AvAudioProgress::Cancelled,
            "full video queue ignored stop");
    require(!source.audioEof(), "cancelled empty PCM queue masqueraded as natural EOF");
    AvCompressedAccessUnit au;
    require(source.readAccessUnit(au, error) == -1, "stopped queue leaked an AU");
    source.close();
    require(source.open(path, options(), error) && source.compressedDiagnostics().queuedPackets == 0,
            "reopen/seek retained queued packets from retired source");
    require(source.readAccessUnit(au, error) == 1, "reopened source did not start cleanly");
}

static void eofWithVideoQueued(const char* path, int expectedFrames) {
    AvInprocDecoder source;
    std::string error;
    require(source.open(path, options(), error), error.c_str());
    uint64_t bytes = 0;
    bool pcmAtEof = false;
    for (unsigned turn = 0; turn < 2000; ++turn) {
        const auto progress = source.advanceCompressedAudio(error);
        require(progress != AvAudioProgress::Error, error.c_str());
        require(progress != AvAudioProgress::Backpressure, "short EOF fixture exceeded video bound");
        const auto state = source.compressedDiagnostics();
        checkBounds(state);
        pcmAtEof |= state.inputEof && state.pcmBytes != 0;
        uint8_t pcm[3840];
        bytes += source.drainPcm(pcm, sizeof(pcm));
        if (source.audioEof()) break;
    }
    require(bytes > 0 && source.audioEof() &&
            source.compressedDiagnostics().queuedPackets == size_t(expectedFrames),
            "audio EOF discarded pending video or queued PCM");
    checkPressure(source);
    int frames = 0;
    for (;;) {
        AvCompressedAccessUnit au;
        const int read = source.readAccessUnit(au, error);
        require(read >= 0, error.c_str());
        if (!read) break;
        ++frames;
    }
    require(frames == expectedFrames, "video queue did not drain after input/audio EOF");
    std::printf("EOF: queued video retained=%d residual-resampler-pcm=%d bytes=%llu\n",
                frames, pcmAtEof, static_cast<unsigned long long>(bytes));
    source.close();
    require(source.open(path, options(), error), error.c_str());
    for (;;) {
        AvCompressedAccessUnit au;
        const int read = source.readAccessUnit(au, error);
        require(read >= 0, error.c_str());
        if (!read) break;
    }
    require(source.compressedDiagnostics().audioEof &&
            source.compressedDiagnostics().pcmBytes > 0 && !source.audioEof(),
            "residual PCM was discarded or misreported as drained EOF");
    uint8_t pcm[3840];
    while (source.drainPcm(pcm, sizeof(pcm))) {}
    require(source.audioEof(), "natural PCM EOF never became drained");
}

static void concurrentReaders(const char* path) {
    AvInprocDecoder source;
    std::string error, audioError;
    require(source.open(path, options(), error), error.c_str());
    uint64_t pcmBytes = 0;
    std::thread audio([&] {
        try {
            uint8_t pcm[3840];
            while (!source.audioEof()) {
                const int count = source.drainPcm(pcm, sizeof(pcm), false);
                pcmBytes += count;
                if (!count) {
                    const auto progress = source.advanceCompressedAudio(audioError);
                    if (progress == AvAudioProgress::Cancelled) break;
                    require(progress != AvAudioProgress::Error, audioError.c_str());
                    if (progress != AvAudioProgress::Ready)
                        std::this_thread::sleep_for(std::chrono::milliseconds(1));
                }
                checkBounds(source.compressedDiagnostics());
            }
        } catch (const std::exception& ex) {
            audioError = ex.what();
            source.requestStop();
        }
    });
    int frames = 0, read = 1;
    while (read > 0) {
        AvCompressedAccessUnit au;
        read = source.readAccessUnit(au, error);
        if (read > 0) ++frames;
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    if (read < 0) source.requestStop();
    audio.join();
    require(read == 0 && frames == 72 && audioError.empty() && pcmBytes > 0 && source.audioEof(),
            "concurrent video/audio demux lost data or failed to retire");
}

static void pauseAndAuRejection(const char* path) {
    AvInprocDecoder source;
    std::string error;
    std::atomic<bool> paused{true};
    auto opts = options();
    opts.paused = &paused;
    require(source.open(path, opts, error), error.c_str());
    const auto before = source.compressedDiagnostics();
    require(source.advanceCompressedAudio(error) == AvAudioProgress::Paused &&
            source.compressedDiagnostics().queuedPackets == before.queuedPackets &&
            source.compressedDiagnostics().pcmBytes == before.pcmBytes,
            "paused audio refill advanced input");
    paused.store(false);
    require(source.advanceCompressedAudio(error) != AvAudioProgress::Paused,
            "audio refill did not resume");
    source.close();
    opts.maxAccessUnitBytes = 8;
    require(source.open(path, opts, error), error.c_str());
    AvAudioProgress result = AvAudioProgress::Pending;
    for (unsigned turn = 0; turn < 500 && result != AvAudioProgress::Error; ++turn) {
        result = source.advanceCompressedAudio(error);
        uint8_t pcm[3840];
        source.drainPcm(pcm, sizeof(pcm));
    }
    require(result == AvAudioProgress::Error && !source.audioEof(),
            "audio read-ahead hid a video packet error as EOF");
    AvCompressedAccessUnit au;
    require(source.readAccessUnit(au, error) == -1 &&
            error.find("bounded ring capacity") != std::string::npos,
            "video consumer did not inherit the read-ahead failure");
    unsigned receipts = 0;
    finishFpgaPlayback({true, false, false, false}, [&] {
        const auto state = source.compressedDiagnostics();
        require(state.detailsAvailable && !state.error.empty() && !state.inputEof,
                "AU-size rejection lost its error or became EOF");
        return formatCompressedDiagnostics(state);
    }, [&] { source.requestStop(); }, [&] { source.close(); return true; },
    [] { return true; }, [] { return true; }, [&](const FpgaTerminalReceipt& receipt) {
        ++receipts;
        require(receipt.classification == PlaybackTerminalState::Stopped &&
                receipt.beforeQuiesce->find("demux_error_present=1") != std::string::npos,
                "AU-size rejection finalizer lost terminal evidence");
    });
    require(receipts == 1, "AU-size rejection emitted multiple receipts");
    AvCompressedDiagnostics safe;
    safe.available = safe.detailsAvailable = true;
    safe.error = "read http://host/path?token=secret token=private";
    const auto text = formatCompressedDiagnostics(safe);
    require(text.find("secret") == std::string::npos && text.find("private") == std::string::npos,
            "terminal demux diagnostic leaked credentials");
}

static void cancelPcmBackpressure(const char* path) {
    AvInprocDecoder source;
    std::string error;
    require(source.open(path, options(), error), error.c_str());
    std::atomic<bool> finished{false};
    std::thread reader([&] {
        AvCompressedAccessUnit au;
        while (source.readAccessUnit(au, error) > 0) {}
        finished.store(true);
    });
    bool blocked = false;
    for (unsigned i = 0; i < 2000 && !finished.load(); ++i) {
        if (source.compressedDiagnostics().blocked == AvDemuxBlocked::PcmQueue) {
            blocked = true;
            require(formatCompressedDiagnostics(source.compressedDiagnostics()).find(
                        "returned_aus=unavailable") != std::string::npos,
                    "busy demux fabricated a coherent zero-valued snapshot");
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    const auto start = std::chrono::steady_clock::now();
    source.requestStop();
    reader.join();
    require(blocked, "fixture did not fill the finite PCM queue");
    require(std::chrono::steady_clock::now() - start < std::chrono::seconds(1),
            "stop failed to wake/join PCM-backpressured demux");
    require(!source.audioEof(), "stopped PCM producer falsely reported EOF");
    unsigned receipts = 0;
    finishFpgaPlayback({true, false, false, true},
        [&] { return formatCompressedDiagnostics(source.compressedDiagnostics()); },
        [] {}, [&] { source.close(); return true; },
        [] { return false; }, [] { return true; },
        [&](const FpgaTerminalReceipt& receipt) {
            ++receipts;
            require(receipt.classification == PlaybackTerminalState::None &&
                    receipt.beforeQuiesce->find("source_cancelled=1") != std::string::npos,
                    "cancelled/superseded real reader escaped accounting");
        });
    require(receipts == 1, "cancelled demux emitted multiple receipts");
}

static void terminalReplay(const char* path, size_t expectedFrames, int64_t periodUs) {
    auto opts = options();
    opts.expectedFpsNum = 24000; opts.expectedFpsDen = 1001;
    AvInprocDecoder source;
    std::string error;
    require(source.open(path, opts, error), error.c_str());
    std::deque<int64_t> video;
    size_t pcmPairs = 0, submitted = 0, presented = 0;
    uint64_t consumed = 0;
    int64_t active = 0, lastPresentation = 0, nextPresentation = 0, origin = 0, trim = 0;
    int64_t videoStart = 0;
    bool aligned = false, eof = false, stalled = false;
    auto tick = [&] {
        active += 2000;
        require(active < 60000000, "bounded production pacing model did not terminate");
        if (!video.empty() && active >= nextPresentation) {
            if (!presented) videoStart = active;
            video.pop_front(); ++presented;
            lastPresentation = active;
            nextPresentation = active + periodUs;
        }
        if (pcmPairs < 960) {
            uint8_t pcm[3840];
            const int got = source.drainPcm(pcm, sizeof(pcm), false);
            if (got) {
                if (!aligned) {
                    const int64_t pts = source.firstAudioPtsUs();
                    require(pts != ddr_bitstream_ring::kNoTimestamp, "missing audio origin");
                    trim = std::max<int64_t>(0, (origin - pts) * 48000 / 1000000);
                    aligned = true;
                }
                const auto skip = std::min<int64_t>(trim, got / 4);
                trim -= skip; pcmPairs += size_t(got / 4 - skip);
            } else if (!source.audioEof()) {
                require(source.advanceCompressedAudio(error) != AvAudioProgress::Error,
                        error.c_str());
            }
        }
        if (presented) {
            const size_t emitted = std::min<size_t>(96, pcmPairs);
            pcmPairs -= emitted; consumed += emitted;
        }
        checkBounds(source.compressedDiagnostics());
        require(video.size() <= 4 && pcmPairs <= 1920, "modeled hardware queues exceeded limits");
        return true;
    };
    for (;;) {
        while (video.size() == 4) tick();
        AvCompressedAccessUnit au;
        const int read = source.readAccessUnit(au, error);
        require(read >= 0, error.c_str());
        if (!read) { eof = true; break; }
        const int64_t pts = int64_t(static_cast<long double>(au.pts) *
                                   au.timebaseNum * 1000000 / au.timebaseDen);
        if (!submitted) origin = pts;
        const auto paced = waitForCompressedAccessUnit(pts - origin,
            [] { return true; }, tick, [&] {
                const bool audioActive = aligned && !(source.audioEof() && pcmPairs == 0);
                return CompressedPacingSnapshot{false, active, lastPresentation,
                    audioActive ? int64_t(consumed) * 1000000 / 48000 : active - videoStart};
            }, [] {});
        if (paced == CompressedPacingResult::Stalled) { stalled = true; break; }
        require(paced == CompressedPacingResult::Due, "unexpected model cancellation");
        video.push_back(au.pts); ++submitted;
    }
    if (eof)
        while (!video.empty() || !source.audioEof() || pcmPairs) tick();
    const bool drained = eof && video.empty() && source.audioEof() && !pcmPairs;
    const auto state = source.compressedDiagnostics();
    unsigned receipts = 0, snapshots = 0;
    const auto result = finishFpgaPlayback({true, eof, drained, presented != 0},
        [&] {
            ++snapshots;
            const auto snapshot = source.compressedDiagnostics();
            require(snapshot.available && snapshot.detailsAvailable,
                    "joined source evidence unavailable");
            return formatCompressedDiagnostics(snapshot);
        }, [&] { source.requestStop(); },
        [&] { source.close(); return true; },
        [] { return true; }, [&] { return stalled; },
        [&](const FpgaTerminalReceipt& receipt) {
            ++receipts;
            require(!source.isOpen() && receipt.beforeReset &&
                    receipt.beforeReset->find("returned_aus=") != std::string::npos,
                    "production terminal call lost evidence at teardown");
            require(receipt.beforeQuiesce->find("source_cancelled=0") != std::string::npos &&
                    receipt.beforeReset->find("source_cancelled=1") != std::string::npos,
                    "retirement cancellation confused with original exit cause");
        });
    require(receipts == 1 && snapshots == 2, "real demux exit bypassed finalizer");
    std::printf("terminal model counts: expected=%zu submitted=%zu presented=%zu "
                "input=%llu returned=%llu eof=%d stalled=%d\n",
                expectedFrames, submitted, presented,
                static_cast<unsigned long long>(state.inputVideoPackets),
                static_cast<unsigned long long>(state.returnedAccessUnits), eof, stalled);
    require(!stalled && result == PlaybackTerminalState::Ended &&
            submitted == expectedFrames && presented == submitted &&
            state.returnedAccessUnits == submitted && state.inputVideoPackets == submitted,
            "real source ended early or failed in bounded production pacing model");
    const auto relativeMs = int64_t(static_cast<long double>(state.lastAuPts - state.firstAuPts) *
                                   state.auTimebaseNum * 1000 / state.auTimebaseDen);
    require(relativeMs == (expectedFrames == 384 ? 15974 : 10969),
            "original rational video extent changed or was padded");
    std::printf("terminal replay: period_us=%lld AUs=%zu relative_ms=%lld last_pts=%lld duration=%lld "
                "tb=%d/%d consumed=%llu ended; one retained terminal receipt\n",
                static_cast<long long>(periodUs), submitted, static_cast<long long>(relativeMs),
                static_cast<long long>(state.lastAuPts),
                static_cast<long long>(state.lastAuDuration), state.auTimebaseNum,
                state.auTimebaseDen, static_cast<unsigned long long>(consumed));
}

int main(int argc, char** argv) {
    try {
        if (argc == 3) {
            const bool full = std::string(argv[1]) == "--terminal-full";
            require(full || std::string(argv[1]) == "--terminal-short", "unknown terminal case");
            terminalReplay(argv[2], full ? 384 : 264, 41708);
            if (full) terminalReplay(argv[2], 384, 50150);
            return 0;
        }
        require(argc == 5, "need interleaved, video-first, short EOF, and long-audio fixtures");
        const auto blocked = paced(argv[1], false);
        require(blocked.stalled, "real interleave did not reproduce serialized-demux pacing failure");
        const auto fixed = paced(argv[1], true);
        require(!fixed.stalled && fixed.pts.size() == 72 && fixed.emittedSamples > 0,
                "independent audio demux failed bounded paced forward progress");
        require(std::equal(blocked.pts.begin(), blocked.pts.end(), fixed.pts.begin()),
                "fix changed original early video timestamps");
        std::printf("real interleave: serialized stalled after %zu AU; independent progressed %zu AU, "
                    "emitted PCM pairs=%llu (modeled sink, not hardware)\n",
                    blocked.pts.size(), fixed.pts.size(),
                    static_cast<unsigned long long>(fixed.emittedSamples));
        fullQueue(argv[2], 72);
        eofWithVideoQueued(argv[3], 12);
        cancelPcmBackpressure(argv[4]);
        concurrentReaders(argv[1]);
        pauseAndAuRejection(argv[1]);
        std::puts("compressed demux progress: bounds, backpressure, concurrent readers, "
                  "pause/cancellation, reopen, error and residual EOF passed");
        return 0;
    } catch (const std::exception& error) {
        std::fprintf(stderr, "FAIL compressed demux progress: %s\n", error.what());
        return 1;
    }
}
