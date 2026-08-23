// L8 red twin: leftover L4 PLXJ (0x504C584A @ 0x3047F130) must not pin 720p
// when the live RBF is Plex_480p / Plex_240p15 / Plex_480i / Plex_SDfamily,
// or when 480p PLXD is changing.
#include "libmisterplex/mailbox_abi_spec.hpp"
#include "libmisterplex/present_bank.hpp"

#include <cstdio>
#include <string>

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

    CHECK(mailbox_abi::kPlxjMagic == 0x504C584Au);

    LiveGlassPin pin;
    pin.core = "Plex";

    pin.rbfname = "Plex_480p";
    CHECK(corroborateLiveGlass(mailbox_abi::kPlxjMagic, pin) == LiveGlass::True480);
    pin.rbfname = "Plex_240p15";
    CHECK(corroborateLiveGlass(mailbox_abi::kPlxjMagic, pin) == LiveGlass::True480);
    pin.rbfname = "Plex_480i";
    CHECK(corroborateLiveGlass(mailbox_abi::kPlxjMagic, pin) == LiveGlass::True480);

    pin.rbfname = "Plex_SDfamily";
    CHECK(corroborateLiveGlass(mailbox_abi::kPlxjMagic, pin) == LiveGlass::True480);
    CHECK(classifyLoadedRbfName("Plex_SDfamily.rbf") == LoadedRbfClass::SdFamily);

    pin.rbfname = "Plex_720p24";
    CHECK(corroborateLiveGlass(mailbox_abi::kPlxjMagic, pin) == LiveGlass::L4);

    CHECK(decideLiveGlassFromProbes(true, false, false, true) == LiveGlass::True480);
    CHECK(decideLiveGlassFromProbes(true, false, true, true) == LiveGlass::True480);

    CHECK(rbfPinBasename("/media/fat/_Utility/Plex_480p.rbf") == "Plex_480p");
    CHECK(rbfPinBasename("Plex_240p15.RBF") == "Plex_240p15");
    CHECK(rbfPinBasename("Plex_480i.rbf") == "Plex_480i");

    if (fails) {
        std::fprintf(stderr, "test_sd_family_leftover_plxj: %d failure(s)\n", fails);
        return 1;
    }
    std::printf("test_sd_family_leftover_plxj: OK\n");
    return 0;
}
