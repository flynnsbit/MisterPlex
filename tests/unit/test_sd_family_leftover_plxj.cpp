// L8 red twin: leftover L4 PLXJ (0x504C584A @ 0x3047F130) must not pin 720p
// when the live RBF is Plex_480p / Plex_240p15 / Plex_480i, or when 480p
// PLXD is changing.
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
    CHECK(mailbox_abi::kPlxjAddr == 0x3007F130u);
    CHECK(mailbox_abi::kPlxhAddr == 0x3007F138u);
    CHECK(mailbox_abi::kPlxhMagic == 0x504C5848u);
    CHECK(mailbox_abi::kPlxjAddr + 8u == mailbox_abi::kPlxhAddr);
    CHECK(mailbox_abi::kL4LeftoverPlxjAddr == 0x3047F130u);
    CHECK(mailbox_abi::leftoverL4PlxjMustNotSatisfyAck(mailbox_abi::kPlxjAddr));
    CHECK(!mailbox_abi::leftoverL4PlxjMustNotSatisfyAck(mailbox_abi::kL4LeftoverPlxjAddr));

    // Product 640×480 doorbell 0x300FF000 must still ACK at 0x3007F130.
    CHECK(mailbox_abi::productMailboxPhys(0x300FF000u, mailbox_abi::kPlxjAddr) ==
          mailbox_abi::kPlxjAddr);
    CHECK(mailbox_abi::productMailboxPhys(0x3007F000u, mailbox_abi::kPlxjAddr) ==
          mailbox_abi::kPlxjAddr);
    CHECK(mailbox_abi::productMailboxPhys(0x300FF000u, mailbox_abi::kPlxhAddr) ==
          mailbox_abi::kPlxhAddr);
    CHECK(mailbox_abi::productMailboxPhys(mailbox_abi::kL4DoorbellPhys, mailbox_abi::kPlxjAddr) ==
          mailbox_abi::kL4LeftoverPlxjAddr);
    CHECK(0x300FF000u + 0x130u != mailbox_abi::kPlxjAddr);

    LiveGlassPin pin;
    pin.core = "Plex";

    pin.rbfname = "Plex_480p";
    CHECK(corroborateLiveGlass(mailbox_abi::kPlxjMagic, pin) == LiveGlass::True480);
    pin.rbfname = "Plex_240p15";
    CHECK(corroborateLiveGlass(mailbox_abi::kPlxjMagic, pin) == LiveGlass::True480);
    pin.rbfname = "Plex_480i";
    CHECK(corroborateLiveGlass(mailbox_abi::kPlxjMagic, pin) == LiveGlass::True480);

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
