// plex_bitstream_feed — push an Annex-B H.264 file into the HPS DDR bitstream
// ring, standalone.
//
// Why this exists: bringing up the FPGA decoder otherwise requires a full Plex
// playback session -- network, PMS, transcode profile, ffmpeg -- just to get
// bytes in front of the decoder. That is a lot of moving parts between "the
// decoder did not work" and "the decoder did not work *because*". This feeds a
// fixed local file, so the input is byte-identical on every run and a change on
// screen can only come from the fabric.
//
// It uses the SAME FpgaBitstreamProducer and NalDispatcher as misterplexd. A
// feeder with its own ring-writing code would prove nothing about the daemon.
//
// Exit codes: 0 fed, 1 error, 77 no device (so a bring-up script cannot mistake
// "there is no FPGA here" for "the feed succeeded").

#include "fpga_bitstream_producer.hpp"
#include "fpga_spi.hpp"
#include "libmisterplex/ddr_bitstream_ring.hpp"
#include "libmisterplex/h264_nal_dispatch.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

using namespace misterplex;

namespace {

constexpr int kExitNoDevice = 77;

std::vector<uint8_t> readFile(const char* path) {
    std::vector<uint8_t> out;
    FILE* f = std::fopen(path, "rb");
    if (!f)
        return out;
    uint8_t buf[65536];
    size_t n;
    while ((n = std::fread(buf, 1, sizeof(buf), f)) > 0)
        out.insert(out.end(), buf, buf + n);
    std::fclose(f);
    return out;
}

void printStatus(const char* when, FpgaSpi& fpga) {
    FpgaSpi::BitstreamStatus s;
    if (!fpga.readBitstreamStatus(s)) {
        std::printf("RING %s: unreadable\n", when);
        return;
    }
    std::printf("RING %s: level=%u/%u producer=%u consumer=%u seq=%u "
                "active=%d paused=%d dormant=%d underrun=%d overrun=%d "
                "desync=%d fatal=%d session=%llu\n",
                when, s.ring_level, s.ring_capacity, s.producer_count,
                s.consumer_count, s.consumer_seq, static_cast<int>(s.active),
                static_cast<int>(s.paused), static_cast<int>(s.dormant),
                static_cast<int>(s.underrun), static_cast<int>(s.overrun),
                static_cast<int>(s.desync), static_cast<int>(s.fatal),
                static_cast<unsigned long long>(s.session_id));
}

void usage() {
    std::fprintf(stderr,
                 "usage: plex_bitstream_feed --file <annexb.264> [options]\n"
                 "  --file PATH     Annex-B H.264 elementary stream (required)\n"
                 "  --idr-only      drop non-IDR slices (Stage-B bring-up)\n"
                 "  --loop N        feed the file N times (default 1, 0 = forever)\n"
                 "  --fps N         pace VCL NALs at N per second (default 0 = as fast as possible)\n"
                 "  --session ID    session id (default 1)\n"
                 "  --hold-ms N     keep the session open N ms after the last NAL\n"
                 "  --dry-run       parse and report, never touch /dev/mem\n");
}

} // namespace

