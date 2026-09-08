#include "Vgop12_oracle_tb.h"
#include "verilated.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
constexpr size_t kPicture = 320 * 240 * 3 / 2;
constexpr uint64_t kFrameBudget = 20000000;

unsigned planeOf(size_t address) {
    const auto offset = address % kPicture;
    return offset < 76800 ? 0 : offset < 96000 ? 1 : 2;
}

bool codedAddress(size_t address, unsigned width, unsigned height) {
    const auto plane = planeOf(address);
    const auto stride = plane ? 160u : 320u;
    const auto offset = address % kPicture - (plane == 0 ? 0 : plane == 1 ? 76800 : 96000);
    return offset % stride < (width >> (plane != 0)) &&
           offset / stride < (height >> (plane != 0));
}

size_t covered(const std::vector<uint8_t>& written, size_t base, unsigned width, unsigned height) {
    size_t count = 0;
    for (size_t i = 0; i < kPicture; ++i)
        if (codedAddress(i, width, height) && written.at(base + i)) ++count;
    return count;
}

void writeCoded(std::ofstream& out, const std::vector<uint8_t>& memory,
                size_t base, unsigned width, unsigned height) {
    for (unsigned plane = 0; plane < 3; ++plane) {
        const auto offset = plane == 0 ? 0 : plane == 1 ? 76800 : 96000;
        const auto stride = plane ? 160u : 320u;
        for (unsigned y = 0; y < (height >> (plane != 0)); ++y)
            out.write(reinterpret_cast<const char*>(memory.data() + base + offset + y * stride),
                      width >> (plane != 0));
    }
}

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
        if (argc != 5 && argc != 6)
            throw std::runtime_error("usage: Vgop12_oracle_tb annexb candidate.i420 frames.jsonl frames [expected_error]");
        const unsigned requiredFrames = std::stoul(argv[4]);
        const unsigned expectedError = argc == 6 ? std::stoul(argv[5]) : 0;
        if (requiredFrames > 12 || (!requiredFrames && !expectedError))
            throw std::runtime_error("requires 1..12 pictures, or an explicit negative case");
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
        uint64_t filterStartCycle = 0, filterDoneCycle = 0, predictionReads = 0;
        std::array<uint64_t, 3> filterWrites{};
        std::array<uint64_t, 5> strengths{};
        std::array<uint64_t, 4> modes{};
        uint64_t fractionalMbs = 0, nonzeroInterMbs = 0;
        bool rejected = false;
        bool collisionSent = false;

        auto tick = [&]() {
            dut.clk = 0;
            dut.eval();
            if (!dut.reset && (dut.product_recon_ok || dut.legacy_diagnostic_mode))
                throw std::runtime_error("functional test must retain capability zero and bounded header mode");
            if (!dut.reset && rejected &&
                (dut.native_accept || dut.reference_promoted || dut.rgb_valid || dut.frames_out != observed))
                throw std::runtime_error("rejected picture escaped its abort/drain fence");
            if (!dut.reset && dut.filter_start) {
                if (filterStartCycle || writes != size_t(dut.coded_width) * dut.coded_height * 3 / 2)
                    throw std::runtime_error("filter started before complete reconstruction, or restarted");
                filterStartCycle = cycle + 1;
            }
            if (!dut.reset && dut.filter_done) {
                if (!filterStartCycle || filterDoneCycle || lastWrite >= cycle + 1)
                    throw std::runtime_error("invalid filter completion/drain");
                filterDoneCycle = cycle + 1;
            }
            if (!dut.reset && dut.filter_edge) {
                if (dut.filter_bs > 4) throw std::runtime_error("invalid boundary strength");
                ++strengths[dut.filter_bs];
            }
            if (!dut.reset && dut.mb_commit) {
                if (dut.mb_mode > 3) throw std::runtime_error("unsupported MB reached commit");
                ++modes[dut.mb_mode];
                if (dut.mb_mode < 2) {
                    fractionalMbs += (dut.mb_mvx & 3) != 0 || (dut.mb_mvy & 3) != 0;
                    nonzeroInterMbs += dut.mb_nonzero != 0;
                }
            }
            if (!dut.reset && dut.prediction_read) {
                if (!dut.reference_ready || filterStartCycle ||
                    dut.native_read_addr / kPicture != dut.reference_base / kPicture ||
                    !codedAddress(dut.native_read_addr, dut.reference_width, dut.reference_height))
                    throw std::runtime_error("prediction read outside the immutable coded reference");
                ++predictionReads;
            }
            if (!dut.reset && dut.filter_read &&
                (!filterStartCycle || dut.native_read_addr / kPicture != dut.current_base / kPicture ||
                 !codedAddress(dut.native_read_addr, dut.coded_width, dut.coded_height)))
                throw std::runtime_error("filter read outside the complete current coded picture");
            // Sample the write accepted on this edge, not the next cycle's strobe.
            if (!dut.reset && dut.rgb_valid) ++rgbWrites;
            if (!dut.reset && dut.native_accept) {
                if (dut.native_addr >= memory.size())
                    throw std::runtime_error("DPB write outside two 320x240 I420 banks");
                if (dut.native_addr / kPicture != dut.current_base / kPicture ||
                    !codedAddress(dut.native_addr, dut.coded_width, dut.coded_height))
                    throw std::runtime_error("write changed a reference bank or allocation padding");
                if (dut.filter_write) {
                    if (!filterStartCycle || filterDoneCycle)
                        throw std::runtime_error("filter write outside its lifetime");
                    ++filterWrites[planeOf(dut.native_addr)];
                } else if (filterStartCycle) {
                    throw std::runtime_error("unfiltered reconstruction continued after filter start");
                }
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
            if (!dut.reset && dut.decoder_error &&
                (dut.reference_promoted || dut.native_picture_valid))
                throw std::runtime_error("decode error coincided with reference/native publication");
            if (!dut.reset && dut.lifetime_observed && expected && observed == expected &&
                (dut.reference_promoted || dut.reference_error || dut.decoder_error))
                throw std::runtime_error("unsolicited promotion/error after completed picture");
            if (!dut.reset && dut.lifetime_observed && expected > observed) {
                promoted = promoted || dut.reference_promoted;
                referenceError = referenceError || dut.reference_error;
                if (dut.reference_promoted) {
                    if (dut.filter_busy || (filterStartCycle && !filterDoneCycle) || dut.decoder_error)
                        throw std::runtime_error("reference promoted before full filter/error retirement");
                    if (++promotionCount == 1) {
                        referenceWidth = dut.reference_width;
                        referenceHeight = dut.reference_height;
                        referenceBase = dut.reference_base;
                        promotionCycle = cycle;
                        if (referenceBase <= written.size() - kPicture)
                            promotionCoverage = covered(written, referenceBase,
                                                        referenceWidth, referenceHeight);
                    }
                }
            }
            if (!dut.reset && dut.frames_out != observed) {
                if (dut.frames_out != observed + 1 || !expected)
                    throw std::runtime_error("unexpected frame completion/order");
                if (!dut.coded_width || !dut.coded_height ||
                    dut.coded_width > 320 || dut.coded_height > 240)
                    throw std::runtime_error("invalid coded geometry");
                const size_t base = lastBank * kPicture;
                const size_t coverage = covered(written, base, dut.coded_width, dut.coded_height);
                const size_t samples = size_t(dut.coded_width) * dut.coded_height * 3 / 2;
                if (coverage != samples || promotionCoverage != samples ||
                    promotionCount != 1 || referenceBase != base ||
                    referenceWidth != dut.coded_width || referenceHeight != dut.coded_height ||
                    rgbWrites != size_t(dut.width) * dut.height)
                    throw std::runtime_error("incomplete coded/reference/visible coverage");
                writeCoded(candidate, memory, base, dut.coded_width, dut.coded_height);
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
                       << ",\"coded_width\":" << dut.coded_width
                       << ",\"coded_height\":" << dut.coded_height
                       << ",\"visible_width\":" << dut.width
                       << ",\"visible_height\":" << dut.height
                       << ",\"filter_start_cycle\":" << filterStartCycle
                       << ",\"filter_done_cycle\":" << filterDoneCycle
                       << ",\"filter_writes\":[" << filterWrites[0] << ',' << filterWrites[1] << ',' << filterWrites[2] << ']'
                       << ",\"bs_counts\":[" << strengths[0] << ',' << strengths[1] << ',' << strengths[2] << ',' << strengths[3] << ',' << strengths[4] << ']'
                       << ",\"mb_modes_P16_skip_I4_I16\":[" << modes[0] << ',' << modes[1] << ',' << modes[2] << ',' << modes[3] << ']'
                       << ",\"fractional_inter_mbs\":" << fractionalMbs
                       << ",\"nonzero_inter_mbs\":" << nonzeroInterMbs
                       << ",\"prediction_reads\":" << predictionReads
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
                filterStartCycle = filterDoneCycle = predictionReads = 0;
                filterWrites.fill(0); strengths.fill(0); modes.fill(0);
                fractionalMbs = nonzeroInterMbs = 0;
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
                       !referenceError && cycle - start < kFrameBudget) {
                    tick();
                    if (expectedError == 12 && !collisionSent && filterWrites[0] >= 32) {
                        // Real overlapping Annex-B input, not a forced decoder state/reference.
                        for (uint8_t byte : {0, 0, 1, 0x65, 0x80}) {
                            dut.ioctl_dout = byte;
                            dut.ioctl_wr = 1;
                            tick();
                            dut.ioctl_wr = 0;
                            for (unsigned gap = 0; gap < 3; ++gap) tick();
                        }
                        collisionSent = true;
                    }
                }
                if (observed != expected || !sawSwap || dut.decoder_error || referenceError) {
                    if (expectedError && dut.decoder_error == expectedError && observed == requiredFrames) {
                        if (promotionCount || rgbWrites || sawSwap)
                            throw std::runtime_error("negative case published a partial picture");
                        const auto errorCode = unsigned(dut.decoder_error);
                        rejected = true;
                        for (unsigned drain = 0; drain < 4096 &&
                             (dut.decoder_busy || dut.filter_busy || dut.reference_fetch_busy); ++drain)
                            tick();
                        if (dut.decoder_busy || dut.filter_busy || dut.reference_fetch_busy || dut.reference_ready)
                            throw std::runtime_error("failed picture did not drain and invalidate its reference");
                        for (unsigned guard = 0; guard < 128; ++guard) tick();
                        events << "{\"rejected\":true,\"decoder_error\":" << errorCode
                               << ",\"completed_prefix\":" << observed
                               << ",\"native_writes\":" << writes
                               << ",\"filter_start_cycle\":" << filterStartCycle
                               << ",\"filter_writes\":[" << filterWrites[0] << ',' << filterWrites[1] << ',' << filterWrites[2] << ']'
                               << ",\"promotion_count\":" << promotionCount
                               << ",\"drained\":true}\n";
                        dut.final();
                        std::cout << "EXPECTED_REJECT error=" << errorCode
                                  << " completed_prefix=" << observed << " drained=1\n";
                        return 0;
                    }
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
        if (expectedError || expected != requiredFrames || observed != requiredFrames)
            throw std::runtime_error("required number of VCL pictures did not complete");
        if (!candidate || !events) throw std::runtime_error("actual output write failed");
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL " << error.what() << '\n';
        return 2;
    }
}
