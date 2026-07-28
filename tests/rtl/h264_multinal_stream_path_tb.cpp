#include "Vh264_multinal_stream_path_tb.h"
#include "verilated.h"

#include <cstdint>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

static std::vector<uint8_t> readBinary(const char* path) {
    std::ifstream in(path, std::ios::binary);
    if (!in)
        throw std::runtime_error(std::string("cannot open fixture: ") + path);
    return std::vector<uint8_t>((std::istreambuf_iterator<char>(in)), {});
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc != 5) {
        std::cerr << "usage: " << argv[0] << " multi-nal.264 min_nals min_slices expect_csum_hex\n";
        std::cerr << "Refuse implicit defaults: each fixture must publish its proven counts/checksum.\n";
        return 2;
    }

    try {
        const auto bytes = readBinary(argv[1]);
        const int minNals = std::stoi(argv[2]);
        const int minSlices = std::stoi(argv[3]);
        const int expectCsum = std::stoi(argv[4], nullptr, 0);
        if (bytes.size() < 2)
            throw std::runtime_error("fixture too small");

        Vh264_multinal_stream_path_tb dut;
        dut.clk = 0;
        dut.reset = 1;
        dut.ioctl_download = 0;
        dut.ioctl_wr = 0;
        dut.ioctl_dout = 0;
        dut.enable = 1;
        dut.flush = 0;

        uint64_t cycle = 0;
        int placePulses = 0;
        int sawExpectedCsum = 0;
        int reconSig3bCycles = 0;
        int sawI = 0;
        int sawP = 0;
        int idleBetweenVcl = 0;
        int prevSliceValid = 0;
        int pFirstMbSeen = 0;
        int pFirstMbMode0 = 0;
        int pFirstMbMode1 = 0;
        int pFirstMbMode2 = 0;
        int pFirstMbBad = 0;
        int cavlcLumaPulses = 0;
        uint32_t cavlcLumaMask = 0;
        int cavlcDone = 0;
        int cavlcBadDone = 0;
        int cavlcNonzeroTc = 0;
        int cavlcCbpNonzeroSeen = 0;
        int cavlcCbpLumaSeen = 0;
        int cavlcCbpChromaSeen = 0;
        int cavlcLastQp = -1;
        int cavlcI4Mode0 = -1;
        int cavlcI4Mode7 = -1;
        int cavlcI4Mode15 = -1;
        int mbSyntaxRecords = 0;
        int mbSyntaxINxN = 0;
        int mbSyntaxP16 = 0;
        int mbSyntaxP16x8 = 0;
        int mbSyntaxP8x16 = 0;
        int mbSyntaxUnsupported = 0;
        int mbSyntaxBadQp = 0;
        int mbSyntaxBadCbp = 0;

        auto tick = [&]() {
            dut.clk = 0;
            dut.eval();
            dut.clk = 1;
            dut.eval();
            ++cycle;
            if (dut.residual_place_pulse)
                ++placePulses;
            if (static_cast<uint8_t>(dut.residual_csum) == expectCsum)
                sawExpectedCsum = 1;
            if (dut.recon_valid && static_cast<uint8_t>(dut.recon_sig) == 0x3b)
                ++reconSig3bCycles;
            if (dut.luma4x4_valid) {
                ++cavlcLumaPulses;
                const int idx = static_cast<int>(dut.luma4x4_idx);
                if (idx >= 0 && idx < 16)
                    cavlcLumaMask |= (1u << idx);
                if (dut.luma4x4_total_coeff != 0)
                    ++cavlcNonzeroTc;
                if (dut.first_mb_cbp_luma != 0)
                    cavlcCbpNonzeroSeen = 1;
                cavlcCbpLumaSeen = static_cast<int>(dut.first_mb_cbp_luma);
                cavlcCbpChromaSeen = static_cast<int>(dut.first_mb_cbp_chroma);
                cavlcLastQp = static_cast<int>(dut.luma4x4_qp);
                cavlcI4Mode0 = static_cast<int>(dut.i4_mode0);
                cavlcI4Mode7 = static_cast<int>(dut.i4_mode7);
                cavlcI4Mode15 = static_cast<int>(dut.i4_mode15);
            }
            if (dut.luma4x4_source_done) {
                ++cavlcDone;
                if (!dut.luma4x4_source_ok)
                    ++cavlcBadDone;
            }
            if (dut.mb_syntax_valid) {
                ++mbSyntaxRecords;
                const int cls = static_cast<int>(dut.mb_syntax_class);
                if (cls == 7)
                    ++mbSyntaxINxN;
                else if (cls == 2)
                    ++mbSyntaxP16;
                else if (cls == 3)
                    ++mbSyntaxP16x8;
                else if (cls == 4)
                    ++mbSyntaxP8x16;
                if (dut.mb_syntax_unsupported)
                    ++mbSyntaxUnsupported;
                if (dut.mb_syntax_qpy > 51 || dut.mb_syntax_qpc > 51)
                    ++mbSyntaxBadQp;
                if (dut.mb_syntax_p_skip && (dut.mb_syntax_cbp_luma != 0 || dut.mb_syntax_cbp_chroma != 0))
                    ++mbSyntaxBadCbp;
            }
            if (dut.slice_valid && !prevSliceValid) {
                const uint8_t st = static_cast<uint8_t>(dut.slice_type) % 5;
                if (st == 2 && dut.slice_is_i)
                    sawI = 1;
                if (st == 0 && !dut.slice_is_i)
                    sawP = 1;
                if (st == 0 && !dut.slice_is_i && dut.has_mb_type) {
                    ++pFirstMbSeen;
                    const int mt = static_cast<int>(dut.first_mb_type);
                    const int pm = static_cast<int>(dut.first_mb_part_mode);
                    const int pc = static_cast<int>(dut.first_mb_part_count);
                    if (dut.p_skip_run != 0 || dut.first_mb_p_skip || dut.first_mb_uses_sub_mb || dut.first_mb_intra) {
                        ++pFirstMbBad;
                    } else if (mt == 0 && pm == 0 && pc == 1) {
                        ++pFirstMbMode0;
                    } else if (mt == 1 && pm == 1 && pc == 2) {
                        ++pFirstMbMode1;
                    } else if (mt == 2 && pm == 2 && pc == 2) {
                        ++pFirstMbMode2;
                    } else {
                        ++pFirstMbBad;
                    }
                }
            }
            prevSliceValid = dut.slice_valid ? 1 : 0;
            if (sawI && !sawP && placePulses >= 1 &&
                static_cast<uint8_t>(dut.slice_parser_state) == 0)
                idleBetweenVcl = 1;
        };

        for (int i = 0; i < 8; ++i)
            tick();
        dut.reset = 0;
        for (int i = 0; i < 4; ++i)
            tick();

        dut.ioctl_download = 1;
        for (uint8_t b : bytes) {
            dut.ioctl_dout = b;
            dut.ioctl_wr = 1;
            tick();
            dut.ioctl_wr = 0;
            tick();
        }
        dut.ioctl_download = 0;
        dut.ioctl_wr = 0;

        const uint64_t deadline = cycle + 2000000;
        while (cycle < deadline) {
            tick();
            const bool countsDone = dut.nalu_count >= minNals && dut.sps_count >= 1 && dut.pps_count >= 1 &&
                                    dut.idr_count >= 1 && dut.slice_count >= minSlices;
            const bool parsedIAndP = sawI && sawP;
            const bool decodedIdr = placePulses >= 1 && sawExpectedCsum;
            const bool paintedSeveral = dut.stub_frames >= 2;
            if (countsDone && parsedIAndP && decodedIdr && idleBetweenVcl && paintedSeveral)
                break;
        }

        bool ok = true;
        auto expect = [&](bool cond, const char* msg) {
            if (!cond) {
                std::cerr << "FAIL multi-NAL stream_path: " << msg << "\n";
                ok = false;
            }
        };
        expect(dut.bytes_in == bytes.size(), "ioctl bytes_in did not match fixture size");
        expect(dut.nalu_count >= minNals, "expected minimum NALs through nalu_scanner");
        expect(dut.sps_count >= 1, "expected SPS count");
        expect(dut.pps_count >= 1, "expected PPS count");
        expect(dut.idr_count >= 1, "expected IDR count");
        expect(dut.slice_count >= minSlices, "expected P-slice count after IDR");
        expect(dut.sps_valid && dut.pps_valid, "SPS/PPS did not validate");
        expect(dut.sps_width == 320 && dut.sps_height == 240, "unexpected SPS geometry");
        expect(placePulses >= 1, "IDR residual ST_PLACE pulse missing");
        expect(sawExpectedCsum, "expected residual_csum was never observed");
        expect(cavlcDone >= 1, "product CAVLC luma source did not complete first I_NxN MB");
        expect(cavlcBadDone == 0, "product CAVLC luma source reported bad completion");
        expect(cavlcLumaPulses >= 16, "product CAVLC luma source did not emit 16 luma4x4 handoff pulses");
        expect((cavlcLumaMask & 0xffffu) == 0xffffu, "product CAVLC luma handoff did not cover all 16 block indices");
        expect(cavlcNonzeroTc > 0, "product CAVLC luma handoff saw no coded residual coefficients");
        expect(cavlcCbpNonzeroSeen, "product CAVLC first MB cbp_luma was zero during handoff");
        expect(cavlcLastQp >= 0, "product CAVLC luma handoff never published QP");
        expect(mbSyntaxRecords >= 2, "decode_core MB syntax handoff did not publish I and P records");
        expect(mbSyntaxINxN >= 1, "decode_core MB syntax handoff missed I_NxN record");
        expect(mbSyntaxP16 >= 1, "decode_core MB syntax handoff missed P_L0_16x16 record");
        expect(mbSyntaxUnsupported == 0, "decode_core MB syntax handoff flagged supported fixture unsupported");
        expect(mbSyntaxBadQp == 0, "decode_core MB syntax handoff published invalid QPy/QPc");
        expect(mbSyntaxBadCbp == 0, "decode_core MB syntax handoff published nonzero CBP for P_Skip");
        expect(sawI, "I-slice parse not observed");
        expect(idleBetweenVcl, "slice_hdr_parser ST_IDLE was not observed between IDR and P VCLs");
        expect(sawP, "P-slice parse not observed after IDR; parser did not prove idle/re-entry");
        if (minSlices >= 11) {
            expect(pFirstMbSeen == 11, "expected first P macroblock syntax for all 11 P slices");
            expect(pFirstMbMode0 == 8, "expected eight first-MB P_L0_16x16 slices");
            expect(pFirstMbMode1 == 2, "expected two first-MB P_L0_16x8 slices");
            expect(pFirstMbMode2 == 1, "expected one first-MB P_L0_8x16 slice");
            expect(pFirstMbBad == 0, "unexpected first P macroblock syntax/classification");
            expect(mbSyntaxRecords >= 12, "expected decode_core syntax records for IDR plus 11 P slices");
            expect(mbSyntaxP16 == 8, "expected eight decode_core P_L0_16x16 syntax records");
            expect(mbSyntaxP16x8 == 2, "expected two decode_core P_L0_16x8 syntax records");
            expect(mbSyntaxP8x16 == 1, "expected one decode_core P_L0_8x16 syntax record");
            expect(reconSig3bCycles > 0, "parsed P DPB/MC recon signature missing");
        }
        expect(dut.stub_frames >= 2, "decode_stub did not consume multiple VCL pulses");

        std::cout << "multi-NAL stream_path raw: bytes=" << bytes.size()
                  << " bytes_in=" << dut.bytes_in
                  << " bytes_seen=" << dut.bytes_seen
                  << " nalu=" << dut.nalu_count
                  << " sps=" << static_cast<int>(dut.sps_count)
                  << " pps=" << static_cast<int>(dut.pps_count)
                  << " idr=" << static_cast<int>(dut.idr_count)
                  << " slice=" << static_cast<int>(dut.slice_count)
                  << " place_pulses=" << placePulses
                  << " cavlc_luma_pulses=" << cavlcLumaPulses
                  << " cavlc_luma_mask=0x" << std::hex << cavlcLumaMask << std::dec
                  << " cavlc_done=" << cavlcDone
                  << " cavlc_bad_done=" << cavlcBadDone
                  << " cavlc_nonzero_tc=" << cavlcNonzeroTc
                  << " cavlc_cbp_nonzero_seen=" << cavlcCbpNonzeroSeen
                  << " cavlc_qp=" << cavlcLastQp
                  << " cavlc_cbp_luma_seen=0x" << std::hex << cavlcCbpLumaSeen
                  << " cavlc_cbp_chroma_seen=0x" << cavlcCbpChromaSeen
                  << " i4_modes_0_7_15=" << std::dec
                  << cavlcI4Mode0 << "/" << cavlcI4Mode7 << "/" << cavlcI4Mode15
                  << " mb_syntax_records=" << mbSyntaxRecords
                  << " mb_syntax_classes_i/p16/p16x8/p8x16="
                  << mbSyntaxINxN << "/" << mbSyntaxP16 << "/" << mbSyntaxP16x8 << "/" << mbSyntaxP8x16
                  << " mb_syntax_unsupported=" << mbSyntaxUnsupported
                  << " mb_syntax_bad_qp=" << mbSyntaxBadQp
                  << " mb_syntax_bad_cbp=" << mbSyntaxBadCbp
                  << " saw_expected_csum=" << sawExpectedCsum
                  << " recon_sig_3b_cycles=" << reconSig3bCycles
                  << " frames=" << dut.stub_frames
                  << " saw_i=" << sawI
                  << " idle_between_vcl=" << idleBetweenVcl
                  << " saw_p=" << sawP
                  << " p_first_mb_seen=" << pFirstMbSeen
                  << " p_first_modes=" << pFirstMbMode0 << "/" << pFirstMbMode1 << "/" << pFirstMbMode2
                  << " p_first_bad=" << pFirstMbBad
                  << " slice_parser_state=" << static_cast<int>(dut.slice_parser_state)
                  << " final_slice_type=" << static_cast<int>(dut.slice_type)
                  << " final_p_skip_run=" << static_cast<int>(dut.p_skip_run)
                  << " final_first_mb_type=" << static_cast<int>(dut.first_mb_type)
                  << " final_first_part_mode=" << static_cast<int>(dut.first_mb_part_mode)
                  << " expect_csum=0x" << std::hex << expectCsum
                  << " residual_csum=0x" << static_cast<int>(static_cast<uint8_t>(dut.residual_csum))
                  << std::dec << " cycles=" << cycle << "\n";
        if (!ok)
            return 1;
        if (reconSig3bCycles == 0) {
            std::cout << "test_h264_multinal_stream_path: OK fixture exposes current RED "
                         "class (IDR->P re-entry works, residual csum observed, recon 0x3b absent)\n";
        } else {
            std::cout << "test_h264_multinal_stream_path: OK fixture exercises GREEN class "
                         "(IDR->P re-entry plus recon 0x3b observed)\n";
        }
        return 0;
    } catch (const std::exception& e) {
        std::cerr << "FAIL multi-NAL stream_path: " << e.what() << "\n";
        return 1;
    }
}