int main(int argc, char** argv) {
    const char* path = nullptr;
    bool idrOnly = false;
    bool dryRun = false;
    int loops = 1;
    int fps = 0;
    int holdMs = 0;
    uint64_t session = 1;

    for (int i = 1; i < argc; ++i) {
        const std::string a = argv[i];
        auto next = [&](const char* what) -> const char* {
            if (i + 1 >= argc) {
                std::fprintf(stderr, "missing value for %s\n", what);
                std::exit(1);
            }
            return argv[++i];
        };
        if (a == "--file")
            path = next("--file");
        else if (a == "--idr-only")
            idrOnly = true;
        else if (a == "--dry-run")
            dryRun = true;
        else if (a == "--loop")
            loops = std::atoi(next("--loop"));
        else if (a == "--fps")
            fps = std::atoi(next("--fps"));
        else if (a == "--hold-ms")
            holdMs = std::atoi(next("--hold-ms"));
        else if (a == "--session")
            session = std::strtoull(next("--session"), nullptr, 0);
        else if (a == "-h" || a == "--help") {
            usage();
            return 0;
        } else {
            std::fprintf(stderr, "unknown argument: %s\n", a.c_str());
            usage();
            return 1;
        }
    }

    if (!path) {
        usage();
        return 1;
    }

    const auto data = readFile(path);
    if (data.empty()) {
        std::fprintf(stderr, "FEED_FAIL: cannot read %s\n", path);
        return 1;
    }

    // Report the input before touching hardware, so a bad file is never
    // reported as a hardware problem.
    size_t inNals = 0, inIdr = 0, inVcl = 0;
    {
        h264stream::AnnexBFramer counter;
        auto tally = [&](const uint8_t* p, size_t n) {
            const uint8_t t = h264stream::annexBNalType(p, n);
            ++inNals;
            if (t == 5)
                ++inIdr;
            if (t == 1 || t == 5)
                ++inVcl;
        };
        counter.push(data.data(), data.size(), tally);
        counter.finish(tally);
    }
    std::printf("INPUT %s bytes=%zu nals=%zu vcl=%zu idr=%zu\n", path,
                data.size(), inNals, inVcl, inIdr);
    if (inIdr == 0) {
        std::fprintf(stderr,
                     "FEED_FAIL: no IDR in %s — a decoder has no entry point\n",
                     path);
        return 1;
    }

    if (dryRun) {
        std::printf("FEED_DRY_RUN idr_only=%d loops=%d — no device touched\n",
                    static_cast<int>(idrOnly), loops);
        return 0;
    }

    FpgaSpi fpga;
    if (!fpga.open() || !fpga.ok()) {
        std::fprintf(stderr, "FEED_NO_DEVICE: %s\n", fpga.lastError().c_str());
        return kExitNoDevice;
    }

    printStatus("before", fpga);

    FpgaBitstreamProducer producer(fpga);
    h264stream::DispatchConfig cfg;
    cfg.idr_only = idrOnly;
    h264stream::NalDispatcher dispatch(producer, cfg);

    if (dispatch.begin(session) != h264stream::ControlResult::Ok) {
        std::fprintf(stderr, "FEED_FAIL: begin session %llu rejected\n",
                     static_cast<unsigned long long>(session));
        return 1;
    }

    const int64_t frameUs = fps > 0 ? 1000000 / fps : 0;
    bool fatal = false;
    for (int loop = 0; (loops == 0 || loop < loops) && !fatal; ++loop) {
        h264stream::AnnexBFramer framer;
        auto emit = [&](const uint8_t* p, size_t n) {
            if (fatal)
                return;
            const uint8_t t = h264stream::annexBNalType(p, n);
            if (dispatch.handleNal(p, n) != h264stream::PushResult::Ok) {
                fatal = true;
                return;
            }
            if (frameUs > 0 && (t == 1 || t == 5))
                std::this_thread::sleep_for(std::chrono::microseconds(frameUs));
        };
        framer.push(data.data(), data.size(), emit);
        framer.finish(emit);
    }

    if (holdMs > 0)
        std::this_thread::sleep_for(std::chrono::milliseconds(holdMs));

    printStatus("after", fpga);
    const auto st = dispatch.stats();
    std::printf("FEED seen=%llu pushed=%llu bytes=%llu sps_replayed=%llu "
                "resyncs=%llu dropped_resync=%llu dropped_idr_only=%llu\n",
                static_cast<unsigned long long>(st.nal_seen),
                static_cast<unsigned long long>(st.nal_pushed),
                static_cast<unsigned long long>(st.bytes_pushed),
                static_cast<unsigned long long>(st.sps_replayed),
                static_cast<unsigned long long>(st.resyncs),
                static_cast<unsigned long long>(st.nal_dropped_resync),
                static_cast<unsigned long long>(st.nal_dropped_idr_only));

    dispatch.end();

    if (fatal) {
        std::fprintf(stderr, "FEED_FAIL: producer returned a fatal result\n");
        return 1;
    }
    if (st.nal_pushed == 0) {
        std::fprintf(stderr, "FEED_FAIL: nothing was pushed\n");
        return 1;
    }
    std::printf("FEED_OK\n");
    return 0;
}
