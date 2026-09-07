#include "Vh264_cavlc_residual_tb_top.h"
#include "verilated.h"
#include "libmisterplex/h264_cavlc.hpp"

#include <array>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <tuple>
#include <vector>

using misterplex::cavlc::tables::coeff_token_bits;
using misterplex::cavlc::tables::coeff_token_len;
using misterplex::cavlc::tables::chroma_dc_bits;
using misterplex::cavlc::tables::chroma_dc_len;
using misterplex::cavlc::tables::chroma_tz_bits;
using misterplex::cavlc::tables::chroma_tz_len;
using misterplex::cavlc::tables::run_bits;
using misterplex::cavlc::tables::run_len;
using misterplex::cavlc::tables::total_zeros_bits;
using misterplex::cavlc::tables::total_zeros_len;

struct Encoded {
    std::vector<int> bits;
    int total_coeff = 0;
    int trailing_ones = 0;
    int total_zeros = 0;
};

static int failures = 0;
static uint64_t cycle_ticks = 0;
static std::ofstream cycle_trace;

static void tick(Vh264_cavlc_residual_tb_top& dut) {
    dut.clk = 0;
    dut.eval();
    dut.clk = 1;
    dut.eval();
    ++cycle_ticks;
    if (cycle_trace.is_open()) {
        const std::array<uint16_t, 7> status{
            dut.busy, dut.done, dut.ok, dut.bit_offset_end,
            dut.total_coeff, dut.trailing_ones, dut.total_zeros};
        cycle_trace.write(reinterpret_cast<const char*>(status.data()), sizeof(status));
        for (int i = 0; i < 16; ++i) {
            const std::array<uint16_t, 3> values{dut.coeff[i], dut.level_dbg[i], dut.run_dbg[i]};
            cycle_trace.write(reinterpret_cast<const char*>(values.data()), sizeof(values));
        }
        if (!cycle_trace) {
            std::cerr << "FAIL writing CAVLC cycle trace\n";
            std::exit(1);
        }
    }
    if (!dut.datapath_equivalent) {
        std::cerr << "FAIL factored window/placement differs from reference equations\n";
        std::exit(1);
    }
}

static int sx16(int v) {
    v &= 0xffff;
    return (v & 0x8000) ? (v - 0x10000) : v;
}

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
    // Match host residualBlock: unsigned(level+3) > 6 (not signed compare).
    return 1 + (static_cast<unsigned>(level + 3) > 6u);
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
    for (; prefix <= 31; ++prefix) {
        suffix_len = prefix == 14 && suffix_length == 0 ? 4 :
                     prefix >= 15 ? prefix - 3 : suffix_length;
        int base = (std::min(prefix, 15) << suffix_length);
        if (prefix >= 15 && suffix_length == 0) base += 15;
        if (prefix >= 16) base += (1 << (prefix - 3)) - 4096;
        suffix_bits = level_code - base;
        if (suffix_bits >= 0 && suffix_bits < (1 << suffix_len)) break;
    }
    if (prefix > 31) std::abort();

    for (int i = 0; i < prefix; ++i)
        bits.push_back(0);
    bits.push_back(1);
    put_bits(bits, suffix_bits, suffix_len);
    suffix_length = first_non_t1 ? suffix_next_first(prefix, suffix_length, level)
                                 : suffix_next(suffix_length, level);
}

