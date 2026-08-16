#include "libmisterplex/hdmi_auto_delay.hpp"

#include <cstdio>
#include <cstring>

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

    CHECK(std::strcmp(hdmiDelaySourceClass(1280, 720), "native1280") == 0);
    CHECK(std::strcmp(hdmiDelaySourceClass(320, 240), "upscale240") == 0);
    CHECK(std::strcmp(hdmiDelaySourceClass(640, 480), "upscale480") == 0);
    CHECK(std::strcmp(hdmiDelaySourceClass(1440, 1080), "downscale720") == 0);
    CHECK(std::strcmp(hdmiDelaySourceClass(0, 0), "unknown") == 0);

    CHECK(hdmiNativeAfterVideoMs("720p") == 106);
    CHECK(hdmiNativeAfterVideoMs("480p") == 137);
    CHECK(hdmiNativeAfterVideoMs("240p") == 137);
    CHECK(hdmiNativeHoldSlackMs("720p") == -110);
    CHECK(hdmiNativeHoldSlackMs("480p") == -5);
    CHECK(hdmiNativeHoldSlackMs("240p") == -170);

    const auto n720 = hdmiAutoDelayForPlay("720p", 1280, 720);
    CHECK(n720.afterVideoMs == 106);
    CHECK(n720.holdSlackMs == -110);
    CHECK(std::strcmp(n720.path, "native1280_disp720") == 0);

    const auto n480 = hdmiAutoDelayForPlay("480p", 1280, 720);
    CHECK(n480.afterVideoMs == 137);
    CHECK(n480.holdSlackMs == -5);
    CHECK(std::strcmp(n480.path, "native1280_disp480") == 0);

    const auto n240 = hdmiAutoDelayForPlay("240p", 1280, 720);
    CHECK(n240.afterVideoMs == 137);
    CHECK(n240.holdSlackMs == -170);
    CHECK(std::strcmp(n240.path, "native1280_disp240") == 0);

    const auto u240 = hdmiAutoDelayForPlay("720p", 320, 240);
    CHECK(u240.afterVideoMs == 353);
    CHECK(u240.holdSlackMs == -218);
    CHECK(std::strcmp(u240.path, "upscale240") == 0);

    const auto u480 = hdmiAutoDelayForPlay("720p", 640, 480);
    CHECK(u480.afterVideoMs == 240);
    CHECK(u480.holdSlackMs == -105);
    CHECK(std::strcmp(u480.path, "upscale480") == 0);

    const auto far = hdmiAutoDelayForPlay("720p", 1440, 1080);
    CHECK(far.afterVideoMs == 106);
    CHECK(far.holdSlackMs == -110);
    CHECK(std::strcmp(far.path, "downscale720_disp720") == 0);

    CHECK(hdmiAutoAfterVideoMs(n720, -1) == 106);
    CHECK(hdmiAutoAfterVideoMs(n720, 0) == 106);
    CHECK(hdmiAutoAfterVideoMs(n720, 145) == 145);

    if (fails) {
        std::fprintf(stderr, "test_hdmi_auto_delay: %d FAILURES\n", fails);
        return 1;
    }
    std::printf("test_hdmi_auto_delay: OK\n");
    return 0;
}
