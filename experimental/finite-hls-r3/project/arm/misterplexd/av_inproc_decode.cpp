#ifndef MPX_HAVE_LIBAV
#error "av_inproc_decode.cpp requires -DMPX_HAVE_LIBAV"
#endif

#include "libmisterplex/av_inproc_decode.hpp"
#include "libmisterplex/h264_sps.hpp"
#include "libmisterplex/fpga_terminal.hpp"
#include "finite_hls_io.hpp"
#include "log_redact.hpp"

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <deque>
#include <cstring>
#include <mutex>
#include <sstream>
#include <sys/stat.h>
#include <vector>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavcodec/bsf.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/dict.h>
#include <libavutil/error.h>
#include <libavutil/mathematics.h>
#include <libavutil/pixfmt.h>
#include <libavutil/rational.h>
#include <libswresample/swresample.h>
}

namespace misterplex {
namespace {

std::string avErr(int ret) {
    char buf[128];
    if (av_strerror(ret, buf, sizeof(buf)) == 0)
        return std::string(buf);
    return "av error " + std::to_string(ret);
}

bool looksHttpUrl(const std::string& path) {
    size_t i = 0;
    while (i < path.size() &&
           (path[i] == ' ' || path[i] == '\t' || path[i] == '\r' || path[i] == '\n'))
        ++i;
    if (path.compare(i, 7, "http://") == 0 || path.compare(i, 7, "HTTP://") == 0)
        return true;
    if (path.compare(i, 8, "https://") == 0 || path.compare(i, 8, "HTTPS://") == 0)
        return true;
    return false;
}

bool looksNetworkUrl(const std::string& path) {
    const auto pos = path.find("://");
    if (pos == std::string::npos)
        return false;
    return path.compare(0, 5, "file:") != 0;
}

bool looksHlsPlaylist(const std::string& url) {
    const auto end = url.find_first_of("?#");
    const auto path = url.substr(0, end);
    return path.size() >= 5 && path.compare(path.size() - 5, 5, ".m3u8") == 0;
}

int64_t monotonicMs() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::steady_clock::now().time_since_epoch()).count();
}

// A container packet (including libav's raw/TS parser output) must be one whole
// picture. The initial product deliberately rejects multislice and B pictures.
struct CompressedSyntax {
    std::vector<uint8_t> sps, pps;
    uint32_t spsId = 0, ppsId = 0;
    uint32_t frameNumBits = 0, pocType = 0, pocLsbBits = 0;
    uint32_t maxReferences = 0;
    int initialQp = 26;
    bool deblockControl = false;
    SourceAspect aspect{};
    AvCompressedVideoGeometry geometry;
    int width = 0, height = 0;
    bool haveSps = false, havePps = false;

    bool inspect(const uint8_t* data, size_t size, const AvInprocOpenOpts& opts,
                 bool& idr, bool& changed, std::string& err) {
        idr = false;
        changed = false;
        int pictures = 0;
        auto start = [&](size_t i) -> size_t {
            if (i + 3 < size && !data[i] && !data[i + 1] && !data[i + 2] &&
                data[i + 3] == 1) return 4;
            if (i + 2 < size && !data[i] && !data[i + 1] && data[i + 2] == 1) return 3;
            return 0;
        };
        size_t pos = 0;
        while (pos < size && data[pos] == 0 && !start(pos)) ++pos;
        while (pos < size) {
            const size_t sc = start(pos);
            if (!sc || pos + sc >= size) {
                err = "malformed Annex-B access unit";
                return false;
            }
            const size_t hdr = pos + sc;
            size_t end = hdr + 1;
            while (end < size && !start(end)) ++end;
            const uint8_t type = data[hdr] & 31;
            if (type == 1 && opts.requireAllIdr) {
                err = "selected all-IDR profile requires every picture to be IDR";
                return false;
            }
            if (data[hdr] & 128) {
                err = "forbidden H.264 NAL bit";
                return false;
            }
            auto rbsp = detail::removeEpb(data + hdr + 1, end - hdr - 1);
            if ((type == 1 || type == 5) && rbsp.size() > opts.maxVclRbspBytes) {
                err = "VCL RBSP exceeds the decoder frontend capacity";
                return false;
            }
            detail::BitReader br(rbsp.data(), rbsp.size());
            if (type == 7) {
                const unsigned profile = br.u(8);
                br.u(8);
                const unsigned level = br.u(8);
                const uint32_t sid = br.ue();
                const uint32_t frameBits = br.ue();
                const uint32_t poc = br.ue();
                uint32_t pocBits = 0;
                if (poc == 0) pocBits = br.ue();
                const uint32_t refs = br.ue();
                const bool gaps = br.u1();
                const uint32_t mbw = br.ue() + 1, mbh = br.ue() + 1;
                const bool progressive = br.u1();
                br.u1();
                uint32_t left = 0, right = 0, top = 0, bottom = 0;
                if (br.u1()) {
                    left = br.ue(); right = br.ue(); top = br.ue(); bottom = br.ue();
                }
                if (!br.ok || profile != 66 || level > 30 || sid > 31 ||
                    frameBits > 12 || (poc != 0 && poc != 2) || pocBits > 12 ||
                    refs > 1 || gaps || !progressive ||
                    mbw > static_cast<unsigned>(opts.expectW / 16) ||
                    mbh > static_cast<unsigned>(opts.expectH / 16) ||
                    left + right >= mbw * 8 || top + bottom >= mbh * 8) {
                    err = "unsupported SPS: requires 8-bit baseline/CAVLC progressive ref<=1 geometry";
                    return false;
                }
                const int w = static_cast<int>(mbw * 16 - 2 * (left + right));
                const int h = static_cast<int>(mbh * 16 - 2 * (top + bottom));
                AvCompressedVideoGeometry nextGeometry;
                nextGeometry.codedWidth = static_cast<int>(mbw * 16);
                nextGeometry.codedHeight = static_cast<int>(mbh * 16);
                nextGeometry.visibleWidth = w;
                nextGeometry.visibleHeight = h;
                nextGeometry.macroblockColumns = static_cast<int>(mbw);
                nextGeometry.macroblockRows = static_cast<int>(mbh);
                nextGeometry.cropLeft = static_cast<int>(left * 2);
                nextGeometry.cropRight = static_cast<int>(right * 2);
                nextGeometry.cropTop = static_cast<int>(top * 2);
                nextGeometry.cropBottom = static_cast<int>(bottom * 2);
                if (w > opts.expectW || h > opts.expectH ||
                    (haveSps && !geometry.samePictureLayout(nextGeometry))) {
                    err = "unsupported mid-session geometry change";
                    return false;
                }
                aspect = {};
                const bool hasVui = br.u1();
                if (hasVui && br.u1()) {
                    const unsigned aspectIdc = br.u(8);
                    static constexpr unsigned sar[][2] = {
                        {0,0}, {1,1}, {12,11}, {10,11}, {16,11}, {40,33},
                        {24,11}, {20,11}, {32,11}, {80,33}, {18,11}, {15,11},
                        {64,33}, {160,99}, {4,3}, {3,2}, {2,1}
                    };
                    unsigned num = 0, den = 0;
                    if (aspectIdc == 255) {
                        num = br.u(16); den = br.u(16);
                    } else if (aspectIdc < sizeof(sar) / sizeof(sar[0])) {
                        num = sar[aspectIdc][0]; den = sar[aspectIdc][1];
                    }
                    if (br.ok && num && den) {
                        int darNum = 0, darDen = 0;
                        av_reduce(&darNum, &darDen, int64_t(w) * num,
                                  int64_t(h) * den, 65535);
                        aspect = {static_cast<uint16_t>(darNum),
                                  static_cast<uint16_t>(darDen), true};
                    }
                }
                if (hasVui) {
                    if (br.u1()) br.u1(); // overscan
                    nextGeometry.videoSignalPresent = br.u1();
                    if (nextGeometry.videoSignalPresent) {
                        br.u(3);
                        nextGeometry.fullRange = br.u1();
                        nextGeometry.colorDescriptionPresent = br.u1();
                        if (nextGeometry.colorDescriptionPresent) {
                            nextGeometry.colorPrimaries = br.u(8);
                            nextGeometry.transferCharacteristics = br.u(8);
                            nextGeometry.matrixCoefficients = br.u(8);
                        }
                    }
                }
                if (!br.ok) {
                    err = "truncated SPS VUI aspect/color description";
                    return false;
                }
                if (nextGeometry.fullRange ||
                    (nextGeometry.matrixCoefficients != 2 &&
                     nextGeometry.matrixCoefficients != 5 &&
                     nextGeometry.matrixCoefficients != 6) ||
                    (opts.requireLimitedBt601 && !nextGeometry.limitedBt601Signaled())) {
                    err = "fixed limited-BT601 scanout color policy rejected SPS: "
                          "full_range=" + std::to_string(nextGeometry.fullRange) +
                          " matrix_coefficients=" + std::to_string(nextGeometry.matrixCoefficients) +
                          " description_present=" + std::to_string(nextGeometry.colorDescriptionPresent);
                    return false;
                }
                nextGeometry.sourceAspect = aspect;
                geometry = nextGeometry;
                std::vector<uint8_t> next(data + hdr, data + end);
                changed |= !haveSps || next != sps;
                if (haveSps && spsId != sid)
                    havePps = false;
                sps = std::move(next);
                spsId = sid; width = w; height = h; haveSps = true;
                maxReferences = refs;
                frameNumBits = frameBits + 4;
                pocType = poc;
                pocLsbBits = pocBits + 4;
            } else if (type == 8) {
                const uint32_t pid = br.ue(), sid = br.ue();
                const bool cabac = br.u1(), bottomPoc = br.u1();
                const uint32_t groups = br.ue();
                const uint32_t l0 = br.ue(), l1 = br.ue();
                const bool weighted = br.u1();
                const uint32_t bipred = br.u(2);
                const int qp = br.se(), qs = br.se(), chroma = br.se();
                const bool deblock = br.u1();
                br.u1();
                const bool redundant = br.u1();
                if (!br.ok || !haveSps || pid > 255 || sid != spsId || cabac ||
                    bottomPoc || groups || l0 || l1 || weighted || bipred || redundant ||
                    qp < -26 || qp > 25 || qs < -26 || qs > 25 ||
                    chroma < -12 || chroma > 12) {
                    err = "unsupported PPS: CABAC/FMO/weighted/multiple references";
                    return false;
                }
                // Baseline permits no transform/scaling-list extension.
                if (br.bit < rbsp.size() * 8) {
                    const bool stopBit = br.u1();
                    bool trailingZero = true;
                    while (br.bit < rbsp.size() * 8)
                        trailingZero &= br.u1() == 0;
                    if (!stopBit || !trailingZero) {
                        err = "unsupported PPS extension";
                        return false;
                    }
                }
                std::vector<uint8_t> next(data + hdr, data + end);
                changed |= !havePps || next != pps;
                pps = std::move(next); ppsId = pid; havePps = true;
                initialQp = 26 + qp;
                deblockControl = deblock;
            } else if (type == 1 || type == 5) {
                const uint32_t firstMb = br.ue(), sliceType = br.ue(), pid = br.ue();
                if (!br.ok || !havePps || firstMb != 0 || pid != ppsId ||
                    sliceType > 9 || (type == 5 && sliceType % 5 != 2) ||
                    (type == 5 && (data[hdr] & 0x60) == 0) ||
                    (sliceType % 5 == 0 && maxReferences != 1) ||
                    (sliceType % 5 != 2 &&
                    !(sliceType % 5 == 0 && opts.allowInter)) || ++pictures != 1) {
                    err = "unsupported slice: requires single complete I/P picture";
                    return false;
                }
                br.u(frameNumBits);
                if (type == 5) br.ue();
                if (pocType == 0) br.u(pocLsbBits);
                if (sliceType % 5 == 0) {
                    if (br.u1() && br.ue() != 0) {
                        err = "multiple active references are unsupported";
                        return false;
                    }
                    if (br.u1()) {
                        err = "reference list modification is unsupported";
                        return false;
                    }
                }
                if ((data[hdr] >> 5) & 3) {
                    if (type == 5) {
                        br.u1();
                        if (br.u1()) {
                            err = "long-term IDR references are unsupported";
                            return false;
                        }
                    } else if (br.u1()) {
                        err = "adaptive reference marking is unsupported";
                        return false;
                    }
                }
                const int qp = initialQp + br.se();
                uint32_t disableFilter = 0;
                if (deblockControl) {
                    disableFilter = br.ue();
                    if (disableFilter != 1) {
                        const int alpha = br.se(), beta = br.se();
                        if (alpha < -6 || alpha > 6 || beta < -6 || beta > 6)
                            br.ok = false;
                    }
                }
                if (!br.ok || qp < 0 || qp > 51 || disableFilter > 2 ||
                    (!opts.allowDeblock && disableFilter != 1)) {
                    err = "unsupported/truncated slice header or unnegotiated deblocking";
                    return false;
                }
                idr |= type == 5;
            } else if (type != 6 && type != 9 && type != 10 && type != 11 && type != 12) {
                err = "unsupported H.264 NAL type " + std::to_string(type);
                return false;
            }
            pos = end;
        }
        if (pictures != 1 || (changed && !idr)) {
            err = "access unit lacks one complete picture or changes SPS/PPS outside IDR";
            return false;
        }
        return true;
    }
};

