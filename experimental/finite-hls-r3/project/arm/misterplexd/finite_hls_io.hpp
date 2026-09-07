#pragma once

#include <atomic>
#include <algorithm>
#include <cerrno>
#include <cctype>
#include <cstdint>
#include <cstring>
#include <limits>
#include <map>
#include <new>
#include <string>

extern "C" {
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/error.h>
#include <libavutil/mem.h>
#include <libavutil/opt.h>
#include <libavutil/parseutils.h>
}

namespace misterplex {

// libav owns HLS parsing, segment selection, reloads and timestamps. Its HLS
// demuxer can otherwise skip failed segments or report EOF on a stalled list.
// Observe the public I/O boundary so neither can become a successful finite EOF.
class FiniteHlsIo {
    struct Manifest {
        uint64_t sequence = 0, discontinuitySequence = 0, segments = 0;
        int64_t durationUs = 0, precisionUs = 0;
        bool target = false;
        bool master = false, media = false, terminal = false;
        bool pending = false, pendingVariant = false;
    };

    struct Origin {
        std::string host;
        int port = -1;
        bool file = false;

        bool parse(const char* url) {
            char protocol[16]{}, auth[1024]{}, hostname[1024]{};
            av_url_split(protocol, sizeof(protocol), auth, sizeof(auth),
                         hostname, sizeof(hostname), &port, nullptr, 0, url);
            if (*auth || std::strlen(hostname) >= sizeof(hostname) - 1) return false;
            file = !*protocol || std::strcmp(protocol, "file") == 0;
            if (file) return !*hostname;
            if (std::strcmp(protocol, "http") || !*hostname) return false;
            if (port < 0) port = 80;
            host = hostname;
            std::transform(host.begin(), host.end(), host.begin(),
                           [](unsigned char c) { return char(std::tolower(c)); });
            return true;
        }

        bool same(const Origin& other) const {
            return file == other.file && (file || (port == other.port && host == other.host));
        }
    };

    struct Input {
        FiniteHlsIo* owner = nullptr;
        AVIOContext* upstream = nullptr;
        AVIOContext* wrapper = nullptr;
        std::string identity, line;
        Manifest manifest;
        uint64_t bytes = 0;
        int64_t expectedBytes = 0;
        bool classified = false, playlist = false, eof = false, finished = false;

        bool unsignedNumber(size_t start, uint64_t& value) const {
            value = 0;
            if (start >= line.size()) return false;
            for (size_t i = start; i < line.size(); ++i) {
                const char digit = line[i];
                if (digit < '0' || digit > '9' ||
                    value > (uint64_t(INT64_MAX) - unsigned(digit - '0')) / 10)
                    return false;
                value = value * 10 + unsigned(digit - '0');
            }
            return true;
        }