#ifndef CAVLC_TIMING_BASELINE
static void check_timing_helpers(Vh264_cavlc_residual_tb_top& dut) {
    unsigned clz_checks = 0, suffix_checks = 0, conversion_checks = 0;
    for (uint32_t low = 0; low < 131072; ++low) {
        for (uint32_t code : {low, low | 0xfffe0000u}) {
            const uint16_t magnitude = uint16_t((code + 2u) >> 1);
            const uint16_t expected = (code & 1) ? uint16_t(0u-magnitude) : magnitude;
            dut.probe_level_code = code;
            dut.eval();
            if (dut.probe_level != expected) {
                std::cerr << "FAIL signed level conversion code=" << code << "\n";
                std::exit(1);
            }
            ++conversion_checks;
        }
    }
    for (uint32_t value = 0; value < 65536; ++value) {
        for (uint32_t word : {value, value << 16, (value << 16) | (value ^ 0xffffu)}) {
            int expected = 0;
            for (uint32_t mask = 0x80000000u; mask && !(word & mask); mask >>= 1)
                ++expected;
            dut.probe_window = word;
            dut.eval();
            if (dut.probe_prefix != expected) {
                std::cerr << "FAIL balanced clz word=" << word << "\n";
                std::exit(1);
            }
            ++clz_checks;
        }
    }
    // Exhaust every signed16 nonzero level and reachable suffix-length context,
    // comparing prefix-only feedback with the existing signed-level encoder.
    for (int first = 0; first <= 1; ++first) {
        for (int sl = 0; sl <= (first ? 1 : 6); ++sl) {
            for (int t1 = 0; t1 <= (first ? 3 : 0); ++t1) {
                for (int level = -32768; level <= 32767; ++level) {
                    if (level == 0 || (first && t1 < 3 && std::abs(level) == 1)) continue;
                    std::vector<int> bits;
                    int expected = sl;
                    encode_level(bits, level, first != 0, t1, expected);
                    uint32_t word = 0;
                    for (size_t i = 0; i < bits.size() && i < 32; ++i)
                        word |= uint32_t(bits[i]) << (31-i);
                    dut.probe_window = word;
                    dut.probe_suffix_length = sl;
                    dut.probe_t1 = t1;
                    dut.eval();
                    const int got = first ? dut.probe_suffix_first : dut.probe_suffix_next;
                    if (got != expected) {
                        std::cerr << "FAIL prefix suffix feedback first=" << first
                                  << " sl=" << sl << " t1=" << t1 << " level=" << level
                                  << " prefix=" << int(dut.probe_prefix)
                                  << " got=" << got << " expected=" << expected << "\n";
                        std::exit(1);
                    }
                    ++suffix_checks;
                }
            }
        }
    }
    std::cout << "CAVLC timing helpers PASS conversion_checks=" << conversion_checks
              << " clz_checks=" << clz_checks
              << " signed16_suffix_checks=" << suffix_checks << "\n";
}
#endif

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

static std::array<int, 16> make_coeff(int tc, int t1, int total_zeros, int max_coeff, const std::vector<int>& run_override = {}) {
    std::array<int, 16> coeff{};
    if (tc == 0)
        return coeff;
    std::vector<int> run(tc, 0);
    if (!run_override.empty()) {
        run = run_override;
    } else {
        run[tc - 1] = total_zeros;
    }
    std::vector<int> levels(tc, 0);
    for (int i = 0; i < tc; ++i) {
        if (i < t1)
            levels[i] = (i & 1) ? -1 : 1;
        else
            levels[i] = (i & 1) ? -(2 + i) : (2 + i);
    }
    int coeff_num = -1;
    for (int i = tc - 1; i >= 0; --i) {
        coeff_num += run[i] + 1;
        if (coeff_num < 0 || coeff_num >= max_coeff) {
            std::cerr << "bad synthetic coeff position\n";
            std::exit(2);
        }
        coeff[coeff_num] = levels[i];
    }
    return coeff;
}

static std::vector<uint8_t> pack_bits(const std::vector<int>& bits) {
    std::vector<uint8_t> bytes((bits.size() + 7) / 8, 0);
    for (size_t i = 0; i < bits.size(); ++i)
        if (bits[i]) bytes[i / 8] |= uint8_t(1u << (7 - (i & 7)));
    return bytes;
}

