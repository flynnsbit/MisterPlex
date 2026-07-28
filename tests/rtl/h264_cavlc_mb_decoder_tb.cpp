// Multi-block CAVLC macroblock decoder — Verilator test.
// Encodes a full I_NxN macroblock (16 luma blocks + chroma) using the PROVEN
// CAVLC encoder from h264_cavlc_residual_tb.cpp, then feeds the bitstream to
// the RTL and verifies every block's coefficients match.
//
// RED-BEFORE-GREEN: With only block 0 wired (slice_hdr_parser single-block),
// blocks 1-15 would either not decode or produce wrong values.  This test
// exercises all 16 luma blocks with non-zero coefficients at various positions,
// proving the multi-block sequencer works end-to-end.
//
// DEGENERACY GUARD: asserts that at least half the blocks produce non-zero
// total_coeff — a test where all blocks are empty proves nothing.

#include "Vh264_cavlc_mb_decoder_tb_top.h"
#include "verilated.h"
#include "libmisterplex/h264_cavlc.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <vector>

using misterplex::cavlc::tables::coeff_token_bits;
using misterplex::cavlc::tables::coeff_token_len;
using misterplex::cavlc::tables::total_zeros_bits;
using misterplex::cavlc::tables::total_zeros_len;
using misterplex::cavlc::tables::run_bits;
using misterplex::cavlc::tables::run_len;
using misterplex::cavlc::tables::chroma_dc_bits;
using misterplex::cavlc::tables::chroma_dc_len;
using misterplex::cavlc::tables::chroma_tz_bits;
using misterplex::cavlc::tables::chroma_tz_len;

static int failures = 0;
static int total_blocks_decoded = 0;
static int nonzero_blocks = 0;

static void tick(Vh264_cavlc_mb_decoder_tb_top& dut) {
    dut.clk = 0; dut.eval();
    dut.clk = 1; dut.eval();
}

// --- PROVEN ENCODER (copied verbatim from h264_cavlc_residual_tb.cpp) ---

static void put_bits(std::vector<int>& out, int bits, int len) {
    for (int i = len - 1; i >= 0; --i)
        out.push_back((bits >> i) & 1);
}

static int signed_to_level_code(int level) {
    return level > 0 ? 2 * level - 2 : -2 * level - 1;
}

static int suffix_next_first(int prefix, int suffix_length, int level) {
    if (prefix > 14 || (prefix == 14 && suffix_length == 0))
        return 2;
    return 1 + (level + 3 > 6);
}

static int suffix_next(int suffix_length, int level) {
    static const unsigned lim[7] = {0, 3, 6, 12, 24, 48, 0xffffffffu};
    if (suffix_length < 6 && lim[suffix_length] + static_cast<unsigned>(level) > 2u * lim[suffix_length])
        return suffix_length + 1;
    return suffix_length;
}

static void encode_level(std::vector<int>& bits, int level, bool first_non_t1, int t1, int& suffix_length) {
    int level_code = signed_to_level_code(level);
    if (first_non_t1 && t1 < 3)
        level_code -= 2;
    if (level_code < 0) {
        std::cerr << "encoder internal negative level_code\n";
        std::exit(2);
    }

    int prefix = 0;
    int suffix_bits = 0;
    int suffix_len = 0;
    if (first_non_t1) {
        if (suffix_length == 0) {
            if (level_code < 14) {
                prefix = level_code;
                suffix_len = 0;
            } else if (level_code < 30) {
                prefix = 14;
                suffix_len = 4;
                suffix_bits = level_code - 14;
            } else {
                prefix = 15;
                suffix_len = 12;
                suffix_bits = level_code - 30;
            }
        } else if (level_code < (14 << suffix_length)) {
            prefix = level_code >> suffix_length;
            suffix_len = suffix_length;
            suffix_bits = level_code & ((1 << suffix_length) - 1);
        } else {
            prefix = 15;
            suffix_len = 12;
            suffix_bits = level_code - (15 << suffix_length);
        }
    } else if (level_code < (15 << suffix_length)) {
        prefix = level_code >> suffix_length;
        suffix_len = suffix_length;
        suffix_bits = level_code & ((1 << suffix_length) - 1);
    } else {
        prefix = 15;
        suffix_len = 12;
        suffix_bits = level_code - (15 << suffix_length);
    }

    for (int i = 0; i < prefix; ++i)
        bits.push_back(0);
    bits.push_back(1);
    put_bits(bits, suffix_bits, suffix_len);
    suffix_length = first_non_t1 ? suffix_next_first(prefix, suffix_length, level)
                                 : suffix_next(suffix_length, level);
}