        int lineComplete() {
            if (!line.empty() && line.back() == '\r') line.pop_back();
            if (!classified) {
                playlist = line == "#EXTM3U";
                classified = true;
                line.clear();
                return 0;
            }
            const bool blank = line.find_first_not_of(" \t") == std::string::npos;
            const bool ordinaryComment =
                !line.empty() && line[0] == '#' && line.rfind("#EXT", 0) != 0;
            if (manifest.pendingVariant && (blank || ordinaryComment)) {
                line.clear();
                return 0;
            }
            if (line.rfind("#EXTINF:", 0) == 0) {
                if (manifest.pending || manifest.pendingVariant || manifest.terminal ||
                    manifest.master)
                    return owner->fail(AVERROR_INVALIDDATA);
                const auto comma = line.find(',', 8);
                const auto duration = line.substr(8, comma == std::string::npos
                                                       ? comma : comma - 8);
                int64_t micros = 0, precision = 1000000;
                bool decimal = false;
                for (char c : duration) {
                    if (c == '.' && !decimal) decimal = true;
                    else if (c < '0' || c > '9')
                        return owner->fail(AVERROR_INVALIDDATA);
                    else if (decimal && precision > 1) precision /= 10;
                }
                if (av_parse_time(&micros, duration.c_str(), 1) < 0 || micros <= 0 ||
                    micros > INT64_MAX - manifest.durationUs ||
                    precision > INT64_MAX - manifest.precisionUs)
                    return owner->fail(AVERROR_INVALIDDATA);
                manifest.durationUs += micros;
                manifest.precisionUs += precision;
                manifest.media = manifest.pending = true;
            } else if (line.rfind("#EXT-X-STREAM-INF:", 0) == 0) {
                if (manifest.pending || manifest.pendingVariant || manifest.terminal ||
                    manifest.media)
                    return owner->fail(AVERROR_INVALIDDATA);
                manifest.master = manifest.pendingVariant = true;
            } else if (line.rfind("#EXT-X-TARGETDURATION:", 0) == 0) {
                uint64_t value = 0;
                if (manifest.master || manifest.pendingVariant ||
                    !unsignedNumber(22, value) || !value)
                    return owner->fail(AVERROR_INVALIDDATA);
                manifest.target = true;
                manifest.media = true;
            } else if (line.rfind("#EXT-X-MEDIA-SEQUENCE:", 0) == 0) {
                uint64_t value = 0;
                if (manifest.master || manifest.pendingVariant || !unsignedNumber(22, value))
                    return owner->fail(AVERROR_INVALIDDATA);
                manifest.sequence = value;
            } else if (line.rfind("#EXT-X-DISCONTINUITY-SEQUENCE:", 0) == 0) {
                uint64_t value = 0;
                if (manifest.master || manifest.pendingVariant ||
                    !unsignedNumber(sizeof("#EXT-X-DISCONTINUITY-SEQUENCE:") - 1, value))
                    return owner->fail(AVERROR_INVALIDDATA);
                manifest.discontinuitySequence = value;
            } else if (line == "#EXT-X-ENDLIST") {
                if (manifest.pending || manifest.pendingVariant || manifest.master)
                    return owner->fail(AVERROR_INVALIDDATA);
                manifest.terminal = true;
            } else if (line.rfind("#EXT-X-MAP:", 0) == 0) {
                return owner->fail(AVERROR_INVALIDDATA);
            } else if (line.rfind("#EXT-X-GAP", 0) == 0 ||
                       line.rfind("#EXT-X-SKIP", 0) == 0 ||
                       line.rfind("#EXT-X-BYTERANGE", 0) == 0 ||
                       line.rfind("#EXT-X-DISCONTINUITY", 0) == 0) {
                return owner->fail(AVERROR_INVALIDDATA);
            } else if (!line.empty() && line[0] != '#') {
                if (manifest.pending) {
                    ++manifest.segments;
                    manifest.pending = false;
                } else if (manifest.pendingVariant) {
                    manifest.pendingVariant = false;
                } else {
                    return owner->fail(AVERROR_INVALIDDATA);
                }
            }
            line.clear();
            return 0;
        }

        int observe(const uint8_t* data, int size) {
            bytes += unsigned(size);
            // TS/media bytes are forwarded unchanged; only a manifest's bounded
            // metadata lines are retained. No segment URI is interpreted here.
            if (!classified && line.empty() && data[0] != '#') {
                classified = true;
                playlist = false;
            }
            if (classified && !playlist) return 0;
            if (bytes > 1024 * 1024) return owner->fail(AVERROR(EFBIG));
            for (int i = 0; i < size; ++i) {
                if (data[i] == '\n') {
                    if (lineComplete() < 0) return owner->error();
                    if (!playlist) return 0;
                } else {
                    if (line.size() >= 4095) return owner->fail(AVERROR(EFBIG));
                    line.push_back(char(data[i]));
                }
            }
            return 0;
        }

        int finish(bool sawEof, bool allowAbandon = false) {
            if (finished) return owner->error();
            finished = true;
            eof = sawEof;
            if (!bytes || bytes != uint64_t(expectedBytes)) {
                if (allowAbandon) return owner->error();
                return owner->fail(AVERROR(EIO), "resource-length");
            }
            if (!classified || playlist) {
                if (!line.empty() && lineComplete() < 0) return owner->error();
                if (!playlist || manifest.pending || manifest.pendingVariant)
                    return owner->fail(AVERROR_INVALIDDATA);
                if (manifest.media) {
                    if (!manifest.target) return owner->fail(AVERROR_INVALIDDATA);
                    auto& previous = owner->manifests_[identity];
                    if ((previous.media &&
                         (previous.sequence != manifest.sequence ||
                          previous.discontinuitySequence != manifest.discontinuitySequence ||
                          previous.segments > manifest.segments ||
                          previous.durationUs > manifest.durationUs ||
                          (previous.terminal && !manifest.terminal))) ||
                        (manifest.terminal && !manifest.segments))
                        return owner->fail(AVERROR_INVALIDDATA);
                    previous = manifest;
                }
            }
            return owner->error();
        }
    };

    using Open = int (*)(AVFormatContext*, AVIOContext**, const char*, int, AVDictionary**);
    using Close = int (*)(AVFormatContext*, AVIOContext*);
    Open originalOpen_ = nullptr;
    Close originalClose_ = nullptr;
    Origin origin_;
    std::atomic<int> error_{0};
    std::atomic<int> transportError_{0};
    std::atomic<const char*> reason_{"none"};
    std::atomic<bool> abandoning_{false};
    std::atomic<bool> seeking_{false};
    std::map<std::string, Manifest> manifests_;
    std::map<AVIOContext*, Input*> inputs_;
    int64_t mediaBytes_ = 0;
    bool enabled_ = false, verified_ = false, transportEof_ = false;

