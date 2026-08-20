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

// Leftover L4 PLXJ in HPS DRAM (survives reboot) must not pin glass=L4 when
// the live RBF is true480 (PLXI at 0x3007F108, doorbell 0x3007F000). Cast then
// writes 720p doorbells the fabric never polls — chevron-only, Web still playing.
inline LiveGlass decideLiveGlassFromProbes(bool l4PlxjMagic, bool l4Changed,
                                           bool t480PlxiMagic, bool t480Changed) {
    if (l4Changed)
        return LiveGlass::L4;
    if (t480Changed)
        return LiveGlass::True480;
    // Leftover true480 PLXI in HPS DRAM is sticky after an L4 load. Static L4
    // PLXJ (magic present, not changing in the 40 ms sample) must still win
    // over that leftover — otherwise 28cb5a75 pins glass=true480 and
    // GLASS-MAX caps DECODE=1280x720 → bank=640x480. Live 480p still wins
    // via t480Changed (scanout ticks PLXD).
    if (l4PlxjMagic)
        return LiveGlass::L4;
    if (t480PlxiMagic)
        return LiveGlass::True480;
    return LiveGlass::True480;
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

// Default OFF. A second ffmpeg on the dual-A9 stole the decode core:
// isolated 1280x720 Farpoint decode 10s in 7.39s (~32 fps) but product
// split-A/V unique stuck at ~15. 480p gold is single-process. Opt-in
// MPX_SPLIT_AV=1 only.
// 720p CATCH swaps once per vblank. Unpaced BestEffort: pfps=23.8 hw_fps=22.2
// (lost kicks). Wait-THIS-swap then avDecide/overlay added ~2 ms/period
// (unique ~22.8). Kick-on-swap: wait the previous blank, doorbell at swap.
// WC copy of the current slot lands in the free bank after that swap.
// Default ON for 1280×720; MPX_BEAM_PACE=0 disables. 480p stays off.
inline bool beamPaceWanted(int bankW, int bankH) {
    const char* e = std::getenv("MPX_BEAM_PACE");
    if (e && *e) {
        const char c = e[0];
        if (c == '0' || c == 'n' || c == 'N' || c == 'f' || c == 'F' || c == 'o' ||
            c == 'O')
            return false;
        return true;
    }
    return bankW == 1280 && bankH == 720;
}

inline bool plex720pClassSplitAv(int w, int h) {
    (void)w;
    (void)h;
    const char* e = std::getenv("MPX_SPLIT_AV");
    if (!e || !*e)
        return false;
    const char c = e[0];
    if (c == '0' || c == 'n' || c == 'N' || c == 'f' || c == 'F')
        return false;
    return true;
}

inline bool rbfPrefix8IsKnown960Store(const std::string& /*prefix8*/) { return false; }

inline ContentResolution glassMax(int contentW, int contentH, LiveGlass glass,
                                  const std::string& prefix8 = std::string()) {
    if (glass == LiveGlass::L4) {
        if (budget960Wanted() || isPlex960BankSize(contentW, contentH) ||
            rbfPrefix8IsKnown960Store(prefix8))
            return {960, 540, "720p", 1500};
        return {1280, 720, "720p", 1500};
    }
    // true480 (07f54d9f) scans one store: 640×480 @ 0x300FF000. OSD 240p is a
    // PMS ladder only. 320×240 / 1280×720 doorbells on this bitstream are
    // chevron (no live PLXD at those pages). 720p24 needs RBF 03f1b95a.
    (void)contentW;
    (void)contentH;
    (void)prefix8;
    return {640, 480, "480p", 2500};
}

// OSD 720p on true480 must not request a 1280 PMS ladder. OSD 240p/480p stay
// as PMS quality. Display raster follows the live RBF, not F12 Display.
inline ContentResolution clampContentToLiveGlass(const ContentResolution& content,
                                                 LiveGlass glass) {
    if (glass == LiveGlass::L4)
        return {1280, 720, "720p", 1500};
    if (content.width >= 1280 || content.height >= 720)
        return {640, 480, "480p", 2500};
    return content;
}

inline ContentResolution clampDisplayToLiveGlass(LiveGlass glass,
                                                const ContentResolution& wanted = {}) {
    if (glass == LiveGlass::L4)
        return {1280, 720, "720p", 1500};
    // true480: present store is always 640×480. Display labels only pick
    // video_mode: 240p=15 kHz bob CRT, 480i=15 kHz weave (OSD Display 720p
    // remaps here — 720p HDMI is illegal on this RBF), 480p=SVGA 800×600.
    if (wanted.label && std::strcmp(wanted.label, "240p") == 0)
        return {320, 240, "240p", 1000};
    if (wanted.label && (std::strcmp(wanted.label, "480i") == 0 ||
                         std::strcmp(wanted.label, "720p") == 0))
        return {720, 480, "480i", 2500};
    return {640, 480, "480p", 2500};
}

inline uint32_t presentBankDoorbell(int bankW, int bankH) {
    const auto geom = ddrFrameGeometryForPresentedSize(bankW, bankH);
    const auto layout = makeDdrFrameLayout(geom, ddrFramePhysBaseForGeometry(geom));
    return layout.doorbell_phys;
}

// WC stick ingest writes the free present bank. Stub fabric_direct must not
// disable that (unique 23.5 memcpy path). New RBF fabric reader can set
// MPX_STICK_I420=0.
inline bool plex720pStickIngestOverridesFabric(bool stickWanted, bool fabricWanted) {
    (void)fabricWanted;
    return stickWanted;
}

inline bool stickI420Wanted() {
    const char* e = std::getenv("MPX_STICK_I420");
    if (e && *e) {
        const char c = e[0];
        if (c == '0' || c == 'n' || c == 'N' || c == 'f' || c == 'F' || c == 'o' ||
            c == 'O')
            return false;
        return true;
    }
#if MPX_STICK_I420
    return true;
#else
    // Default ON. 720p AND's this with plex720pWcBankIngest; 480p stays memcpy.
    // Dual-bank I420 after swap is banned (copy_us=5280 unique 21.5).
    return true;
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
    // Watcher writes this from the live Plex.rbf md5. Leftover L4/true480
    // mailbox words in HPS DRAM must not override the bitstream on glass.
    const std::string pin = readTrimPinFile("/tmp/misterplex-live-glass");
    if (pin == "L4" || pin == "l4" || pin == "720p24")
        return LiveGlass::L4;
    if (pin == "true480" || pin == "480p")
        return LiveGlass::True480;
    if (!memPath || !memPath[0])
        return LiveGlass::True480;
    const int fd = ::open(memPath, O_RDONLY | O_SYNC | O_CLOEXEC);
    if (fd < 0)
        return LiveGlass::True480;
    constexpr size_t kPage = 4096u;
    auto readWord = [&](uint32_t phys) -> uint32_t {
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
    const uint32_t l4Plxj0 = readWord(kPlex720pYuv420pDoorbellPhys + 0x130u);
    const uint32_t l4Plxd0 = readWord(kPlex720pYuv420pDoorbellPhys + 0x12cu);
    const uint32_t t480Plxi0 = readWord(mailbox_abi::kPlxiAddr);
    const uint32_t t480Plxd0 = readWord(mailbox_abi::kPlxdAddr + 4u);
    ::usleep(40000);
    const uint32_t l4Plxj1 = readWord(kPlex720pYuv420pDoorbellPhys + 0x130u);
    const uint32_t l4Plxd1 = readWord(kPlex720pYuv420pDoorbellPhys + 0x12cu);
    const uint32_t t480Plxi1 = readWord(mailbox_abi::kPlxiAddr);
    const uint32_t t480Plxd1 = readWord(mailbox_abi::kPlxdAddr + 4u);
    ::close(fd);
    const bool l4Changed = (l4Plxj0 != l4Plxj1) || (l4Plxd0 != l4Plxd1);
    const bool t480Changed = (t480Plxi0 != t480Plxi1) || (t480Plxd0 != t480Plxd1);
    return decideLiveGlassFromProbes(l4Plxj1 == mailbox_abi::kPlxjMagic, l4Changed,
                                     t480Plxi1 == mailbox_abi::kPlxiMagic, t480Changed);
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