bool copyPackedI420(const AVFrame* fr, uint8_t* dst, int w, int h, std::string& err) {
    if (!fr || !dst || !fr->data[0] || !fr->data[1] || !fr->data[2]) {
        err = "missing I420 plane";
        return false;
    }
    const int cw = w / 2;
    const int ch = h / 2;
    if (w <= 0 || h <= 0 || (w & 1) || (h & 1) ||
        fr->linesize[0] < w || fr->linesize[1] < cw || fr->linesize[2] < cw) {
        err = "I420 linesize/size invalid";
        return false;
    }
    const size_t ysz = static_cast<size_t>(w) * static_cast<size_t>(h);
    const size_t csz = static_cast<size_t>(cw) * static_cast<size_t>(ch);
    if (fr->linesize[0] == w && fr->linesize[1] == cw && fr->linesize[2] == cw) {
        std::memcpy(dst, fr->data[0], ysz);
        std::memcpy(dst + ysz, fr->data[1], csz);
        std::memcpy(dst + ysz + csz, fr->data[2], csz);
        return true;
    }
    for (int row = 0; row < h; ++row)
        std::memcpy(dst + static_cast<size_t>(row) * static_cast<size_t>(w),
                    fr->data[0] + static_cast<size_t>(row) * static_cast<size_t>(fr->linesize[0]),
                    static_cast<size_t>(w));
    uint8_t* u = dst + ysz;
    uint8_t* v = u + csz;
    for (int row = 0; row < ch; ++row) {
        std::memcpy(u + static_cast<size_t>(row) * static_cast<size_t>(cw),
                    fr->data[1] + static_cast<size_t>(row) * static_cast<size_t>(fr->linesize[1]),
                    static_cast<size_t>(cw));
        std::memcpy(v + static_cast<size_t>(row) * static_cast<size_t>(cw),
                    fr->data[2] + static_cast<size_t>(row) * static_cast<size_t>(fr->linesize[2]),
                    static_cast<size_t>(cw));
    }
    return true;
}

} // namespace

int16_t s16sat(int v) {
    if (v > 32767)
        return 32767;
    if (v < -32768)
        return -32768;
    return static_cast<int16_t>(v);
}

int avFrameChannels(const AVFrame* fr, const AVCodecContext* ctx) {
    if (fr && fr->ch_layout.nb_channels > 0)
        return fr->ch_layout.nb_channels;
    if (ctx && ctx->ch_layout.nb_channels > 0)
        return ctx->ch_layout.nb_channels;
    return 1;
}

struct AvInprocDecoder::Impl {
    AVFormatContext* fmt = nullptr;
    FiniteHlsIo hls;
    AVCodecContext* codec = nullptr;
    AVCodecContext* acodec = nullptr;
    AVFrame* frame = nullptr;
    AVFrame* aframe = nullptr;
    AVPacket* pkt = nullptr;
    AVBSFContext* bsf = nullptr;
    SwrContext* resampler = nullptr;
    int resampleRate = 0, resampleFormat = -1, resampleChannels = 0;
    std::deque<AVPacket*> queuedPackets;
    AVPacket* aheadPacket = nullptr;
    size_t queuedBytes = 0;
    std::mutex compressedMu;
    std::atomic<size_t> diagnosticPackets{0}, diagnosticBytes{0};
    std::atomic<int64_t> diagnosticNextPts{ddr_bitstream_ring::kNoTimestamp};
    std::atomic<AvDemuxBlocked> blocked{AvDemuxBlocked::Idle};
    std::atomic<bool> inputEof{false};
#if MPX_FPGA_AV_TRACE
    std::atomic<size_t> diagnosticPcmBytes{0};
    std::atomic<bool> diagnosticAudioEof{false}, diagnosticReservedVideo{false};
#endif
    std::string compressedError;
    AvInprocOpenOpts options;
    CompressedSyntax syntax;
    bool compressed = false;
    bool bsfFlushed = false;
    bool audioFlushed = false;
    std::string audioError;
    std::atomic<int64_t> audioPtsUs{ddr_bitstream_ring::kNoTimestamp};
    SourceAspect aspect{};
    int64_t previousPts = ddr_bitstream_ring::kNoTimestamp;
    int64_t firstPts = ddr_bitstream_ring::kNoTimestamp;
    uint64_t accessUnits = 0;
    std::optional<int> inputReadResult;
    bool inputReadCancelled = false;
    uint64_t inputVideoPackets = 0;
    int64_t lastInputPts = AV_NOPTS_VALUE, lastInputDuration = 0, lastAuDuration = 0;
    int64_t hlsOriginPts = AV_NOPTS_VALUE;
    AVRational inputTimebase{0, 0};
    int64_t seekTargetPts = AV_NOPTS_VALUE;
    bool seekChecked = false;
    int vidx = -1;
    int aidx = -1;
    int w = 0;
    int h = 0;
    int srcW = 0;
    int srcH = 0;
    int arate = 0;
    bool open = false;
    bool flushing = false;
    bool pending = false;
    bool audioEof = false;
    bool stopping = false;
    std::mutex pcmMu;
    std::condition_variable pcmCv;
    std::vector<uint8_t> pcm;

    void pushPcm48(const uint8_t* p, size_t n) {
        if (!p || n == 0)
            return;
        std::unique_lock<std::mutex> lk(pcmMu);
        constexpr size_t kCap = kCompressedPcmByteLimit;
        if (compressed) {
            auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
            while (!stopping && !audioEof && pcm.size() + n > kCap) {
                blocked.store(AvDemuxBlocked::PcmQueue);
                if (options.cancelled && options.cancelled->load()) return;
                if (options.paused && options.paused->load())
                    deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
                else if (std::chrono::steady_clock::now() >= deadline) {
                    audioError = "PCM backpressure timeout";
                    return;
                }
                pcmCv.wait_for(lk, std::chrono::milliseconds(20));
            }
            if (stopping || audioEof) return;
        }
        pcm.insert(pcm.end(), p, p + n);
        if (pcm.size() > kCap)
            pcm.erase(pcm.begin(), pcm.begin() + static_cast<std::ptrdiff_t>(pcm.size() - kCap));
        MPX_AV_TRACE(diagnosticPcmBytes.store(pcm.size(), std::memory_order_relaxed);)
        pcmCv.notify_all();
    }