static void run_case(Vh264_cavlc_residual_tb_top& dut, const char* name, const std::array<int, 16>& coeff, int table, int max_coeff, int start_offset=-1) {
    static unsigned offset_sequence=0;
    const int offset=start_offset<0 ? offset_sequence++%64 : start_offset;
    Encoded enc = encode_residual(coeff, table, max_coeff);
    auto bytes = pack_bits(enc.bits);
    misterplex::detail::BitReader oracle_bits(bytes.data(), bytes.size());
    const int oracle_nc[] = {0, 2, 4, 8, -1};
    const auto oracle = misterplex::cavlc::residualBlock(oracle_bits, oracle_nc[table], max_coeff);
    if (!oracle.ok || oracle_bits.bit != enc.bits.size()) {
        std::cerr << "independent host oracle rejected " << name << "\n";
        ++failures;
    }
    auto shifted=enc.bits;
    shifted.insert(shifted.begin(),offset,0);
    bytes=pack_bits(shifted);
    if (bytes.size() > 128) {
        std::cerr << "case too large " << name << "\n";
        std::exit(2);
    }
    for (int i = 0; i < 128; ++i)
        dut.rbsp[i] = (i < static_cast<int>(bytes.size())) ? bytes[i] : 0;
    dut.coeff_token_table = table;
    dut.max_coeff = max_coeff;
    dut.bit_offset_start = offset;
    dut.bit_len = static_cast<int>(enc.bits.size()) + offset;
    dut.start = 1;
    tick(dut);
    dut.start = 0;
    int guard = 1000;
    while (!dut.done && guard-- > 0)
        tick(dut);
    if (guard <= 0) {
        std::cerr << "timeout " << name << "\n";
        ++failures;
        return;
    }
    bool bad = false;
    if (!dut.ok || dut.total_coeff != enc.total_coeff || dut.trailing_ones != enc.trailing_ones ||
        dut.total_zeros != enc.total_zeros || dut.bit_offset_end != enc.bits.size()+offset) {
        bad = true;
    }
    for (int i = 0; i < 16; ++i) {
        if (sx16(dut.coeff[i]) != coeff[i] || oracle.coeff[i] != coeff[i])
            bad = true;
    }
    std::vector<int> positions;
    for (int i = max_coeff-1; i >= 0; --i) if (coeff[i]) positions.push_back(i);
    for (size_t i = 0; i < positions.size(); ++i) {
        const int next = i+1 < positions.size() ? positions[i+1] : -1;
        if (sx16(dut.level_dbg[i]) != coeff[positions[i]] ||
            dut.run_dbg[i] != positions[i]-next-1) bad = true;
    }
    if (bad) {
        std::cerr << "FAIL " << name << " table=" << table << " max=" << max_coeff
                  << " ok=" << int(dut.ok) << " tc=" << int(dut.total_coeff) << "/" << enc.total_coeff
                  << " t1=" << int(dut.trailing_ones) << "/" << enc.trailing_ones
                  << " tz=" << int(dut.total_zeros) << "/" << enc.total_zeros
                  << " bits=" << int(dut.bit_offset_end) << "/" << enc.bits.size()+offset << " coeff=";
        for (int i = 0; i < 16; ++i)
            std::cerr << ' ' << sx16(dut.coeff[i]) << '(' << coeff[i] << ')';
        std::cerr << "\n";
        ++failures;
    }
}

static void malformed(Vh264_cavlc_residual_tb_top& dut, const std::vector<int>& bits,
                      int length, int table, int maxc, const char* name) {
    const auto bytes = pack_bits(bits);
    for (int i = 0; i < 128; ++i) dut.rbsp[i] = i < int(bytes.size()) ? bytes[i] : 0;
    dut.coeff_token_table = table; dut.max_coeff = maxc;
    dut.bit_offset_start = 0; dut.bit_len = length;
    dut.start = 1; tick(dut); dut.start = 0;
    int timeout = 1000;
    while (!dut.done && --timeout) tick(dut);
    if (!timeout || dut.ok) {
        std::cerr << "malformed accepted/hung " << name << " bits=" << length << "\n";
        ++failures;
    }
    tick(dut);
}

