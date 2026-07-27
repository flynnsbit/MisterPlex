#include "misterplexd/plex_resolve.hpp"
#include "libmisterplex/h264_nal_dispatch.hpp"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

namespace {

using Clock = std::chrono::steady_clock;

std::string envOrEmpty(const char* name) {
    const char* v = std::getenv(name);
    return v ? std::string(v) : std::string();
}

std::string shellQuote(const std::string& s) {
    std::string out = "'";
    for (char c : s) {
        if (c == '\'')
            out += "'\\''";
        else
            out += c;
    }
    out += "'";
    return out;
}

struct NalSample {
    uint64_t t_us = 0;
    size_t bytes = 0;
    uint8_t type = 0;
};

struct NalStats {
    std::vector<NalSample> samples;
    uint64_t stdout_bytes = 0;
    uint64_t nal_bytes = 0;
    int vcl = 0;
    int idr = 0;
    int sps = 0;
    int pps = 0;
    int other = 0;
    int pclose_rc = 0;
};

uint64_t microsSince(Clock::time_point start, Clock::time_point now) {
    return static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::microseconds>(now - start).count());
}

bool runFfmpegNalStats(const std::string& url, const std::string& headers, int seconds,
                       NalStats& stats) {
    std::ostringstream cmd;
    cmd << "ffmpeg -hide_banner -loglevel error -nostdin"
        << " -headers " << shellQuote(headers)
        << " -i " << shellQuote(url)
        << " -map 0:v:0 -t " << seconds
        << " -c:v copy -an -f h264 - 2>/dev/null";

    FILE* pipe = popen(cmd.str().c_str(), "r");
    if (!pipe)
        return false;

    misterplex::h264stream::AnnexBFramer framer;
    const auto t0 = Clock::now();
    char buf[16384];
    while (true) {
        const size_t n = std::fread(buf, 1, sizeof(buf), pipe);
        if (n > 0) {
            const auto now = Clock::now();
            stats.stdout_bytes += n;
            const bool ok = framer.push(reinterpret_cast<const uint8_t*>(buf), n,
                                        [&](const uint8_t* p, size_t len) {
                                            const uint8_t type =
                                                misterplex::h264stream::annexBNalType(p, len);
                                            stats.samples.push_back(
                                                {microsSince(t0, now), len, type});
                                            stats.nal_bytes += len;
                                            if (type == 1 || type == 5)
                                                ++stats.vcl;
                                            if (type == 5)
                                                ++stats.idr;
                                            else if (type == 7)
                                                ++stats.sps;
                                            else if (type == 8)
                                                ++stats.pps;
                                            else if (type != 1)
                                                ++stats.other;
                                        });
            if (!ok)
                break;
        }
        if (n < sizeof(buf)) {
            if (std::feof(pipe) || std::ferror(pipe))
                break;
        }
    }
    const auto now = Clock::now();
    framer.finish([&](const uint8_t* p, size_t len) {
        const uint8_t type = misterplex::h264stream::annexBNalType(p, len);
        stats.samples.push_back({microsSince(t0, now), len, type});
        stats.nal_bytes += len;
        if (type == 1 || type == 5)
            ++stats.vcl;
        if (type == 5)
            ++stats.idr;
        else if (type == 7)
            ++stats.sps;
        else if (type == 8)
            ++stats.pps;
        else if (type != 1)
            ++stats.other;
    });
    stats.pclose_rc = pclose(pipe);
    return !stats.samples.empty();
}

template <typename T>
T percentile(std::vector<T> values, double p) {
    if (values.empty())
        return {};
    std::sort(values.begin(), values.end());
    const size_t idx = std::min(values.size() - 1,
                                static_cast<size_t>(p * static_cast<double>(values.size() - 1) +
                                                    0.5));
    return values[idx];
}

uint64_t maxBurstBytes(const std::vector<NalSample>& samples, uint64_t window_us) {
    uint64_t best = 0;
    uint64_t cur = 0;
    size_t left = 0;
    for (size_t right = 0; right < samples.size(); ++right) {
        cur += samples[right].bytes;
        while (left < right && samples[right].t_us - samples[left].t_us > window_us) {
            cur -= samples[left].bytes;
            ++left;
        }
        best = std::max(best, cur);
    }
    return best;
}

uint64_t nextPow2(uint64_t v) {
    if (v <= 1)
        return 1;
    --v;
    for (size_t s = 1; s < sizeof(v) * 8; s <<= 1)
        v |= v >> s;
    return v + 1;
}

int usage(const char* argv0) {
    std::cerr << "usage: " << argv0 << " --base URL --token TOKEN --key /library/metadata/N "
              << "[--seconds N]\n"
              << "       Env equivalents: PLEX_BASE, PLEX_TOKEN, MISTERPLEX_BASELINE_KEY\n";
    return 2;
}

} // namespace