    void ingestAudioFrame() {
        if (!aframe)
            return;
        const int n = aframe->nb_samples;
        if (n <= 0)
            return;
        const int ch = avFrameChannels(aframe, acodec);
        int rate = aframe->sample_rate > 0 ? aframe->sample_rate : arate;
        if (rate <= 0)
            rate = 48000;
        if (compressed) {
            if (!resampler) {
                AVChannelLayout stereo = AV_CHANNEL_LAYOUT_STEREO;
                if (swr_alloc_set_opts2(&resampler, &stereo, AV_SAMPLE_FMT_S16, 48000,
                        &aframe->ch_layout, static_cast<AVSampleFormat>(aframe->format),
                        rate, 0, nullptr) < 0 || swr_init(resampler) < 0) {
                    audioError = "audio resampler initialization failed";
                    return;
                }
                resampleRate = rate;
                resampleFormat = aframe->format;
                resampleChannels = ch;
            }
            if (rate != resampleRate || aframe->format != resampleFormat ||
                ch != resampleChannels) {
                audioError = "unsupported mid-session audio format change";
                return;
            }
            if (audioPtsUs.load() == ddr_bitstream_ring::kNoTimestamp &&
                aframe->best_effort_timestamp != AV_NOPTS_VALUE)
                audioPtsUs.store(av_rescale_q(aframe->best_effort_timestamp,
                                              fmtTimebase(), AVRational{1, 1000000}));
            const int capacity = swr_get_out_samples(resampler, n);
            if (capacity <= 0 || capacity > 48000) {
                audioError = "audio resampler output bound";
                return;
            }
            std::vector<uint8_t> out(static_cast<size_t>(capacity) * 4);
            uint8_t* output = out.data();
            const int samples = swr_convert(resampler, &output, capacity,
                                            const_cast<const uint8_t**>(aframe->extended_data), n);
            if (samples < 0) { audioError = "audio resample failed"; return; }
            pushPcm48(out.data(), static_cast<size_t>(samples) * 4);
            return;
        }
        std::vector<float> stereo(static_cast<size_t>(n) * 2u, 0.f);
        const int fmt = aframe->format;
        auto sampleAt = [&](int c, int i) -> float {
            const int cc = c < ch ? c : 0;
            if (fmt == AV_SAMPLE_FMT_FLTP && aframe->data[cc])
                return reinterpret_cast<const float*>(aframe->data[cc])[i];
            if (fmt == AV_SAMPLE_FMT_FLT && aframe->data[0])
                return reinterpret_cast<const float*>(aframe->data[0])[i * ch + cc];
            if (fmt == AV_SAMPLE_FMT_S16P && aframe->data[cc])
                return static_cast<float>(
                           reinterpret_cast<const int16_t*>(aframe->data[cc])[i]) /
                       32768.f;
            if (fmt == AV_SAMPLE_FMT_S16 && aframe->data[0])
                return static_cast<float>(
                           reinterpret_cast<const int16_t*>(aframe->data[0])[i * ch + cc]) /
                       32768.f;
            return 0.f;
        };
        for (int i = 0; i < n; ++i) {
            stereo[static_cast<size_t>(i) * 2u] = sampleAt(0, i);
            stereo[static_cast<size_t>(i) * 2u + 1u] = ch > 1 ? sampleAt(1, i) : sampleAt(0, i);
        }
        const int n48 = rate == 48000 ? n : static_cast<int>((static_cast<int64_t>(n) * 48000) / rate);
        std::vector<uint8_t> out(static_cast<size_t>(n48) * 4u);
        for (int i = 0; i < n48; ++i) {
            int src = i;
            if (rate != 48000)
                src = static_cast<int>((static_cast<int64_t>(i) * n) / n48);
            if (src >= n)
                src = n - 1;
            const float l = stereo[static_cast<size_t>(src) * 2u];
            const float r = stereo[static_cast<size_t>(src) * 2u + 1u];
            const int16_t ls = s16sat(static_cast<int>(l * 32767.f));
            const int16_t rs = s16sat(static_cast<int>(r * 32767.f));
            out[static_cast<size_t>(i) * 4u] = static_cast<uint8_t>(ls & 0xff);
            out[static_cast<size_t>(i) * 4u + 1u] = static_cast<uint8_t>((ls >> 8) & 0xff);
            out[static_cast<size_t>(i) * 4u + 2u] = static_cast<uint8_t>(rs & 0xff);
            out[static_cast<size_t>(i) * 4u + 3u] = static_cast<uint8_t>((rs >> 8) & 0xff);
        }
        pushPcm48(out.data(), out.size());
    }

    void decodeAudioPacket() {
        if (!acodec || !aframe || !pkt)
            return;
        int ret = avcodec_send_packet(acodec, pkt);
        if (ret < 0 && ret != AVERROR(EAGAIN) && ret != AVERROR_EOF)
            return;
        for (;;) {
            ret = avcodec_receive_frame(acodec, aframe);
            if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF)
                break;
            if (ret < 0)
                break;
            ingestAudioFrame();
            av_frame_unref(aframe);
        }
    }

    AVRational fmtTimebase() const { return fmt->streams[aidx]->time_base; }

    std::string inputError(const char* context, int result) const {
        std::string error = std::string(context) + ": " + avErr(result);
        if (hls.enabled() && hls.error())
            error += std::string(" (finite HLS ") + hls.reason() + ")";
        return error;
    }

    int readInput(const std::atomic<int>& abort) {
        int result = av_read_frame(fmt, pkt);
        if (hls.enabled()) {
            if (result >= 0 && (pkt->flags & AV_PKT_FLAG_CORRUPT))
                hls.fail(AVERROR_INVALIDDATA, "corrupt-packet");
            if (hls.error())
                result = hls.error();
            else if (result == AVERROR_EOF) {
                const AVRational micros{1, 1000000};
                const bool spanSafe = hlsOriginPts != AV_NOPTS_VALUE &&
                    lastInputPts >= hlsOriginPts &&
                    (hlsOriginPts >= 0 || lastInputPts <= INT64_MAX + hlsOriginPts);
                const int64_t span = spanSafe ? lastInputPts - hlsOriginPts : 0;
                const bool timed = spanSafe && lastInputDuration > 0 &&
                    span <= INT64_MAX - lastInputDuration &&
                    inputTimebase.num > 0 && inputTimebase.den > 0;
                const auto duration = timed ? av_rescale_q(
                    span + lastInputDuration, inputTimebase, micros) : 0;
                const auto frame = timed ? av_rescale_q(lastInputDuration, inputTimebase, micros) : 0;
                const auto tick = timed ? av_rescale_q_rnd(1, inputTimebase, micros, AV_ROUND_UP) : 0;
                if (hls.verifyEof(duration, frame, tick) < 0)
                    result = hls.error();
            }
            if (result < 0) av_packet_unref(pkt);
        }
        inputReadCancelled = abort.load() || (options.cancelled && options.cancelled->load());
        inputReadResult = result;
        if (result >= 0 &&
            fmt->streams[pkt->stream_index]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
            ++inputVideoPackets;
            if (hls.enabled() && hlsOriginPts == AV_NOPTS_VALUE)
                hlsOriginPts = pkt->pts;
            lastInputPts = pkt->pts;
            lastInputDuration = pkt->duration;
            inputTimebase = fmt->streams[pkt->stream_index]->time_base;
        }
        return result;
    }

    void publishQueueDepth() {
        MPX_AV_TRACE(diagnosticReservedVideo.store(aheadPacket != nullptr, std::memory_order_relaxed);)
        diagnosticPackets.store(queuedPackets.size() + (aheadPacket ? 1 : 0));
        diagnosticBytes.store(queuedBytes + (aheadPacket ? size_t(aheadPacket->size) : 0));
        const auto video = std::find_if(queuedPackets.begin(), queuedPackets.end(),
            [&](const AVPacket* packet) { return packet->stream_index == vidx; });
        diagnosticNextPts.store(video != queuedPackets.end() ? (*video)->pts :
            aheadPacket ? aheadPacket->pts : ddr_bitstream_ring::kNoTimestamp);
    }

    bool decodeCompressedAudio(AVPacket* packet, std::string& err) {
        auto* audio = fmt->streams[aidx];
        if (!acodec) {
            const AVCodec* decoder = avcodec_find_decoder(audio->codecpar->codec_id);
            if (!decoder || decoder->type != AVMEDIA_TYPE_AUDIO ||
                !(acodec = avcodec_alloc_context3(decoder))) {
                err = "audio decoder unavailable";
                return false;
            }
            acodec->pkt_timebase = audio->time_base;
            if (avcodec_parameters_to_context(acodec, audio->codecpar) < 0 ||
                avcodec_open2(acodec, decoder, nullptr) < 0 ||
                !(aframe = av_frame_alloc())) {
                err = "audio decoder unavailable";
                return false;
            }
            arate = acodec->sample_rate;
        }
        const int sent = avcodec_send_packet(acodec, packet);
        if (sent < 0 && sent != AVERROR_EOF) {
            err = "audio packet rejected: " + avErr(sent);
            return false;
        }
        for (;;) {
            const int got = avcodec_receive_frame(acodec, aframe);
            if (got == AVERROR(EAGAIN) || got == AVERROR_EOF) break;
            if (got < 0) { err = "audio decode failed: " + avErr(got); return false; }
            ingestAudioFrame();
            av_frame_unref(aframe);
            if (!audioError.empty()) { err = audioError; return false; }
        }
        return true;
    }

    bool finishCompressedAudio(std::string& err) {
        if (audioFlushed) return true;
        if (acodec && !decodeCompressedAudio(nullptr, err)) return false;
        if (resampler) {
            uint8_t tail[4096];
            for (;;) {
                uint8_t* output = tail;
                const int samples = swr_convert(resampler, &output, sizeof(tail) / 4, nullptr, 0);
                if (samples < 0) { err = "audio resampler EOF drain failed"; return false; }
                if (!samples) break;
                pushPcm48(tail, size_t(samples) * 4);
                if (!audioError.empty()) { err = audioError; return false; }
            }
        }
        audioFlushed = true;
        std::lock_guard<std::mutex> lock(pcmMu);
        audioEof = true;
        MPX_AV_TRACE(diagnosticAudioEof.store(true, std::memory_order_relaxed);)
        pcmCv.notify_all();
        return true;
    }

    ~Impl() {
        if (resampler) swr_free(&resampler);
        if (aheadPacket) av_packet_free(&aheadPacket);
        for (auto* packet : queuedPackets) av_packet_free(&packet);
        if (bsf) av_bsf_free(&bsf);
        if (aframe)
            av_frame_free(&aframe);
        if (frame)
            av_frame_free(&frame);
        if (pkt)
            av_packet_free(&pkt);
        if (acodec)
            avcodec_free_context(&acodec);
        if (codec)
            avcodec_free_context(&codec);
        if (fmt)
            avformat_close_input(&fmt);
    }
};

