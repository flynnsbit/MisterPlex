#pragma once
// Present decoded RGB frames via MiSTer /dev/fb0 (HPS framebuffer → FPGA ascal).
// Phase 2 path while SDRAM/native decode matures. Matches console-core principle:
// FPGA owns final scanout; ARM only fills the frame store.

#include <cstdint>
#include <string>

namespace misterplex {

class FbPresent {
public:
    ~FbPresent();

    // Open /dev/fb0 (or path). Returns false if unavailable.
    bool open(const char* path = "/dev/fb0");
    void close();
    bool ok() const { return fd_ >= 0 && mem_ != nullptr; }

    int width() const { return width_; }
    int height() const { return height_; }
    int bpp() const { return bpp_; }

    // Copy packed RGB24 (w*h*3) centered into ARGB8888 or RGB565 fb.
    // Returns false on size mismatch / not open.
    bool blitRgb24(const uint8_t* rgb, int w, int h);

    // Clear to black
    void clear();

    std::string info() const;

private:
    int fd_ = -1;
    uint8_t* mem_ = nullptr;
    size_t mapLen_ = 0;
    int width_ = 0;
    int height_ = 0;
    int bpp_ = 32;
    int stride_ = 0; // bytes per line
};

} // namespace misterplex