static void check_reset_cancellation(Vh264_cavlc_residual_tb_top& dut) {
    const int prior_failures = failures;
    std::array<int, 16> c{};
    c[0] = -32768; c[2] = 32767; c[4] = -35; c[7] = 49;
    c[9] = -9; c[12] = -3; c[14] = 1; c[15] = -1;
    const auto encoded = encode_residual(c, 0, 16);
    const auto bytes = pack_bits(encoded.bits);
    int cancelled = 0;
    for (int delay = 0; delay < 128; ++delay) {
        for (int i = 0; i < 128; ++i) dut.rbsp[i] = i < int(bytes.size()) ? bytes[i] : 0;
        dut.coeff_token_table = 0; dut.max_coeff = 16;
        dut.bit_offset_start = 0; dut.bit_len = encoded.bits.size();
        dut.start = 1; tick(dut); dut.start = 0;
        for (int i = 0; i < delay && !dut.done; ++i) tick(dut);
        if (dut.done) {
            if (!dut.ok) ++failures;
            std::cout << "CAVLC reset cancellation "
                      << (failures == prior_failures ? "PASS" : "FAIL")
                      << " interrupted_cycles=" << cancelled << "\n";
            return;
        }
        dut.reset = 1; dut.start = 1; tick(dut);
        dut.reset = 0; dut.start = 0;
        for (int i = 0; i < 4; ++i) {
            if (dut.busy || dut.done || dut.ok || dut.bit_offset_end != 0) ++failures;
            for (int k = 0; k < 16; ++k)
                if (dut.coeff[k] || dut.level_dbg[k] || dut.run_dbg[k]) ++failures;
            tick(dut);
        }
        ++cancelled;
        run_case(dut, "reset-recovery", c, 0, 16, 0);
    }
    std::cerr << "FAIL reset-cancellation block did not terminate\n";
    ++failures;
}

struct Code { int len; int bits; std::string sym; };

static void validate_prefix_free(const std::string& name, const std::vector<Code>& codes) {
    std::set<std::pair<int,int>> seen;
    for (const auto& c : codes) {
        if (!seen.insert({c.len, c.bits}).second) {
            std::cerr << "duplicate VLC code in " << name << " len=" << c.len << " bits=" << c.bits << "\n";
            ++failures;
        }
    }
    for (size_t i = 0; i < codes.size(); ++i) {
        for (size_t j = 0; j < codes.size(); ++j) {
            if (i == j) continue;
            const auto& a = codes[i];
            const auto& b = codes[j];
            if (a.len <= b.len && (b.bits >> (b.len - a.len)) == a.bits) {
                std::cerr << "prefix violation " << name << ": " << a.sym << " prefixes " << b.sym << "\n";
                ++failures;
            }
        }
    }
}

