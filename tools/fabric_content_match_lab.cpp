// fabric_content_match_lab — RESEARCH-ONLY device lab harness.
//
// Proves (or offline-mocks) fabric offload content_match:
//   fill Rank2 staging 0x30601000 → programFabricKick → wait PLXH →
//   memcmp/CRC bank vs staging.
//
// SoT: DESIGN_CARD_FABRIC_DEVICE_CONTENT_MATCH_R2
//      fabric_dma_host.hpp / fabric_src_staging.hpp / fabric_src_phys.hpp
//
// SAFETY / GATES:
//   - Requires MISTERPLEX_FABRIC_DMA=1 OR --force-lab (fail closed)
//   - Default: NEVER rings PLXK (caller-owned; --ring-plxk opt-in, default OFF)
//   - kDdrPublishFabricPathEnabledInProduct must remain false (asserted)
//   - NO product sendDdrFrame wire; NO claim 720/visual
//   - --mock: offline CI path using MockFabricKickMem + heap bank/staging
//
// Device phys (product doorbell / Rank2 OPT-A):
//   doorbell 0x302FF000, staging 0x30601000, bank0 0x30000000, bank1 0x30180000
//
// Exit: 0 only on full content_match success; nonzero otherwise.
//
// Usage (device, parent-only after research RBF load — this tool does NOT load RBF):
//   MISTERPLEX_FABRIC_DMA=1 ./fabric_content_match_lab --len 4096 --bank 0
//   MISTERPLEX_FABRIC_DMA=1 ./fabric_content_match_lab --len 65536 --bank 1
// Offline smoke:
//   ./fabric_content_match_lab --mock --len 4096

#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/ddr_zero_copy_ingest.hpp"
#include "libmisterplex/fabric_dma_host.hpp"
#include "libmisterplex/fabric_src_phys.hpp"
#include "libmisterplex/fabric_src_staging.hpp"
#include "libmisterplex/mailbox_abi_spec.hpp"

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <string>
#include <sys/mman.h>
#include <unistd.h>
#include <vector>

namespace {

using misterplex::FabricDmaJob;
using misterplex::FabricKickHostState;
using misterplex::FabricKickWaitResult;
using misterplex::FabricStartMode;
using misterplex::MockFabricKickMem;
using misterplex::VolatileFabricKickMem;
using misterplex::fabricKickWaitResultName;
using misterplex::fabricResearchPathEnvEnabled;
using misterplex::fillStagingFromPayloadEx;
using misterplex::kDdrPublishFabricPathEnabledInProduct;
using misterplex::kPlex720pYuv420pBankStride;
using misterplex::kPlex720pYuv420pDoorbellPhys;
using misterplex::programFabricKick;
using misterplex::stagingPhysBase;
using misterplex::stagingRegionBytes;
using misterplex::waitFabricKickDone;
using misterplex::StagingFillResult;
using misterplex::stagingFillResultName;

// IEEE CRC-32 (poly 0xEDB88320), init 0xFFFFFFFF, final xor 0xFFFFFFFF.
uint32_t crc32(const uint8_t* data, size_t n) {
    uint32_t c = 0xFFFFFFFFu;
    for (size_t i = 0; i < n; ++i) {
        c ^= data[i];
        for (int b = 0; b < 8; ++b)
            c = (c >> 1) ^ (0xEDB88320u & (uint32_t)-(int32_t)(c & 1u));
    }
    return c ^ 0xFFFFFFFFu;
}

void fillPattern(uint8_t* p, size_t n) {
    // Same style as ddr_pl330_ingest_bench fill + unique header so idle banks
    // cannot accidental-match.
    for (size_t i = 0; i < n; ++i)
        p[i] = static_cast<uint8_t>((i * 131u) ^ 0x5Au);
    if (n >= 4) {
        p[0] = 0xFAu;
        p[1] = 0xB0u;
        p[2] = 0xCCu;
        p[3] = 0x11u;
    }
}

struct MapWin {
    int fd = -1;
    void* map = MAP_FAILED;
    size_t map_len = 0;
    uint32_t map_phys = 0;

