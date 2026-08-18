#include "libmisterplex/present_bank.hpp"

#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <string>
#include <unistd.h>
#include <utility>

static int fails = 0;
#define CHECK(cond)                                                                              \
    do {                                                                                         \
        if (!(cond)) {                                                                           \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                 \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

int main() {
    using namespace misterplex;

    CHECK(std::strcmp(liveGlassLabel(LiveGlass::True480), "true480") == 0);
    CHECK(std::strcmp(liveGlassLabel(LiveGlass::L4), "L4") == 0);
    CHECK(std::strcmp(liveGlassLabel(LiveGlass::Crt15), "crt15") == 0);

    CHECK(classifyLiveGlass(mailbox_abi::kPlxjMagic) == LiveGlass::L4);
    CHECK(classifyLiveGlass(0) == LiveGlass::True480);

    {
        LiveGlassPin p;
        p.rbfname = "Plex_15k";
        CHECK(pinLooksCrt15(p));
        CHECK(classifyLiveGlassPin(p) == LiveGlass::Crt15);
        CHECK(corroborateLiveGlass(LiveGlass::True480, p) == LiveGlass::Crt15);
        CHECK(corroborateLiveGlass(0u, p) == LiveGlass::Crt15);
    }
    {
        LiveGlassPin p;
        p.glass = "crt15";
        CHECK(pinLooksCrt15(p));
        CHECK(classifyLiveGlassPin(p) == LiveGlass::Crt15);
    }
    {
        LiveGlassPin p;
        p.glass = "CRT15";
        CHECK(pinTextEquals(p.glass, "crt15"));
        CHECK(classifyLiveGlassPin(p) == LiveGlass::Crt15);
    }
    {
        LiveGlassPin p;
        p.rbfname = "Plex_240p15";
        CHECK(pinLooksCrt15(p));
        CHECK(classifyLiveGlassPin(p) == LiveGlass::Crt15);
        CHECK(corroborateLiveGlass(LiveGlass::True480, p) == LiveGlass::Crt15);
    }
    {
        LiveGlassPin p;
        p.rbfname = rbfPinBasename("Plex_240p15.rbf");
        CHECK(p.rbfname == "Plex_240p15");
        CHECK(classifyLiveGlassPin(p) == LiveGlass::Crt15);
    }
    {
        LiveGlassPin p;
        p.core = "Plex_240p15";
        CHECK(pinLooksCrt15(p));
        CHECK(classifyLiveGlassPin(p) == LiveGlass::Crt15);
    }
    {
        LiveGlassPin p;
        p.rbfname = "Plex_480i";
        CHECK(pinLooksCrt15(p));
        CHECK(classifyLiveGlassPin(p) == LiveGlass::Crt15);
        CHECK(corroborateLiveGlass(LiveGlass::True480, p) == LiveGlass::Crt15);
    }
    {
        LiveGlassPin p;
        p.rbfname = rbfPinBasename("Plex_480i.rbf");
        CHECK(p.rbfname == "Plex_480i");
        CHECK(classifyLiveGlassPin(p) == LiveGlass::Crt15);
    }
    {
        LiveGlassPin p;
        p.core = "Plex_480i";
        CHECK(pinLooksCrt15(p));
        CHECK(classifyLiveGlassPin(p) == LiveGlass::Crt15);
    }
    {
        LiveGlassPin p;
        p.glass = "crt240p15";
        CHECK(pinLooksCrt15(p));
        CHECK(classifyLiveGlassPin(p) == LiveGlass::Crt15);
    }
    {
        LiveGlassPin p;
        p.glass = "crt480i";
        CHECK(pinLooksCrt15(p));
        CHECK(classifyLiveGlassPin(p) == LiveGlass::Crt15);
    }
    {
        LiveGlassPin p;
        p.rbfname = "Plex";
        CHECK(!pinLooksCrt15(p));
        CHECK(classifyLiveGlassPin(p) == LiveGlass::True480);
    }
    {
        LiveGlassPin p;
        p.core = "Plex";
        p.rbfname = "Plex_720p24";
        CHECK(!pinLooksCrt15(p));
        CHECK(classifyLiveGlassPin(p) == LiveGlass::L4);
        CHECK(corroborateLiveGlass(LiveGlass::True480, p) == LiveGlass::L4);
    }
    {
        LiveGlassPin p;
        p.rbfname = "Plex_15k";
        CHECK(corroborateLiveGlass(LiveGlass::L4, p) == LiveGlass::L4);
    }

    // crt15 present bank is always 640×480 @ 0x300FF000.
    for (const auto& wh : {std::pair<int, int>{320, 240}, {640, 480}, {1280, 720}}) {
        const auto bank = glassMax(wh.first, wh.second, LiveGlass::Crt15);
        CHECK(bank.width == 640);
        CHECK(bank.height == 480);
        CHECK(std::strcmp(bank.label, "480p") == 0);
        CHECK(presentBankDoorbell(bank.width, bank.height) == kPlex480pYuv420pDoorbellPhys);
        CHECK(presentBankDoorbell(bank.width, bank.height) == 0x300FF000u);
    }

    const auto t480_240 = glassMax(320, 240, LiveGlass::True480);
    CHECK(t480_240.width == 320);
    CHECK(t480_240.height == 240);
    CHECK(presentBankDoorbell(t480_240.width, t480_240.height) == 0x3007F000u);
    CHECK(presentBankDoorbell(320, 240) != 0x300FF000u);

    const auto l4 = glassMax(320, 240, LiveGlass::L4);
    CHECK(l4.width == 1280);
    CHECK(l4.height == 720);

    // clampDisplayToLiveGlass: 240p stays label 240p; 720p→480i; never 320×240.
    const ContentResolution osd240{320, 240, "240p", 1000};
    const ContentResolution osd720{1280, 720, "720p", 20000};
    const ContentResolution osd480{640, 480, "480p", 2500};
    {
        const auto d = clampDisplayToLiveGlass(osd240, LiveGlass::Crt15);
        CHECK(std::strcmp(d.label, "240p") == 0);
        CHECK(d.width == 640);
        CHECK(d.height == 480);
        CHECK(presentBankDoorbell(d.width, d.height) == 0x300FF000u);
        CHECK(d.width != 320);
        CHECK(d.height != 240);
    }
    {
        const auto d = clampDisplayToLiveGlass(osd720, LiveGlass::Crt15);
        CHECK(std::strcmp(d.label, "480i") == 0);
        CHECK(d.width == 640);
        CHECK(d.height == 480);
        CHECK(presentBankDoorbell(d.width, d.height) == 0x300FF000u);
    }
    {
        const auto d = clampDisplayToLiveGlass(osd480, LiveGlass::Crt15);
        CHECK(std::strcmp(d.label, "480p") == 0);
        CHECK(d.width == 640);
        CHECK(d.height == 480);
    }
    {
        const auto id = clampDisplayToLiveGlass(osd240, LiveGlass::True480);
        CHECK(id.width == 320);
        CHECK(std::strcmp(id.label, "240p") == 0);
    }

    char glassTmpl[] = "/tmp/misterplex-glass-XXXXXX";
    const int gfd = ::mkstemp(glassTmpl);
    CHECK(gfd >= 0);
    if (gfd >= 0) {
        const char txt[] = "crt15\n";
        CHECK(::write(gfd, txt, sizeof(txt) - 1) == static_cast<ssize_t>(sizeof(txt) - 1));
        ::close(gfd);
        const auto pin = readLiveGlassPin("/dev/null", "/dev/null", "/dev/null", glassTmpl);
        CHECK(pinTextEquals(pin.glass, "crt15"));
        CHECK(classifyLiveGlassPin(pin) == LiveGlass::Crt15);
        ::unlink(glassTmpl);
    }

    char liveTmpl[] = "/tmp/misterplex-live-glass-XXXXXX";
    const int lfd = ::mkstemp(liveTmpl);
    CHECK(lfd >= 0);
    if (lfd >= 0) {
        const char txt[] = "crt240p15\n";
        CHECK(::write(lfd, txt, sizeof(txt) - 1) == static_cast<ssize_t>(sizeof(txt) - 1));
        ::close(lfd);
        const auto pin = readLiveGlassPin("/dev/null", "/dev/null", "/dev/null", liveTmpl);
        CHECK(pinTextEquals(pin.glass, "crt240p15"));
        CHECK(classifyLiveGlassPin(pin) == LiveGlass::Crt15);
        ::unlink(liveTmpl);
    }

    char live480[] = "/tmp/misterplex-live-glass-XXXXXX";
    const int lfd2 = ::mkstemp(live480);
    CHECK(lfd2 >= 0);
    if (lfd2 >= 0) {
        const char txt[] = "crt480i\n";
        CHECK(::write(lfd2, txt, sizeof(txt) - 1) == static_cast<ssize_t>(sizeof(txt) - 1));
        ::close(lfd2);
        const auto pin = readLiveGlassPin("/dev/null", "/dev/null", "/dev/null", live480);
        CHECK(pinTextEquals(pin.glass, "crt480i"));
        CHECK(classifyLiveGlassPin(pin) == LiveGlass::Crt15);
        ::unlink(live480);
    }

    char liveFb[] = "/tmp/misterplex-live-glass-XXXXXX";
    const int lfd3 = ::mkstemp(liveFb);
    CHECK(lfd3 >= 0);
    if (lfd3 >= 0) {
        const char txt[] = "crt480i\n";
        CHECK(::write(lfd3, txt, sizeof(txt) - 1) == static_cast<ssize_t>(sizeof(txt) - 1));
        ::close(lfd3);
        const auto pin = readLiveGlassPin("/dev/null", "/dev/null", "/dev/null",
                                          "/no-such-misterplex-glass", liveFb);
        CHECK(pinTextEquals(pin.glass, "crt480i"));
        CHECK(classifyLiveGlassPin(pin) == LiveGlass::Crt15);
        ::unlink(liveFb);
    }

    if (fails) {
        std::fprintf(stderr, "test_present_bank: %d FAILURES\n", fails);
        return 1;
    }
    std::printf("test_present_bank: OK\n");
    return 0;
}