static void validate_tables(Vh264_cavlc_residual_tb_top& dut) {
    for (int tab = 0; tab < 4; ++tab) {
        std::vector<Code> codes;
        for (int idx = 0; idx < 68; ++idx)
            if (coeff_token_len[tab][idx]) codes.push_back({coeff_token_len[tab][idx], coeff_token_bits[tab][idx], std::to_string(idx)});
        validate_prefix_free("coeff_token_" + std::to_string(tab), codes);
    }
    {
        std::array<int, 16> c{};
        c[0] = -32768; c[7] = 32767; c[14] = -4;
        const auto enc = encode_residual(c, 0, 15);
        for (int cut = 0; cut < int(enc.bits.size()); ++cut)
            malformed(dut, enc.bits, cut, 0, 15, "each truncated prefix");
        malformed(dut, {1}, 1, 5, 16, "invalid table");
        malformed(dut, {1}, 1, 0, 14, "invalid max_coeff");
        malformed(dut, {1}, 1025, 0, 16, "window overflow");
        std::array<int, 16> illegal{};
        illegal[15] = 1;
        const auto extra = encode_residual(illegal, 0, 16);
        malformed(dut, extra.bits, extra.bits.size(), 0, 15, "max15 forbids position15");
        illegal.fill(0); illegal[0] = 32768;
        const auto positive_overflow = encode_residual(illegal, 0, 16);
        malformed(dut, positive_overflow.bits, positive_overflow.bits.size(), 0, 16, "signed16 positive overflow");
        for (int slot = 0; slot < 3; ++slot) {
            for (int value : {-32769, 32768}) {
                illegal.fill(0);
                illegal[0] = 4; illegal[1] = -6; illegal[2] = 8;
                illegal[2-slot] = value;
                const auto overflow = encode_residual(illegal, 0, 16);
                malformed(dut, overflow.bits, overflow.bits.size(), 0, 16,
                          "signed16 overflow in each speculative slot");
            }
        }
    }
    {
        std::vector<Code> codes;
        for (int idx = 0; idx < 20; ++idx)
            if (chroma_dc_len[idx]) codes.push_back({chroma_dc_len[idx], chroma_dc_bits[idx], std::to_string(idx)});
        validate_prefix_free("coeff_token_chroma_dc", codes);
    }
    for (int tc = 1; tc <= 15; ++tc) {
        std::vector<Code> codes;
        for (int z = 0; z <= 16 - tc; ++z)
            if (total_zeros_len[tc - 1][z]) codes.push_back({total_zeros_len[tc - 1][z], total_zeros_bits[tc - 1][z], std::to_string(z)});
        validate_prefix_free("total_zeros_" + std::to_string(tc), codes);
    }
    for (int tc = 1; tc <= 3; ++tc) {
        std::vector<Code> codes;
        for (int z = 0; z <= 4 - tc; ++z)
            if (chroma_tz_len[tc - 1][z]) codes.push_back({chroma_tz_len[tc - 1][z], chroma_tz_bits[tc - 1][z], std::to_string(z)});
        validate_prefix_free("chroma_total_zeros_" + std::to_string(tc), codes);
    }
    for (int zl = 1; zl <= 7; ++zl) {
        std::vector<Code> codes;
        int row = zl < 7 ? zl - 1 : 6;
        int n = zl < 7 ? zl + 1 : 15;
        for (int r = 0; r < n; ++r)
            if (run_len[row][r]) codes.push_back({run_len[row][r], run_bits[row][r], std::to_string(r)});
        validate_prefix_free("run_before_" + std::to_string(zl), codes);
    }
}

static void check_nc(Vh264_cavlc_residual_tb_top& dut, const char* name, int mbx, int mby, int mb_index, int mbw,
                     int first, int bx, int by, bool lv, int ltc, bool uv, int utc,
                     bool exp_a, bool exp_b, int exp_nc, int exp_tab) {
    dut.nc_mb_x = mbx; dut.nc_mb_y = mby; dut.nc_mb_index = mb_index; dut.nc_mb_width = mbw;
    dut.nc_first_mb_in_slice = first; dut.nc_block_x = bx; dut.nc_block_y = by;
    dut.nc_left_tc_valid = lv; dut.nc_left_tc = ltc; dut.nc_up_tc_valid = uv; dut.nc_up_tc = utc;
    dut.eval();
    if (dut.nc_nA_available != exp_a || dut.nc_nB_available != exp_b || dut.nc_nC != exp_nc || dut.nc_coeff_token_table != exp_tab) {
        std::cerr << "NC FAIL " << name << " got avail=" << int(dut.nc_nA_available) << ',' << int(dut.nc_nB_available)
                  << " nC=" << int(dut.nc_nC) << " tab=" << int(dut.nc_coeff_token_table)
                  << " expected avail=" << exp_a << ',' << exp_b << " nC=" << exp_nc << " tab=" << exp_tab << "\n";
        ++failures;
    }
}