    uint8_t* ptrAt(uint32_t phys) const {
        if (map == MAP_FAILED || phys < map_phys)
            return nullptr;
        const uint64_t off = static_cast<uint64_t>(phys) - map_phys;
        if (off >= map_len)
            return nullptr;
        return static_cast<uint8_t*>(map) + static_cast<size_t>(off);
    }

    void close() {
        if (map != MAP_FAILED) {
            ::munmap(map, map_len);
            map = MAP_FAILED;
        }
        if (fd >= 0) {
            ::close(fd);
            fd = -1;
        }
    }
};

// Map window covering [phys, phys+need). O_RDWR|O_SYNC like pl330 bench.
bool mapWindow(MapWin& w, uint32_t phys, size_t need, std::string* err) {
    w.close();
    const uint32_t page = phys & ~0xFFFu;
    const size_t off = static_cast<size_t>(phys - page);
    const size_t map_need = off + need;
    size_t map_len = (map_need + 0xFFFu) & ~static_cast<size_t>(0xFFFu);
    // Prefer 4 MiB windows inside reserved HPS DDR window (bench pattern).
    if (map_len < 0x400000u && phys >= 0x30000000u && phys < 0x31000000u)
        map_len = 0x400000u;
    w.fd = ::open("/dev/mem", O_RDWR | O_SYNC | O_CLOEXEC);
    if (w.fd < 0) {
        if (err)
            *err = "open /dev/mem failed";
        return false;
    }
    w.map = ::mmap(nullptr, map_len, PROT_READ | PROT_WRITE, MAP_SHARED, w.fd,
                   static_cast<off_t>(page));
    if (w.map == MAP_FAILED) {
        ::close(w.fd);
        w.fd = -1;
        if (err)
            *err = "mmap failed";
        return false;
    }
    w.map_len = map_len;
    w.map_phys = page;
    return true;
}

double contentMatchFrac(const uint8_t* a, const uint8_t* b, size_t n) {
    if (n == 0)
        return 0.0;
    size_t match = 0;
    for (size_t i = 0; i < n; ++i) {
        if (a[i] == b[i])
            ++match;
    }
    return static_cast<double>(match) / static_cast<double>(n);
}

// Raw doorbell fabric-block snapshot for lab RCA (read-only).
// Dumps +0x140..+0x15c and observes +0x000 PLXK only (never writes PLXK here).
static void dumpHexHead(const char* tag, const uint8_t* p, size_t n) {
    std::printf("SCORE hex_head %s n=%zu:", tag, n);
    for (size_t i = 0; i < n; ++i)
        std::printf(" %02x", p[i]);
    std::printf("\n");
}

void dumpDoorbellWords(const misterplex::FabricKickMemIo& io, const char* phase) {
    const uint32_t plxg_lo = io.read32(0x140u);
    const uint32_t plxg_hi = io.read32(0x144u);
    const uint32_t src = io.read32(0x148u);
    const uint32_t bank = io.read32(0x14cu);
    const uint32_t len = io.read32(0x150u);
    const uint32_t pad = io.read32(0x154u);
    const uint32_t plxh_lo = io.read32(0x158u);
    const uint32_t plxh_hi = io.read32(0x15cu);
    const uint32_t plxk_lo = io.read32(0x000u); // observe only; no write
    std::printf("SCORE doorbell_dump phase=%s\n", phase);
    std::printf("dump_off_140_plxg_lo=0x%08x\n", plxg_lo);
    std::printf("dump_off_144_plxg_hi=0x%08x\n", plxg_hi);
    std::printf("dump_off_148_src_phys=0x%08x\n", src);
    std::printf("dump_off_14c_bank_phys=0x%08x\n", bank);
    std::printf("dump_off_150_frame_bytes=0x%08x\n", len);
    std::printf("dump_off_154_pad=0x%08x\n", pad);
    std::printf("dump_plxh_lo=0x%08x\n", plxh_lo);
    std::printf("dump_plxh_hi=0x%08x\n", plxh_hi);
    std::printf("dump_off_000_plxk_lo=0x%08x (observe_only no_write)\n", plxk_lo);
}

void printScore(const char* mode, FabricKickWaitResult wait_r, double wait_us,
                double match_frac, uint32_t crc_s, uint32_t crc_b, bool full_match,
                uint32_t frame_bytes, uint32_t bank_phys, uint32_t src_phys,
                uint16_t cmd_seq, bool ring_plxk, bool product_flag) {
    std::printf("SCORE mode=%s\n", mode);
    std::printf("PLXH_result=%s\n", fabricKickWaitResultName(wait_r));
    std::printf("wait_us=%.1f\n", wait_us);
    std::printf("content_match_frac=%.6f\n", match_frac);
    std::printf("content_match_full=%d\n", full_match ? 1 : 0);
    std::printf("crc32_staging=0x%08x crc32_bank=0x%08x\n", crc_s, crc_b);
    std::printf("frame_bytes=%u src_phys=0x%08x bank_phys=0x%08x cmd_seq=0x%04x\n",
                frame_bytes, src_phys, bank_phys, cmd_seq);
    std::printf("ring_plxk=%d (default OFF; caller-owned after PLXH done)\n",
                ring_plxk ? 1 : 0);
    std::printf("CLAIM_720=NO\n");
    std::printf("PRODUCT_FABRIC=%s\n", product_flag ? "ON" : "OFF");
    std::printf("FIT_GO=NO G-DEVICE=parent_only RESEARCH_LAB=1\n");
}

void usage() {
    std::printf(
        "fabric_content_match_lab — RESEARCH fabric offload content_match\n"
        "\n"
        "Gate (fail closed): MISTERPLEX_FABRIC_DMA=1  OR  --force-lab\n"
        "Default: does NOT ring PLXK (present doorbell). Opt-in: --ring-plxk\n"
        "Product fabric flag must stay OFF (asserted at runtime).\n"
        "\n"
        "Options:\n"
        "  --len N          frame_bytes (default 4096; 8B aligned; max staging)\n"
        "  --bank 0|1       bank0=0x30000000 bank1=0x30180000 (default 0)\n"
        "  --bank-phys 0x.. override bank phys\n"
        "  --cmd-seq N      PLXG cmd_seq (default 0x00C1)\n"
        "  --polls N        waitFabricKickDone max polls (default 100000)\n"
        "  --start-w        use StartW instead of Toggle\n"
        "  --force-lab      allow run without MISTERPLEX_FABRIC_DMA=1\n"
        "  --mock           offline CI: MockFabricKickMem + heap bank/staging\n"
        "  --ring-plxk      FORBIDDEN default; optional present ring AFTER done\n"
        "  --help\n"
        "\n"
        "Exit codes:\n"
        "  0  full content_match (PLXH Success + bank==staging)\n"
        "  1  PLXH fail and/or content mismatch\n"
        "  2  gate closed / bad args / product flag ON\n"
        "  3  mmap /dev/mem or map failure\n"
        "\n"
        "Device (parent only; tool does NOT load RBF):\n"
        "  MISTERPLEX_FABRIC_DMA=1 ./fabric_content_match_lab --len 4096 --bank 0\n"
        "Offline:\n"
        "  ./fabric_content_match_lab --mock --len 4096\n");
}

// Minimal PLXK present ring for opt-in lab only (NOT default).
// Writes PLXK magic+hi at doorbell base +0x000 — never called unless --ring-plxk.
void ringPlxkPresent(VolatileFabricKickMem& io, uint32_t bank_index) {
    // Keep deliberately minimal; product kickDdrDoorbell is richer. Lab opt-in only.
    io.write32(0x000u, mailbox_abi::kPlxkMagic);
    io.write32(0x004u, bank_index & 1u);
    io.barrier();
}

} // namespace

