#ifndef MPX_HAVE_LIBAV
#error "av_inproc_decode.cpp requires -DMPX_HAVE_LIBAV"
#endif

#include "libmisterplex/av_inproc_decode.hpp"

#include <cerrno>
#include <cstring>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
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

struct AvInprocDecoder::Impl {
    AVFormatContext* fmt = nullptr;
    AVCodecContext* codec = nullptr;
    AVFrame* frame = nullptr;
    AVPacket* pkt = nullptr;
    int vidx = -1;
    int w = 0;
    int h = 0;
    int srcW = 0;
    int srcH = 0;
    bool open = false;
    bool flushing = false;
    bool pending = false;

    ~Impl() {
        if (frame)
            av_frame_free(&frame);
        if (pkt)
            av_packet_free(&pkt);
        if (codec)
            avcodec_free_context(&codec);
        if (fmt)
            avformat_close_input(&fmt);
    }
};

void AvInprocDecoder::close() {
    delete impl_;
    impl_ = nullptr;
}

int AvInprocDecoder::width() const { return impl_ ? impl_->w : 0; }
int AvInprocDecoder::height() const { return impl_ ? impl_->h : 0; }
bool AvInprocDecoder::isOpen() const { return impl_ && impl_->open; }

const char* AvInprocDecoder::libavIdent() { return av_version_info(); }

bool AvInprocDecoder::open(const std::string& pathOrUrl, const AvInprocOpenOpts& o,
                           std::string& err) {
    close();
    err.clear();
    if (pathOrUrl.empty()) {
        err = "empty path";
        return false;
    }
    if (looksNetworkUrl(pathOrUrl)) {
        err = "network protocols disabled";
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

    impl_ = new Impl();
    av_log_set_level(AV_LOG_ERROR);

    int ret = avformat_open_input(&impl_->fmt, pathOrUrl.c_str(), nullptr, nullptr);
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
    for (unsigned i = 0; i < impl_->fmt->nb_streams; ++i) {
        const AVCodecParameters* par = impl_->fmt->streams[i]->codecpar;
        if (par && par->codec_type == AVMEDIA_TYPE_VIDEO) {
            impl_->vidx = static_cast<int>(i);
            break;
        }
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

    if (o.startMs > 0) {
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
        if (impl_->pkt->stream_index != impl_->vidx) {
            av_packet_unref(impl_->pkt);
            continue;
        }
        ret = avcodec_send_packet(impl_->codec, impl_->pkt);
        av_packet_unref(impl_->pkt);
        if (ret < 0 && ret != AVERROR(EAGAIN)) {
            err = "avcodec_send_packet: " + avErr(ret);
            return -1;
        }
    }
}

} // namespace misterplex