static void check_inline_helpers(Vh264_cavlc_residual_tb_top& dut) {
    uint64_t checked = 0;
    for (unsigned prefix = 0; prefix <= 17; ++prefix) {
        for (unsigned sl = 0; sl < 8; ++sl) {
            const unsigned bits = prefix == 14 && sl == 0 ? 4 : prefix < 15 ? sl : prefix - 3;
            const unsigned consumed = prefix + 1 + bits;
            const unsigned tail = 32 - consumed;
            const uint32_t tailMask = (uint32_t{1} << tail) - 1;
            for (uint32_t suffix = 0; suffix < (uint32_t{1} << bits); ++suffix) {
                for (unsigned first = 0; first < 2; ++first) {
                    for (unsigned t1 : {0u, 3u}) {
                        uint32_t expected = ((prefix < 15 ? prefix : 15) << sl) + suffix;
                        if (prefix >= 15 && sl == 0) expected += 15;
                        if (prefix >= 16) expected += (uint32_t{1} << (prefix - 3)) - 4096;
                        if (first && t1 < 3) expected += 2;
                        for (uint32_t trailing : {uint32_t{0}, tailMask}) {
                            dut.probe_window = (uint32_t{1} << (31 - prefix)) |
                                               (suffix << tail) | trailing;
                            dut.probe_suffix_length = sl;
                            dut.probe_suffix_bits = bits;
                            dut.probe_consumed = consumed;
                            dut.probe_first = first;
                            dut.probe_t1 = t1;
                            dut.eval();
                            if (dut.probe_inline_suffix != suffix || dut.probe_inline_code != expected) {
                                std::cerr << "FAIL inline suffix/code prefix=" << prefix << " sl=" << sl
                                          << " suffix=" << suffix << " first=" << first << " t1=" << t1 << "\n";
                                ++failures;
                                return;
                            }
                            ++checked;
                        }
                    }
                }
            }
        }
    }
    std::cout << "CAVLC inline helpers PASS combinations=" << checked << "\n";
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (const char* path = std::getenv("CAVLC_TIMING_TRACE")) {
        cycle_trace.open(path, std::ios::binary);
        if (!cycle_trace) {
            std::cerr << "FAIL opening CAVLC cycle trace " << path << "\n";
            return 1;
        }
    }
    Vh264_cavlc_residual_tb_top dut;
    dut.clk = 0; dut.reset = 1; dut.start = 0;
    tick(dut);
    dut.reset = 0;
#ifndef CAVLC_TIMING_BASELINE
    check_timing_helpers(dut);
    check_inline_helpers(dut);
#endif
    validate_tables(dut);

    check_nc(dut, "mb0-none", 0,0,0,39,0,0,0,false,0,false,0,false,false,0,0);
    check_nc(dut, "intra-mb-left", 0,0,0,39,0,1,0,true,5,false,0,true,false,5,2);
    check_nc(dut, "row0-left-mb", 1,0,1,39,0,0,0,true,3,false,0,true,false,3,1);
    check_nc(dut, "col0-up-mb", 0,1,39,39,0,0,0,false,0,true,4,false,true,4,2);
    check_nc(dut, "both-average", 2,2,80,39,0,0,0,true,3,true,4,true,true,4,2);
    check_nc(dut, "slice-start-blocked", 1,1,40,39,40,0,0,true,7,true,8,false,false,0,0);
    check_nc(dut, "slice-start-internal", 1,1,40,39,40,1,1,true,7,true,8,true,true,8,3);
    check_nc(dut, "both-full16", 2,2,80,39,0,0,0,true,16,true,16,true,true,16,3);
    check_nc(dut, "full15-plus16", 2,2,80,39,0,0,0,true,15,true,16,true,true,16,3);

    int cases = 0;
    for (int tab = 0; tab < 4; ++tab) {
        for (int tc = 0; tc <= 16; ++tc) {
            for (int t1 = 0; t1 <= 3; ++t1) {
                if (t1 > tc || coeff_token_len[tab][4 * tc + t1] == 0) continue;
                auto c = make_coeff(tc, t1, 0, 16);
                run_case(dut, "coeff_token", c, tab, 16);
                ++cases;
            }
        }
    }
    for (int tc = 0; tc <= 4; ++tc) {
        for (int t1 = 0; t1 <= 3; ++t1) {
            if (t1 > tc || chroma_dc_len[4 * tc + t1] == 0) continue;
            auto c = make_coeff(tc, t1, 0, 4);
            run_case(dut, "chroma_coeff_token", c, 4, 4);
            ++cases;
        }
    }
    for (int tc = 1; tc <= 15; ++tc) {
        int t1 = std::min(3, tc);
        for (int z = 0; z <= 16 - tc; ++z) {
            auto c = make_coeff(tc, t1, z, 16);
            run_case(dut, "total_zeros", c, 0, 16);
            ++cases;
        }
    }
    for (int tc = 1; tc <= 3; ++tc) {
        int t1 = std::min(3, tc);
        for (int z = 0; z <= 4 - tc; ++z) {
            auto c = make_coeff(tc, t1, z, 4);
            run_case(dut, "chroma_total_zeros", c, 4, 4);
            ++cases;
        }
    }
    for (int z = 1; z <= 14; ++z) {
        for (int r = 0; r <= z; ++r) {
            std::vector<int> runs = {r, z - r};
            auto c = make_coeff(2, 0, z, 16, runs);
            run_case(dut, "run_before", c, 0, 16);
            ++cases;
        }
    }
    {
        std::array<int, 16> c{};
        int vals[] = {300, -301, 255, -256, 64, -33, 17, -8, 4, -2, 1, -1};
        for (int i = 0; i < 12; ++i) c[i] = vals[i];
        run_case(dut, "large_suffix_gt9bit", c, 0, 16);
        ++cases;
    }
    for (int maxc : {4, 15, 16}) {
        std::array<int, 16> dense{};
        for (int k=0;k<maxc;++k) dense[k] = k%2 ? -32768 : 32767;
        run_case(dut, "dense-full_signed16", dense, maxc==4?4:3, maxc);
        ++cases;
        for (int value : {-32768, -4097, -256, -15, -4, 4, 15, 256, 4097, 32767}) {
            std::array<int, 16> c{};
            c[maxc - 1] = value;
            run_case(dut, "full_signed16_tail", c, maxc == 4 ? 4 : 0, maxc);
            ++cases;
        }
        {
            std::array<int,16> c{};
            run_case(dut,"window-final-bit",c,0,16,1023);
            c[15]=-32768;
            run_case(dut,"window-upper-half",c,0,16,900);
            cases+=2;
        }
    }
    for (int tab = 0; tab < 4; ++tab) {
        for (int tc = 0; tc <= 15; ++tc) {
            auto c = make_coeff(tc, std::min(tc, 3), tc ? 15-tc : 0, 15);
            run_case(dut, "max15-ac", c, tab, 15);
            ++cases;
        }
    }
    {
        std::array<int,16> c{};
        c[0]=13000; c[7]=-13000; c[15]=13000;
        // Three prefix17/suffix14 levels consume the full96-bit lookahead.
        const auto enc=encode_residual(c,0,16);
        for (int offset=0;offset<64;++offset) {
            run_case(dut,"three32bit-levels-word-boundary",c,0,16,448+offset);
            ++cases;
        }
        for (int cut=0;cut<int(enc.bits.size());++cut)
            malformed(dut,enc.bits,cut,0,16,"truncated speculative level group");
    }

    check_reset_cancellation(dut);
    if (cycle_trace.is_open()) {
        cycle_trace.close();
        if (!cycle_trace) {
            std::cerr << "FAIL closing CAVLC cycle trace\n";
            return 1;
        }
    }
    if (failures) {
        std::cerr << "H264 CAVLC residual RTL FAILED failures=" << failures << " cases=" << cases << "\n";
        return 1;
    }
    std::cout << "H264 CAVLC residual Verilator PASS: prefix-free tables checked; roundtrip_cases="
              << cases << " cycle_ticks=" << cycle_ticks
              << " including all coeff_token tables, luma/chroma total_zeros, run_before, nC edges, suffix escalation\n";
    return 0;
}
