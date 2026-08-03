// plex_chrome_ddr_loader host model + PLXC seqlock gates.
#include "libmisterplex/plex_chrome_ddr_loader.hpp"
#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/plex_chrome_cmds.hpp"

#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
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
    const uint64_t cmds[2] = {g0, g1};
    misterplex::plex_chrome_ddr::hostPublishSeqlock(mem.data(), cmds, 2, true, 3);
    CHECK(misterplex::plex_chrome_ddr::stepLoad(m, mem.data(), false, true, 1280, 720, 3));
    CHECK(m.cnt_loads == 1);
    CHECK(m.beats.size() == 3);
    CHECK(m.beats[0].addr == 0 && m.beats[0].data == g0);
    CHECK(m.beats[1].addr == 1 && m.beats[1].data == g1);
    CHECK(m.beats[2].addr == 0xFF);
    CHECK(m.last_seq == 3);
    CHECK(!misterplex::plex_chrome_ddr::stepLoad(m, mem.data(), false, true, 1280, 720, 3));
    CHECK(m.cnt_loads == 1);
}

static void checkPlxoChromeHwBit() {
    const uint64_t on = misterplex::plex_chrome_ddr::packPlxo(true, 1280, 720, 3);
    const uint64_t off = misterplex::plex_chrome_ddr::packPlxo(false, 1280, 720, 3);
    CHECK(static_cast<uint32_t>(on) == mailbox_abi::kPlxoMagic);
    CHECK(((on >> 32) & 1ull) == 1ull);
    CHECK(((off >> 32) & 1ull) == 0ull);
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
    CHECK(!misterplex::plex_chrome_ddr::stepLoad(m, mem.data(), false, false, 0, 0, 0));
    CHECK(m.cnt_bad == 1);
    CHECK(m.cnt_loads == 0);
}

// Concurrent: body mutates after snapshot → torn, no commit
static void checkTornMidBody() {
    misterplex::plex_chrome_ddr::Model m;
    m.enable = true;
    std::vector<uint64_t> mem(0x200 / 8, 0);
    const uint64_t g0 = misterplex::plex_chrome_cmds::packGlyph(1, 1, 'A');
    const uint64_t g1 = misterplex::plex_chrome_cmds::packGlyph(2, 1, 'B');
    const uint64_t cmds[2] = {g0, g1};
    misterplex::plex_chrome_ddr::hostPublishSeqlock(mem.data(), cmds, 2, true, 9);
    const bool ok = misterplex::plex_chrome_ddr::stepLoad(
        m, mem.data(), false, true, 1280, 720, 3, [&](uint64_t* mm) {
            // Host concurrent update: invalidate + new body + new seq
            mm[mailbox_abi::kPlxcOffset / 8] = 0;
            mm[mailbox_abi::kPlxlOffset / 8] =
                misterplex::plex_chrome_cmds::packGlyph(9, 9, 'Z');
            mm[mailbox_abi::kPlxcOffset / 8] =
                misterplex::plex_chrome_cmds::packPlxcCtrl(true, 1, 10);
        });
    CHECK(!ok);
    CHECK(m.cnt_torn == 1);
    CHECK(m.cnt_loads == 0);
    CHECK(m.last_seq == 0);
    // Stable retry loads seq 10
    CHECK(misterplex::plex_chrome_ddr::stepLoad(m, mem.data(), false, true, 1280, 720, 3));
    CHECK(m.last_seq == 10);
    CHECK(m.beats.size() == 2);
    CHECK(m.beats[0].data == misterplex::plex_chrome_cmds::packGlyph(9, 9, 'Z'));
}

