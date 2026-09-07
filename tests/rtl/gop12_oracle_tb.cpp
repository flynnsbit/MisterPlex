#include "Vgop12_oracle_tb.h"
#include "verilated.h"

#include <algorithm>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
constexpr size_t kPicture = 320 * 240 * 3 / 2;
constexpr uint64_t kFrameBudget = 20000000;

std::vector<uint8_t> readBytes(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) throw std::runtime_error("cannot read " + path);
    return {std::istreambuf_iterator<char>(in), {}};
}

struct Nal { size_t begin, end; unsigned type; };
std::vector<Nal> split(const std::vector<uint8_t>& bytes) {
    std::vector<Nal> nals;
    for (size_t i = 0; i + 3 < bytes.size();) {
        size_t length = 0;
        if (i + 4 < bytes.size() && bytes[i] == 0 && bytes[i+1] == 0 &&
            bytes[i+2] == 0 && bytes[i+3] == 1) length = 4;
        else if (bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 1) length = 3;
        if (!length) { ++i; continue; }
        if (!nals.empty()) nals.back().end = i;
        nals.push_back({i, bytes.size(), unsigned(bytes[i+length] & 31)});
        i += length + 1;
    }
    if (nals.empty() || nals.front().begin != 0)
        throw std::runtime_error("expected Annex-B start code at byte zero");
    return nals;
}
}