int main(int argc, char** argv) {
    uint32_t frame_bytes = 4096u;
    int bank = 0;
    uint32_t bank_phys_override = 0;
    uint16_t cmd_seq = 0x00C1u;
    unsigned max_polls = 100000u;
    FabricStartMode start_mode = FabricStartMode::Toggle;
    bool force_lab = false;
    bool mock = false;
    bool ring_plxk = false;

    for (int i = 1; i < argc; ++i) {
        const std::string a = argv[i];
        if (a == "--help" || a == "-h") {
            usage();
            return 0;
        } else if (a == "--len" && i + 1 < argc) {
            frame_bytes = static_cast<uint32_t>(std::strtoul(argv[++i], nullptr, 0));
        } else if (a == "--bank" && i + 1 < argc) {
            bank = std::atoi(argv[++i]);
        } else if (a == "--bank-phys" && i + 1 < argc) {
            bank_phys_override =
                static_cast<uint32_t>(std::strtoul(argv[++i], nullptr, 0));
        } else if (a == "--cmd-seq" && i + 1 < argc) {
            cmd_seq = static_cast<uint16_t>(std::strtoul(argv[++i], nullptr, 0));
        } else if (a == "--polls" && i + 1 < argc) {
            max_polls = static_cast<unsigned>(std::strtoul(argv[++i], nullptr, 0));
        } else if (a == "--start-w") {
            start_mode = FabricStartMode::StartW;
        } else if (a == "--force-lab") {
            force_lab = true;
        } else if (a == "--mock") {
            mock = true;
        } else if (a == "--ring-plxk") {
            ring_plxk = true;
        } else {
            std::fprintf(stderr, "unknown arg: %s (try --help)\n", a.c_str());
            return 2;
        }
    }

    // ---- Hard product-flag assert (must stay false in this research land) ----
    if (kDdrPublishFabricPathEnabledInProduct) {
        std::fprintf(stderr,
                     "FATAL: kDdrPublishFabricPathEnabledInProduct is true — "
                     "lab tool refuses (PRODUCT_FABRIC must stay OFF)\n");
        std::printf("CLAIM_720=NO\nPRODUCT_FABRIC=ON\n");
        return 2;
    }

    // ---- Fail-closed gate: env or --force-lab ----
    // --mock still requires gate so CI documents intentional research enable.
    if (!fabricResearchPathEnvEnabled() && !force_lab && !mock) {
        std::fprintf(stderr,
                     "gate closed: set MISTERPLEX_FABRIC_DMA=1 or pass "
                     "--force-lab (or --mock for offline smoke)\n");
        std::printf("CLAIM_720=NO\nPRODUCT_FABRIC=OFF\n");
        return 2;
    }
    // mock implies intentional research; force_lab not required but env preferred.
    if (mock && !fabricResearchPathEnvEnabled() && !force_lab) {
        // Allow --mock alone for CI convenience, but print gate note.
        std::printf("gate_note=mock_mode_without_env (offline CI)\n");
    }

    if (bank != 0 && bank != 1 && bank_phys_override == 0) {
        std::fprintf(stderr, "bad --bank (need 0|1 or --bank-phys)\n");
        return 2;
    }
    if (frame_bytes == 0u || (frame_bytes % 8u) != 0u) {
        std::fprintf(stderr, "frame_bytes must be non-zero 8B-aligned\n");
        return 2;
    }
    if (frame_bytes > stagingRegionBytes()) {
        std::fprintf(stderr, "frame_bytes exceeds staging region (%u)\n",
                     stagingRegionBytes());
        return 2;
    }

    const uint32_t src_phys = stagingPhysBase(); // 0x30601000 Rank2 OPT-A
    const uint32_t bank_phys =
        bank_phys_override
            ? bank_phys_override
            : (misterplex::kDdrFramePhysBase +
               static_cast<uint32_t>(bank) * kPlex720pYuv420pBankStride);
    const uint32_t doorbell_phys = kPlex720pYuv420pDoorbellPhys; // 0x302FF000

    std::printf("fabric_content_match_lab RESEARCH\n");
    std::printf("mode=%s env_fabric_dma=%d force_lab=%d ring_plxk=%d\n",
                mock ? "mock" : "device", fabricResearchPathEnvEnabled() ? 1 : 0,
                force_lab ? 1 : 0, ring_plxk ? 1 : 0);
    std::printf("doorbell_phys=0x%08x src_phys=0x%08x bank_phys=0x%08x "
                "frame_bytes=%u cmd_seq=0x%04x\n",
                doorbell_phys, src_phys, bank_phys, frame_bytes, cmd_seq);
    std::printf("product_flag=%d CLAIM_720=NO PRODUCT_FABRIC=OFF\n",
                kDdrPublishFabricPathEnabledInProduct ? 1 : 0);

    FabricDmaJob job;
    job.src_phys = src_phys;
    job.bank_phys = bank_phys;
    job.frame_bytes = frame_bytes;
    job.bank_sel = (bank != 0);
    job.use_bank_sel = false; // R2 bankphys path: explicit BANK_PHYS
    // R9/R10: fixed 0x00c1 + sticky done_seq can false-Success without new COPY.
    // If caller did not pass --cmd-seq, derive a unique seq from time.
    if (cmd_seq == 0x00c1u) {
        const auto ns = static_cast<uint16_t>(
            std::chrono::steady_clock::now().time_since_epoch().count() & 0xffffu);
        if (ns != 0)
            cmd_seq = ns;
        if (cmd_seq == 0x00c1u)
            cmd_seq = 0x00c2u;
    }
    job.cmd_seq = cmd_seq;
    std::printf("SCORE cmd_seq_effective=0x%04x use_bank_sel=0 bank_sel=%d\n",
                cmd_seq, job.bank_sel ? 1 : 0);

    FabricKickHostState kick_st;
    FabricKickWaitResult wait_r = FabricKickWaitResult::BadArgs;
    double wait_us = 0.0;
    double match_frac = 0.0;
    uint32_t crc_s = 0;
    uint32_t crc_b = 0;
    bool full_match = false;

    if (mock) {
        // ---- Offline CI: MockFabricKickMem + heap windows ----
        std::vector<uint8_t> staging(frame_bytes, 0);
        std::vector<uint8_t> bank_buf(frame_bytes, 0xA5);
        std::vector<uint8_t> payload(frame_bytes, 0);
        fillPattern(payload.data(), frame_bytes);

        const auto fr = fillStagingFromPayloadEx(staging.data(), payload.data(),
                                                 frame_bytes, frame_bytes);
        if (fr != StagingFillResult::Ok) {
            std::fprintf(stderr, "fillStaging failed: %s\n",
                         stagingFillResultName(fr));
            printScore("mock", FabricKickWaitResult::BadArgs, 0, 0, 0, 0, false,
                       frame_bytes, bank_phys, src_phys, cmd_seq, ring_plxk,
                       false);
            return 1;
        }

        MockFabricKickMem mem;
        if (!programFabricKick(mem, kick_st, job, start_mode)) {
            std::fprintf(stderr, "programFabricKick failed (align/args)\n");
            printScore("mock", FabricKickWaitResult::BadArgs, 0, 0, 0, 0, false,
                       frame_bytes, bank_phys, src_phys, cmd_seq, ring_plxk,
                       false);
            return 1;
        }
        dumpDoorbellWords(mem, "post_program");
        if (mem.wrotePlxk()) {
            std::fprintf(stderr, "FATAL: programFabricKick wrote PLXK\n");
            return 1;
        }

        // Simulate fabric COPY (mock has no silicon): staging → bank, then PLXH done.
        std::memcpy(bank_buf.data(), staging.data(), frame_bytes);
        mailbox_abi::PlxhStatusHi ok;
        ok.busy = false;
        ok.done_sticky = true;
        ok.done_seq = job.cmd_seq;
        ok.accepted = true;
        mem.seedPlxh(mailbox_abi::packPlxhStatusHi(ok));

        const auto t0 = std::chrono::steady_clock::now();
        wait_r = waitFabricKickDone(mem, job.cmd_seq, max_polls);
        const auto t1 = std::chrono::steady_clock::now();
        wait_us = std::chrono::duration<double, std::micro>(t1 - t0).count();
        dumpDoorbellWords(mem, "post_wait");

        if (mem.wrotePlxk()) {
            std::fprintf(stderr, "FATAL: wait path wrote PLXK\n");
            return 1;
        }
        // --ring-plxk is a no-op on mock (no doorbell page); report only.
        if (ring_plxk)
            std::printf("ring_plxk=requested but mock has no PLXK hardware path\n");

        match_frac = contentMatchFrac(staging.data(), bank_buf.data(), frame_bytes);
        full_match = (std::memcmp(staging.data(), bank_buf.data(), frame_bytes) == 0);
        crc_s = crc32(staging.data(), frame_bytes);
        crc_b = crc32(bank_buf.data(), frame_bytes);

        printScore("mock", wait_r, wait_us, match_frac, crc_s, crc_b, full_match,
                   frame_bytes, bank_phys, src_phys, cmd_seq, ring_plxk, false);
        std::printf("mock_plxk_writes=%d\n", mem.wrotePlxk() ? 1 : 0);

        const bool pass =
            (wait_r == FabricKickWaitResult::Success) && full_match && match_frac == 1.0;
        std::printf("fabric_content_match_lab: DONE true_rc=%d\n", pass ? 0 : 1);
        return pass ? 0 : 1;
    }

    // ---- Device path: /dev/mem maps ----
    MapWin win_doorbell;
    MapWin win_staging;
    MapWin win_bank;
    std::string err;

    if (!mapWindow(win_doorbell, doorbell_phys, 0x1000u, &err)) {
        std::fprintf(stderr, "map doorbell failed: %s\n", err.c_str());
        return 3;
    }
    uint8_t* doorbell_page = win_doorbell.ptrAt(doorbell_phys);
    if (!doorbell_page) {
        std::fprintf(stderr, "doorbell_phys out of map\n");
        return 3;
    }

    if (!mapWindow(win_staging, src_phys, static_cast<size_t>(frame_bytes), &err)) {
        std::fprintf(stderr, "map staging failed: %s\n", err.c_str());
        return 3;
    }
    uint8_t* staging_map = win_staging.ptrAt(src_phys);
    if (!staging_map) {
        std::fprintf(stderr, "staging_phys out of map\n");
        return 3;
    }

    if (!mapWindow(win_bank, bank_phys, static_cast<size_t>(frame_bytes), &err)) {
        std::fprintf(stderr, "map bank failed: %s\n", err.c_str());
        return 3;
    }
    uint8_t* bank_map = win_bank.ptrAt(bank_phys);
    if (!bank_map) {
        std::fprintf(stderr, "bank_phys out of map\n");
        return 3;
    }

    std::vector<uint8_t> payload(frame_bytes, 0);
    fillPattern(payload.data(), frame_bytes);

    // Poison target bank so idle/false-complete cannot content-match.
    std::memset(bank_map, 0xA5, frame_bytes);
    __sync_synchronize();
    dumpHexHead("bank_after_poison", bank_map, 32);

    // Also poison the OTHER bank so WRONG_BANK landing cannot be stale R8 gold.
    MapWin win_other;
    const uint32_t other_phys =
        (bank == 0) ? (misterplex::kDdrFramePhysBase + kPlex720pYuv420pBankStride)
                    : misterplex::kDdrFramePhysBase;
    std::string err_other;
    uint8_t* other_map = nullptr;
    if (mapWindow(win_other, other_phys, static_cast<size_t>(frame_bytes),
                  &err_other)) {
        other_map = win_other.ptrAt(other_phys);
        if (other_map) {
            std::memset(other_map, 0x5A, frame_bytes);
            __sync_synchronize();
            dumpHexHead("other_bank_after_poison_0x5a", other_map, 32);
        }
    } else {
        std::printf("SCORE other_bank_map_fail %s\n", err_other.c_str());
    }

    const auto fr = fillStagingFromPayloadEx(
        staging_map, payload.data(), frame_bytes, stagingRegionBytes());
    if (fr != StagingFillResult::Ok) {
        std::fprintf(stderr, "fillStaging failed: %s\n", stagingFillResultName(fr));
        printScore("device", FabricKickWaitResult::BadArgs, 0, 0, 0, 0, false,
                   frame_bytes, bank_phys, src_phys, cmd_seq, ring_plxk, false);
        win_other.close();
        win_bank.close();
        win_staging.close();
        win_doorbell.close();
        return 1;
    }
    dumpHexHead("staging_after_fill", staging_map, 32);
    dumpHexHead("bank_after_fill_pre_kick", bank_map, 32);

    VolatileFabricKickMem io(doorbell_page, 0x1000u);
    // Clear sticky done/err so a prior seq cannot false-Success.
    kick_st.last_cmd_seq = job.cmd_seq;
    clearFabricKickDone(io, kick_st, true);
    dumpDoorbellWords(io, "post_clr_done");
    if (!programFabricKick(io, kick_st, job, start_mode)) {
        std::fprintf(stderr, "programFabricKick failed (align/args)\n");
        printScore("device", FabricKickWaitResult::BadArgs, 0, 0, 0, 0, false,
                   frame_bytes, bank_phys, src_phys, cmd_seq, ring_plxk, false);
        win_other.close();
        win_bank.close();
        win_staging.close();
        win_doorbell.close();
        return 1;
    }
    dumpDoorbellWords(io, "post_program");

    const auto t0 = std::chrono::steady_clock::now();
    wait_r = waitFabricKickDone(io, job.cmd_seq, max_polls);
    const auto t1 = std::chrono::steady_clock::now();
    wait_us = std::chrono::duration<double, std::micro>(t1 - t0).count();
    dumpDoorbellWords(io, "post_wait");

    __sync_synchronize(); // payload barrier before bank read
    dumpHexHead("staging_post_wait", staging_map, 32);
    dumpHexHead("bank_post_wait", bank_map, 32);
    if (other_map)
        dumpHexHead("other_bank_post_wait", other_map, 32);

    // Optional PLXK only after PLXH success and only if explicitly requested.
    if (ring_plxk) {
        if (wait_r == FabricKickWaitResult::Success) {
            ringPlxkPresent(io, static_cast<uint32_t>(bank));
            std::printf("ring_plxk=done bank=%d (opt-in)\n", bank);
            // Observe PLXK write (dump_off_000_plxk_lo); prior dumps are pre-ring only.
            dumpDoorbellWords(io, "post_plxk");
        } else {
            std::printf("ring_plxk=skipped (PLXH not Success)\n");
        }
    }

    match_frac = contentMatchFrac(staging_map, bank_map, frame_bytes);
    full_match = (std::memcmp(staging_map, bank_map, frame_bytes) == 0);
    crc_s = crc32(staging_map, frame_bytes);
    crc_b = crc32(bank_map, frame_bytes);

    printScore("device", wait_r, wait_us, match_frac, crc_s, crc_b, full_match,
               frame_bytes, bank_phys, src_phys, cmd_seq, ring_plxk, false);

    // Dump first mismatch offset for lab RCA.
    if (!full_match) {
        size_t first = frame_bytes;
        for (size_t i = 0; i < frame_bytes; ++i) {
            if (staging_map[i] != bank_map[i]) {
                first = i;
                break;
            }
        }
        if (first < frame_bytes) {
            std::printf("first_mismatch_off=%zu staging=0x%02x bank=0x%02x\n", first,
                        staging_map[first], bank_map[first]);
        }
    }

    win_other.close();
    win_bank.close();
    win_staging.close();
    win_doorbell.close();

    const bool pass =
        (wait_r == FabricKickWaitResult::Success) && full_match && match_frac == 1.0;
    std::printf("fabric_content_match_lab: DONE true_rc=%d\n", pass ? 0 : 1);
    return pass ? 0 : 1;
}