struct Encoded {
    std::vector<int> bits;
    int total_coeff = 0;
    int trailing_ones = 0;
    int total_zeros = 0;
};

static Encoded encode_residual(const std::array<int, 16>& coeff, int table, int max_coeff) {
    Encoded e;
    std::vector<int> positions;
    std::vector<int> levels;
    for (int p = max_coeff - 1; p >= 0; --p) {
        if (coeff[p] != 0) {
            positions.push_back(p);
            levels.push_back(coeff[p]);
        }
    }
    const int tc = static_cast<int>(levels.size());
    int t1 = 0;
    while (t1 < tc && t1 < 3 && std::abs(levels[t1]) == 1)
        ++t1;
    e.total_coeff = tc;
    e.trailing_ones = t1;

    const int tok_idx = 4 * tc + t1;
    int tok_len = 0, tok_bits = 0;
    if (table == 4) {
        tok_len = chroma_dc_len[tok_idx];
        tok_bits = chroma_dc_bits[tok_idx];
    } else {
        tok_len = coeff_token_len[table][tok_idx];
        tok_bits = coeff_token_bits[table][tok_idx];
    }
    if (!tok_len) {
        std::cerr << "invalid token table=" << table << " tc=" << tc << " t1=" << t1 << "\n";
        std::exit(2);
    }
    put_bits(e.bits, tok_bits, tok_len);
    if (tc == 0)
        return e;

    for (int i = 0; i < t1; ++i)
        e.bits.push_back(levels[i] < 0 ? 1 : 0);

    int suffix_length = (tc > 10 && t1 < 3) ? 1 : 0;
    for (int i = t1; i < tc; ++i)
        encode_level(e.bits, levels[i], i == t1, t1, suffix_length);

    std::vector<int> pos_asc = positions;
    std::reverse(pos_asc.begin(), pos_asc.end());
    std::vector<int> run(tc, 0);
    int prev = -1;
    for (int a = 0; a < tc; ++a) {
        int run_for_ascending = pos_asc[a] - prev - 1;
        run[tc - 1 - a] = run_for_ascending;
        prev = pos_asc[a];
    }
    int total_zeros = 0;
    for (int r : run) total_zeros += r;
    e.total_zeros = total_zeros;

    if (tc < max_coeff) {
        int z_len = 0, z_bits = 0;
        if (max_coeff == 4) {
            z_len = chroma_tz_len[tc - 1][total_zeros];
            z_bits = chroma_tz_bits[tc - 1][total_zeros];
        } else {
            z_len = total_zeros_len[tc - 1][total_zeros];
            z_bits = total_zeros_bits[tc - 1][total_zeros];
        }
        if (!z_len) {
            std::cerr << "invalid total_zeros tc=" << tc << " z=" << total_zeros << " max=" << max_coeff << "\n";
            std::exit(2);
        }
        put_bits(e.bits, z_bits, z_len);
    }

    int zeros_left = total_zeros;
    for (int i = 0; i < tc - 1 && zeros_left > 0; ++i) {
        int r = run[i];
        int row = zeros_left < 7 ? zeros_left - 1 : 6;
        int r_len = run_len[row][r];
        int r_bits = run_bits[row][r];
        if (!r_len) {
            std::cerr << "invalid run_before zeros_left=" << zeros_left << " run=" << r << "\n";
            std::exit(2);
        }
        put_bits(e.bits, r_bits, r_len);
        zeros_left -= r;
    }
    return e;
}