int main(int argc, char** argv) {
    try {
        if (argc != 5)
            throw std::runtime_error("usage: Vgop12_oracle_tb annexb candidate.i420 frames.jsonl 1|2|12");
        const unsigned requiredFrames = std::stoul(argv[4]);
        if (requiredFrames != 1 && requiredFrames != 2 && requiredFrames != 12)
            throw std::runtime_error("only a single IDR, an I/P pair, or exact GOP12 is supported");
        Verilated::commandArgs(argc, argv);
        const auto bytes = readBytes(argv[1]);
        const auto nals = split(bytes);
        std::ofstream candidate(argv[2], std::ios::binary);
        std::ofstream events(argv[3]);
        if (!candidate || !events) throw std::runtime_error("cannot create actual outputs");
        Vgop12_oracle_tb dut;
        std::vector<uint8_t> memory(2 * kPicture), written(2 * kPicture);
        uint64_t cycle = 0, start = 0, writes = 0, firstWrite = 0, lastWrite = 0;
        uint64_t rgbWrites = 0;
        unsigned observed = 0, expected = 0;
        size_t activeNal = 0, lastBank = 0;
        bool sawSwap = false;
        bool promoted = false, referenceError = false;
        unsigned referenceWidth = 0, referenceHeight = 0, referenceBase = 0;
        unsigned promotionCount = 0;
        size_t promotionCoverage = 0;
        uint64_t promotionCycle = 0;

        auto tick = [&]() {
            dut.clk = 0;
            dut.eval();
            // Sample the write accepted on this edge, not the next cycle's strobe.
            if (!dut.reset && dut.rgb_valid) ++rgbWrites;
            if (!dut.reset && dut.native_accept) {
                if (dut.native_addr >= memory.size())
                    throw std::runtime_error("DPB write outside two 320x240 I420 banks");
                memory[dut.native_addr] = dut.native_data;
                written[dut.native_addr] = 1;
                lastBank = dut.native_addr / kPicture;
                if (writes == 0) firstWrite = cycle + 1;
                lastWrite = cycle + 1;
                ++writes;
            }
            dut.clk = 1;
            dut.eval();
            ++cycle;
            if (!dut.reset && dut.lifetime_observed && expected && observed == expected &&
                (dut.reference_promoted || dut.reference_error || dut.decoder_error))
                throw std::runtime_error("unsolicited promotion/error after completed picture");
            if (!dut.reset && dut.lifetime_observed && expected > observed) {
                promoted = promoted || dut.reference_promoted;
                referenceError = referenceError || dut.reference_error;
                if (dut.reference_promoted) {
                    if (++promotionCount == 1) {
                        referenceWidth = dut.reference_width;
                        referenceHeight = dut.reference_height;
                        referenceBase = dut.reference_base;
                        promotionCycle = cycle;
                        if (referenceBase <= written.size() - kPicture)
                            promotionCoverage = std::count(written.begin() + referenceBase,
                                                           written.begin() + referenceBase + kPicture, 1);
                    }
                }
            }
            if (!dut.reset && dut.frames_out != observed) {
                if (dut.frames_out != observed + 1 || !expected)
                    throw std::runtime_error("unexpected frame completion/order");
                if (dut.width != 320 || dut.height != 240)
                    throw std::runtime_error("this source-bound bench supports only 320x240");
                const size_t base = lastBank * kPicture;
                const size_t coverage = std::count(written.begin() + base,
                                                  written.begin() + base + kPicture, 1);
                candidate.write(reinterpret_cast<const char*>(memory.data() + base), kPicture);
                events << "{\"index\":" << observed
                       << ",\"rtl_frame_num\":" << dut.frame_num
                       << ",\"nal_index\":" << activeNal
                       << ",\"nal_offset\":" << nals[activeNal].begin
                       << ",\"nal_bytes\":" << nals[activeNal].end - nals[activeNal].begin
                       << ",\"nal_type\":" << nals[activeNal].type
                       << ",\"begin_cycle\":" << start
                       << ",\"complete_cycle\":" << cycle
                       << ",\"input_to_frame_signal_cycles\":" << cycle - start
                       << ",\"native_first_write_cycle\":" << firstWrite
                       << ",\"native_last_write_cycle\":" << lastWrite
                       << ",\"input_to_last_native_write_cycles\":" << (writes ? lastWrite - start : 0)
                       << ",\"native_writes\":" << writes
                       << ",\"rgb_write_accepts_at_frame_signal\":" << rgbWrites
                       << ",\"dpb_lifetime_observed\":" << (dut.lifetime_observed ? "true" : "false")
                       << ",\"reference_promoted\":" << (promoted ? "true" : "false")
                       << ",\"reference_error\":" << (referenceError ? "true" : "false")
                       << ",\"promoted_reference_width\":" << referenceWidth
                       << ",\"promoted_reference_height\":" << referenceHeight
                       << ",\"promoted_reference_base\":" << referenceBase
                       << ",\"coverage_at_promotion\":" << promotionCoverage
                       << ",\"promotion_cycle\":" << promotionCycle
                       << ",\"promotion_count\":" << promotionCount
                       << ",\"decoder_error\":" << unsigned(dut.decoder_error)
                       << ",\"color_metadata_observed\":" << (dut.color_metadata_observed ? "true" : "false")
                       << ",\"color_full_range\":" << (dut.color_full_range ? "true" : "false")
                       << ",\"color_matrix\":" << unsigned(dut.color_matrix)
                       << ",\"frontend_mode_observed\":" << (dut.frontend_mode_observed ? "true" : "false")
                       << ",\"legacy_diagnostic_mode\":" << (dut.legacy_diagnostic_mode ? "true" : "false")
                       << ",\"covered_samples\":" << coverage
                       << ",\"bank\":" << lastBank
                       << ",\"mb_index\":" << dut.mb_index << "}\n";
                events.flush();
                candidate.flush();
                observed = dut.frames_out;
                std::cout << "ACTUAL frame=" << observed - 1
                          << " frame_num=" << dut.frame_num << " samples=" << coverage
                          << " cycles=" << cycle - start << '\n';
            }
            if (!dut.reset && dut.fs_swap) sawSwap = true;
        };
        dut.reset = 1;
        dut.ioctl_download = 0;
        dut.ioctl_wr = 0;
        dut.ioctl_dout = 0;
        for (int i = 0; i < 16; ++i) tick();
        dut.reset = 0;
        dut.ioctl_download = 1;
        for (int i = 0; i < 64; ++i) tick();

        for (size_t n = 0; n < nals.size(); ++n) {
            const auto& nal = nals[n];
            const bool vcl = nal.type == 1 || nal.type == 5;
            if (vcl) {
                activeNal = n;
                ++expected;
                start = cycle;
                writes = 0;
                rgbWrites = 0;
                firstWrite = lastWrite = 0;
                sawSwap = false;
                promoted = referenceError = false;
                referenceWidth = referenceHeight = referenceBase = 0;
                promotionCount = 0;
                promotionCoverage = promotionCycle = 0;
                std::fill(written.begin(), written.end(), 0);
            }
            for (size_t i = nal.begin; i < nal.end; ++i) {
                dut.ioctl_dout = bytes[i];
                dut.ioctl_wr = 1;
                tick();
                dut.ioctl_wr = 0;
                for (int gap = 0; gap < 3; ++gap) tick();
            }
            dut.ioctl_wr = 0;
            if (vcl) {
                while ((observed < expected || !sawSwap) && !dut.decoder_error &&
                       !referenceError && cycle - start < kFrameBudget)
                    tick();
                if (observed != expected || !sawSwap || dut.decoder_error || referenceError) {
                    // Incomplete writes are diagnostic only: never emit a completed picture.
                    std::ofstream partial(std::string(argv[3]) + ".partial.json");
                    partial << "{\"index\":" << expected - 1
                            << ",\"complete\":false,\"nal_offset\":" << nal.begin
                            << ",\"nal_bytes\":" << nal.end - nal.begin
                            << ",\"rtl_frame_num\":" << dut.frame_num
                            << ",\"cycles\":" << cycle - start
                            << ",\"phase\":" << unsigned(dut.phase)
                            << ",\"mb_index\":" << dut.mb_index
                            << ",\"bit_pos\":" << dut.bit_pos
                            << ",\"decoder_error\":" << unsigned(dut.decoder_error)
                            << ",\"dpb_lifetime_observed\":" << (dut.lifetime_observed ? "true" : "false")
                            << ",\"reference_promoted\":" << (promoted ? "true" : "false")
                            << ",\"reference_error\":" << (referenceError ? "true" : "false")
                            << ",\"rgb_write_accepts\":" << rgbWrites
                            << ",\"frontend_mode_observed\":" << (dut.frontend_mode_observed ? "true" : "false")
                            << ",\"legacy_diagnostic_mode\":" << (dut.legacy_diagnostic_mode ? "true" : "false")
                            << ",\"native_writes\":" << writes << ",\"samples\":[";
                    bool first = true;
                    for (size_t i = 0; i < kPicture; ++i) {
                        const size_t address = lastBank * kPicture + i;
                        if (!written[address]) continue;
                        if (!first) partial << ',';
                        partial << '[' << i << ',' << unsigned(memory[address]) << ']';
                        first = false;
                    }
                    partial << "]}\n";
                    std::cerr << "FAIL frame=" << expected - 1 << " incomplete/error phase="
                              << unsigned(dut.phase) << " mb=" << dut.mb_index
                              << " bit_pos=" << dut.bit_pos << " frames=" << observed
                              << " decode_error=" << unsigned(dut.decoder_error)
                              << " fifo=" << dut.fifo_level << '\n';
                    return 2;
                }
            }
            // Pacing lets the donor's single RBSP capture retire before the next NAL.
            for (int gap = 0; gap < 512; ++gap) tick();
        }
        dut.final();
        if (expected != requiredFrames || observed != requiredFrames)
            throw std::runtime_error("required number of VCL pictures did not complete");
        if (!candidate || !events) throw std::runtime_error("actual output write failed");
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL " << error.what() << '\n';
        return 2;
    }
}
