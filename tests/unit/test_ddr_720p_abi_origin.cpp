// Path A 720p dual-header ABI gate for origin/main (w-mem).
// Compares host/libmisterplex/ddr_frame_layout.hpp kPlex720p* against
// fpga/Plex_MiSTer/rtl/ddr_frame_layout_params.svh DDR_FRAME_720P_*.
// Product 480p freeze must remain valid. M10K of this change: 0 (headers only).
#include "libmisterplex/ddr_frame_layout.hpp"

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <regex>
#include <sstream>
#include <stdexcept>
#include <string>

namespace {

using misterplex::ddrFrameLayoutMatches720pTier;
using misterplex::ddrFrameLayoutMatchesProductSilicon;
using misterplex::kDdrFrameStrideAlign;
using misterplex::kPlex720pChromaStrideBytes;
using misterplex::kPlex720pCodedHeight;
using misterplex::kPlex720pCodedWidth;
using misterplex::kPlex720pDdrFramePhysBase;
using misterplex::kPlex720pYStrideBytes;
using misterplex::kPlex720pYuv420pBankStride;
using misterplex::kPlex720pYuv420pBytes;
using misterplex::kPlex720pYuv420pDoorbellPhys;
using misterplex::kPlex720pUPlaneOffset;
using misterplex::kPlex720pVPlaneOffset;
using misterplex::makeDdrFrameLayout;
using misterplex::makePlex720pDdrFrameLayout;
using misterplex::plex480pDdrFrameGeometry;

std::string repoRoot() {
    const char* env = std::getenv("MISTERPLEX_ROOT");
    if (env && env[0] != '\0')
        return std::string(env);
    return ".";
}

std::string readFile(const std::string& path) {
    std::ifstream in(path);
    if (!in)
        throw std::runtime_error("open failed: " + path);
    std::ostringstream ss;
    ss << in.rdbuf();
    return ss.str();
}

int requireIntParam(const std::string& text, const std::string& name) {
    const std::regex re("localparam\\s+int\\s+" + name + "\\s*=\\s*([0-9_]+)\\s*;");
    std::smatch m;
    if (!std::regex_search(text, m, re))
        throw std::runtime_error("missing int param " + name);
    std::string lit = m[1].str();
    lit.erase(std::remove(lit.begin(), lit.end(), '_'), lit.end());
    return std::stoi(lit, nullptr, 0);
}

std::uint32_t requireHexParam(const std::string& text, const std::string& name) {
    const std::regex re(
        "localparam\\s+int\\s+" + name +
        "\\s*=\\s*32'h([0-9A-Fa-f_]+)\\s*;");
    std::smatch m;
    if (!std::regex_search(text, m, re))
        throw std::runtime_error("missing hex param " + name);
    std::string lit = m[1].str();
    lit.erase(std::remove(lit.begin(), lit.end(), '_'), lit.end());
    return static_cast<std::uint32_t>(std::stoul(lit, nullptr, 16));
}

void expectEqU32(const char* label, std::uint32_t got, std::uint32_t want) {
    if (got != want) {
        std::cerr << "FAIL " << label << ": got=0x" << std::hex << got << " want=0x" << want
                  << std::dec << "\n";
        std::exit(1);
    }
}

void expectEqI(const char* label, int got, int want) {
    if (got != want) {
        std::cerr << "FAIL " << label << ": got=" << got << " want=" << want << "\n";
        std::exit(1);
    }
}

void expectTrue(const char* label, bool ok) {
    if (!ok) {
        std::cerr << "FAIL " << label << "\n";
        std::exit(1);
    }
}

} // namespace