    static void* child(void* object, void* previous) {
        if (previous) return nullptr;
        return static_cast<Input*>(static_cast<AVIOContext*>(object)->opaque)->upstream;
    }

    static const AVClass* ioClass() {
        static const AVOption options[1] = {};
        static const AVClass value = [] {
            AVClass result{};
            result.class_name = "MiSTerPlex finite HLS I/O";
            result.item_name = av_default_item_name;
            result.option = options;
            result.version = LIBAVUTIL_VERSION_INT;
            // Preserve libav's redirect location, headers and protocol options.
            result.child_next = child;
            return result;
        }();
        return &value;
    }

    static int read(void* opaque, uint8_t* data, int size) noexcept {
        auto& input = *static_cast<Input*>(opaque);
        if (input.owner->error()) return input.owner->error();
        const int result = avio_read_partial(input.upstream, data, size);
        try {
            if (result > 0) {
                if (input.observe(data, result) < 0) return input.owner->error();
                if (input.classified && !input.playlist)
                    input.owner->mediaBytes_ += result;
                return result;
            }
            if (result != AVERROR_EOF && result != 0)
                return input.owner->transportFail(result);
            if (input.upstream->error < 0 && input.upstream->error != AVERROR_EOF)
                return input.owner->transportFail(input.upstream->error);
            input.owner->transportEof_ = true;
            if (input.finish(true) < 0) return input.owner->error();
            return AVERROR_EOF;
        } catch (...) {
            return input.owner->fail(AVERROR(ENOMEM));
        }
    }

    static int64_t seek(void* opaque, int64_t offset, int whence) {
        auto& input = *static_cast<Input*>(opaque);
        if (whence == AVSEEK_SIZE) return avio_size(input.upstream);
        // HLS owns time/segment seeks. A manifest must be observed in order;
        // libav's own AVIO buffer still handles its short probe rewinds.
        if (input.playlist) return AVERROR(ENOSYS);
        return avio_seek(input.upstream, offset, whence);
    }

    static int open(AVFormatContext* format, AVIOContext** output, const char* url,
                    int flags, AVDictionary** options) noexcept {
        auto& owner = *static_cast<FiniteHlsIo*>(format->opaque);
        if (owner.error()) return owner.error();
        if (flags != AVIO_FLAG_READ || !url)
            return owner.fail(AVERROR(EINVAL));
        Input* input = nullptr;
        uint8_t* buffer = nullptr;
        AVIOContext* upstream = nullptr;
        try {
            Origin requested;
            if (!requested.parse(url) || !owner.origin_.same(requested))
                return owner.fail(AVERROR(EACCES), "origin");
            if (owner.inputs_.size() >= 8 || owner.manifests_.size() >= 8)
                return owner.fail(AVERROR(EFBIG));
            // libav forwards custom headers on redirects. The fixed PMS origin
            // is authoritative; do not send a session/token to another endpoint.
            AVDictionary* local = nullptr;
            AVDictionary** protocolOptions = options ? options : &local;
            if (av_dict_set(protocolOptions, "max_redirects", "0", 0) < 0)
                return owner.fail(AVERROR(ENOMEM));
            owner.transportEof_ = false;
            const int result = owner.originalOpen_(format, &upstream, url, flags, protocolOptions);
            av_dict_free(&local);
            if (result < 0) return owner.transportFail(result);
            input = new Input;
            input->owner = &owner;
            input->upstream = upstream;
            input->identity = url;
            input->expectedBytes = avio_size(upstream);
            // Public libav I/O does not distinguish a truncated chunked body
            // from EOF on all supported versions. Require a verifiable length
            // instead of guessing that an unknown-length response completed.
            if (input->expectedBytes <= 0) {
                const int error = input->expectedBytes < 0 ? AVERROR(ENOSYS) : AVERROR_INVALIDDATA;
                owner.originalClose_(format, upstream);
                delete input;
                return owner.fail(error, "resource-length");
            }
            uint8_t* location = nullptr;
            if (av_opt_get(upstream, "location", AV_OPT_SEARCH_CHILDREN, &location) >= 0) {
                try {
                    if (location && *location)
                        input->identity = reinterpret_cast<const char*>(location);
                } catch (...) {
                    av_free(location);
                    throw;
                }
                av_free(location);
            }
            if (input->identity.size() > 4095) {
                owner.originalClose_(format, upstream);
                delete input;
                return owner.fail(AVERROR(EFBIG));
            }
            buffer = static_cast<uint8_t*>(av_malloc(32768));
            if (!buffer) throw std::bad_alloc();
            input->wrapper = avio_alloc_context(buffer, 32768, 0, input, read, nullptr, seek);
            if (!input->wrapper) throw std::bad_alloc();
            buffer = nullptr;
            input->wrapper->av_class = ioClass();
            input->wrapper->seekable = upstream->seekable;
            owner.inputs_.emplace(input->wrapper, input);
            *output = input->wrapper;
            return 0;
        } catch (...) {
            av_free(buffer);
            if (input && input->wrapper) {
                av_freep(&input->wrapper->buffer);
                avio_context_free(&input->wrapper);
            }
            if (upstream) owner.originalClose_(format, upstream);
            delete input;
            return owner.fail(AVERROR(ENOMEM));
        }
    }

