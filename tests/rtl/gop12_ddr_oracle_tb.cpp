#include "Vgop12_oracle_tb.h"
#include "verilated.h"
#include "ddr_bitstream_ring_bfm.hpp"

#include <algorithm>
#include <fstream>
#include <iostream>
#include <string>

namespace ring = misterplex::ddr_bitstream_ring;
using misterplex::test::DdrBitstreamRingBfm;
using misterplex::test::RingBytes;
using misterplex::test::encodeAccessUnitRecord;
using misterplex::test::encodeRingRecord;

static void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}

struct Frame {
    unsigned seq, numerator, denominator, flags, cw, ch, vw, vh;
    unsigned left, right, top, bottom, sarw, sarh;
    int64_t pts, duration;
    RingBytes bytes;
};

int main(int argc, char** argv) {
    try {
        require(argc == 5, "usage: ddr-oracle inputs-directory actual.i420 frames.jsonl input-limit");
        Verilated::commandArgs(argc, argv);
        const std::string directory = argv[1];
        const unsigned inputLimit = std::stoul(argv[4]);
        std::ifstream input(directory + "/au-metadata.txt");
        unsigned count = 0;
        input >> count;
        require(count > 0 && count <= 256, "expected 1..256 actual access units");
        std::vector<Frame> frames(count);
        for (auto& f : frames) {
            input >> f.seq >> f.pts >> f.duration >> f.numerator >> f.denominator >> f.flags
                  >> f.cw >> f.ch >> f.vw >> f.vh >> f.left >> f.right >> f.top >> f.bottom
                  >> f.sarw >> f.sarh;
            require(bool(input), "missing actual AU/geometry metadata");
            std::ifstream file(directory + "/au" + std::to_string(f.seq) + ".264", std::ios::binary);
            require(bool(file), "missing actual AU bytes");
            f.bytes = RingBytes(std::istreambuf_iterator<char>(file), {});
            require(!f.bytes.empty() && f.bytes.size() <= inputLimit, "AU exceeds requested input bound");
        }
        std::ofstream output(argv[2], std::ios::binary), events(argv[3]);
        std::ofstream rgb(std::string(argv[3]) + ".rgb565", std::ios::binary);
        require(bool(output) && bool(events) && bool(rgb), "cannot open actual-output files");
        Vgop12_oracle_tb dut;
        DdrBitstreamRingBfm bfm;
        constexpr uint64_t nonce = UINT64_C(0x474f503132000001);
        constexpr uint64_t session = UINT64_C(0x474f503132000002);
        constexpr uint64_t budget = 20000000;
        uint32_t producer = 0;
        uint64_t cycle = 0, start = 0, nativeWrites = 0, rgbWrites = 0;
        uint64_t firstWrite = 0, lastWrite = 0, promotionCycle = 0;
        unsigned observed = 0, promotions = 0, bank = 0, promotionCoverage = 0;
        bool active = false, metadataCaptured = false;
        Frame* expected = nullptr;
        ring::AccessUnit observedAu;
        RingBytes memory(230400), written(230400);
        const auto coverage = [&]() {
            unsigned total = 0;
            const auto& f = *expected;
            for (unsigned plane = 0; plane < 3; ++plane) {
                const unsigned scale = plane ? 2 : 1;
                const unsigned offset = plane == 0 ? 0 : plane == 1 ? dut.native_u_offset : dut.native_v_offset;
                const unsigned stride = plane ? dut.native_uv_stride : dut.native_y_stride;
                for (unsigned y = 0; y < f.ch / scale; ++y)
                    for (unsigned x = 0; x < f.cw / scale; ++x)
                        total += written[bank * dut.native_bank_bytes + offset + y * stride + x] != 0;
            }
            return total;
        };
        const auto checkMetadata = [&]() {
            const auto& f = *expected;
            require(dut.current_au_valid && dut.current_au_session_id == session &&
                    dut.current_au_seq == f.seq && int64_t(dut.current_au_pts) == f.pts &&
                    int64_t(dut.current_au_duration) == f.duration &&
                    dut.current_au_timebase_num == f.numerator && dut.current_au_timebase_den == f.denominator &&
                    dut.current_au_flags == f.flags, "actual held AU identity differs from supplied metadata");
            require(dut.coded_width == f.cw && dut.coded_height == f.ch &&
                    dut.visible_width == f.vw && dut.visible_height == f.vh &&
                    dut.crop_left == f.left && dut.crop_right == f.right &&
                    dut.crop_top == f.top && dut.crop_bottom == f.bottom &&
                    dut.sar_width == f.sarw && dut.sar_height == f.sarh,
                    "actual latched geometry/crop/SAR differs from encoded SPS");
            require(dut.native_bank_bytes == 115200 && dut.native_y_stride == 320 &&
                    dut.native_uv_stride == 160 && dut.native_u_offset == 76800 &&
                    dut.native_v_offset == 96000, "native allocation contract changed");
        };
        const auto tick = [&]() {
            dut.clk = 0;
            bfm.beforePosedge(dut, cycle);
            if (!dut.reset && active) {
                if (metadataCaptured) checkMetadata();
                if (dut.rgb_valid) {
                    const char pixel[2] = {char(dut.rgb_pixel), char(dut.rgb_pixel >> 8)};
                    rgb.write(pixel, 2);
                    ++rgbWrites;
                }
                if (dut.native_accept) {
                    checkMetadata();
                    require(dut.native_addr < memory.size(), "native write outside allocated banks");
                    const unsigned nextBank = dut.native_addr / dut.native_bank_bytes;
                    require(!metadataCaptured || bank == nextBank, "picture writes crossed native banks");
                    bank = nextBank;
                    if (!metadataCaptured) {
                        observedAu.session_id = dut.current_au_session_id;
                        observedAu.seq = dut.current_au_seq;
                        observedAu.pts = int64_t(dut.current_au_pts);
                        observedAu.duration = int64_t(dut.current_au_duration);
                        observedAu.timebase_num = dut.current_au_timebase_num;
                        observedAu.timebase_den = dut.current_au_timebase_den;
                        observedAu.flags = dut.current_au_flags;
                    }
                    metadataCaptured = true;
                    const unsigned offset = dut.native_addr % dut.native_bank_bytes;
                    const unsigned plane = offset < dut.native_u_offset ? 0 : offset < dut.native_v_offset ? 1 : 2;
                    const unsigned planeOffset = plane == 0 ? 0 : plane == 1 ? dut.native_u_offset : dut.native_v_offset;
                    const unsigned stride = plane ? dut.native_uv_stride : dut.native_y_stride;
                    const unsigned scale = plane ? 2 : 1;
                    require((offset - planeOffset) / stride < expected->ch / scale &&
                            (offset - planeOffset) % stride < expected->cw / scale,
                            "native write outside actual coded rectangle");
                    memory[dut.native_addr] = dut.native_data;
                    written[dut.native_addr] = 1;
                    if (!nativeWrites) firstWrite = cycle + 1;
                    lastWrite = cycle + 1;
                    ++nativeWrites;
                }
            }
            dut.clk = 1;
            dut.eval();
            bfm.afterPosedge();
            ++cycle;
            if (!dut.reset && (dut.decoder_error || dut.reference_error)) {
                std::cerr << "decoder_error=" << unsigned(dut.decoder_error)
                          << " phase=" << unsigned(dut.phase) << " MB=" << dut.mb_index
                          << " bit_pos=" << dut.full_bit_pos << " cycles=" << cycle << '\n';
                throw std::runtime_error("actual decoder/reference error");
            }
            if (!dut.reset && dut.reference_promoted) {
                require(active && metadataCaptured, "unsolicited native promotion");
                ++promotions;
                promotionCycle = cycle;
                promotionCoverage = coverage();
                require(dut.reference_base == bank * dut.native_bank_bytes &&
                        dut.reference_width == expected->cw && dut.reference_height == expected->ch,
                        "promotion bank/geometry mismatch");
            }
            if (!dut.reset && dut.frames_out != observed) {
                require(active && dut.frames_out == observed + 1, "unsolicited/out-of-order completion");
                const auto& f = *expected;
                const unsigned samples = f.cw * f.ch * 3 / 2;
                if (!(metadataCaptured && promotions == 1 && promotionCoverage == samples &&
                      coverage() == samples && rgbWrites == uint64_t(f.vw) * f.vh))
                    std::cerr << "completion samples=" << coverage() << "/" << samples
                              << " promoted_coverage=" << promotionCoverage << " promotions=" << promotions
                              << " rgb_accepts=" << rgbWrites << "/" << uint64_t(f.vw) * f.vh << '\n';
                require(metadataCaptured && promotions == 1 && promotionCoverage == samples &&
                        coverage() == samples && rgbWrites == uint64_t(f.vw) * f.vh,
                        "completion lacks accepted coded coverage/promotion/visible RGB");
                for (unsigned plane = 0; plane < 3; ++plane) {
                    const unsigned scale = plane ? 2 : 1;
                    const unsigned offset = plane == 0 ? 0 : plane == 1 ? dut.native_u_offset : dut.native_v_offset;
                    const unsigned stride = plane ? dut.native_uv_stride : dut.native_y_stride;
                    for (unsigned y = 0; y < f.ch / scale; ++y)
                        output.write(reinterpret_cast<const char*>(memory.data() + bank * dut.native_bank_bytes +
                                     offset + y * stride), f.cw / scale);
                }
                events << "{\"index\":" << observedAu.seq << ",\"rtl_frame_num\":" << dut.frame_num
                       << ",\"session_id\":" << observedAu.session_id << ",\"pts\":" << observedAu.pts
                       << ",\"duration\":" << observedAu.duration << ",\"timebase_num\":" << observedAu.timebase_num
                       << ",\"timebase_den\":" << observedAu.timebase_den << ",\"flags\":" << observedAu.flags
                       << ",\"coded_width\":" << dut.coded_width << ",\"coded_height\":" << dut.coded_height
                       << ",\"visible_width\":" << dut.visible_width << ",\"visible_height\":" << dut.visible_height
                       << ",\"crop_left\":" << dut.crop_left << ",\"crop_right\":" << dut.crop_right
                       << ",\"crop_top\":" << dut.crop_top << ",\"crop_bottom\":" << dut.crop_bottom
                       << ",\"sar_width\":" << dut.sar_width << ",\"sar_height\":" << dut.sar_height
                       << ",\"color_full_range\":" << unsigned(dut.color_full_range)
                       << ",\"color_matrix\":" << unsigned(dut.color_matrix)
                       << ",\"native_y_stride\":" << dut.native_y_stride << ",\"native_uv_stride\":" << dut.native_uv_stride
                       << ",\"native_u_offset\":" << dut.native_u_offset << ",\"native_v_offset\":" << dut.native_v_offset
                       << ",\"bank_base\":" << bank * dut.native_bank_bytes
                       << ",\"covered_samples\":" << coverage() << ",\"native_writes\":" << nativeWrites
                       << ",\"promotions\":" << promotions << ",\"coverage_at_promotion\":" << promotionCoverage
                       << ",\"promotion_cycle\":" << promotionCycle << ",\"rgb_accepts\":" << rgbWrites
                       << ",\"input_cycle\":" << start << ",\"first_write_cycle\":" << firstWrite
                       << ",\"last_write_cycle\":" << lastWrite << ",\"complete_cycle\":" << cycle << "}\n";
                output.flush();
                events.flush();
                std::cout << "NATIVE_FRAME seq=" << f.seq << " samples=" << samples
                          << " cycles=" << cycle - start << '\n';
                observed = dut.frames_out;
                active = false;
            }
        };
        const auto until = [&](auto condition, const char* message) {
            const uint64_t begin = cycle;
            while (!condition() && cycle - begin < budget) tick();
            require(condition(), message);
        };
        const auto append = [&](const RingBytes& record, bool data) {
            until([&] { return bfm.canAppend(producer, record.size(), data); }, "ring capacity/status timeout");
            bfm.append(producer, record);
            bfm.publishCtrl(producer, true);
        };
        dut.reset = 1;
        dut.ioctl_download = 0;
        dut.ioctl_wr = 0;
        dut.ioctl_dout = 0;
        bfm.publishCtrl(0, true);
        for (unsigned i = 0; i < 16; ++i) tick();
        dut.reset = 0;
        until([&] { return bfm.resetAcknowledged(0, true); }, "real ring reset acknowledgement timeout");
        append(encodeRingRecord(ring::Event::Probe, nonce, mailbox_abi::kFpgaVideoLayoutId), false);
        ring::VideoCapabilities caps;
        until([&] { return bfm.capabilitiesFor(nonce, caps); }, "real capability nonce acknowledgement timeout");
        std::cout << "DDR_CAPS abi=" << caps.abi_version << " layout=" << caps.layout_id
                  << " max_au_bytes=" << caps.max_au_bytes << " features=" << caps.features << '\n';
        require(caps.abi_version == 2 && caps.layout_id == 1 && caps.max_au_bytes >= inputLimit,
                "actual reader ABI/layout/capacity below requested scope");
        append(encodeRingRecord(ring::Event::Begin, session), false);
        ring::Status status;
        until([&] { return bfm.readStatus(status) && status.active && status.session_id == session &&
                           status.consumer_count == producer; }, "real Begin acknowledgement timeout");
        for (auto& f : frames) {
            require(f.seq == observed, "input AU sequence is not contiguous");
            expected = &f;
            active = true;
            metadataCaptured = false;
            nativeWrites = rgbWrites = firstWrite = lastWrite = promotions = promotionCoverage = promotionCycle = 0;
            std::fill(written.begin(), written.end(), 0);
            start = cycle;
            ring::AccessUnit au;
            au.session_id = session; au.seq = f.seq; au.annexb = f.bytes.data(); au.len = f.bytes.size();
            au.pts = f.pts; au.duration = f.duration; au.timebase_num = f.numerator;
            au.timebase_den = f.denominator; au.flags = f.flags;
            append(encodeAccessUnitRecord(au, caps.max_au_bytes), true);
            until([&] { return !active && dut.decoder_idle && bfm.readStatus(status) &&
                               status.consumer_count == producer; }, "actual AU decode/retirement timeout");
        }
        append(encodeRingRecord(ring::Event::Drain, session), false);
        until([&] { return dut.decoder_idle && bfm.readStatus(status) && status.consumer_count == producer; },
              "actual decoder Drain fence timeout");
        require(observed == count && output && events && rgb, "incomplete actual outputs");
        dut.final();
        std::cout << "DDR_NATIVE_DONE frames=" << observed << " sys_cycles=" << cycle
                  << " ddr_reads=" << bfm.reads << " ddr_writes=" << bfm.writes
                  << " busy_offers=" << bfm.busyOffers << " caps_features=" << caps.features << '\n';
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL DDR native oracle: " << error.what() << '\n';
        return 2;
    }
}