// Reset/retained: last_seq=0, coherent PLXC in mem → one load
static void checkRetainedCoherent() {
    misterplex::plex_chrome_ddr::Model m;
    m.enable = true;
    m.last_seq = 0; // post-reset
    std::vector<uint64_t> mem(0x200 / 8, 0);
    const uint64_t g = misterplex::plex_chrome_cmds::packGlyph(5, 5, 'R');
    misterplex::plex_chrome_ddr::hostPublishSeqlock(mem.data(), &g, 1, true, 42);
    CHECK(misterplex::plex_chrome_ddr::stepLoad(m, mem.data(), false, true, 1280, 720, 3));
    CHECK(m.last_seq == 42);
    CHECK(m.beats[0].data == g);
}

// Retained invalidated: no load
static void checkRetainedInvalid() {
    misterplex::plex_chrome_ddr::Model m;
    m.enable = true;
    std::vector<uint64_t> mem(0x200 / 8, 0);
    mem[mailbox_abi::kPlxcOffset / 8] = 0;
    mem[mailbox_abi::kPlxlOffset / 8] = misterplex::plex_chrome_cmds::packGlyph(1, 1, 'Q');
    CHECK(!misterplex::plex_chrome_ddr::stepLoad(m, mem.data(), false, false, 0, 0, 0));
    CHECK(m.cnt_loads == 0);
    CHECK(m.cnt_bad >= 1);
}