int AvInprocDecoder::interruptThunk(void* p) {
    auto* d = static_cast<AvInprocDecoder*>(p);
    const bool timedOut = d && d->ioDeadlineMs_.load() > 0 &&
                          monotonicMs() > d->ioDeadlineMs_.load();
    if (timedOut && d->impl_ && d->impl_->hls.enabled())
        d->impl_->hls.fail(AVERROR(ETIMEDOUT), "deadline");
    if (d && d->impl_ && d->impl_->hls.enabled() &&
        (d->abort_.load(std::memory_order_relaxed) ||
         (d->cancelled_ && d->cancelled_->load())))
        d->impl_->hls.noteAbandon();
    return d && (d->abort_.load(std::memory_order_relaxed) ||
                 (d->cancelled_ && d->cancelled_->load()) ||
                 timedOut || (d->impl_ && d->impl_->hls.error()));
}

void AvInprocDecoder::requestStop() {
    abort_.store(1, std::memory_order_relaxed);
    if (!impl_)
        return;
    if (impl_->hls.enabled()) impl_->hls.noteAbandon();
    std::lock_guard<std::mutex> lk(impl_->pcmMu);
    impl_->stopping = true;
    impl_->blocked.store(AvDemuxBlocked::Cancelled);
    impl_->pcmCv.notify_all();
}

void AvInprocDecoder::close() {
    requestStop();
    delete impl_;
    impl_ = nullptr;
}

int AvInprocDecoder::width() const { return impl_ ? impl_->w : 0; }
int AvInprocDecoder::height() const { return impl_ ? impl_->h : 0; }
bool AvInprocDecoder::isOpen() const { return impl_ && impl_->open; }
bool AvInprocDecoder::hasAudio() const {
    if (!impl_) return false;
    std::lock_guard<std::mutex> lock(impl_->compressedMu);
    return impl_->aidx >= 0 && impl_->acodec;
}
bool AvInprocDecoder::audioEof() const {
    if (!impl_)
        return true;
    std::lock_guard<std::mutex> lk(impl_->pcmMu);
    return impl_->audioEof && impl_->pcm.empty();
}

int AvInprocDecoder::drainPcm(uint8_t* dst, size_t n, bool wait) {
    if (!impl_ || !dst || n == 0)
        return 0;
    std::unique_lock<std::mutex> lk(impl_->pcmMu);
    if (wait && impl_->pcm.empty() && !impl_->audioEof && !impl_->stopping && impl_->open)
        impl_->pcmCv.wait_for(lk, std::chrono::milliseconds(20),
                              [&] { return !impl_->pcm.empty() || impl_->audioEof ||
                                            impl_->stopping || !impl_->open; });
    const size_t take = std::min(n, impl_->pcm.size());
    if (take == 0)
        return 0;
    std::memcpy(dst, impl_->pcm.data(), take);
    impl_->pcm.erase(impl_->pcm.begin(),
                     impl_->pcm.begin() + static_cast<std::ptrdiff_t>(take));
    MPX_AV_TRACE(impl_->diagnosticPcmBytes.store(impl_->pcm.size(), std::memory_order_relaxed);)
    impl_->pcmCv.notify_all();
    return static_cast<int>(take);
}

const char* AvInprocDecoder::libavIdent() { return av_version_info(); }

SourceAspect AvInprocDecoder::sourceAspect() const {
    return impl_ ? impl_->aspect : SourceAspect{};
}

AvCompressedVideoGeometry AvInprocDecoder::videoGeometry() const {
    if (!impl_ || !impl_->compressed)
        return {};
    auto geometry = impl_->syntax.geometry;
    geometry.sourceAspect = impl_->aspect;
    return geometry;
}

int64_t AvInprocDecoder::firstAudioPtsUs() const {
    return impl_ ? impl_->audioPtsUs.load() : ddr_bitstream_ring::kNoTimestamp;
}

bool AvInprocDecoder::openCompressed(const std::string& url,
                                     const AvInprocOpenOpts& opts, std::string& err) {
    err.clear();
    abort_.store(0);
    av_log_set_level(AV_LOG_QUIET); // URL-bearing libav diagnostics must not expose Plex tokens.
    impl_ = new Impl();
    impl_->compressed = true;
    impl_->options = opts;
    if (url.empty() || opts.expectW <= 0 || opts.expectH <= 0 ||
        opts.maxAccessUnitBytes == 0 ||
        opts.maxAccessUnitBytes > ddr_bitstream_ring::kMaxAccessUnitBytes ||
        opts.maxVclRbspBytes == 0) {
        err = "invalid compressed session options";
        return false;
    }
    if ((opts.expectedFpsNum != 0 || opts.expectedFpsDen != 0) &&
        !((opts.expectedFpsNum == 24 && opts.expectedFpsDen == 1) ||
          (opts.expectedFpsNum == 24000 && opts.expectedFpsDen == 1001))) {
        err = "unsupported expected source frame rate";
        return false;
    }
    impl_->fmt = avformat_alloc_context();
    if (!impl_->fmt) { err = "format allocation failed"; return false; }
    impl_->fmt->interrupt_callback = {interruptThunk, this};
    // Stream probing may open a video decoder; it is not used in this backend.
    // Demuxers and their H.264 packet parser discover stream parameters instead.
    AVDictionary* options = nullptr;
    if (!opts.headers.empty())
        av_dict_set(&options, "headers", opts.headers.c_str(), 0);
    av_dict_set(&options, "rw_timeout", "5000000", 0);
    av_dict_set(&options, "probesize", "262144", 0);
    const bool finiteHls = opts.finiteHls || looksHlsPlaylist(url);
    const AVInputFormat* inputFormat = nullptr;
    if (finiteHls) {
        inputFormat = av_find_input_format("hls");
        if (!inputFormat) {
            av_dict_free(&options);
            err = "finite HLS requires the reviewed static-safe libav HLS demuxer";
            return false;
        }
        if (impl_->hls.attach(impl_->fmt, url) < 0) {
            av_dict_free(&options);
            err = "finite HLS requires a fixed LAN HTTP origin or local files";
            return false;
        }
        av_dict_set(&options, "protocol_whitelist", "file,http,tcp", 0);
        av_dict_set(&options, "format_whitelist", "hls,mpegts", 0);
        av_dict_set(&options, "live_start_index", "0", 0);
        av_dict_set(&options, "http_persistent", "0", 0);
        av_dict_set(&options, "http_multiple", "0", 0);
        av_dict_set(&options, "seg_max_retry", "0", 0);
        // Nested HLS probing may inspect audio; video remains parser-only.
        av_dict_set(&options, "codec_whitelist",
            "aac,aac_latm,ac3,eac3,mp3,mp3float,flac,alac,opus,vorbis,"
            "pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le", 0);
    } else {
        // Refuse unguarded HLS before its demuxer can open nested resources.
        av_dict_set(&options, "format_whitelist",
                    "mov,mp4,m4a,3gp,3g2,mj2,mpegts,h264,matroska,webm,mpeg,flv", 0);
    }
    ioDeadlineMs_.store(monotonicMs() + 5000);
    int opened = avformat_open_input(&impl_->fmt, url.c_str(), inputFormat, &options);
    if (impl_->hls.error()) opened = impl_->hls.error();
    av_dict_free(&options);
    if (opened < 0) { err = impl_->inputError("compressed input open", opened); return false; }
    if (!finiteHls && std::string(impl_->fmt->iformat->name) == "hls") {
        err = "extensionless HLS requires an explicit finite transport contract";
        return false;
    }
    impl_->pkt = av_packet_alloc();
    if (!impl_->pkt) { err = "packet allocation failed"; return false; }
    auto findStreams = [&] {
        for (unsigned i = 0; i < impl_->fmt->nb_streams; ++i) {
            auto* par = impl_->fmt->streams[i]->codecpar;
            if (impl_->vidx < 0 && par->codec_type == AVMEDIA_TYPE_VIDEO)
                impl_->vidx = static_cast<int>(i);
            if (impl_->aidx < 0 && par->codec_type == AVMEDIA_TYPE_AUDIO)
                impl_->aidx = static_cast<int>(i);
        }
    };
    findStreams();
    size_t probeBytes = 0;
    while (impl_->vidx < 0) {
        const int read = impl_->readInput(abort_);
        if (read < 0) { err = impl_->inputError("no compressed video stream", read); return false; }
        probeBytes += static_cast<size_t>(impl_->pkt->size);
        if (probeBytes > kCompressedPacketByteLimit ||
            impl_->queuedPackets.size() >= kCompressedPacketCountLimit) {
            err = "compressed stream discovery limit";
            return false;
        }
        AVPacket* saved = av_packet_clone(impl_->pkt);
        if (!saved) { err = "packet clone failed"; return false; }
        impl_->queuedPackets.push_back(saved);
        impl_->queuedBytes += size_t(saved->size);
        impl_->publishQueueDepth();
        av_packet_unref(impl_->pkt);
        findStreams();
    }
    auto* video = impl_->fmt->streams[impl_->vidx];
    if (video->codecpar->codec_id != AV_CODEC_ID_H264 ||
        video->time_base.num <= 0 || video->time_base.den <= 0) {
        err = "FPGA backend requires H.264 with rational container timestamps";
        return false;
    }
    const AVBitStreamFilter* filter = av_bsf_get_by_name("h264_mp4toannexb");
    int ret = filter ? av_bsf_alloc(filter, &impl_->bsf) : AVERROR(ENOSYS);
    if (ret >= 0)
        ret = avcodec_parameters_copy(impl_->bsf->par_in, video->codecpar);
    if (ret >= 0) {
        impl_->bsf->time_base_in = video->time_base;
        ret = av_bsf_init(impl_->bsf);
    }
    if (ret < 0) { err = "Annex-B bitstream filter: " + avErr(ret); return false; }
    if (opts.startMs > 0) {
        int64_t origin = video->start_time;
        size_t discovered = 0;
        while (origin == AV_NOPTS_VALUE) {
            ret = impl_->readInput(abort_);
            if (ret < 0) { err = impl_->inputError("seek origin unavailable", ret); return false; }
            discovered += static_cast<size_t>(impl_->pkt->size);
            if (impl_->pkt->stream_index == impl_->vidx)
                origin = impl_->pkt->pts;
            av_packet_unref(impl_->pkt);
            if (discovered > 2 * 1024 * 1024) {
                err = "bounded seek origin discovery exceeded";
                return false;
            }
        }
        const int64_t offset = av_rescale_q(opts.startMs, AVRational{1, 1000}, video->time_base);
        if (offset < 0 || origin > std::numeric_limits<int64_t>::max() - offset) {
            err = "compressed seek timestamp overflow";
            return false;
        }
        const int64_t ts = origin + offset;
        if (finiteHls) impl_->hlsOriginPts = origin;
        if (finiteHls) impl_->hls.beginSeek();
        ret = av_seek_frame(impl_->fmt, impl_->vidx, ts, AVSEEK_FLAG_BACKWARD);
        if (finiteHls) impl_->hls.endSeek();
        if (ret < 0) { err = "compressed seek: " + avErr(ret); return false; }
        impl_->seekTargetPts = ts;
        for (auto* packet : impl_->queuedPackets) av_packet_free(&packet);
        impl_->queuedPackets.clear();
        impl_->queuedBytes = 0;
        impl_->publishQueueDepth();
    }
    impl_->w = 0;
    impl_->h = 0;
    impl_->open = true;
    ioDeadlineMs_.store(0);
    return true;
}

