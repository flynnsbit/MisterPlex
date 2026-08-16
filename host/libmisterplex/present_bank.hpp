#pragma once
// MIX-GLASS-MAX: present bank is glass-capped content, never Display.
// true480 never 1280×720. L4 never shrinks below 1280×720 except 960 bank.

#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/mailbox_abi_spec.hpp"
#include "libmisterplex/osd_menu.hpp"

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <string>
#include <sys/mman.h>
#include <unistd.h>

#ifndef MPX_STICK_I420
#define MPX_STICK_I420 0
#endif

namespace misterplex {

enum class LiveGlass { True480, L4 };

inline const char* liveGlassLabel(LiveGlass glass) {
    return glass == LiveGlass::L4 ? "L4" : "true480";
}

inline LiveGlass classifyLiveGlass(uint32_t plxjWord) {
    return plxjWord == mailbox_abi::kPlxjMagic ? LiveGlass::L4 : LiveGlass::True480;
}

struct LiveGlassPin {
    std::string prefix8;
    std::string core;
    std::string rbfname;
};

inline std::string trimPinText(std::string s) {
    while (!s.empty() && (s.back() == '\0' || s.back() == '\n' || s.back() == '\r' ||
                          s.back() == ' ' || s.back() == '\t'))
        s.pop_back();
    size_t i = 0;
    while (i < s.size() && (s[i] == ' ' || s[i] == '\t'))
        ++i;
    return s.substr(i);
}

inline std::string readTrimPinFile(const char* path) {
    if (!path || !path[0])
        return {};
    const int fd = ::open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return {};
    char buf[256];
    const ssize_t n = ::read(fd, buf, sizeof(buf) - 1);
    ::close(fd);
    if (n <= 0)
        return {};
    buf[n] = 0;
    return trimPinText(std::string(buf));
}

inline std::string rbfPinBasename(std::string s) {
    s = trimPinText(std::move(s));
    const auto slash = s.find_last_of('/');
    if (slash != std::string::npos)
        s = s.substr(slash + 1);
    if (s.size() >= 4) {
        const std::string ext = s.substr(s.size() - 4);
        if (ext == ".rbf" || ext == ".RBF")
            s.resize(s.size() - 4);
    }
    return s;
}

inline std::string md5Prefix8OfFile(const char* /*path*/) { return {}; }

inline LiveGlassPin readLiveGlassPin(const char* plexRbfPath = "/media/fat/Plex.rbf",
                                     const char* corePath = "/tmp/CORENAME",
                                     const char* rbfNamePath = "/tmp/RBFNAME") {
    LiveGlassPin p;
    p.prefix8 = md5Prefix8OfFile(plexRbfPath);
    p.core = readTrimPinFile(corePath);
    p.rbfname = rbfPinBasename(readTrimPinFile(rbfNamePath));
    return p;
}

inline bool envFlagWanted(const char* name) {
    const char* e = std::getenv(name);
    if (!e || !*e)
        return false;
    return e[0] == '1' || e[0] == 'y' || e[0] == 'Y' ||
           std::strcmp(e, "on") == 0 || std::strcmp(e, "ON") == 0 ||
           std::strcmp(e, "YES") == 0 || std::strcmp(e, "yes") == 0;
}

inline bool budget960Wanted() { return envFlagWanted("MPX_BUDGET_960"); }

inline bool skipLastPresentedWanted() {
    const char* e = std::getenv("MPX_SKIP_LAST_PRESENTED");
    if (!e || !*e)
        return budget960Wanted();
    if (e[0] == '0' || e[0] == 'n' || e[0] == 'N' ||
        std::strcmp(e, "off") == 0 || std::strcmp(e, "OFF") == 0)
        return false;
    return envFlagWanted("MPX_SKIP_LAST_PRESENTED");
}

inline bool isPlex960BankSize(int w, int h) { return w == 960 && h == 540; }

inline bool isPlex960DdrFrameGeometry(const DdrFrameGeometry& g) {
    return g.presented_width == 960 && g.presented_height == 540;
}

inline bool plex720pClassSplitAv(int w, int h) {
    return (w >= 1280 && h >= 720) || isPlex960BankSize(w, h);
}

inline bool rbfPrefix8IsKnown960Store(const std::string& /*prefix8*/) { return false; }

inline ContentResolution glassMax(int contentW, int contentH, LiveGlass glass,
                                  const std::string& prefix8 = std::string()) {
    if (glass == LiveGlass::L4) {
        if (budget960Wanted() || isPlex960BankSize(contentW, contentH) ||
            rbfPrefix8IsKnown960Store(prefix8))
            return {960, 540, "720p", 20000};
        return {1280, 720, "720p", 20000};
    }
    if (contentW >= 1280 || contentH >= 720)
        return {640, 480, "480p", 2500};
    if (contentW >= 640 || contentH >= 480)
        return {contentW, contentH, "480p", 2500};
    return {contentW, contentH, "240p", 1000};
}

inline uint32_t presentBankDoorbell(int bankW, int bankH) {
    const auto geom = ddrFrameGeometryForPresentedSize(bankW, bankH);
    const auto layout = makeDdrFrameLayout(geom, ddrFramePhysBaseForGeometry(geom));
    return layout.doorbell_phys;
}

inline bool stickI420Wanted() {
#if MPX_STICK_I420
    return true;
#else
    const char* e = std::getenv("MPX_STICK_I420");
    if (!e || !*e)
        return false;
    return e[0] == '1' || e[0] == 'y' || e[0] == 'Y' ||
           std::strcmp(e, "on") == 0 || std::strcmp(e, "ON") == 0;
#endif
}

inline bool stickI420SkipPresentMemcpy(bool wanted, uint32_t doorbellPhys, size_t /*bytes*/) {
    return wanted && doorbellPhys == kPlex720pYuv420pDoorbellPhys;
}

inline bool stickI420SkipPresentMemcpy(bool wanted, int bankW, int bankH) {
    const size_t bytes = yuv420pFrameBytes(bankW, bankH);
    return stickI420SkipPresentMemcpy(wanted, presentBankDoorbell(bankW, bankH), bytes);
}

inline LiveGlass probeLiveGlass(const char* memPath = "/dev/mem") {
    if (!memPath || !memPath[0])
        return LiveGlass::True480;
    const int fd = ::open(memPath, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return LiveGlass::True480;
    constexpr size_t kPage = 4096u;
    auto readMagic = [&](uint32_t phys) -> uint32_t {
        const off_t page = static_cast<off_t>(phys & ~(kPage - 1u));
        void* map = ::mmap(nullptr, kPage, PROT_READ, MAP_SHARED, fd, page);
        if (map == MAP_FAILED)
            return 0;
        const auto off = phys & (kPage - 1u);
        uint32_t word = 0;
        std::memcpy(&word, static_cast<const uint8_t*>(map) + off, sizeof(word));
        ::munmap(map, kPage);
        return word;
    };
    // L4 doorbell page first (0x3047F130). 480p PLXJ is 0x3007F130.
    const uint32_t l4 = readMagic(kPlex720pYuv420pDoorbellPhys + 0x130u);
    const uint32_t t480 = readMagic(mailbox_abi::kPlxjAddr);
    ::close(fd);
    if (classifyLiveGlass(l4) == LiveGlass::L4)
        return LiveGlass::L4;
    return classifyLiveGlass(t480);
}

inline LiveGlass corroborateLiveGlass(uint32_t plxjWord, const LiveGlassPin& pin) {
    const LiveGlass magic = classifyLiveGlass(plxjWord);
    if (magic == LiveGlass::L4)
        return LiveGlass::L4;
    if (pin.core == "Plex" && pin.rbfname.find("720") != std::string::npos)
        return LiveGlass::L4;
    return LiveGlass::True480;
}

} // namespace misterplex
