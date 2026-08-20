#ifndef MPX_HAVE_LIBAV
#error "av_inproc_decode.cpp requires -DMPX_HAVE_LIBAV"
#endif

#include "libmisterplex/av_inproc_decode.hpp"

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <sys/stat.h>
#include <vector>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/dict.h>
#include <libavutil/error.h>
#include <libavutil/mathematics.h>
#include <libavutil/pixfmt.h>
#include <libavutil/rational.h>
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
    AVCodecContext* codec = nullptr;
    AVCodecContext* acodec = nullptr;
    AVFrame* frame = nullptr;
    AVFrame* aframe = nullptr;
    AVPacket* pkt = nullptr;
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
    std::mutex pcmMu;
    std::condition_variable pcmCv;
    std::vector<uint8_t> pcm;

    void pushPcm48(const uint8_t* p, size_t n) {
        if (!p || n == 0)
            return;
        std::lock_guard<std::mutex> lk(pcmMu);
        pcm.insert(pcm.end(), p, p + n);
        constexpr size_t kCap = 48000u * 4u * 4u;
        if (pcm.size() > kCap)
            pcm.erase(pcm.begin(), pcm.begin() + static_cast<std::ptrdiff_t>(pcm.size() - kCap));
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

    ~Impl() {
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
    return (d && d->abort_.load(std::memory_order_relaxed)) ? 1 : 0;
}

void AvInprocDecoder::requestStop() {
    abort_.store(1, std::memory_order_relaxed);
    if (!impl_)
        return;
    std::lock_guard<std::mutex> lk(impl_->pcmMu);
    impl_->audioEof = true;
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
bool AvInprocDecoder::hasAudio() const { return impl_ && impl_->aidx >= 0 && impl_->acodec; }
bool AvInprocDecoder::audioEof() const {
    if (!impl_)
        return true;
    std::lock_guard<std::mutex> lk(impl_->pcmMu);
    return impl_->audioEof && impl_->pcm.empty();
}

int AvInprocDecoder::drainPcm(uint8_t* dst, size_t n) {
    if (!impl_ || !dst || n == 0)
        return 0;
    std::unique_lock<std::mutex> lk(impl_->pcmMu);
    if (impl_->pcm.empty() && !impl_->audioEof && impl_->open)
        impl_->pcmCv.wait_for(lk, std::chrono::milliseconds(20),
                              [&] { return !impl_->pcm.empty() || impl_->audioEof || !impl_->open; });
    const size_t take = std::min(n, impl_->pcm.size());
    if (take == 0)
        return 0;
    std::memcpy(dst, impl_->pcm.data(), take);
    impl_->pcm.erase(impl_->pcm.begin(),
                     impl_->pcm.begin() + static_cast<std::ptrdiff_t>(take));
    return static_cast<int>(take);
}

const char* AvInprocDecoder::libavIdent() { return av_version_info(); }

bool AvInprocDecoder::open(const std::string& pathOrUrl, const AvInprocOpenOpts& o,
                           std::string& err) {
    close();
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