#if MPX_FPGA_AV_TRACE
AvCompressedPressure AvInprocDecoder::compressedPressure() const noexcept {
    AvCompressedPressure result;
    if (!impl_) return result;
    result.available = true;
    result.queuedPackets = impl_->diagnosticPackets.load(std::memory_order_relaxed);
    result.queuedBytes = impl_->diagnosticBytes.load(std::memory_order_relaxed);
    result.pcmBytes = impl_->diagnosticPcmBytes.load(std::memory_order_relaxed);
    result.inputEof = impl_->inputEof.load(std::memory_order_relaxed);
    result.audioEof = impl_->diagnosticAudioEof.load(std::memory_order_relaxed);
    result.reservedVideo = impl_->diagnosticReservedVideo.load(std::memory_order_relaxed);
    result.blocked = impl_->blocked.load(std::memory_order_relaxed);
    return result;
}
#endif

AvCompressedDiagnostics AvInprocDecoder::compressedDiagnostics() const {
    AvCompressedDiagnostics result;
    if (!impl_) return result;
    result.available = true;
    result.sourceOpen = impl_->open;
    result.queuedPackets = impl_->diagnosticPackets.load();
    result.queuedBytes = impl_->diagnosticBytes.load();
    result.nextQueuedPts = impl_->diagnosticNextPts.load();
    result.inputEof = impl_->inputEof.load();
    result.blocked = impl_->blocked.load();
    result.cancelled = abort_.load() || (cancelled_ && cancelled_->load());
    // Never wait behind a demux producer blocked on the PCM consumer.
    std::unique_lock<std::mutex> demux(impl_->compressedMu, std::try_to_lock);
    result.detailsAvailable = demux.owns_lock();
    if (result.detailsAvailable) {
        result.inputReadResult = impl_->inputReadResult;
        result.inputReadCancelled = impl_->inputReadCancelled;
        if (impl_->fmt) {
            if (impl_->fmt->duration != AV_NOPTS_VALUE)
                result.containerDurationUs = impl_->fmt->duration;
            if (impl_->fmt->pb) {
                result.ioError = impl_->fmt->pb->error;
                result.ioEof = impl_->fmt->pb->eof_reached != 0;
                result.ioBytesRead = impl_->fmt->pb->bytes_read;
            }
        }
        if (impl_->hls.enabled()) {
            result.ioError = impl_->hls.transportError();
            result.ioEof = impl_->hls.transportEof();
            result.ioBytesRead = impl_->hls.mediaBytes();
            result.finiteHlsError = impl_->hls.error();
            result.finiteHlsVerified = impl_->hls.verified();
            result.finiteHlsErrorKind = impl_->hls.reason();
        }
        result.inputVideoPackets = impl_->inputVideoPackets;
        result.returnedAccessUnits = impl_->accessUnits;
        result.lastInputPts = impl_->lastInputPts;
        result.lastInputDuration = impl_->lastInputDuration;
        result.inputTimebaseNum = impl_->inputTimebase.num;
        result.inputTimebaseDen = impl_->inputTimebase.den;
        result.lastAuPts = impl_->previousPts;
        result.firstAuPts = impl_->firstPts;
        result.lastAuDuration = impl_->lastAuDuration;
        if (impl_->bsf) {
            result.auTimebaseNum = impl_->bsf->time_base_out.num;
            result.auTimebaseDen = impl_->bsf->time_base_out.den;
        }
        result.reservedVideo = impl_->aheadPacket != nullptr;
        for (const auto* packet : impl_->queuedPackets)
            if (packet->stream_index == impl_->vidx) ++result.queuedVideoPackets;
        result.error = impl_->compressedError;
    }
    std::lock_guard<std::mutex> lock(impl_->pcmMu);
    result.pcmBytes = impl_->pcm.size();
    result.audioEof = impl_->audioEof;
    return result;
}

std::string formatCompressedDiagnostics(const AvCompressedDiagnostics& state) {
    if (!state.available) return "demux=unavailable";
    std::ostringstream out;
    out << "source_open=" << state.sourceOpen << " input_eof=" << state.inputEof
        << " audio_eof=" << state.audioEof << " source_cancelled=" << state.cancelled
        << " queued_packets=" << state.queuedPackets << " queued_bytes=" << state.queuedBytes
        << " pcm_bytes=" << state.pcmBytes << " demux_blocked=" << unsigned(state.blocked);
    auto field = [&](const char* name, auto value, bool known) {
        out << ' ' << name << '=';
        if (known) out << value;
        else out << "unavailable";
    };
    const bool known = state.detailsAvailable;
    field("input_read_code", state.inputReadResult.value_or(0),
          known && state.inputReadResult.has_value());
    field("input_read_cancelled", state.inputReadCancelled,
          known && state.inputReadResult.has_value());
    field("io_error", state.ioError.value_or(0), known && state.ioError.has_value());
    field("io_eof", state.ioEof.value_or(false), known && state.ioEof.has_value());
    field("io_bytes_read", state.ioBytesRead.value_or(0), known && state.ioBytesRead.has_value());
    field("container_duration_us", state.containerDurationUs.value_or(0),
          known && state.containerDurationUs.has_value());
    out << " input_read_kind=" << (!known || !state.inputReadResult ? "unavailable" :
        *state.inputReadResult >= 0 ? "packet" :
        *state.inputReadResult == AVERROR_EOF ? "eof" :
        state.inputReadCancelled ? "cancelled" : "error");
    field("input_video_packets", state.inputVideoPackets, known);
    field("returned_aus", state.returnedAccessUnits, known);
    field("queued_next_video_pts", state.nextQueuedPts, state.nextQueuedPts != AV_NOPTS_VALUE);
    field("queued_video", state.queuedVideoPackets, known);
    field("reserved_video", state.reservedVideo, known);
    field("input_last_pts", state.lastInputPts,
          known && state.lastInputPts != AV_NOPTS_VALUE);
    field("input_last_duration", state.lastInputDuration, known && state.lastInputDuration > 0);
    field("input_tb_num", state.inputTimebaseNum, known && state.inputTimebaseNum > 0);
    field("input_tb_den", state.inputTimebaseDen, known && state.inputTimebaseDen > 0);
    field("au_last_pts", state.lastAuPts, known && state.lastAuPts != AV_NOPTS_VALUE);
    field("au_first_pts", state.firstAuPts, known && state.firstAuPts != AV_NOPTS_VALUE);
    field("au_last_duration", state.lastAuDuration, known && state.lastAuDuration > 0);
    field("au_tb_num", state.auTimebaseNum, known && state.auTimebaseNum > 0);
    field("au_tb_den", state.auTimebaseDen, known && state.auTimebaseDen > 0);
    field("demux_error_present", !state.error.empty(), known);
    out << " demux_error=" << (known ? fpgaTerminalText(redactSensitive(state.error)) :
                                       "unavailable");
    if (state.finiteHlsError) {
        field("finite_hls_error", *state.finiteHlsError, known);
        field("finite_hls_verified", state.finiteHlsVerified.value_or(false), known);
        out << " finite_hls_error_kind=" << state.finiteHlsErrorKind;
    }
    return out.str();
}

