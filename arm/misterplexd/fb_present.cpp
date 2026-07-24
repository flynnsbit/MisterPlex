#include "fb_present.hpp"

#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#include <cstdio>
#include <cstring>
#include <linux/fb.h>
#include <sstream>

namespace misterplex {

FbPresent::~FbPresent() { close(); }

bool FbPresent::open(const char* path) {
    close();
    fd_ = ::open(path, O_RDWR);
    if (fd_ < 0) {
        std::perror("fb open");
        return false;
    }

    fb_var_screeninfo vinfo{};
    fb_fix_screeninfo finfo{};
    if (ioctl(fd_, FBIOGET_VSCREENINFO, &vinfo) != 0 ||
        ioctl(fd_, FBIOGET_FSCREENINFO, &finfo) != 0) {
        std::perror("fb ioctl");
        close();
        return false;
    }

    width_ = static_cast<int>(vinfo.xres);
    height_ = static_cast<int>(vinfo.yres);
    bpp_ = static_cast<int>(vinfo.bits_per_pixel);
    stride_ = static_cast<int>(finfo.line_length);
    mapLen_ = static_cast<size_t>(finfo.smem_len);
    if (mapLen_ == 0)
        mapLen_ = static_cast<size_t>(stride_) * static_cast<size_t>(height_);

    mem_ = static_cast<uint8_t*>(
        mmap(nullptr, mapLen_, PROT_READ | PROT_WRITE, MAP_SHARED, fd_, 0));
    if (mem_ == MAP_FAILED) {
        std::perror("fb mmap");
        mem_ = nullptr;
        close();
        return false;
    }
    return true;
}

void FbPresent::close() {
    if (mem_ && mem_ != MAP_FAILED) {
        munmap(mem_, mapLen_);
        mem_ = nullptr;
    }
    if (fd_ >= 0) {
        ::close(fd_);
        fd_ = -1;
    }
    mapLen_ = 0;
}

void FbPresent::clear() {
    if (!ok())
        return;
    std::memset(mem_, 0, mapLen_);
}

std::string FbPresent::info() const {
    std::ostringstream o;
    o << width_ << "x" << height_ << " bpp=" << bpp_ << " stride=" << stride_;
    return o.str();
}

bool FbPresent::blitRgb24(const uint8_t* rgb, int w, int h) {
    if (!ok() || !rgb || w <= 0 || h <= 0)
        return false;

    // Letterbox into fb
    const int dstW = width_;
    const int dstH = height_;
    const int x0 = (dstW > w) ? (dstW - w) / 2 : 0;
    const int y0 = (dstH > h) ? (dstH - h) / 2 : 0;
    const int copyW = (w < dstW) ? w : dstW;
    const int copyH = (h < dstH) ? h : dstH;

    if (bpp_ == 32 || bpp_ == 24) {
        for (int y = 0; y < copyH; ++y) {
            const uint8_t* src = rgb + static_cast<size_t>(y) * static_cast<size_t>(w) * 3;
            uint8_t* dst = mem_ + static_cast<size_t>(y0 + y) * static_cast<size_t>(stride_) +
                           static_cast<size_t>(x0) * 4;
            for (int x = 0; x < copyW; ++x) {
                // ARGB8888 little-endian: B G R A (MiSTer often BGR order with RxB flag)
                dst[0] = src[2]; // B
                dst[1] = src[1]; // G
                dst[2] = src[0]; // R
                dst[3] = 0xFF;
                dst += 4;
                src += 3;
            }
        }
        return true;
    }

    if (bpp_ == 16) {
        for (int y = 0; y < copyH; ++y) {
            const uint8_t* src = rgb + static_cast<size_t>(y) * static_cast<size_t>(w) * 3;
            uint16_t* dst = reinterpret_cast<uint16_t*>(
                mem_ + static_cast<size_t>(y0 + y) * static_cast<size_t>(stride_) +
                static_cast<size_t>(x0) * 2);
            for (int x = 0; x < copyW; ++x) {
                const unsigned r = src[0] >> 3;
                const unsigned g = src[1] >> 2;
                const unsigned b = src[2] >> 3;
                *dst++ = static_cast<uint16_t>((r << 11) | (g << 5) | b);
                src += 3;
            }
        }
        return true;
    }

    return false;
}

} // namespace misterplex
