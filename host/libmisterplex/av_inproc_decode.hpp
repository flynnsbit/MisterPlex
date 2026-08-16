#pragma once

#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>

#ifdef MPX_HAVE_LIBAV
#include <string>
#endif

namespace misterplex {

// Default OFF. Pipe path is unchanged unless MPX_INPROC_DECODE is truthy.
// 0/n/f/o/empty → off. Play script may export MPX_INPROC_DECODE=1.
inline bool inprocDecodeWanted() {
    const char* e = std::getenv("MPX_INPROC_DECODE");
    if (!e || !e[0])
        return false;
    const char c = e[0];
    if (c == '0' || c == 'n' || c == 'N' || c == 'f' || c == 'F' || c == 'o' ||
        c == 'O')
        return false;
    return true;
}

constexpr int kInproc720W = 1280;
constexpr int kInproc720H = 720;
constexpr int kInproc960W = 960;
constexpr int kInproc960H = 540;
constexpr size_t kInprocI420_1280 =
    static_cast<size_t>(kInproc720W) * static_cast<size_t>(kInproc720H) * 3 / 2;
constexpr size_t kInprocI420_960 =
    static_cast<size_t>(kInproc960W) * static_cast<size_t>(kInproc960H) * 3 / 2;

inline bool inprocDecodeSizeOk(int w, int h) {
    return (w == kInproc720W && h == kInproc720H) ||
           (w == kInproc960W && h == kInproc960H);
}

inline bool inprocScale1280to960(int srcW, int srcH, int dstW, int dstH) {
    return srcW == kInproc720W && srcH == kInproc720H && dstW == kInproc960W &&
           dstH == kInproc960H;
}

// Point-sample dest(x,y)=src(x*4/3,y*4/3). 1280/960=720/540=4/3. No swscale.
inline void pointSamplePlane4_3(const uint8_t* src, int srcStride, uint8_t* dst,
                                int dstW, int dstH) {
    for (int y = 0; y < dstH; ++y) {
        const uint8_t* srow =
            src + static_cast<size_t>(y * 4 / 3) * static_cast<size_t>(srcStride);
        uint8_t* drow = dst + static_cast<size_t>(y) * static_cast<size_t>(dstW);
        int x = 0;
        for (; x + 2 < dstW; x += 3) {
            const int sx = x * 4 / 3;
            drow[x] = srow[sx];
            drow[x + 1] = srow[sx + 1];
            drow[x + 2] = srow[sx + 2];
        }
        for (; x < dstW; ++x)
            drow[x] = srow[x * 4 / 3];
    }
}

inline bool downsampleI420_1280_to_960_planes(const uint8_t* y, int yStride,
                                              const uint8_t* u, int uStride,
                                              const uint8_t* v, int vStride,
                                              uint8_t* dst, size_t dstBytes) {
    if (!y || !u || !v || !dst || dstBytes != kInprocI420_960)
        return false;
    if (yStride < kInproc720W || uStride < (kInproc720W / 2) ||
        vStride < (kInproc720W / 2))
        return false;
    const size_t ysz =
        static_cast<size_t>(kInproc960W) * static_cast<size_t>(kInproc960H);
    const size_t csz = ysz / 4;
    pointSamplePlane4_3(y, yStride, dst, kInproc960W, kInproc960H);
    pointSamplePlane4_3(u, uStride, dst + ysz, kInproc960W / 2, kInproc960H / 2);
    pointSamplePlane4_3(v, vStride, dst + ysz + csz, kInproc960W / 2,
                        kInproc960H / 2);
    return true;
}

// Packed I420 (Y then U then V, no plane padding). 1382400 → 777600.
inline bool downsampleI420_1280_to_960(const uint8_t* src, size_t srcBytes,
                                       uint8_t* dst, size_t dstBytes) {
    if (!src || srcBytes != kInprocI420_1280)
        return false;
    const size_t ysz =
        static_cast<size_t>(kInproc720W) * static_cast<size_t>(kInproc720H);
    const size_t csz = ysz / 4;
    return downsampleI420_1280_to_960_planes(src, kInproc720W, src + ysz,
                                             kInproc720W / 2, src + ysz + csz,
                                             kInproc720W / 2, dst, dstBytes);
}

// Repeat each src sample rx times. rx==2/4 use word stores (no per-pixel div).
inline void nearestRepeatRow(const uint8_t* s, uint8_t* d, int srcW, int rx) {
    if (rx == 4) {
        for (int sx = 0; sx < srcW; ++sx) {
            const uint32_t v = static_cast<uint32_t>(s[sx]) * 0x01010101u;
            std::memcpy(d + static_cast<size_t>(sx) * 4u, &v, 4);
        }
        return;
    }
    if (rx == 2) {
        int sx = 0;
        for (; sx + 3 < srcW; sx += 4) {
            const uint32_t a = static_cast<uint32_t>(s[sx]) * 0x0101u |
                               ((static_cast<uint32_t>(s[sx + 1]) * 0x0101u) << 16);
            const uint32_t b = static_cast<uint32_t>(s[sx + 2]) * 0x0101u |
                               ((static_cast<uint32_t>(s[sx + 3]) * 0x0101u) << 16);
            std::memcpy(d + static_cast<size_t>(sx) * 2u, &a, 4);
            std::memcpy(d + static_cast<size_t>(sx) * 2u + 4u, &b, 4);
        }
        for (; sx < srcW; ++sx) {
            const uint16_t v = static_cast<uint16_t>(
                static_cast<uint16_t>(s[sx]) * static_cast<uint16_t>(0x0101u));
            std::memcpy(d + static_cast<size_t>(sx) * 2u, &v, 2);
        }
        return;
    }
    for (int sx = 0; sx < srcW; ++sx) {
        const uint8_t p = s[sx];
        uint8_t* dp = d + static_cast<size_t>(sx * rx);
        for (int k = 0; k < rx; ++k)
            dp[k] = p;
    }
}

inline void nearestRepeatChroma(const uint8_t* su, const uint8_t* sv, uint8_t* du,
                                uint8_t* dv, int srcCw, int crx) {
    if (crx == 2 || crx == 4) {
        nearestRepeatRow(su, du, srcCw, crx);
        nearestRepeatRow(sv, dv, srcCw, crx);
        return;
    }
    for (int sx = 0; sx < srcCw; ++sx) {
        const uint8_t pu = su[sx];
        const uint8_t pv = sv[sx];
        uint8_t* dpu = du + static_cast<size_t>(sx * crx);
        uint8_t* dpv = dv + static_cast<size_t>(sx * crx);
        for (int k = 0; k < crx; ++k) {
            dpu[k] = pu;
            dpv[k] = pv;
        }
    }
}

// Nearest I420 into a packed dest (Y then U then V, no padding).
// dest(x,y)=src(x*srcW/dstW, y*srcH/dstH). Even sizes only. No libswscale
// (ARM ffmpeg prefix has none). Identity is a stride-aware row copy.
// Fast: integer box (320×240→1280×720 is 4×3) and 2×/3/2 (640×480→1280×720).
inline bool scaleI420NearestPlanes(const uint8_t* y, int yStride,
                                   const uint8_t* u, int uStride,
                                   const uint8_t* v, int vStride,
                                   int srcW, int srcH,
                                   uint8_t* dst, int dstW, int dstH,
                                   size_t dstBytes) {
    if (!y || !u || !v || !dst)
        return false;
    if (srcW <= 0 || srcH <= 0 || dstW <= 0 || dstH <= 0)
        return false;
    if ((srcW & 1) || (srcH & 1) || (dstW & 1) || (dstH & 1))
        return false;
    const size_t need =
        static_cast<size_t>(dstW) * static_cast<size_t>(dstH) * 3 / 2;
    if (dstBytes != need)
        return false;
    const int srcCw = srcW / 2;
    const int srcCh = srcH / 2;
    const int dstCw = dstW / 2;
    const int dstCh = dstH / 2;
    if (yStride < srcW || uStride < srcCw || vStride < srcCw)
        return false;
    const size_t ysz = static_cast<size_t>(dstW) * static_cast<size_t>(dstH);
    uint8_t* dy = dst;
    uint8_t* du = dst + ysz;
    uint8_t* dv = du + ysz / 4;
    if (srcW == dstW && srcH == dstH) {
        for (int row = 0; row < dstH; ++row) {
            std::memcpy(dy + static_cast<size_t>(row) * static_cast<size_t>(dstW),
                        y + static_cast<size_t>(row) * static_cast<size_t>(yStride),
                        static_cast<size_t>(dstW));
        }
        for (int row = 0; row < dstCh; ++row) {
            std::memcpy(du + static_cast<size_t>(row) * static_cast<size_t>(dstCw),
                        u + static_cast<size_t>(row) * static_cast<size_t>(uStride),
                        static_cast<size_t>(dstCw));
            std::memcpy(dv + static_cast<size_t>(row) * static_cast<size_t>(dstCw),
                        v + static_cast<size_t>(row) * static_cast<size_t>(vStride),
                        static_cast<size_t>(dstCw));
        }
        return true;
    }
    // Integer box upsample (320×240→1280×720 is 4×3). dest(x,y)=src(x/rx,y/ry).
    if (dstW % srcW == 0 && dstH % srcH == 0) {
        const int rx = dstW / srcW;
        const int ry = dstH / srcH;
        for (int sy = 0; sy < srcH; ++sy) {
            const uint8_t* srow =
                y + static_cast<size_t>(sy) * static_cast<size_t>(yStride);
            uint8_t* drow = dy + static_cast<size_t>(sy * ry) *
                                     static_cast<size_t>(dstW);
            nearestRepeatRow(srow, drow, srcW, rx);
            for (int k = 1; k < ry; ++k)
                std::memcpy(drow + static_cast<size_t>(k) * static_cast<size_t>(dstW),
                            drow, static_cast<size_t>(dstW));
        }
        const int crx = dstCw / srcCw;
        const int cry = dstCh / srcCh;
        for (int sy = 0; sy < srcCh; ++sy) {
            const uint8_t* su =
                u + static_cast<size_t>(sy) * static_cast<size_t>(uStride);
            const uint8_t* sv =
                v + static_cast<size_t>(sy) * static_cast<size_t>(vStride);
            uint8_t* durow = du + static_cast<size_t>(sy * cry) *
                                      static_cast<size_t>(dstCw);
            uint8_t* dvrow = dv + static_cast<size_t>(sy * cry) *
                                      static_cast<size_t>(dstCw);
            nearestRepeatChroma(su, sv, durow, dvrow, srcCw, crx);
            for (int k = 1; k < cry; ++k) {
                std::memcpy(durow + static_cast<size_t>(k) * static_cast<size_t>(dstCw),
                            durow, static_cast<size_t>(dstCw));
                std::memcpy(dvrow + static_cast<size_t>(k) * static_cast<size_t>(dstCw),
                            dvrow, static_cast<size_t>(dstCw));
            }
        }
        return true;
    }
    // 640×480 → 1280×720: 2× width, 3/2 height. y*480/720 = y*2/3.
    // Dest groups of 3 rows sample src (2g, 2g, 2g+1). Same on chroma.
    if (srcW * 2 == dstW && srcH * 3 == dstH * 2) {
        const size_t dYb = static_cast<size_t>(dstW);
        const size_t dCb = static_cast<size_t>(dstCw);
        for (int g = 0; g < dstH / 3; ++g) {
            const int sy0 = g * 2;
            uint8_t* d0 = dy + static_cast<size_t>(g * 3) * dYb;
            nearestRepeatRow(y + static_cast<size_t>(sy0) * static_cast<size_t>(yStride),
                             d0, srcW, 2);
            std::memcpy(d0 + dYb, d0, dYb);
            nearestRepeatRow(y + static_cast<size_t>(sy0 + 1) * static_cast<size_t>(yStride),
                             d0 + 2 * dYb, srcW, 2);
        }
        for (int g = 0; g < dstCh / 3; ++g) {
            const int sy0 = g * 2;
            uint8_t* u0 = du + static_cast<size_t>(g * 3) * dCb;
            uint8_t* v0 = dv + static_cast<size_t>(g * 3) * dCb;
            nearestRepeatChroma(u + static_cast<size_t>(sy0) * static_cast<size_t>(uStride),
                                v + static_cast<size_t>(sy0) * static_cast<size_t>(vStride),
                                u0, v0, srcCw, 2);
            std::memcpy(u0 + dCb, u0, dCb);
            std::memcpy(v0 + dCb, v0, dCb);
            nearestRepeatChroma(
                u + static_cast<size_t>(sy0 + 1) * static_cast<size_t>(uStride),
                v + static_cast<size_t>(sy0 + 1) * static_cast<size_t>(vStride),
                u0 + 2 * dCb, v0 + 2 * dCb, srcCw, 2);
        }
        return true;
    }
    // Generic: one div per column (xmap), not per pixel.
    if (dstW <= 2048 && dstCw <= 1024) {
        int xmap[2048];
        int cxmap[1024];
        for (int x = 0; x < dstW; ++x)
            xmap[x] = x * srcW / dstW;
        for (int x = 0; x < dstCw; ++x)
            cxmap[x] = x * srcCw / dstCw;
        for (int row = 0; row < dstH; ++row) {
            const int sy = row * srcH / dstH;
            const uint8_t* srow =
                y + static_cast<size_t>(sy) * static_cast<size_t>(yStride);
            uint8_t* drow = dy + static_cast<size_t>(row) * static_cast<size_t>(dstW);
            for (int x = 0; x < dstW; ++x)
                drow[x] = srow[xmap[x]];
        }
        for (int row = 0; row < dstCh; ++row) {
            const int sy = row * srcCh / dstCh;
            const uint8_t* su =
                u + static_cast<size_t>(sy) * static_cast<size_t>(uStride);
            const uint8_t* sv =
                v + static_cast<size_t>(sy) * static_cast<size_t>(vStride);
            uint8_t* durow = du + static_cast<size_t>(row) * static_cast<size_t>(dstCw);
            uint8_t* dvrow = dv + static_cast<size_t>(row) * static_cast<size_t>(dstCw);
            for (int x = 0; x < dstCw; ++x) {
                const int sx = cxmap[x];
                durow[x] = su[sx];
                dvrow[x] = sv[sx];
            }
        }
        return true;
    }
    for (int row = 0; row < dstH; ++row) {
        const int sy = row * srcH / dstH;
        const uint8_t* srow =
            y + static_cast<size_t>(sy) * static_cast<size_t>(yStride);
        uint8_t* drow = dy + static_cast<size_t>(row) * static_cast<size_t>(dstW);
        for (int x = 0; x < dstW; ++x)
            drow[x] = srow[x * srcW / dstW];
    }
    for (int row = 0; row < dstCh; ++row) {
        const int sy = row * srcCh / dstCh;
        const uint8_t* su =
            u + static_cast<size_t>(sy) * static_cast<size_t>(uStride);
        const uint8_t* sv =
            v + static_cast<size_t>(sy) * static_cast<size_t>(vStride);
        uint8_t* durow = du + static_cast<size_t>(row) * static_cast<size_t>(dstCw);
        uint8_t* dvrow = dv + static_cast<size_t>(row) * static_cast<size_t>(dstCw);
        for (int x = 0; x < dstCw; ++x) {
            const int sx = x * srcCw / dstCw;
            durow[x] = su[sx];
            dvrow[x] = sv[sx];
        }
    }
    return true;
}

#ifdef MPX_HAVE_LIBAV

struct AvInprocOpenOpts {
    int expectW = 1280;
    int expectH = 720;
    int threads = 2;
    int64_t startMs = 0;
    // 0 → same as expect (bank). Source may differ; readI420 nearest-scales.
    int outW = 0;
    int outH = 0;
    // FFmpeg-style header block (CRLF). PMS universal needs X-Plex-Token etc.
    std::string headers;
};

class AvInprocDecoder {
public:
    bool open(const std::string& pathOrUrl, const AvInprocOpenOpts& o, std::string& err);
    // 1=frame, 0=EOF, -1=error. Packed I420 (Y then U then V, no padding between planes).
    int readI420(uint8_t* dst, size_t frameBytes, std::string& err);
    void close();
    ~AvInprocDecoder() { close(); }
    int width() const;
    int height() const;
    bool isOpen() const;
    static const char* libavIdent();

    AvInprocDecoder() = default;
    AvInprocDecoder(const AvInprocDecoder&) = delete;
    AvInprocDecoder& operator=(const AvInprocDecoder&) = delete;

private:
    struct Impl;
    Impl* impl_ = nullptr;
};

#endif // MPX_HAVE_LIBAV

} // namespace misterplex