AvAudioProgress AvInprocDecoder::advanceCompressedAudio(std::string& err) {
    err.clear();
    if (!impl_ || !impl_->open || !impl_->compressed || !impl_->options.decodeAudio) {
        err = "compressed audio progress requires an open audio-enabled session";
        return AvAudioProgress::Error;
    }
    if (abort_.load() || (cancelled_ && cancelled_->load()))
        return AvAudioProgress::Cancelled;
    if (impl_->options.paused && impl_->options.paused->load())
        return AvAudioProgress::Paused;
    // A video reader can be blocked supplying PCM. Never wait for its demux
    // lock here: release this call so the existing PCM consumer can drain it.
    std::unique_lock<std::mutex> lock(impl_->compressedMu, std::try_to_lock);
    if (!lock.owns_lock()) return AvAudioProgress::Pending;
    auto fail = [&](const std::string& message) {
        err = message;
        impl_->compressedError = message;
        impl_->blocked.store(AvDemuxBlocked::Error);
        ioDeadlineMs_.store(0);
        return AvAudioProgress::Error;
    };
    if (!impl_->compressedError.empty()) return fail(impl_->compressedError);
    auto pcmState = [&] {
        std::lock_guard<std::mutex> pcm(impl_->pcmMu);
        return !impl_->pcm.empty() ? AvAudioProgress::Ready :
            impl_->audioEof ? AvAudioProgress::Eof : AvAudioProgress::Pending;
    };
    if (pcmState() != AvAudioProgress::Pending) return pcmState();
    auto full = [&] {
        impl_->blocked.store(AvDemuxBlocked::VideoQueue);
        return AvAudioProgress::Backpressure;
    };
    const size_t regularByteLimit =
        kCompressedPacketByteLimit - impl_->options.maxAccessUnitBytes;
    if (impl_->aheadPacket) {
        if (impl_->queuedPackets.size() >= kCompressedPacketCountLimit - 1 ||
            impl_->queuedBytes + size_t(impl_->aheadPacket->size) > regularByteLimit)
            return full();
        impl_->queuedPackets.push_back(impl_->aheadPacket);
        impl_->queuedBytes += size_t(impl_->aheadPacket->size);
        impl_->aheadPacket = nullptr;
        impl_->publishQueueDepth();
        impl_->blocked.store(AvDemuxBlocked::Idle);
        return AvAudioProgress::Pending;
    }
    // Reserve one packet so audio immediately after a full regular video queue
    // can still be decoded. A video packet in that slot is retained, never dropped.
    auto savedAudio = std::find_if(impl_->queuedPackets.begin(), impl_->queuedPackets.end(),
        [&](const AVPacket* packet) {
            return impl_->fmt->streams[packet->stream_index]->codecpar->codec_type ==
                   AVMEDIA_TYPE_AUDIO;
        });
    int read = 0;
    if (savedAudio != impl_->queuedPackets.end()) {
        AVPacket* packet = *savedAudio;
        impl_->queuedBytes -= size_t(packet->size);
        impl_->queuedPackets.erase(savedAudio);
        av_packet_move_ref(impl_->pkt, packet);
        av_packet_free(&packet);
        impl_->publishQueueDepth();
    } else if (impl_->inputEof.load()) {
        read = AVERROR_EOF;
    } else {
        if (impl_->queuedPackets.size() >= kCompressedPacketCountLimit ||
            impl_->queuedBytes > regularByteLimit)
            return full();
        impl_->blocked.store(AvDemuxBlocked::Input);
        ioDeadlineMs_.store(monotonicMs() + 5000);
        read = impl_->readInput(abort_);
        ioDeadlineMs_.store(0);
    }
    if (abort_.load() || (cancelled_ && cancelled_->load()))
        return AvAudioProgress::Cancelled;
    if (read == AVERROR_EOF) {
        impl_->inputEof.store(true);
        if (!impl_->finishCompressedAudio(err)) return fail(err);
        impl_->blocked.store(AvDemuxBlocked::Eof);
        return pcmState();
    }
    if (read < 0) return fail(impl_->inputError("compressed audio demux", read));
    if (impl_->pkt->stream_index == impl_->vidx) {
        if (impl_->pkt->size <= 0 ||
            size_t(impl_->pkt->size) > impl_->options.maxAccessUnitBytes)
            return fail("access unit exceeds negotiated bounded ring capacity");
        AVPacket* packet = av_packet_clone(impl_->pkt);
        if (!packet) return fail("compressed read-ahead packet allocation failed");
        if (impl_->queuedPackets.size() < kCompressedPacketCountLimit - 1 &&
            impl_->queuedBytes + size_t(packet->size) <= regularByteLimit) {
            try {
                impl_->queuedPackets.push_back(packet);
            } catch (...) {
                av_packet_free(&packet);
                throw;
            }
            impl_->queuedBytes += size_t(packet->size);
        } else {
            impl_->aheadPacket = packet;
        }
        impl_->publishQueueDepth();
    } else {
        auto* stream = impl_->fmt->streams[impl_->pkt->stream_index];
        if (stream->codecpar->codec_type == AVMEDIA_TYPE_AUDIO &&
            (impl_->aidx < 0 || impl_->aidx == impl_->pkt->stream_index)) {
            impl_->aidx = impl_->pkt->stream_index;
            if (!impl_->decodeCompressedAudio(impl_->pkt, err)) return fail(err);
        }
    }
    av_packet_unref(impl_->pkt);
    impl_->blocked.store(AvDemuxBlocked::Idle);
    return pcmState();
}