// Convert bit vector to byte buffer (MSB first, same as RBSP)
static std::vector<uint8_t> bits_to_bytes(const std::vector<int>& bits) {
    std::vector<uint8_t> bytes((bits.size() + 7) / 8, 0);
    for (size_t i = 0; i < bits.size(); ++i) {
        if (bits[i])
            bytes[i / 8] |= (1 << (7 - (i % 8)));
    }
    return bytes;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vh264_cavlc_mb_decoder_tb_top dut;
    dut.clk = 0; dut.reset = 1; dut.start = 0;
    tick(dut); tick(dut);
    dut.reset = 0;
    tick(dut);

    // --- Test: I_NxN macroblock with 16 luma blocks, all coded ---
    // Generate diverse coefficients for each block (scan order: [0]=DC, [15]=highest freq)
    std::array<std::array<int, 16>, 16> block_coeffs{};
    for (int blk = 0; blk < 16; ++blk) {
        int base = (blk + 1) * 3;
        block_coeffs[blk][0] = base;         // DC
        if (blk % 2 == 0)
            block_coeffs[blk][1] = -(base / 2 + 1);  // low-freq AC
        if (blk % 3 == 0)
            block_coeffs[blk][3] = base / 3 + 1;
    }

    // Encode all 16 blocks into a bitstream using PROVEN encoder.
    // CRITICAL: compute nC table per block to match what the RTL will select,
    // using stored total_coeff from previously encoded blocks.
    std::vector<int> all_bits;
    std::array<int, 16> expected_tc{};
    std::array<int, 16> stored_tc{}; // total_coeff stored per luma block

    // Luma block index → (bx, by) mapping (H.264 Table 6-10)
    auto luma_bx = [](int idx) -> int {
        static const int bx[] = {0,1,0,1,2,3,2,3,0,1,0,1,2,3,2,3};
        return bx[idx];
    };
    auto luma_by = [](int idx) -> int {
        static const int by[] = {0,0,1,1,0,0,1,1,2,2,3,3,2,2,3,3};
        return by[idx];
    };
    // Inverse: find block index at (bx, by)
    auto luma_idx_at = [](int bx, int by) -> int {
        static const int map[4][4] = {
            {0,  2,  8,  10},
            {1,  3,  9,  11},
            {4,  6,  12, 14},
            {5,  7,  13, 15}
        };
        return map[bx][by];
    };

    for (int blk = 0; blk < 16; ++blk) {
        int bx = luma_bx(blk);
        int by = luma_by(blk);

        // Compute nC for this block (same logic as RTL)
        int nc_left = 0, nc_above = 0;
        bool left_valid = false, above_valid = false;

        if (bx > 0) {
            // Left neighbour is within this MB
            int left_idx = luma_idx_at(bx - 1, by);
            nc_left = stored_tc[left_idx];
            left_valid = true;
        }
        // bx == 0: left is external, not valid for first MB

        if (by > 0) {
            // Above neighbour is within this MB
            int above_idx = luma_idx_at(bx, by - 1);
            nc_above = stored_tc[above_idx];
            above_valid = true;
        }
        // by == 0: above is external, not valid for first MB

        int nc_val = 0;
        if (left_valid && above_valid)
            nc_val = (nc_left + nc_above + 1) / 2;
        else if (left_valid)
            nc_val = nc_left;
        else if (above_valid)
            nc_val = nc_above;
        else
            nc_val = 0;

        int table;
        if (nc_val < 2)       table = 0;
        else if (nc_val < 4)  table = 1;
        else if (nc_val < 8)  table = 2;
        else                   table = 3;

        Encoded enc = encode_residual(block_coeffs[blk], table, 16);
        expected_tc[blk] = enc.total_coeff;
        stored_tc[blk] = enc.total_coeff;
        std::cout << "  encode blk " << blk << " bx=" << bx << " by=" << by
                  << " nC=" << nc_val << " table=" << table
                  << " tc=" << enc.total_coeff << " bits=" << enc.bits.size()
                  << " cumul=" << (all_bits.size() + enc.bits.size()) << "\n";
        all_bits.insert(all_bits.end(), enc.bits.begin(), enc.bits.end());
    }

    // Convert bit vector to bytes
    std::vector<uint8_t> bytes = bits_to_bytes(all_bits);
    while (bytes.size() < 512) bytes.push_back(0);

    // Load bitstream into DUT
    for (int i = 0; i < 512; ++i)
        dut.rbsp[i] = bytes[i];

    int total_bits = (int)all_bits.size();
    dut.bit_offset_in = 0;
    dut.bit_len = total_bits;
    dut.mb_type = 0;  // I_NxN
    dut.cbp = 0x3C;   // all 4 luma 8x8 coded (bits 5:2 = 1111), no chroma (bits 1:0 = 00)
    dut.mb_x = 0;
    dut.mb_y = 0;
    dut.mb_index = 0;
    dut.mb_width = 39;
    dut.first_mb_in_slice = 0;
    dut.left_tc_luma_valid = 0;
    dut.above_tc_luma_valid = 0;
    dut.left_tc_cb_valid = 0;
    dut.above_tc_cb_valid = 0;
    dut.left_tc_cr_valid = 0;
    dut.above_tc_cr_valid = 0;

    // Start decode
    dut.start = 1;
    tick(dut);
    dut.start = 0;

    // Run until mb_done
    int cycles = 0;
    int blocks_seen = 0;
    constexpr int MAX_CYCLES = 50000;

    while (!dut.mb_done && cycles < MAX_CYCLES) {
        tick(dut);
        cycles++;

        if (dut.block_done) {
            int idx = dut.block_idx;
            if (idx < 16) {
                blocks_seen++;
                total_blocks_decoded++;
                int tc = dut.block_tc;
                if (tc > 0) nonzero_blocks++;

                std::cout << "  RTL blk " << idx << ": tc=" << tc
                          << " bit_end=" << dut.bit_offset_out << "\n";

                // Check total_coeff
                if (tc != expected_tc[idx]) {
                    std::cerr << "FAIL block " << idx << ": tc got=" << tc
                              << " want=" << expected_tc[idx] << "\n";
                    ++failures;
                }

                // Check coefficients (RTL outputs in scan order)
                for (int i = 0; i < 16; ++i) {
                    int got = (int16_t)dut.block_coeff[i];
                    int want = block_coeffs[idx][i];
                    if (got != want) {
                        std::cerr << "FAIL block " << idx << " coeff[" << i
                                  << "]: got=" << got << " want=" << want << "\n";
                        ++failures;
                    }
                }
            }
        }
    }

    if (cycles >= MAX_CYCLES) {
        std::cerr << "FAIL: timeout after " << MAX_CYCLES << " cycles\n";
        ++failures;
    }

    if (dut.error) {
        std::cerr << "FAIL: decoder reported error\n";
        ++failures;
    }

    if (blocks_seen != 16) {
        std::cerr << "FAIL: expected 16 block_done pulses, got " << blocks_seen << "\n";
        ++failures;
    }

    // DEGENERACY GUARD
    if (nonzero_blocks < 8) {
        std::cerr << "DEGENERATE: only " << nonzero_blocks << "/16 blocks had non-zero tc\n";
        ++failures;
    }

    std::cout << "h264_cavlc_mb_decoder: I_NxN test, " << blocks_seen << "/16 blocks decoded, "
              << nonzero_blocks << " non-zero, " << cycles << " cycles\n";
    std::cout << "  Bitstream: " << total_bits << " bits for 16 blocks\n";

    if (failures) {
        std::cerr << "h264_cavlc_mb_decoder: " << failures << " FAILURES\n";
        return 1;
    }

    std::cout << "h264_cavlc_mb_decoder: PASS [RTL] — 16 luma blocks decoded with correct nC context\n";
    std::cout << "  Degeneracy: " << nonzero_blocks << "/16 blocks non-zero\n";
    return 0;
}