// ARM source must invalidate magic before body, and publish ctrl hi before magic lo.
// Seqlock body lives in publishPlxcSeqlockToMap; writeChromeCommandList targets bootstrap.
static void checkFpgaSpiSeqlockSource() {
    const char* paths[] = {
        "arm/misterplexd/fpga_spi.cpp",
        "../arm/misterplexd/fpga_spi.cpp",
    };
    std::string src;
    for (const char* path : paths) {
        std::ifstream in(path);
        if (!in)
            continue;
        src.assign(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
        break;
    }
    CHECK(!src.empty());
    const auto helper = src.find("publishPlxcSeqlockToMap");
    CHECK(helper != std::string::npos);
    const auto fn = src.find("bool FpgaSpi::writeChromeCommandList");
    CHECK(fn != std::string::npos);
    const auto end = src.find("bool FpgaSpi::readChromeHwPresent", fn + 10);
    CHECK(end != std::string::npos);
    // Helper precedes writeChrome; scan from helper through write end.
    const std::string body = src.substr(helper, end - helper);
    const auto inv = body.find("cw[0] = 0");
    const auto list = body.find("list[i] = cmds[i]");
    const auto pack = body.find("packPlxcCtrl");
    const auto hi = body.find("cw[1] = static_cast<uint32_t>(ctrl >> 32)");
    const auto lo = body.find("cw[0] = static_cast<uint32_t>(ctrl)");
    CHECK(inv != std::string::npos);
    CHECK(list != std::string::npos);
    CHECK(pack != std::string::npos);
    CHECK(hi != std::string::npos);
    CHECK(lo != std::string::npos);
    CHECK(inv < list);
    CHECK(list < pack);
    CHECK(pack < hi);
    CHECK(hi < lo); // magic LAST
    CHECK(body.find("seqlock") != std::string::npos || body.find("Invalidate") != std::string::npos ||
          body.find("magic LAST") != std::string::npos);
    CHECK(body.find("kDdrFramePlxcBootstrapDoorbellPhys") != std::string::npos);
    CHECK(body.find("bootDoor") != std::string::npos);
}

// Interleave a loader poll after each 32-bit half of ctrl publish.
// Observations that fail under wrong order:
//   PRODUCT hi→magic: poll after hi-only must not load; magic last commits full.
//   FAULT magic→hi with last_seq!=0: poll after magic-only MUST load seq0 empty.
//   Reverse product halves with last_seq!=0 → incomplete-half check fails.
static void checkHalfWordPublishOrder() {
    std::vector<uint64_t> mem(512, 0);
    const uint64_t g = misterplex::plex_chrome_cmds::packGlyph(8, 8, 'H');
    const size_t c = mailbox_abi::kPlxcOffset / 8;
    const size_t base = mailbox_abi::kPlxlOffset / 8;
    auto* cw = reinterpret_cast<uint32_t*>(&mem[c]);

    // --- Product order: hi then magic (baseline last_seq != 0) ---
    {
        misterplex::plex_chrome_ddr::Model m;
        m.enable = true;
        m.last_seq = 50;
        mem[c] = 0;
        mem[base] = g;
        const uint64_t ctrl = misterplex::plex_chrome_cmds::packPlxcCtrl(true, 1, 7);
        cw[1] = static_cast<uint32_t>(ctrl >> 32);
        // Magic still 0: must not accept (observation fails if magic-first).
        CHECK(!misterplex::plex_chrome_ddr::stepLoad(m, mem.data(), false, false, 0, 0, 0));
        CHECK(m.cnt_loads == 0);
        CHECK(m.last_seq == 50);
        cw[0] = static_cast<uint32_t>(ctrl);
        CHECK(misterplex::plex_chrome_ddr::stepLoad(m, mem.data(), false, false, 0, 0, 0));
        CHECK(m.cnt_loads == 1);
        CHECK(m.last_seq == 7);
        CHECK(m.beats.size() >= 1 && m.beats[0].data == g);
    }

    // --- Product mutation (magic first): incomplete half MUST wrong-commit ---
    {
        misterplex::plex_chrome_ddr::Model m;
        m.enable = true;
        m.last_seq = 50;
        mem[c] = 0;
        mem[base] = g;
        const uint64_t ctrl = misterplex::plex_chrome_cmds::packPlxcCtrl(true, 1, 7);
        cw[0] = static_cast<uint32_t>(ctrl); // magic FIRST, hi=0
        CHECK(misterplex::plex_chrome_ddr::stepLoad(m, mem.data(), false, false, 0, 0, 0));
        CHECK(m.cnt_loads == 1);
        CHECK(m.last_seq == 0); // empty/wrong ctrl — gate goes red vs product stay@50
        std::fprintf(stderr, "host halfword mutation wrong_accept seq0 PASS\n");
    }

    // --- FAULT magic-first with nonzero seed: require seq0 wrong accept ---
    {
        misterplex::plex_chrome_ddr::Model m;
        m.enable = true;
        m.last_seq = 77;
        mem[c] = 0;
        mem[base] = g;
        const uint64_t ctrl = misterplex::plex_chrome_cmds::packPlxcCtrl(true, 1, 9);
        cw[0] = static_cast<uint32_t>(ctrl); // magic first, hi still 0
        CHECK(misterplex::plex_chrome_ddr::stepLoad(m, mem.data(), false, false, 0, 0, 0));
        CHECK(m.cnt_loads == 1);
        CHECK(m.last_seq == 0);
        cw[1] = static_cast<uint32_t>(ctrl >> 32);
        CHECK(misterplex::plex_chrome_ddr::stepLoad(m, mem.data(), false, false, 0, 0, 0));
        CHECK(m.last_seq == 9);
        std::fprintf(stderr, "host halfword_magic_first wrong_accept=1 PASS\n");
    }
}


// Fabric bootstrap door is product YUV — never packed-320 example, never Option-C alone.
static void checkPlxcBootstrapDoor() {
    CHECK(mailbox_abi::kProductYuv480pDoorbellPhys == 0x300FF000u);
    CHECK(mailbox_abi::kPacked320ExampleDoorbellPhys == 0x3007F000u);
    CHECK(mailbox_abi::kOptionC720pDoorbellPhys == 0x3047F000u);
    CHECK(mailbox_abi::kProductYuv480pDoorbellPhys !=
          mailbox_abi::kPacked320ExampleDoorbellPhys);
    CHECK(misterplex::kDdrFramePlxcBootstrapDoorbellPhys == 0x300FF000u);
    CHECK(misterplex::kDdrFramePlxcBootstrapPhys == 0x300FF130u);
    CHECK(misterplex::plex_chrome_ddr::kDoor == mailbox_abi::kProductYuv480pDoorbellPhys);
    // Offsets identical across maps; only base moves.
    CHECK(mailbox_abi::frameStoreMailboxPhys(mailbox_abi::kProductYuv480pDoorbellPhys,
                                             mailbox_abi::kPlxcOffset) == 0x300FF130u);
    CHECK(mailbox_abi::frameStoreMailboxPhys(mailbox_abi::kOptionC720pDoorbellPhys,
                                             mailbox_abi::kPlxcOffset) == 0x3047F130u);
    CHECK(mailbox_abi::frameStoreMailboxPhys(mailbox_abi::kPacked320ExampleDoorbellPhys,
                                             mailbox_abi::kPlxcOffset) == 0x3007F130u);
    // Loader must not default-poll packed-320 or Option-C without override.
    std::ifstream ldr("fpga/Plex_MiSTer/rtl/plex_chrome_ddr_loader.sv");
    if (!ldr)
        ldr.open("../fpga/Plex_MiSTer/rtl/plex_chrome_ddr_loader.sv");
    CHECK(ldr.good());
    std::string src((std::istreambuf_iterator<char>(ldr)), std::istreambuf_iterator<char>());
    CHECK(src.find("DOORBELL_PHYS  = 32'h300F_F000") != std::string::npos ||
          src.find("DOORBELL_PHYS = 32'h300F_F000") != std::string::npos);
    CHECK(src.find("parameter [31:0]     DOORBELL_PHYS  = 32'h3007_F000") == std::string::npos);
    std::ifstream plex("fpga/Plex_MiSTer/Plex.sv");
    if (!plex)
        plex.open("../fpga/Plex_MiSTer/Plex.sv");
    CHECK(plex.good());
    std::string ps((std::istreambuf_iterator<char>(plex)), std::istreambuf_iterator<char>());
    const auto inst = ps.find("u_plxc_ddr_loader");
    CHECK(inst != std::string::npos);
    const auto params = ps.rfind("plex_chrome_ddr_loader", inst);
    CHECK(params != std::string::npos);
    const std::string block = ps.substr(params, inst - params + 20);
    CHECK(block.find("300F_F000") != std::string::npos);
    CHECK(block.find("3007_F000") == std::string::npos);
    // ARM must name bootstrap door in write path.
    std::ifstream spi("arm/misterplexd/fpga_spi.cpp");
    if (!spi)
        spi.open("../arm/misterplexd/fpga_spi.cpp");
    CHECK(spi.good());
    std::string ss((std::istreambuf_iterator<char>(spi)), std::istreambuf_iterator<char>());
    const auto fn = ss.find("bool FpgaSpi::writeChromeCommandList");
    CHECK(fn != std::string::npos);
    const auto end = ss.find("bool FpgaSpi::readChromeHwPresent", fn + 10);
    CHECK(end != std::string::npos);
    const std::string body = ss.substr(fn, end - fn);
    CHECK(body.find("kDdrFramePlxcBootstrapDoorbellPhys") != std::string::npos ||
          body.find("kProductYuv480pDoorbellPhys") != std::string::npos);
    CHECK(body.find("bootDoor") != std::string::npos ||
          body.find("bootstrap") != std::string::npos);
    std::fprintf(stderr, "plxc bootstrap door product+mirror gate PASS\n");
}

int main() {
    checkEnableOffQuiet();
    checkLoadListThenCtrl();
    checkPlxoChromeHwBit();
    checkBadMagic();
    checkTornMidBody();
    checkRetainedCoherent();
    checkRetainedInvalid();
    checkFpgaSpiSeqlockSource();
    checkHalfWordPublishOrder();
    checkPlxcBootstrapDoor();
    if (fails) {
        std::fprintf(stderr, "test_plex_chrome_ddr_loader: %d FAIL(s)\n", fails);
        return 1;
    }
    std::fprintf(stderr, "test_plex_chrome_ddr_loader: PASS\n");
    return 0;
}