int AvInprocDecoder::readAccessUnit(AvCompressedAccessUnit& au, std::string& err) {
    err.clear();
    au = {};
    if (!impl_ || !impl_->open || !impl_->compressed || !impl_->bsf) {
        err = "compressed session is not open";
        return -1;
    }
    std::lock_guard<std::mutex> compressed(impl_->compressedMu);
    auto fail = [&](const std::string& message) {
        err = message;
        impl_->compressedError = message;
        impl_->blocked.store(AvDemuxBlocked::Error);
        ioDeadlineMs_.store(0);
        return -1;
    };
    if (!impl_->compressedError.empty()) return fail(impl_->compressedError);
    for (;;) {
        if (interruptThunk(this)) return fail("compressed session cancelled or timed out");
        int ret = av_bsf_receive_packet(impl_->bsf, impl_->pkt);
        if (ret >= 0) {
            if (impl_->pkt->size <= 0 ||
                static_cast<size_t>(impl_->pkt->size) > impl_->options.maxAccessUnitBytes)
                return fail("access unit exceeds negotiated bounded ring capacity");
            if (impl_->pkt->pts == AV_NOPTS_VALUE)
                return fail("access unit has no original PTS (no fabricated frame-rate clock)");
            if (!impl_->seekChecked && impl_->seekTargetPts != AV_NOPTS_VALUE &&
                impl_->pkt->pts < impl_->seekTargetPts)
                return fail("non-IDR direct seek requires FPGA preroll; use the PMS offset transcode");
            impl_->seekChecked = true;
            bool key = false, changed = false;
            if (!impl_->syntax.inspect(impl_->pkt->data, impl_->pkt->size,
                                      impl_->options, key, changed, err))
                return fail(err);
            impl_->w = impl_->syntax.geometry.codedWidth;
            impl_->h = impl_->syntax.geometry.codedHeight;
            au.annexb.assign(impl_->pkt->data, impl_->pkt->data + impl_->pkt->size);
            au.pts = impl_->pkt->pts;
            au.duration = std::max<int64_t>(0, impl_->pkt->duration);
            au.timebaseNum = impl_->bsf->time_base_out.num;
            au.timebaseDen = impl_->bsf->time_base_out.den;
            if (impl_->bsf->time_base_out.num <= 0 || impl_->bsf->time_base_out.den <= 0)
                return fail("invalid original stream timebase");
            const long double ptsUs = static_cast<long double>(au.pts) *
                                      au.timebaseNum * 1000000 / au.timebaseDen;
            if (std::fabs(ptsUs) > std::numeric_limits<int64_t>::max() / 4)
                return fail("original timestamp is outside the bounded session clock");
            au.keyframe = key;
            au.parameterSetsChanged = changed;
            if (impl_->previousPts != ddr_bitstream_ring::kNoTimestamp) {
                const long double delta = static_cast<long double>(au.pts) - impl_->previousPts;
                const long double ticks = delta * au.timebaseNum;
                const bool film24 = std::fabs(ticks * 24 - au.timebaseDen) <=
                                    static_cast<long double>(au.timebaseNum) * 24;
                const bool film23976 = std::fabs(ticks * 24000 -
                                               static_cast<long double>(au.timebaseDen) * 1001) <=
                                       static_cast<long double>(au.timebaseNum) * 24000;
                if (delta <= 0 || (!film24 && !film23976))
                    return fail("unsupported PTS cadence/discontinuity: requires actual 24 or 24000/1001");
            }
            if (impl_->firstPts == ddr_bitstream_ring::kNoTimestamp)
                impl_->firstPts = au.pts;
            if (impl_->options.expectedFpsNum > 0 && impl_->accessUnits > 0) {
                const long double elapsed =
                    (static_cast<long double>(au.pts) - impl_->firstPts) * au.timebaseNum;
                const long double requested =
                    static_cast<long double>(impl_->accessUnits) *
                    impl_->options.expectedFpsDen * au.timebaseDen;
                const long double oneTick =
                    static_cast<long double>(au.timebaseNum) * impl_->options.expectedFpsNum;
                if (std::fabs(elapsed * impl_->options.expectedFpsNum - requested) > oneTick)
                    return fail("delivered PTS do not match the requested source frame rate");
            }
            if (impl_->accessUnits == std::numeric_limits<uint64_t>::max())
                return fail("access-unit clock counter exhausted");
            ++impl_->accessUnits;
            impl_->previousPts = au.pts;
            impl_->lastAuDuration = au.duration;
            auto* stream = impl_->fmt->streams[impl_->vidx];
            AVRational sar = stream->sample_aspect_ratio;
            if (sar.num <= 0 || sar.den <= 0) sar = stream->codecpar->sample_aspect_ratio;
            if (impl_->syntax.aspect.valid) {
                impl_->aspect = impl_->syntax.aspect;
            } else if (sar.num > 0 && sar.den > 0) {
                int num = 0, den = 0;
                av_reduce(&num, &den, int64_t(impl_->syntax.width) * sar.num,
                          int64_t(impl_->syntax.height) * sar.den, 65535);
                impl_->aspect = {static_cast<uint16_t>(num), static_cast<uint16_t>(den),
                                  num > 0 && den > 0};
            } else {
                impl_->aspect = {};
            }
            au.geometry = videoGeometry();
            av_packet_unref(impl_->pkt);
            ioDeadlineMs_.store(0);
            impl_->blocked.store(AvDemuxBlocked::Idle);
            return 1;
        }
        if (ret == AVERROR_EOF) {
            if (!impl_->finishCompressedAudio(err)) return fail(err);
            ioDeadlineMs_.store(0);
            impl_->blocked.store(AvDemuxBlocked::Eof);
            return 0;
        }
        if (ret != AVERROR(EAGAIN)) return fail("Annex-B receive: " + avErr(ret));
        if (!impl_->queuedPackets.empty()) {
            AVPacket* packet = impl_->queuedPackets.front();
            impl_->queuedPackets.pop_front();
            impl_->queuedBytes -= size_t(packet->size);
            av_packet_move_ref(impl_->pkt, packet);
            av_packet_free(&packet);
            impl_->publishQueueDepth();
            ret = 0;
        } else if (impl_->aheadPacket) {
            av_packet_move_ref(impl_->pkt, impl_->aheadPacket);
            av_packet_free(&impl_->aheadPacket);
            impl_->publishQueueDepth();
            ret = 0;
        } else if (impl_->inputEof.load()) {
            ret = AVERROR_EOF;
        } else {
            impl_->blocked.store(AvDemuxBlocked::Input);
            ioDeadlineMs_.store(monotonicMs() + 5000);
            ret = impl_->readInput(abort_);
            ioDeadlineMs_.store(0);
        }
        if (ret == AVERROR_EOF) {
            impl_->inputEof.store(true);
            if (impl_->bsfFlushed) return fail("bitstream filter stalled after EOF");
            impl_->bsfFlushed = true;
            ret = av_bsf_send_packet(impl_->bsf, nullptr);
            if (ret < 0) return fail("Annex-B EOF drain: " + avErr(ret));
            continue;
        }
        if (ret < 0) return fail(impl_->inputError("compressed demux", ret));
        if (impl_->pkt->stream_index == impl_->vidx) {
            ret = av_bsf_send_packet(impl_->bsf, impl_->pkt);
            if (ret < 0) return fail("Annex-B packet rejected: " + avErr(ret));
        } else {
            auto* stream = impl_->fmt->streams[impl_->pkt->stream_index];
            if (impl_->options.decodeAudio &&
                stream->codecpar->codec_type == AVMEDIA_TYPE_AUDIO &&
                (impl_->aidx < 0 || impl_->aidx == impl_->pkt->stream_index)) {
                impl_->aidx = impl_->pkt->stream_index;
                if (!impl_->decodeCompressedAudio(impl_->pkt, err)) return fail(err);
            }
            av_packet_unref(impl_->pkt);
        }
    }
}

bool AvInprocDecoder::open(const std::string& pathOrUrl, const AvInprocOpenOpts& o,
                           std::string& err) {
    close();
    cancelled_ = o.cancelled;
    ioDeadlineMs_.store(0);
    if (o.compressedVideo)
        return openCompressed(pathOrUrl, o, err);
    err.clear();
    if (pathOrUrl.empty()) {
        err = "empty path";
        return false;
    }
    // Static ARM binary cannot call getaddrinfo (glibc NSS abort). Remote
    // HTTP is remuxed to a fifo. Numeric loopback does not need NSS.
    const bool loopbackHttp =
        pathOrUrl.compare(0, 16, "http://127.0.0.1") == 0 ||
        pathOrUrl.compare(0, 16, "HTTP://127.0.0.1") == 0;
    if (looksNetworkUrl(pathOrUrl) && !loopbackHttp) {
        err = "network protocols disabled prefix=" + pathOrUrl.substr(0, 24);
        return false;
    }
    if (o.expectW <= 0 || o.expectH <= 0 || (o.expectW & 1) || (o.expectH & 1)) {
        err = "expect WxH must be positive even";
        return false;
    }
    const int outW = o.outW > 0 ? o.outW : o.expectW;
    const int outH = o.outH > 0 ? o.outH : o.expectH;
    if (outW <= 0 || outH <= 0 || (outW & 1) || (outH & 1)) {
        err = "out WxH must be positive even";
        return false;
    }

    abort_.store(0, std::memory_order_relaxed);
    impl_ = new Impl();
    av_log_set_level(AV_LOG_ERROR);

    AVDictionary* opts = nullptr;
    if (!o.headers.empty()) {
        std::string h = o.headers;
        if (h.size() < 2 || h.back() != '\n')
            h += "\r\n";
        av_dict_set(&opts, "headers", h.c_str(), 0);
    }
    const AVInputFormat* ifmt = nullptr;
    if (o.liveFifo) {
        ifmt = av_find_input_format("h264");
        // 2 MiB probe on a slow live HEVC remux filled the 1 MiB PCM fifo
        // (nobody pumping yet) and deadlocked annex-B. 128 KiB is one IDR.
        av_dict_set(&opts, "probesize", "131072", 0);
        av_dict_set(&opts, "analyzeduration", "0", 0);
    } else {
        av_dict_set(&opts, "fflags", "nobuffer", 0);
        av_dict_set(&opts, "probesize", "32768", 0);
        av_dict_set(&opts, "analyzeduration", "0", 0);
    }
    impl_->fmt = avformat_alloc_context();
    if (!impl_->fmt) {
        av_dict_free(&opts);
        err = "avformat_alloc_context failed";
        close();
        return false;
    }
    impl_->fmt->interrupt_callback.callback = interruptThunk;
    impl_->fmt->interrupt_callback.opaque = this;
    int ret = avformat_open_input(&impl_->fmt, pathOrUrl.c_str(), ifmt, &opts);
    av_dict_free(&opts);
    if (ret < 0) {
        err = "avformat_open_input: " + avErr(ret);
        close();
        return false;
    }
    ret = avformat_find_stream_info(impl_->fmt, nullptr);
    if (ret < 0) {
        err = "avformat_find_stream_info: " + avErr(ret);
        close();
        return false;
    }

    impl_->vidx = -1;
    impl_->aidx = -1;
    for (unsigned i = 0; i < impl_->fmt->nb_streams; ++i) {
        const AVCodecParameters* par = impl_->fmt->streams[i]->codecpar;
        if (!par)
            continue;
        if (impl_->vidx < 0 && par->codec_type == AVMEDIA_TYPE_VIDEO)
            impl_->vidx = static_cast<int>(i);
        if (impl_->aidx < 0 && par->codec_type == AVMEDIA_TYPE_AUDIO)
            impl_->aidx = static_cast<int>(i);
    }
    if (impl_->vidx < 0) {
        err = "no video stream";
        close();
        return false;
    }

    AVStream* st = impl_->fmt->streams[impl_->vidx];
    const AVCodecParameters* par = st->codecpar;
    const int sw = par->width;
    const int sh = par->height;
    // Bank is out WxH. Source may be 240/480 while the live L4 bank is 1280×720.
    if (sw != 0 || sh != 0) {
        if (sw <= 0 || sh <= 0 || (sw & 1) || (sh & 1)) {
            err = "source WxH must be positive even";
            close();
            return false;
        }
    }
    if (par->format != AV_PIX_FMT_NONE && par->format != AV_PIX_FMT_YUV420P) {
        err = "pixfmt not YUV420P";
        close();
        return false;
    }

    const AVCodec* dec = avcodec_find_decoder(par->codec_id);
    if (!dec) {
        err = "no decoder for codec_id";
        close();
        return false;
    }
    impl_->codec = avcodec_alloc_context3(dec);
    if (!impl_->codec) {
        err = "avcodec_alloc_context3 failed";
        close();
        return false;
    }
    ret = avcodec_parameters_to_context(impl_->codec, par);
    if (ret < 0) {
        err = "avcodec_parameters_to_context: " + avErr(ret);
        close();
        return false;
    }
    impl_->codec->thread_count = o.threads > 0 ? o.threads : 2;
#ifdef FF_THREAD_FRAME
    impl_->codec->thread_type = FF_THREAD_FRAME;
#endif
    // Match ffmpeg -skip_loop_filter all on the identity 720p pipe (2–4 ms/f
    // deblock was the 21.8 unique lock). Inproc had no equivalent.
#ifdef AVDISCARD_ALL
    if (inprocSkipLoopFilter720p(outW, outH))
        impl_->codec->skip_loop_filter = AVDISCARD_ALL;
#endif
    ret = avcodec_open2(impl_->codec, dec, nullptr);
    if (ret < 0) {
        err = "avcodec_open2: " + avErr(ret);
        close();
        return false;
    }
    if (impl_->codec->pix_fmt != AV_PIX_FMT_NONE &&
        impl_->codec->pix_fmt != AV_PIX_FMT_YUV420P) {
        err = "decoder pixfmt not YUV420P";
        close();
        return false;
    }

    impl_->frame = av_frame_alloc();
    impl_->pkt = av_packet_alloc();
    if (!impl_->frame || !impl_->pkt) {
        err = "av_frame/av_packet alloc failed";
        close();
        return false;
    }
    if (impl_->aidx >= 0) {
        AVStream* ast = impl_->fmt->streams[impl_->aidx];
        const AVCodecParameters* apar = ast->codecpar;
        const AVCodec* adec = avcodec_find_decoder(apar->codec_id);
        if (adec) {
            impl_->acodec = avcodec_alloc_context3(adec);
            if (impl_->acodec && avcodec_parameters_to_context(impl_->acodec, apar) >= 0 &&
                avcodec_open2(impl_->acodec, adec, nullptr) >= 0) {
                impl_->aframe = av_frame_alloc();
                impl_->arate = impl_->acodec->sample_rate;
                if (impl_->arate <= 0)
                    impl_->arate = 48000;
            } else {
                if (impl_->acodec)
                    avcodec_free_context(&impl_->acodec);
                impl_->aidx = -1;
            }
        } else {
            impl_->aidx = -1;
        }
        if (!impl_->aframe)
            impl_->aidx = -1;
    }

    if (o.startMs > 0) {
        struct stat stbuf {};
        const bool fifo =
            ::stat(pathOrUrl.c_str(), &stbuf) == 0 && S_ISFIFO(stbuf.st_mode);
        // HTTP universal already has offset=; a second av_seek_frame on
        // loopback mpegts added seconds of A/V hole.
        if (!fifo && !loopbackHttp) {
            const int64_t ts =
                av_rescale_q(o.startMs, AVRational{1, 1000}, st->time_base);
            ret = av_seek_frame(impl_->fmt, impl_->vidx, ts, AVSEEK_FLAG_BACKWARD);
            if (ret < 0) {
                err = "av_seek_frame: " + avErr(ret);
                close();
                return false;
            }
            avcodec_flush_buffers(impl_->codec);
        }
    }

    int srcW = 0;
    int srcH = 0;
    if (sw > 0 && sh > 0) {
        srcW = sw;
        srcH = sh;
    } else {
        const int dw = impl_->codec->width;
        const int dh = impl_->codec->height;
        if (dw > 0 && dh > 0) {
            if ((dw & 1) || (dh & 1)) {
                err = "source WxH must be positive even";
                close();
                return false;
            }
            srcW = dw;
            srcH = dh;
        }
    }
    impl_->srcW = srcW;
    impl_->srcH = srcH;
    impl_->w = outW;
    impl_->h = outH;
    impl_->open = true;
    impl_->flushing = false;
    impl_->pending = false;

    // Fail-closed: first frame must be YUV420P. Bank is out WxH; source may scale.
    std::string rerr;
    const int first = readI420(nullptr, 0, rerr);
    if (first != 1) {
        err = first == 0 ? "no video frames" : rerr;
        close();
        return false;
    }
    return true;
}