    static int close(AVFormatContext* format, AVIOContext* io) noexcept {
        auto& owner = *static_cast<FiniteHlsIo*>(format->opaque);
        const auto found = owner.inputs_.find(io);
        if (found == owner.inputs_.end())
            return owner.originalClose_(format, io);
        Input* input = found->second;
        const bool abandoning = owner.abandoning();
        const int transportError = input->upstream->error;
        if (transportError < 0 && transportError != AVERROR_EOF &&
            !(abandoning && transportError == AVERROR_EXIT))
            owner.transportFail(transportError);
        if (input->finish(false, abandoning) < 0 && !abandoning) {
            // Preserve the first explicit finite-contract error across close.
        }
        const int result = owner.originalClose_(format, input->upstream);
        if (result < 0 && !(abandoning && result == AVERROR_EXIT))
            owner.transportFail(result);
        owner.inputs_.erase(found);
        av_freep(&io->buffer);
        avio_context_free(&io);
        delete input;
        return result;
    }

public:
    int attach(AVFormatContext* format, const std::string& url) {
        if (url.size() > 4095 || !origin_.parse(url.c_str()))
            return fail(AVERROR(EINVAL));
        enabled_ = true;
        originalOpen_ = format->io_open;
        originalClose_ = format->io_close2;
        format->opaque = this;
        format->io_open = open;
        format->io_close2 = close;
        return 0;
    }

    bool enabled() const { return enabled_; }
    int error() const { return error_.load(std::memory_order_relaxed); }
    int fail(int result, const char* reason = "manifest") {
        if (result >= 0) result = AVERROR_INVALIDDATA;
        int empty = 0;
        if (error_.compare_exchange_strong(empty, result, std::memory_order_relaxed))
            reason_.store(reason, std::memory_order_relaxed);
        return error();
    }
    int transportFail(int result) {
        int empty = 0;
        transportError_.compare_exchange_strong(empty, result, std::memory_order_relaxed);
        return fail(result, "transport");
    }
    int transportError() const { return transportError_.load(std::memory_order_relaxed); }
    bool transportEof() const { return transportEof_; }
    const char* reason() const { return reason_.load(std::memory_order_relaxed); }
    int64_t mediaBytes() const { return mediaBytes_; }
    bool verified() const { return verified_; }
    void noteAbandon() { abandoning_.store(true, std::memory_order_relaxed); }
    void beginSeek() { seeking_.store(true, std::memory_order_relaxed); }
    void endSeek() { seeking_.store(false, std::memory_order_relaxed); }
    bool abandoning() const {
        return abandoning_.load(std::memory_order_relaxed) ||
               seeking_.load(std::memory_order_relaxed);
    }

    int verifyEof(int64_t videoDurationUs, int64_t frameDurationUs, int64_t tickUs) {
        if (error()) return error();
        if (!mediaBytes_ || manifests_.size() != 1 || videoDurationUs <= 0 ||
            frameDurationUs <= 0)
            return fail(AVERROR_INVALIDDATA, "completion");
        for (const auto& entry : manifests_)
            if (!entry.second.terminal || !entry.second.segments)
                return fail(AVERROR_INVALIDDATA, "completion");
        const auto& media = manifests_.begin()->second;
        // This is a completion check, not a replacement clock: retain every
        // original PTS and reject a terminal list whose video extent is short.
        // Decimal EXTINF rounding is bounded to less than half a source frame.
        const int64_t halfFrame = (frameDurationUs - 1) / 2;
        const uint64_t boundaries = 2 * (media.segments + 1);
        const int64_t clockRounding = tickUs > 0 && boundaries > uint64_t(halfFrame / tickUs)
            ? halfFrame : int64_t(boundaries) * tickUs;
        const int64_t tolerance = std::min(halfFrame,
            std::min(media.precisionUs, halfFrame) + clockRounding);
        const int64_t difference = videoDurationUs > media.durationUs
            ? videoDurationUs - media.durationUs : media.durationUs - videoDurationUs;
        if (difference > tolerance) return fail(AVERROR_INVALIDDATA, "video-extent");
        verified_ = true;
        return 0;
    }
};

} // namespace misterplex
