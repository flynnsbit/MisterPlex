// plex_chrome_ddr_loader host model + PLXO pack gates.
#include "libmisterplex/plex_chrome_ddr_loader.hpp"
#include "libmisterplex/plex_chrome_cmds.hpp"

#include <cstdio>
#include <cstring>
#include <vector>

static int fails = 0;
#define CHECK(c)                                                                                 \
    do {                                                                                         \
        if (!(c)) {                                                                              \
            std::fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #c);                    \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

static void checkEnableOffQuiet() {
    misterplex::plex_chrome_ddr::Model m;
    m.enable = false;
    std::vector<uint64_t> mem(0x200 / 8, 0);
    mem[mailbox_abi::kPlxcOffset / 8] =
        misterplex::plex_chrome_cmds::packPlxcCtrl(true, 1, 7);
    mem[mailbox_abi::kPlxlOffset / 8] =
        misterplex::plex_chrome_cmds::packGlyph(10, 20, 'A');
    misterplex::plex_chrome_ddr::stepLoad(m, mem.data(), true, true, 1280, 720, 3);
    CHECK(misterplex::plex_chrome_ddr::enableOffIsQuiet(m));
    CHECK(m.cnt_loads == 0);
    CHECK(m.cnt_plxo == 0);
    CHECK(mem[mailbox_abi::kPlxoOffset / 8] == 0);
}

static void checkLoadListThenCtrl() {
    misterplex::plex_chrome_ddr::Model m;
    m.enable = true;
    std::vector<uint64_t> mem(0x200 / 8, 0);
    const uint64_t g0 = misterplex::plex_chrome_cmds::packGlyph(64, 64, '#');
    const uint64_t g1 = misterplex::plex_chrome_cmds::packGlyph(80, 64, '!');
    mem[mailbox_abi::kPlxlOffset / 8 + 0] = g0;
    mem[mailbox_abi::kPlxlOffset / 8 + 1] = g1;
    mem[mailbox_abi::kPlxcOffset / 8] =
        misterplex::plex_chrome_cmds::packPlxcCtrl(true, 2, 3);
    misterplex::plex_chrome_ddr::stepLoad(m, mem.data(), false, true, 1280, 720, 3);
    CHECK(m.cnt_loads == 1);
    CHECK(m.beats.size() == 3);
    CHECK(m.beats[0].addr == 0 && m.beats[0].data == g0);
    CHECK(m.beats[1].addr == 1 && m.beats[1].data == g1);
    CHECK(m.beats[2].addr == 0xFF);
    CHECK(m.last_seq == 3);
    // Same seq → no reload
    misterplex::plex_chrome_ddr::stepLoad(m, mem.data(), false, true, 1280, 720, 3);
    CHECK(m.cnt_loads == 1);
}

static void checkPlxoChromeHwBit() {
    const uint64_t on = misterplex::plex_chrome_ddr::packPlxo(true, 1280, 720, 3);
    const uint64_t off = misterplex::plex_chrome_ddr::packPlxo(false, 1280, 720, 3);
    CHECK(static_cast<uint32_t>(on) == mailbox_abi::kPlxoMagic);
    CHECK(((on >> 32) & 1ull) == 1ull);
    CHECK(((off >> 32) & 1ull) == 0ull);
    // Matches ARM readChromeHwPresent: hi bit0
    CHECK((static_cast<uint32_t>(on >> 32) & 0x1u) != 0);
    CHECK((static_cast<uint32_t>(off >> 32) & 0x1u) == 0);
    CHECK(((on >> 33) & 0xFFFu) == 1280);
    CHECK(((on >> 45) & 0xFFFu) == 720);
    CHECK(((on >> 57) & 0xFu) == 3);
}

static void checkBadMagic() {
    misterplex::plex_chrome_ddr::Model m;
    m.enable = true;
    std::vector<uint64_t> mem(0x200 / 8, 0);
    mem[mailbox_abi::kPlxcOffset / 8] = 0xDEADBEEF;
    misterplex::plex_chrome_ddr::stepLoad(m, mem.data(), false, false, 0, 0, 0);
    CHECK(m.cnt_bad == 1);
    CHECK(m.cnt_loads == 0);
}

int main() {
    checkEnableOffQuiet();
    checkLoadListThenCtrl();
    checkPlxoChromeHwBit();
    checkBadMagic();
    if (fails) {
        std::fprintf(stderr, "test_plex_chrome_ddr_loader: %d FAIL(s)\n", fails);
        return 1;
    }
    std::fprintf(stderr, "test_plex_chrome_ddr_loader: PASS\n");
    return 0;
}