int main() {
    expectEqI("720p I420 bytes", static_cast<int>(kPlex720pYuv420pBytes), 1382400);
    expectEqI("720p Y stride", static_cast<int>(kPlex720pYStrideBytes), 1280);
    expectEqI("720p C stride", static_cast<int>(kPlex720pChromaStrideBytes), 640);
    expectEqI("720p U off", static_cast<int>(kPlex720pUPlaneOffset), 921600);
    expectEqI("720p V off", static_cast<int>(kPlex720pVPlaneOffset), 1152000);
    expectEqU32("720p bank stride", kPlex720pYuv420pBankStride, 0x00180000u);
    expectEqU32("720p phys", kPlex720pDdrFramePhysBase, 0x30180000u);
    expectEqU32("720p doorbell", kPlex720pYuv420pDoorbellPhys, 0x3047F000u);
    expectEqU32("720p doorbell formula",
                kPlex720pDdrFramePhysBase + 2u * kPlex720pYuv420pBankStride - 0x1000u,
                kPlex720pYuv420pDoorbellPhys);
    expectTrue("720p stride fits payload",
               kPlex720pYuv420pBankStride >= kPlex720pYuv420pBytes);
    expectTrue("720p stride align",
               (kPlex720pYuv420pBankStride % kDdrFrameStrideAlign) == 0);

    const auto l720 = makePlex720pDdrFrameLayout();
    expectTrue("makePlex720p valid tier", ddrFrameLayoutMatches720pTier(l720));
    expectEqI("layout coded_w", static_cast<int>(l720.coded_width.get()),
              static_cast<int>(kPlex720pCodedWidth.get()));
    expectEqI("layout coded_h", static_cast<int>(l720.coded_height.get()),
              static_cast<int>(kPlex720pCodedHeight.get()));
    expectEqU32("layout phys", l720.phys_base, kPlex720pDdrFramePhysBase);
    expectEqU32("layout stride", l720.bank_stride, kPlex720pYuv420pBankStride);
    expectEqU32("layout doorbell", l720.doorbell_phys, kPlex720pYuv420pDoorbellPhys);

    const auto l480 = makeDdrFrameLayout(plex480pDdrFrameGeometry());
    expectTrue("480p product freeze", ddrFrameLayoutMatchesProductSilicon(l480));
    expectTrue("480p != 720p doorbell", l480.doorbell_phys != l720.doorbell_phys);
    expectTrue("480p != 720p stride", l480.bank_stride != l720.bank_stride);

    const std::string svh_path =
        repoRoot() + "/fpga/Plex_MiSTer/rtl/ddr_frame_layout_params.svh";
    const std::string svh = readFile(svh_path);

    expectEqI("svh 720p coded_w", requireIntParam(svh, "DDR_FRAME_720P_CODED_WIDTH"), 1280);
    expectEqI("svh 720p coded_h", requireIntParam(svh, "DDR_FRAME_720P_CODED_HEIGHT"), 720);
    expectEqI("svh 720p bytes", requireIntParam(svh, "DDR_FRAME_720P_YUV420P_BYTES"), 1382400);
    expectEqI("svh 720p Y stride", requireIntParam(svh, "DDR_FRAME_720P_Y_STRIDE_BYTES"), 1280);
    expectEqI("svh 720p C stride", requireIntParam(svh, "DDR_FRAME_720P_CHROMA_STRIDE_BYTES"),
              640);
    expectEqI("svh 720p U", requireIntParam(svh, "DDR_FRAME_720P_U_PLANE_OFFSET"), 921600);
    expectEqI("svh 720p V", requireIntParam(svh, "DDR_FRAME_720P_V_PLANE_OFFSET"), 1152000);
    expectEqU32("svh 720p stride", requireHexParam(svh, "DDR_FRAME_720P_YUV420P_BANK_STRIDE"),
                0x00180000u);
    expectEqU32("svh 720p phys", requireHexParam(svh, "DDR_FRAME_720P_PHYS_BASE"), 0x30180000u);
    expectEqU32("svh 720p doorbell",
                requireHexParam(svh, "DDR_FRAME_720P_YUV420P_DOORBELL_PHYS"), 0x3047F000u);

    expectEqI("svh 480p coded_w", requireIntParam(svh, "DDR_FRAME_CODED_WIDTH"), 624);
    expectEqI("svh 480p bytes", requireIntParam(svh, "DDR_FRAME_YUV420P_BYTES"), 449280);
    expectEqU32("svh 480p stride", requireHexParam(svh, "DDR_FRAME_YUV420P_BANK_STRIDE"),
                0x00080000u);
    expectEqU32("svh 480p doorbell", requireHexParam(svh, "DDR_FRAME_YUV420P_DOORBELL_PHYS"),
                0x300FF000u);

    // NEGATIVE: naive keep-legacy-stride cannot hold 720p payload.
    expectTrue("NEG: 720p bytes > legacy stride",
               kPlex720pYuv420pBytes > 0x00080000u);

    std::cout << "PASS test_ddr_720p_abi_origin (Path A dual-header; M10K=0 headers)\n";
    return 0;
}