int AvInprocDecoder::readI420(uint8_t* dst, size_t frameBytes, std::string& err) {
    err.clear();
    if (!impl_ || !impl_->open || !impl_->codec || !impl_->fmt) {
        err = "decoder not open";
        return -1;
    }
    const int w = impl_->w;
    const int h = impl_->h;
    const size_t need = static_cast<size_t>(w) * static_cast<size_t>(h) * 3 / 2;
    // dst==null / frameBytes==0 is the open() probe: decode+stash, no copy.
    const bool probe = (dst == nullptr && frameBytes == 0);
    if (!probe && (!dst || frameBytes != need)) {
        err = "frameBytes want " + std::to_string(need);
        return -1;
    }

    auto accept = [&]() -> int {
        if (impl_->frame->format != AV_PIX_FMT_YUV420P) {
            err = "frame pixfmt not YUV420P";
            av_frame_unref(impl_->frame);
            impl_->pending = false;
            return -1;
        }
        if (impl_->srcW == 0 || impl_->srcH == 0) {
            const int fw = impl_->frame->width;
            const int fh = impl_->frame->height;
            if (fw <= 0 || fh <= 0 || (fw & 1) || (fh & 1)) {
                err = "frame size must be positive even";
                av_frame_unref(impl_->frame);
                impl_->pending = false;
                return -1;
            }
            impl_->srcW = fw;
            impl_->srcH = fh;
        }
        const int srcW = impl_->srcW;
        const int srcH = impl_->srcH;
        if (impl_->frame->width != srcW || impl_->frame->height != srcH) {
            err = "frame size " + std::to_string(impl_->frame->width) + "x" +
                  std::to_string(impl_->frame->height) + " != src " +
                  std::to_string(srcW) + "x" + std::to_string(srcH);
            av_frame_unref(impl_->frame);
            impl_->pending = false;
            return -1;
        }
        if (probe) {
            impl_->pending = true;
            return 1;
        }
        bool packed = false;
        if (w == srcW && h == srcH) {
            packed = copyPackedI420(impl_->frame, dst, w, h, err);
        } else if (inprocScale1280to960(srcW, srcH, w, h)) {
            packed = downsampleI420_1280_to_960_planes(
                impl_->frame->data[0], impl_->frame->linesize[0],
                impl_->frame->data[1], impl_->frame->linesize[1],
                impl_->frame->data[2], impl_->frame->linesize[2], dst, need);
            if (!packed)
                err = "I420 4/3 downsample failed";
        } else {
            packed = scaleI420NearestPlanes(
                impl_->frame->data[0], impl_->frame->linesize[0],
                impl_->frame->data[1], impl_->frame->linesize[1],
                impl_->frame->data[2], impl_->frame->linesize[2], srcW, srcH,
                dst, w, h, need);
            if (!packed)
                err = "I420 nearest scale failed";
        }
        if (!packed) {
            av_frame_unref(impl_->frame);
            impl_->pending = false;
            return -1;
        }
        av_frame_unref(impl_->frame);
        impl_->pending = false;
        return 1;
    };

    if (impl_->pending) {
        return accept();
    }

    int invalidSkip = 0;
    for (;;) {
        int ret = avcodec_receive_frame(impl_->codec, impl_->frame);
        if (ret == 0)
            return accept();
        if (ret == AVERROR_EOF)
            return 0;
        if (ret != AVERROR(EAGAIN)) {
            err = "avcodec_receive_frame: " + avErr(ret);
            return -1;
        }
        if (impl_->flushing)
            return 0;

        ret = av_read_frame(impl_->fmt, impl_->pkt);
        if (ret == AVERROR_EOF) {
            impl_->flushing = true;
            if (impl_->acodec && impl_->aframe) {
                (void)avcodec_send_packet(impl_->acodec, nullptr);
                for (;;) {
                    const int ar = avcodec_receive_frame(impl_->acodec, impl_->aframe);
                    if (ar < 0)
                        break;
                    impl_->ingestAudioFrame();
                    av_frame_unref(impl_->aframe);
                }
            }
            {
                std::lock_guard<std::mutex> lk(impl_->pcmMu);
                impl_->audioEof = true;
                MPX_AV_TRACE(impl_->diagnosticAudioEof.store(true, std::memory_order_relaxed);)
                impl_->pcmCv.notify_all();
            }
            ret = avcodec_send_packet(impl_->codec, nullptr);
            if (ret < 0 && ret != AVERROR_EOF && ret != AVERROR(EAGAIN)) {
                err = "avcodec_send_packet(flush): " + avErr(ret);
                return -1;
            }
            continue;
        }
        if (ret < 0) {
            err = "av_read_frame: " + avErr(ret);
            return -1;
        }
        if (impl_->aidx >= 0 && impl_->pkt->stream_index == impl_->aidx) {
            impl_->decodeAudioPacket();
            av_packet_unref(impl_->pkt);
            continue;
        }
        if (impl_->pkt->stream_index != impl_->vidx) {
            av_packet_unref(impl_->pkt);
            continue;
        }
        ret = avcodec_send_packet(impl_->codec, impl_->pkt);
        av_packet_unref(impl_->pkt);
        if (ret < 0 && ret != AVERROR(EAGAIN)) {
            if (probe && ret == AVERROR_INVALIDDATA && invalidSkip < 24) {
                ++invalidSkip;
                continue;
            }
            err = "avcodec_send_packet: " + avErr(ret);
            return -1;
        }
    }
}

} // namespace misterplex