int main(int argc, char** argv) {
    std::string base = envOrEmpty("PLEX_BASE");
    std::string token = envOrEmpty("PLEX_TOKEN");
    std::string key = envOrEmpty("MISTERPLEX_BASELINE_KEY");
    int seconds = 30;

    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        auto needValue = [&](std::string& out) -> bool {
            if (i + 1 >= argc)
                return false;
            out = argv[++i];
            return true;
        };
        if (a == "--base") {
            if (!needValue(base))
                return usage(argv[0]);
        } else if (a == "--token") {
            if (!needValue(token))
                return usage(argv[0]);
        } else if (a == "--key") {
            if (!needValue(key))
                return usage(argv[0]);
        } else if (a == "--seconds") {
            std::string v;
            if (!needValue(v))
                return usage(argv[0]);
            seconds = std::atoi(v.c_str());
        } else if (a == "--help" || a == "-h") {
            return usage(argv[0]);
        } else {
            std::cerr << "unknown argument: " << a << "\n";
            return usage(argv[0]);
        }
    }

    base = misterplex::normalizePlexBase(base);
    if (base.empty() || token.empty() || key.empty()) {
        std::cerr << "SKIP-NOT-PASS pms_nal_stats: live PMS inputs missing; set PLEX_BASE, "
                     "PLEX_TOKEN, and MISTERPLEX_BASELINE_KEY. This is not a pass.\n";
        return 77;
    }
    if (seconds < 4)
        seconds = 4;
    if (seconds > 120)
        seconds = 120;

    misterplex::WeakLadder weak;
    if (!misterplex::applyPlexTranscodeProfile("480p", weak)) {
        std::cerr << "FAIL pms_nal_stats: built-in 480p transcode profile missing\n";
        return 1;
    }

    const std::string session = "mplex-nal-stats";
    const std::string startUrl =
        misterplex::buildUniversalTranscodeUrl(base, key, token, session, 0, weak);
    if (!misterplex::ensureUniversalDecision(startUrl, session, token, weak)) {
        std::cerr << "FAIL pms_nal_stats: PMS universal decision request failed before stream fetch\n";
        return 1;
    }

    NalStats stats;
    if (!runFfmpegNalStats(startUrl, misterplex::plexFfmpegHeaders(session, token, weak), seconds,
                           stats)) {
        std::cerr << "FAIL pms_nal_stats: no Annex-B NAL units observed; pclose_rc="
                  << stats.pclose_rc << " stdout_bytes=" << stats.stdout_bytes << "\n";
        return 1;
    }

    std::vector<size_t> nalSizes;
    std::vector<size_t> vclSizes;
    std::vector<uint64_t> deltas;
    nalSizes.reserve(stats.samples.size());
    for (size_t i = 0; i < stats.samples.size(); ++i) {
        nalSizes.push_back(stats.samples[i].bytes);
        if (stats.samples[i].type == 1 || stats.samples[i].type == 5)
            vclSizes.push_back(stats.samples[i].bytes);
        if (i > 0)
            deltas.push_back(stats.samples[i].t_us - stats.samples[i - 1].t_us);
    }

    const auto maxNal = *std::max_element(nalSizes.begin(), nalSizes.end());
    const auto maxVcl = vclSizes.empty() ? 0 : *std::max_element(vclSizes.begin(), vclSizes.end());
    const uint64_t burst100 = maxBurstBytes(stats.samples, 100000);
    const uint64_t burst250 = maxBurstBytes(stats.samples, 250000);
    const uint64_t burst500 = maxBurstBytes(stats.samples, 500000);
    const uint64_t burst1000 = maxBurstBytes(stats.samples, 1000000);
    const uint64_t suggested = nextPow2(std::max<uint64_t>(maxNal, burst500) * 2u);

    std::cout << "PMS_NAL_STATS seconds=" << seconds << " nals=" << stats.samples.size()
              << " vcl=" << stats.vcl << " idr=" << stats.idr << " sps=" << stats.sps
              << " pps=" << stats.pps << " other=" << stats.other
              << " stdout_bytes=" << stats.stdout_bytes << " nal_bytes=" << stats.nal_bytes
              << " pclose_rc=" << stats.pclose_rc << "\n";
    std::cout << "PMS_NAL_SIZE max=" << maxNal << " max_vcl=" << maxVcl
              << " p50=" << percentile(nalSizes, 0.50) << " p95="
              << percentile(nalSizes, 0.95) << " p99=" << percentile(nalSizes, 0.99)
              << " vcl_p95=" << (vclSizes.empty() ? 0 : percentile(vclSizes, 0.95))
              << " vcl_p99=" << (vclSizes.empty() ? 0 : percentile(vclSizes, 0.99))
              << "\n";
    std::cout << "PMS_NAL_DELTA_US max=" << (deltas.empty() ? 0 : percentile(deltas, 1.0))
              << " p50=" << (deltas.empty() ? 0 : percentile(deltas, 0.50))
              << " p95=" << (deltas.empty() ? 0 : percentile(deltas, 0.95))
              << " p99=" << (deltas.empty() ? 0 : percentile(deltas, 0.99)) << "\n";
    std::cout << "PMS_NAL_BURST_BYTES win100ms=" << burst100 << " win250ms=" << burst250
              << " win500ms=" << burst500 << " win1000ms=" << burst1000
              << " suggested_ring_bytes=" << suggested << "\n";
    return 0;
}
